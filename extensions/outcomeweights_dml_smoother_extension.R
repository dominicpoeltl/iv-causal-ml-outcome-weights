# outcomeweights_dml_smoother_extension.R
#
# Adapted from the DML-with-smoother implementation in:
# Knaus, M. C. OutcomeWeights
# https://github.com/MCKnaus/OutcomeWeights
#
# Original file/path in the package structure:
# OutcomeWeights/R/dml_with_smoother.R
#
# Most of the implementation structure in this file is due to the original
# OutcomeWeights package. For this course project, we added a small number of
# project-specific lines to implement additional LATT/LATU estimators derived
# in the accompanying analysis.
#
# This adapted file is included solely to make the public repository
# reproducible and to document the exact analysis workflow used for the
# rendered results and figures.

#' Double ML estimators with outcome smoothers
#'
#' Existing Double ML implementations are too general to easily extract smoother matrices
#' required to be compatible with the get_forest_weights() method. This motivates yet 
#' another Double ML implementation.
#'
#' @param Y Numeric vector containing the outcome variable.
#' @param D Optional binary treatment variable.
#' @param X Covariate matrix with N rows and p columns.
#' @param Z Optional binary instrumental variable.
#' @param estimators String (vector) indicating which estimators should be run.
#' Current menu: c("PLR","PLR_IV","AIPW_ATE","Wald_AIPW","AIPW_ATT","AIPW_ATU","Wald_AIPW_LATT","Wald_AIPW_LATU").
#' @param smoother Indicate which smoother to be used for nuisance parameter estimation.
#' Currently only available option \code{"honest_forest"} from the \pkg{grf} package.
#' @param n_cf_folds Number of cross-fitting folds. Default is 5.
#' @param n_reps Number of repetitions of cross-fitting. Default is 1.
#' @param ... Options to be passed to smoothers.
#' 
#' @return A list with three entries:
#' - \code{results}: a list storing the results, influence functions, and score functions of each estimator
#' - \code{NuPa.hat}: a list storing the estimated nuisance parameters and the outcome smoother matrices
#' 
#' @examples
#' \donttest{
#' # Sample from DGP borrowed from grf documentation
#' n = 200
#' p = 5
#' X = matrix(rbinom(n * p, 1, 0.5), n, p)
#' Z = rbinom(n, 1, 0.5)
#' Q = rbinom(n, 1, 0.5)
#' W = Q * Z
#' tau =  X[, 1] / 2
#' Y = rowSums(X[, 1:3]) + tau * W + Q + rnorm(n)
#' 
#' # Run outcome regression and extract smoother matrix
#' # Run DML and look at results
#' dml = dml_with_smoother(Y,W,X,Z)
#' results_dml = summary(dml)
#' plot(dml)
#' 
#' # Get weights
#' omega_dml = get_outcome_weights(dml)
#' 
#' # Observe that they perfectly replicate the original estimates
#' all.equal(as.numeric(omega_dml$omega %*% Y), 
#'           as.numeric(as.numeric(results_dml[,1])))
#'
#' # The weights can then be passed to the cobalt package for example.
#' }
#' 
#' @references 
#' Chernozhukov, V., Chetverikov, D., Demirer, M., Duflo, E., Hansen, C., Newey, W., & Robins, J. (2018). 
#' Double/debiased machine learning for treatment and structural parameters. The Econometrics Journal, 21(1), C1-C68.
#'     
#' Knaus, M. C. (2024). Treatment effect estimators as weighted outcomes, \url{https://arxiv.org/abs/2411.11559}.
#'      
#' @export
#' 
dml_with_smoother = function(Y,D,X,Z=NULL,
                             estimators = c("PLR","PLR_IV","AIPW_ATE","Wald_AIPW","AIPW_ATT","AIPW_ATU","Wald_AIPW_LATT","Wald_AIPW_LATU"),
                             smoother = "honest_forest", 
                             n_cf_folds = 5,
                             n_reps=1,
                             ...) {
  # Sanity checks
  supported_estimators = c("PLR","PLR_IV","AIPW_ATE","Wald_AIPW","AIPW_ATT","AIPW_ATU","Wald_AIPW_LATT","Wald_AIPW_LATU")
  not_supported = estimators[!estimators %in% supported_estimators]
  if (length(not_supported) > 0) {
    stop(paste("Error: The following specified estimators are not supported:", 
               paste(not_supported, collapse = ", ")))}
  supported_smoothers = c("honest_forest")
  not_supported = smoother[!smoother %in% supported_smoothers]
  if (length(not_supported) > 0) {
    stop(paste("Error: The following specified smoothers are not supported:", 
               paste(not_supported, collapse = ", ")))}
  if (any(c("PLR_IV", "Wald_AIPW", "Wald_AIPW_LATT","Wald_AIPW_LATU") %in% estimators) && is.null(Z)) {
    stop("Error: Z cannot be NULL when using either 'PLR_IV', 'Wald_AIPW', 'Wald_AIPW_LATT' or 'Wald_AIPW_LATU' as an estimator.")
  }
  
  # Extract useful information
  N = length(Y)
  n_estimators = length(estimators)
  
  # Find required NuPas
  NuPa = character(0)
  if ("PLR" %in% estimators) NuPa = c(NuPa, "Y.hat", "D.hat")
  if ("PLR_IV" %in% estimators) NuPa = c(NuPa, "Y.hat", "D.hat", "Z.hat")
  if ("AIPW_ATE" %in% estimators) NuPa = c(NuPa, "Y.hat.d", "D.hat")
  if ("Wald_AIPW" %in% estimators) NuPa = c(NuPa, "Y.hat.z", "D.hat.z", "Z.hat")
  if ("AIPW_ATT" %in% estimators) NuPa = c(NuPa, "Y.hat.d", "D.hat")
  if ("AIPW_ATU" %in% estimators) NuPa = c(NuPa, "Y.hat.d", "D.hat")
  if ("Wald_AIPW" %in% estimators) NuPa = c(NuPa, "Y.hat.z", "D.hat.z", "Z.hat")
  if ("Wald_AIPW_LATT" %in% estimators) NuPa = c(NuPa, "Y.hat.z", "D.hat.z", "Z.hat")
  if ("Wald_AIPW_LATU" %in% estimators) NuPa = c(NuPa, "Y.hat.z", "D.hat.z", "Z.hat")
  NuPa = unique(NuPa)
  
  # Estimate required nuisance parameters
  if (smoother == "honest_forest") {
  NuPa.hat = NuPa_honest_forest(NuPa = NuPa,
                             X,Y,D,Z,
                             n_cf_folds=n_cf_folds,
                             n_reps=n_reps,
                             ...) }
  
  # Intialize empty
  dml_plr = dml_PLR_IV = dml_AIPW_ATE = dml_Wald_AIPW = 
    dml_AIPW_ATT = dml_AIPW_ATU = dml_Wald_AIPW_LATT = dml_Wald_AIPW_LATU = "This estimator was not run."

  # Run the specified DML estimators
  if ("PLR" %in% estimators) {
    D.hat = NuPa.hat$predictions$D.hat
    Y.hat = NuPa.hat$predictions$Y.hat
    psi.a = -(D - D.hat)^2
    psi.b = (Y - Y.hat) * (D - D.hat)
    dml_plr = dml_inference(psi.a,psi.b)
  }
  if ("PLR_IV" %in% estimators) {
    D.hat = NuPa.hat$predictions$D.hat
    Y.hat = NuPa.hat$predictions$Y.hat
    Z.hat = NuPa.hat$predictions$Z.hat
    psi.a = -(D - D.hat) * (Z - Z.hat)
    psi.b = (Y - Y.hat) * (Z - Z.hat) 
    dml_PLR_IV = dml_inference(psi.a,psi.b)
  }
  if ("AIPW_ATE" %in% estimators) {
    D.hat = NuPa.hat$predictions$D.hat
    Y.hat.d0 = NuPa.hat$predictions$Y.hat.d0
    Y.hat.d1 = NuPa.hat$predictions$Y.hat.d1
    psi.a = matrix(-1,N,n_reps)
    psi.b = Y.hat.d1 - Y.hat.d0 + D * (Y - Y.hat.d1) / D.hat - (1 - D) * (Y - Y.hat.d0) / (1-D.hat)
    dml_AIPW_ATE = dml_inference(psi.a,psi.b)
  }
  if ("Wald_AIPW" %in% estimators) {
    Z.hat = NuPa.hat$predictions$Z.hat
    D.hat.z0 = NuPa.hat$predictions$D.hat.z0
    D.hat.z1 = NuPa.hat$predictions$D.hat.z1
    Y.hat.z0 = NuPa.hat$predictions$Y.hat.z0
    Y.hat.z1 = NuPa.hat$predictions$Y.hat.z1
    psi.a = -( D.hat.z1 - D.hat.z0 + Z * (D - D.hat.z1) / Z.hat - (1 - Z) * (D - D.hat.z0) / (1-Z.hat) )
    psi.b = Y.hat.z1 - Y.hat.z0 + Z * (Y - Y.hat.z1) / Z.hat - (1 - Z) * (Y - Y.hat.z0) / (1-Z.hat)
    dml_Wald_AIPW = dml_inference(psi.a,psi.b)
  }
  if ("AIPW_ATT" %in% estimators) {
    pi.hat =  mean(D)
    D.hat = NuPa.hat$predictions$D.hat 
    Y.hat.d0 = NuPa.hat$predictions$Y.hat.d0 
    psi.a = replicate(n_reps, - D / pi.hat) 
    psi.b = (D / pi.hat - (1 - D) * D.hat / (pi.hat * (1 - D.hat))) * (Y - Y.hat.d0)
    dml_AIPW_ATT = dml_inference(psi.a,psi.b)
  }
  if ("AIPW_ATU" %in% estimators) {
    pi.hat =  mean(D)
    D.hat = NuPa.hat$predictions$D.hat 
    Y.hat.d1 = NuPa.hat$predictions$Y.hat.d1
    psi.a = replicate(n_reps, - (1 - D) / (1 - pi.hat)) 
    psi.b = (D * (1 - D.hat) / ((1 - pi.hat) * D.hat) - (1 - D) / (1 - pi.hat)) * (Y - Y.hat.d1)
    dml_AIPW_ATU = dml_inference(psi.a,psi.b)
  }
  if ("Wald_AIPW_LATT" %in% estimators) {
    Z.hat = NuPa.hat$predictions$Z.hat
    D.hat.z0 = NuPa.hat$predictions$D.hat.z0
    Y.hat.z0 = NuPa.hat$predictions$Y.hat.z0
    psi.a = -(Z * (D - D.hat.z0) - (1 - Z) * Z.hat / (1 - Z.hat) * (D - D.hat.z0))
    psi.b = (Z * (Y - Y.hat.z0) - (1 - Z) * Z.hat / (1 - Z.hat) * (Y - Y.hat.z0))
    dml_Wald_AIPW_LATT = dml_inference(psi.a,psi.b)
  }
  if ("Wald_AIPW_LATU" %in% estimators) {
    Z.hat = NuPa.hat$predictions$Z.hat
    D.hat.z1 = NuPa.hat$predictions$D.hat.z1
    Y.hat.z1 = NuPa.hat$predictions$Y.hat.z1
    psi.a = -((Z * (1-Z.hat) / Z.hat) *  (D - D.hat.z1) - (1 - Z) * (D - D.hat.z1))
    psi.b = (Z * (1-Z.hat) / Z.hat) *  (Y - Y.hat.z1) - (1 - Z) * (Y - Y.hat.z1)
    dml_Wald_AIPW_LATU = dml_inference(psi.a,psi.b)
  }
  
  list_results = list(
    "PLR" = dml_plr,
    "PLR_IV" = dml_PLR_IV,
    "AIPW_ATE" = dml_AIPW_ATE,
    "Wald_AIPW" = dml_Wald_AIPW,
    "AIPW_ATT" = dml_AIPW_ATT,
    "AIPW_ATU" = dml_AIPW_ATU,
    "Wald_AIPW_LATT" = dml_Wald_AIPW_LATT,
    "Wald_AIPW_LATU" = dml_Wald_AIPW_LATU)

  list_data = list(
    "Y" = Y,
    "D" = D,
    "Z" = Z,
    "X" = X )
  
  list_nums = list(
    "N" = N,
    "n_estimators" = n_estimators,
    "n_reps" = n_reps,
    "n_cf_folds" = n_cf_folds
  )
  
  output = list("results" = list_results,
                "NuPa.hat" = NuPa.hat,
                "data" = list_data,
                "numbers" = list_nums)
  
  class(output) = c("dml_with_smoother")
  
  return(output)
}



