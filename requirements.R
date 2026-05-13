# Minimal dependency setup for reproducing Assignment.Rmd.

required_packages <- c(
  "devtools",
  "rmarkdown",
  "knitr",
  "hdm",
  "grf",
  "cobalt",
  "tidyverse",
  "viridis",
  "gridExtra"
)

missing_packages <- setdiff(required_packages, rownames(installed.packages()))

if (length(missing_packages) > 0) {
  install.packages(missing_packages, dependencies = TRUE)
}

if (!dir.exists("OutcomeWeights")) {
  stop(
    "OutcomeWeights submodule not found. ",
    "Run: git submodule update --init --recursive"
  )
}

devtools::install_local("OutcomeWeights", force = TRUE)
