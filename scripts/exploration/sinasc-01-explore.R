
# SINASC Exploration — Phase 2
# Goal: Map access paths, download minimum sample, compare formats (FTP .dbc
#       vs OpenDATASUS CSV), inventory volume, and identify artifacts.
#
# Outputs feed directly into docs/sinasc/exploration-pt.md (Phase 2 artifact).
#
# Run interactively in RStudio; results are printed to the console.
# Log key findings in exploration-pt.md as you go.
#
# Date: 2026-03-07

# ── Packages ──────────────────────────────────────────────────────────────────
if (!require("pacman")) install.packages("pacman")
pacman::p_load(
  read.dbc,   # read DATASUS .dbc files (requires installation from CRAN)
  foreign,    # read .dbf files (fallback)
  arrow,      # write Parquet
  dplyr,
  readr,
  fs,
  glue,
  curl,
  httr2,
  purrr,
  tibble,
  stringr
)

# Install read.dbc if not available (it is on CRAN)
if (!requireNamespace("read.dbc", quietly = TRUE)) {
  install.packages("read.dbc")
  library(read.dbc)
}

# ── Paths ─────────────────────────────────────────────────────────────────────
# IMPORTANT: Use a temp dir OUTSIDE OneDrive to avoid EPERM on deletion
DIR_TEMP <- "C:/Temp/sinasc-exploration"
fs::dir_create(DIR_TEMP)

# ── 1. MAP ACCESS PATHS ───────────────────────────────────────────────────────
# Two independent paths to SINASC data:
#
#   A) FTP DATASUS — .dbc files by UF x year
#      - DN{UF}{AAAA}.dbc  → NOV/DNRES/ (all years by place of residence)
#      Base: ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/
#
#      FTP root structure (confirmed 2026-03-07):
#        NOV/      → current data  → DNRES/ (734 files, 1996–2022, 29 UFs)
#        ANT/      → older data    → DNRES/ (109 files, includes 1994–1995)
#        PRELIM/   → preliminary   → DNRES/ (empty as of exploration date)
#        1994_1995/ and 1996_/ → legacy directories
#
#   B) OpenDATASUS (S3) — CSV files by year
#      Portal: https://opendatasus.saude.gov.br/dataset/sistema-de-informacao-sobre-nascidos-vivos-sinasc
#      Coverage: 1996–2025 (includes preliminary current year)
#      NOTE: S3 URLs returned HTTP 403 — access pattern TBD

cat("=== STEP 1: Verify FTP directory structure ===\n")

# List FTP root directory for SINASC
ftp_root <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/"
h <- curl::new_handle()
curl::handle_setopt(h, ftp_use_epsv = FALSE, dirlistonly = TRUE, connecttimeout = 30)
con <- curl::curl(ftp_root, handle = h)
ftp_result <- readLines(con)
close(con)
cat("FTP root contents:\n")
print(ftp_result)

# List the confirmed data directory: NOV/DNRES/
ftp_dnres <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/NOV/DNRES/"
h <- curl::new_handle()
curl::handle_setopt(h, ftp_use_epsv = FALSE, dirlistonly = TRUE, connecttimeout = 30)
con <- curl::curl(ftp_dnres, handle = h)
ftp_dnres_result <- readLines(con)
close(con)
cat("\nFTP NOV/DNRES directory contents (sample):\n")
print(head(ftp_dnres_result, 30))

# ── 2. DOWNLOAD MINIMUM SAMPLE FROM FTP ──────────────────────────────────────
cat("\n=== STEP 2: Download minimum sample from FTP (.dbc) ===\n")

# Start with a small UF for testing: DF (Distrito Federal)
# Pattern: DN{UF}{YEAR}.dbc — NOTE: extension case varies (.dbc vs .DBC)
# Most recent available year as of 2026-03-07: 2022 (2023 not yet on FTP)
sample_uf    <- "DF"
sample_year  <- "2022"
sample_fname <- glue::glue("DN{sample_uf}{sample_year}.dbc")
sample_url   <- glue::glue("ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/NOV/DNRES/{sample_fname}")
sample_path  <- file.path(DIR_TEMP, sample_fname)

cat(glue::glue("Downloading: {sample_url}\n"))
download_result <- tryCatch({
  curl::curl_download(
    url      = sample_url,
    destfile = sample_path,
    quiet    = FALSE
  )
  "success"
}, error = function(e) paste("Error:", e$message))
cat("Download result:", download_result, "\n")

