if (!requireNamespace("read.dbc", quietly = TRUE)) {
  if (!requireNamespace("remotes", quietly = TRUE)) {
    install.packages("remotes", repos = "https://cloud.r-project.org")
  }
  remotes::install_github("danicat/read.dbc")
}
cat("read.dbc version:", as.character(packageVersion("read.dbc")), "\n")