#' Outcome weights for the \code{\link{dml_with_smoother}} function
#'
#' @description Post-estimation command to extract outcome weights for double ML
#' run with an outcome smoother.
#'
#' @param object An object of class \code{dml_with_smoother}, i.e. the result of running \code{\link{dml_with_smoother}}.
#' @param ... Pass potentially generic \link{get_outcome_weights} options.
#' @param all_reps If \code{TRUE}, outcomes weights of each repetitions passed. Default \code{FALSE}.
#'
#' @return 
#' - If \code{all_reps == FALSE}: \link{get_outcome_weights} object
#' - If \code{all_reps == TRUE}: additionally list \code{omega_all_reps}: 
#' A list containing the outcome weights of each repetition.
#'
#' @references 
#' Knaus, M. C. (2024). Treatment effect estimators as weighted outcomes, \url{https://arxiv.org/abs/2411.11559}.
#'
#' @export
#' 
get_outcome_weights.dml_with_smoother = function(object,..., 
                                                 all_reps = FALSE) {
  
  # Preps
  N = object$numbers$N
  n_reps = object$numbers$n_reps
  omega = estimator_names = NULL
  if (n_reps == 1) all_reps = FALSE
  
  # Go through those estimators called and extract their weights
  ### PLR ### 
  if (!is.character(object$results$PLR)) {
    Z.tilde = D.tilde = object$data$D - object$NuPa.hat$predictions$D.hat
    omega_plr = NULL
    for (r in 1:n_reps) {
      T_mat = diag(N) - object$NuPa.hat$smoothers$S[r,,]
      omega_plr = rbind(omega_plr, pive_weight_maker(Z.tilde[,r], D.tilde[,r], T_mat) )
    }
    if(isFALSE(all.equal(as.numeric(omega_plr %*% object$data$Y),
                         as.numeric(object$results$PLR$TaPa[,1])))){
      warning("Estimated PLR using weights differ from original estimates.") }
    estimator_names = c(estimator_names, "PLR") 
    omega = rbind(omega,colMeans(omega_plr))  }
  
  ### PLR-IV ### 
  if (!is.character(object$results$PLR_IV)){
    Z.tilde = object$data$Z - object$NuPa.hat$predictions$Z.hat
    D.tilde = object$data$D - object$NuPa.hat$predictions$D.hat
    omega_plriv = NULL
    for (r in 1:n_reps) {
      T_mat = diag(N) - object$NuPa.hat$smoothers$S[r,,]
      omega_plriv = rbind(omega_plriv, pive_weight_maker(Z.tilde[,r], D.tilde[,r], T_mat) )
    }
    if(isFALSE(all.equal(as.numeric(omega_plriv %*% object$data$Y),
                         as.numeric(object$results$PLR_IV$TaPa[,1])))){
      warning("Estimated PLR-IV using weights differ from original estimates.") }
    estimator_names = c(estimator_names, "PLR-IV") 
    omega = rbind(omega,colMeans(omega_plriv))  }
  
  ### AIPW_ATE ### 
  if (!is.character(object$results$AIPW_ATE)){
    Z.tilde = D.tilde = matrix(1,N,n_reps)
    lambda1 = object$data$D / object$NuPa.hat$predictions$D.hat
    lambda0 = (1 - object$data$D) / (1 - object$NuPa.hat$predictions$D.hat)
    omega_aipw = NULL
    for (r in 1:n_reps) {
      T_mat = object$NuPa.hat$smoothers$S.d1[r,,] - object$NuPa.hat$smoothers$S.d0[r,,] + 
        lambda1[,r] * (diag(N) - object$NuPa.hat$smoothers$S.d1[r,,]) - 
        lambda0[,r] * (diag(N) - object$NuPa.hat$smoothers$S.d0[r,,])
      omega_aipw = rbind(omega_aipw, pive_weight_maker(Z.tilde[,r], D.tilde[,r], T_mat) )
    }
    if(isFALSE(all.equal(as.numeric(omega_aipw %*% object$data$Y),
                         as.numeric(object$results$AIPW_ATE$TaPa[,1])))){
      warning("Estimated AIPW-ATE using weights differ from original estimates.") }
    estimator_names = c(estimator_names, "AIPW-ATE") 
    omega = rbind(omega,colMeans(omega_aipw))  }
  
  ### Wald_AIPW ### 
  if (!is.character(object$results$Wald_AIPW)){
    lambdaz1 = object$data$Z / object$NuPa.hat$predictions$Z.hat
    lambdaz0 = (1 - object$data$Z) / (1 - object$NuPa.hat$predictions$Z.hat)
    Z.tilde = matrix(1,N,n_reps)
    D.tilde = object$NuPa.hat$predictions$D.hat.z1 - object$NuPa.hat$predictions$D.hat.z0 + 
      lambdaz1 * (object$data$D - object$NuPa.hat$predictions$D.hat.z1) - 
      lambdaz0 * (object$data$D - object$NuPa.hat$predictions$D.hat.z0)
    omega_waipw = NULL
    for (r in 1:n_reps) {
      T_mat = object$NuPa.hat$smoothers$S.z1[r,,] - object$NuPa.hat$smoothers$S.z0[r,,] + 
        lambdaz1[,r] * (diag(N) - object$NuPa.hat$smoothers$S.z1[r,,]) - 
        lambdaz0[,r] * (diag(N) - object$NuPa.hat$smoothers$S.z0[r,,])
      omega_waipw = rbind(omega_waipw, pive_weight_maker(Z.tilde[,r], D.tilde[,r], T_mat) )
    }
    if(isFALSE(all.equal(as.numeric(omega_waipw %*% object$data$Y),
                         as.numeric(object$results$Wald_AIPW$TaPa[,1])))){
      warning("Estimated Wald-AIPW using weights differ from original estimates.") }
    estimator_names = c(estimator_names, "Wald-AIPW") 
    omega = rbind(omega,colMeans(omega_waipw))  }
  
  ### AIPW_ATT ### 
  if (!is.character(object$results$AIPW_ATT)){
    Z.tilde = matrix(1,N,n_reps)
    D.tilde = replicate(n_reps, object$data$D / mean(object$data$D)) 
    lambda1 = replicate(n_reps, object$data$D / mean(object$data$D)) 
    lambda0 = (1 - object$data$D) * object$NuPa.hat$predictions$D.hat / 
              ( (1 - object$NuPa.hat$predictions$D.hat) * mean(object$data$D) )
    omega_aipw_att = NULL
    for (r in 1:n_reps) {
      T_mat = (lambda1[,r] - lambda0[,r]) * (diag(N) - object$NuPa.hat$smoothers$S.d0[r,,])
      omega_aipw_att = rbind(omega_aipw_att, pive_weight_maker(Z.tilde[,r], D.tilde[,r], T_mat) )
    }
    if(isFALSE(all.equal(as.numeric(omega_aipw_att %*% object$data$Y),
                         as.numeric(object$results$AIPW_ATT$TaPa[,1])))){
      warning("Estimated AIPW-ATT using weights differ from original estimates.") }
    estimator_names = c(estimator_names, "AIPW-ATT") 
    omega = rbind(omega,colMeans(omega_aipw_att))  }
  
  ### AIPW_ATU ### 
  if (!is.character(object$results$AIPW_ATU)){
    Z.tilde = matrix(1,N,n_reps)
    D.tilde = replicate(n_reps, (1-object$data$D) / mean(1-object$data$D)) 
    lambda1 = object$data$D * (1-object$NuPa.hat$predictions$D.hat) / 
      ( object$NuPa.hat$predictions$D.hat * mean(1-object$data$D) )
    lambda0 = replicate(n_reps, (1-object$data$D) / mean(1-object$data$D)) 
    omega_aipw_atu = NULL
    for (r in 1:n_reps) {
      T_mat = (lambda1[,r] - lambda0[,r]) * (diag(N) - object$NuPa.hat$smoothers$S.d1[r,,])
      omega_aipw_atu = rbind(omega_aipw_atu, pive_weight_maker(Z.tilde[,r], D.tilde[,r], T_mat) )
    }
    if(isFALSE(all.equal(as.numeric(omega_aipw_atu %*% object$data$Y),
                         as.numeric(object$results$AIPW_ATU$TaPa[,1])))){
      warning("Estimated AIPW-ATU using weights differ from original estimates.") }
    estimator_names = c(estimator_names, "AIPW-ATU") 
    omega = rbind(omega,colMeans(omega_aipw_atu))  }
   
  ### Wald_AIPW_LATT ### 
  if (!is.character(object$results$Wald_AIPW_LATT)){
    Z.tilde = matrix(1,N,n_reps)
    lambdaz0 = (1 - object$data$Z) * object$NuPa.hat$predictions$Z.hat / (1 - object$NuPa.hat$predictions$Z.hat)
    D.tilde = (object$data$Z - lambdaz0) * (object$data$D - object$NuPa.hat$predictions$D.hat.z0)
    omega_waipw_latt = NULL
    for (r in 1:n_reps) {
      T_mat = (object$data$Z - lambdaz0[,r]) * (diag(N) - object$NuPa.hat$smoothers$S.z0[r,,])
      omega_waipw_latt = rbind(omega_waipw_latt, pive_weight_maker(Z.tilde[,r], D.tilde[,r], T_mat) )
    }
    if(isFALSE(all.equal(as.numeric(omega_waipw_latt %*% object$data$Y),
                         as.numeric(object$results$Wald_AIPW_LATT$TaPa[,1])))){
      warning("Estimated Wald-AIPW-LATT using weights differ from original estimates.") }
    estimator_names = c(estimator_names, "Wald-AIPW-LATT") 
    omega = rbind(omega,colMeans(omega_waipw_latt))  }
  
  ### Wald_AIPW_LATU ### 
  if (!is.character(object$results$Wald_AIPW_LATU)){
    Z.tilde = matrix(1,N,n_reps)
    lambdaz1 = object$data$Z * (1 - object$NuPa.hat$predictions$Z.hat) / object$NuPa.hat$predictions$Z.hat
    D.tilde = (lambdaz1 - (1 - object$data$Z)) * (object$data$D - object$NuPa.hat$predictions$D.hat.z1)
    omega_waipw_latu = NULL
    for (r in 1:n_reps) {
      T_mat = (lambdaz1[,r] - (1 - object$data$Z)) * (diag(N) - object$NuPa.hat$smoothers$S.z1[r,,])
      omega_waipw_latu = rbind(omega_waipw_latu, pive_weight_maker(Z.tilde[,r], D.tilde[,r], T_mat) )
    }
    if(isFALSE(all.equal(as.numeric(omega_waipw_latu %*% object$data$Y),
                         as.numeric(object$results$Wald_AIPW_LATU$TaPa[,1])))){
      warning("Estimated Wald-AIPW-LATU using weights differ from original estimates.") }
    estimator_names = c(estimator_names, "Wald-AIPW-LATU") 
    omega = rbind(omega,colMeans(omega_waipw_latu))  }

  rownames(omega) = estimator_names
  
  output = list(
    "omega" = omega,
    "treat" = object$data$D
  )
  
  if (all_reps) {
    list_all_weights = list(
      "PLR" = omega_plr,
      "PLR_IV" = omega_plriv,
      "AIPW_ATE" = omega_aipw,
      "Wald_AIPW" = omega_waipw,      
      "AIPW_ATT" = omega_aipw_att,
      "AIPW_ATU" = omega_aipw_atu,
      "Wald_AIPW_LATT" = omega_waipw_latt,
      "Wald_AIPW_LATU" = omega_waipw_latu

    )
    output$omega_all_reps = list_all_weights
  }

  class(output) = c("get_outcome_weights")
  
  return(output)
}