# Read the .dbc file
if (file.exists(sample_path)) {
  cat("\nReading .dbc sample with read.dbc::read.dbc()...\n")
  df_sample <- tryCatch(
    read.dbc::read.dbc(sample_path),
    error = function(e) {
      cat("read.dbc error:", e$message, "\n")
      NULL
    }
  )
  
  if (!is.null(df_sample)) {
    cat(glue::glue("\nShape: {nrow(df_sample)} rows × {ncol(df_sample)} cols\n"))
    cat("\nColumn names:\n")
    print(names(df_sample))
    cat("\nData types:\n")
    print(sapply(df_sample, class))
    cat("\nFirst 3 rows:\n")
    print(head(df_sample, 3))
    cat("\nSummary of first 10 cols:\n")
    print(summary(df_sample[, 1:min(10, ncol(df_sample))]))
    cat("\nMissing values per column:\n")
    print(colSums(is.na(df_sample)))
  }
}

# ── 3. CHECK DNR (by residence) sample ───────────────────────────────────────
cat("\n=== STEP 3: Check DNR (by residence) sample ===\n")

# NOTE: DNR files (by residence) were NOT found in NOV/DNRES — all DN* files
# in NOV/DNRES appear to already represent residence-based data (DNRES naming).
# ANT/DNRES contains older/legacy files. No separate DNR prefix confirmed.
sample_dnr_fname <- glue::glue("DNR{sample_uf}{sample_year}.dbc")
sample_dnr_url   <- glue::glue("ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/NOV/DNRES/{sample_dnr_fname}")
sample_dnr_path  <- file.path(DIR_TEMP, sample_dnr_fname)

# Note: DNR may be in a different directory — check if it exists
dnr_result <- tryCatch({
  curl::curl_download(
    url      = sample_dnr_url,
    destfile = sample_dnr_path,
    quiet    = TRUE
  )
  "success"
}, error = function(e) paste("Not found or error:", e$message))
cat("DNR download:", dnr_result, "\n")

# ── 4. DOWNLOAD OPENDATASUS CSV SAMPLE ───────────────────────────────────────
cat("\n=== STEP 4: Download OpenDATASUS CSV sample ===\n")

# OpenDATASUS portal for SINASC — discover the S3 URL pattern
# Known pattern (to verify): similar to other DATASUS datasets on OpenDATASUS
opendatasus_url_2023 <- "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SINASC/sinasc_2023.csv"
csv_path <- file.path(DIR_TEMP, "sinasc_2023_sample.csv")

cat(glue::glue("Attempting OpenDATASUS CSV: {opendatasus_url_2023}\n"))

# First do a HEAD request to check existence and size
head_result <- tryCatch({
  resp <- httr2::request(opendatasus_url_2023) |>
    httr2::req_method("HEAD") |>
    httr2::req_perform()
  list(
    status  = httr2::resp_status(resp),
    size_mb = as.numeric(httr2::resp_header(resp, "content-length")) / 1e6,
    type    = httr2::resp_header(resp, "content-type")
  )
}, error = function(e) list(error = e$message))

cat("HEAD result:\n")
print(head_result)

# If found, download first 5000 lines only for structure inspection
if (!is.null(head_result$status) && head_result$status == 200) {
  con <- curl::curl(opendatasus_url_2023)
  csv_lines <- tryCatch({
    readLines(con, n = 100, encoding = "UTF-8")
  }, error = function(e) {
    # Try latin1
    readLines(curl::curl(opendatasus_url_2023), n = 100, encoding = "latin1")
  }, finally = close(con))
  
  cat("\nFirst 3 lines of CSV:\n")
  print(head(csv_lines, 3))
  cat(glue::glue("\nDetected encoding / delimiter probe: {csv_lines[1]}\n"))
}

# ── 5. COMPARE FORMATS ────────────────────────────────────────────────────────
cat("\n=== STEP 5: Compare FTP .dbc vs OpenDATASUS CSV structure ===\n")

# If both samples were successfully downloaded, compare column names
# This section is completed interactively after steps 2 and 4

# ── 6. INVENTORY VOLUME (FTP HEAD REQUESTS) ───────────────────────────────────
cat("\n=== STEP 6: Inventory FTP volume via directory listing ===\n")

# Get full file listing for NOV/DNRES directory (confirmed correct path)
h <- curl::new_handle()
curl::handle_setopt(h, ftp_use_epsv = FALSE, dirlistonly = TRUE, connecttimeout = 30)
con <- curl::curl(ftp_dnres, handle = h)
ftp_listing <- tryCatch({ lines <- readLines(con); close(con); lines }, error = function(e) character(0))

# Extract DN* files (occurrence-based)
dn_files <- ftp_listing[grepl("^DN[A-Z]{2}[0-9]{4}\\.dbc$", ftp_listing, ignore.case = TRUE)]
cat(glue::glue("\nDN (occurrence) files found: {length(dn_files)}\n"))

# Extract DNR* files (residence-based) — may be in same or different directory
dnr_files <- ftp_listing[grepl("^DNR[A-Z]{2}[0-9]{4}\\.dbc$", ftp_listing, ignore.case = TRUE)]
cat(glue::glue("DNR (residence) files found: {length(dnr_files)}\n"))

# Extract year range
if (length(dn_files) > 0) {
  years <- as.integer(str_extract(dn_files, "[0-9]{4}"))
  cat(glue::glue("Year range (DN): {min(years, na.rm=TRUE)}–{max(years, na.rm=TRUE)}\n"))
  cat("Files per UF (sample count):\n")
  uf_counts <- table(str_extract(dn_files, "(?<=DN)[A-Z]{2}"))
  print(uf_counts)
}

# ── 7. IDENTIFY ARTIFACTS ────────────────────────────────────────────────────
cat("\n=== STEP 7: Inspect for common artifacts ===\n")

if (exists("df_sample") && !is.null(df_sample)) {
  # Check for leading zeros lost in numeric columns
  # Key fields: CODMUNNASC (municipality code), CODESTAB (CNES), CODMUNRES
  cols_to_check <- c("CODMUNNASC", "CODMUNRES", "CODESTAB", "CODMUNNATU")
  
  for (col in intersect(cols_to_check, names(df_sample))) {
    vals <- as.character(df_sample[[col]])
    vals_nona <- vals[!is.na(vals) & vals != ""]
    if (length(vals_nona) > 0) {
      n_short <- sum(nchar(vals_nona) < 6, na.rm = TRUE)
      cat(glue::glue("  {col}: {length(vals_nona)} non-NA values; {n_short} with <6 chars (potential leading zero loss)\n"))
    }
  }
  
  # Check for float suffixes (common in CSV exports)
  # In .dbc this is less common but worth verifying
  char_cols <- names(df_sample)[sapply(df_sample, is.character)]
  float_pattern <- "\\.[0-9]+$"
  for (col in head(char_cols, 20)) {
    vals <- df_sample[[col]][!is.na(df_sample[[col]])]
    n_float <- sum(grepl(float_pattern, vals))
    if (n_float > 0) {
      cat(glue::glue("  {col}: {n_float} values with float suffix (e.g. '12.0')\n"))
    }
  }
  
  # Check encoding — look for corrupted accented characters
  cat("\nSample of character columns for encoding check:\n")
  char_sample_cols <- intersect(c("LOCNASC", "IDADEMAE", "ESCMAE", "GESTACAO"), names(df_sample))
  for (col in char_sample_cols) {
    cat(glue::glue("  {col}: {paste(head(unique(df_sample[[col]]), 5), collapse=', ')}\n"))
  }
}

# ── 8. CHECK OPENDATASUS PAGE FOR SINASC ─────────────────────────────────────
cat("\n=== STEP 8: Verify OpenDATASUS dataset page ===\n")

# Check if the portal page is accessible and extract dataset info
portal_url <- "https://opendatasus.saude.gov.br/dataset/sistema-de-informacao-sobre-nascidos-vivos-sinasc"
cat(glue::glue("Portal URL: {portal_url}\n"))
cat("(Open manually in browser to verify resource URLs and dictionary PDF)\n")

# Test a few likely S3 URL patterns
candidate_urls <- c(
  "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SINASC/sinasc_2023.csv",
  "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SINASC/2023/SINASC_2023.csv",
  "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SINASC/SINASC_2023.csv"
)

for (url in candidate_urls) {
  status <- tryCatch({
    resp <- httr2::request(url) |>
      httr2::req_method("HEAD") |>
      httr2::req_timeout(10) |>
      httr2::req_perform()
    glue::glue("HTTP {httr2::resp_status(resp)} — {round(as.numeric(httr2::resp_header(resp, 'content-length'))/1e6, 1)} MB")
  }, error = function(e) glue::glue("Error: {e$message}"))
  cat(glue::glue("  {url}\n    → {status}\n"))
}

# ── SESSION INFO ──────────────────────────────────────────────────────────────
cat("\n=== Session info ===\n")
sessionInfo()
