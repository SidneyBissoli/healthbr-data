# SIH Exploration — Phase 2
# Goal: Map FTP structure, download minimum sample of AIH Reduzida (RD) from
#       both eras (modern 2008+ and legacy 1992-2007), compare schemas,
#       inventory volume, and identify artifacts.
#
# Outputs feed directly into docs/sih/exploration-pt.md (Phase 2 artifact).
#
# Run interactively in RStudio; results are printed to the console.
# Log key findings in exploration-pt.md as you go.
#
# Date: 2026-03-08

# ── Packages ──────────────────────────────────────────────────────────────────
if (!require("pacman")) install.packages("pacman")
pacman::p_load(
  read.dbc,   # read DATASUS .dbc files
  foreign,    # read .dbf files (fallback)
  arrow,      # write/read Parquet
  dplyr,
  readr,
  fs,
  glue,
  curl,
  purrr,
  tibble,
  stringr
)

# ── Paths ─────────────────────────────────────────────────────────────────────
# IMPORTANT: Use a temp dir OUTSIDE OneDrive to avoid EPERM on deletion
DIR_TEMP <- "C:/Temp/sih-exploration"
fs::dir_create(DIR_TEMP)

# ── FTP PATHS ─────────────────────────────────────────────────────────────────
# SIH has TWO eras on FTP DATASUS:
#   Era moderna (2008–present): ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/200801_/Dados/
#   Era antiga  (1992–2007):    ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/199201_200712/Dados/
#
# File naming pattern: {TIPO}{UF}{AAMM}.dbc
#   TIPO: RD (AIH Reduzida), SP (Serv.Profissionais), RJ (Rejeitadas), ER (Erros)
#   UF:   2-letter state code (AC, AL, ..., TO)
#   AAMM: 2-digit year + 2-digit month (ex: 2107 = Jul 2021)
#
# SCOPE: Focus on RD (AIH Reduzida) — the primary research dataset

FTP_MODERN <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/200801_/Dados/"
FTP_LEGACY <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/199201_200712/Dados/"

# ── Helper: list FTP directory ────────────────────────────────────────────────
list_ftp <- function(ftp_url, timeout = 60) {
  h <- curl::new_handle()
  curl::handle_setopt(h, ftp_use_epsv = FALSE, dirlistonly = TRUE,
                      connecttimeout = timeout)
  con <- curl::curl(ftp_url, handle = h)
  result <- tryCatch({
    lines <- readLines(con)
    close(con)
    lines
  }, error = function(e) {
    tryCatch(close(con), error = function(x) NULL)
    character(0)
  })
  result
}

# ── Helper: download .dbc from FTP ───────────────────────────────────────────
download_dbc <- function(ftp_base, filename, dest_dir = DIR_TEMP,
                         timeout = 120, retries = 3) {
  url  <- paste0(ftp_base, filename)
  dest <- file.path(dest_dir, filename)
  
  for (attempt in seq_len(retries)) {
    result <- tryCatch({
      h <- curl::new_handle()
      curl::handle_setopt(h,
        connecttimeout  = 60,
        timeout         = timeout,
        low_speed_limit = 1000,
        low_speed_time  = 60
      )
      curl::curl_download(url, dest, handle = h, quiet = TRUE)
      "success"
    }, error = function(e) {
      if (attempt < retries) Sys.sleep(2 * attempt)
      paste("Error:", e$message)
    })
    if (result == "success") break
  }
  
  if (result == "success" && file.exists(dest)) {
    list(status = "ok", path = dest, size = file.size(dest))
  } else {
    list(status = "fail", error = result)
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: MAP FTP DIRECTORY STRUCTURE
# ══════════════════════════════════════════════════════════════════════════════
cat("=== STEP 1: Map FTP directory structure ===\n\n")

# 1a. List SIHSUS root
ftp_sih_root <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/"
cat("Listing SIHSUS root:", ftp_sih_root, "\n")
sih_root_contents <- list_ftp(ftp_sih_root)
cat("Root contents:\n")
print(sih_root_contents)

# 1b. List modern era data directory
cat("\nListing modern era data directory:\n")
modern_files <- list_ftp(FTP_MODERN)
cat(glue("Total files in modern era: {length(modern_files)}\n"))
cat("Sample (first 20):\n")
print(head(modern_files, 20))

# 1c. List legacy era data directory
cat("\nListing legacy era data directory:\n")
legacy_files <- list_ftp(FTP_LEGACY)
cat(glue("Total files in legacy era: {length(legacy_files)}\n"))
cat("Sample (first 20):\n")
print(head(legacy_files, 20))

# 1d. Classify files by type (RD, SP, RJ, ER)
classify_files <- function(files) {
  types <- c("RD", "SP", "RJ", "ER")
  counts <- sapply(types, function(t) {
    sum(grepl(paste0("^", t), files, ignore.case = TRUE))
  })
  other <- length(files) - sum(counts)
  c(counts, OTHER = other)
}

cat("\nModern era file types:\n")
print(classify_files(modern_files))

cat("\nLegacy era file types:\n")
print(classify_files(legacy_files))

# 1e. Extract RD files and analyze coverage
rd_modern <- modern_files[grepl("^RD", modern_files, ignore.case = TRUE)]
rd_legacy <- legacy_files[grepl("^RD", legacy_files, ignore.case = TRUE)]

cat(glue("\nRD files — Modern era: {length(rd_modern)}\n"))
cat(glue("RD files — Legacy era: {length(rd_legacy)}\n"))

# Extract UFs and year-month from RD files
parse_rd_files <- function(files) {
  # Pattern: RD{UF}{AAMM}.dbc — UF = 2 chars, AAMM = 4 digits
  pattern <- "^RD([A-Z]{2})([0-9]{4})\\.dbc$"
  matched <- files[grepl(pattern, files, ignore.case = TRUE)]
  
  uf   <- str_extract(matched, "(?<=^RD)[A-Z]{2}")
  aamm <- str_extract(matched, "[0-9]{4}(?=\\.dbc$)")
  yy   <- as.integer(substr(aamm, 1, 2))
  mm   <- as.integer(substr(aamm, 3, 4))
  
  # Convert 2-digit year to 4-digit
  year <- ifelse(yy >= 92, 1900L + yy, 2000L + yy)
  
  tibble(
    file = matched,
    uf   = uf,
    yy   = yy,
    mm   = mm,
    year = year,
    month = mm
  )
}

rd_modern_parsed <- parse_rd_files(rd_modern)
rd_legacy_parsed <- parse_rd_files(rd_legacy)

cat("\n--- Modern era RD coverage ---\n")
cat(glue("UFs: {length(unique(rd_modern_parsed$uf))}\n"))
cat(glue("Year range: {min(rd_modern_parsed$year)}-{max(rd_modern_parsed$year)}\n"))
cat(glue("Month range: {min(rd_modern_parsed$mm)}-{max(rd_modern_parsed$mm)}\n"))
cat("Files per year:\n")
print(table(rd_modern_parsed$year))
cat("\nUFs present:\n")
print(sort(unique(rd_modern_parsed$uf)))

cat("\n--- Legacy era RD coverage ---\n")
cat(glue("UFs: {length(unique(rd_legacy_parsed$uf))}\n"))
cat(glue("Year range: {min(rd_legacy_parsed$year)}-{max(rd_legacy_parsed$year)}\n"))
cat("Files per year:\n")
print(table(rd_legacy_parsed$year))
cat("\nUFs present:\n")
print(sort(unique(rd_legacy_parsed$uf)))

# 1f. Check for auxiliary/documentation directories
cat("\n--- Checking for auxiliary/docs directories ---\n")

# Check if there are Tabelas/Docs directories like in SINASC
aux_paths <- c(
  "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/200801_/Auxiliar/",
  "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/200801_/Doc/",
  "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/200801_/Tabelas/",
  "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/199201_200712/Auxiliar/",
  "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/199201_200712/Doc/",
  "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/199201_200712/Tabelas/"
)

for (aux_path in aux_paths) {
  cat(glue("\n{aux_path}\n"))
  contents <- list_ftp(aux_path, timeout = 15)
  if (length(contents) > 0) {
    cat(glue("  Found {length(contents)} items: "))
    cat(paste(head(contents, 10), collapse = ", "))
    if (length(contents) > 10) cat(glue(" ... (+{length(contents)-10} more)"))
    cat("\n")
  } else {
    cat("  Empty or inaccessible\n")
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: DOWNLOAD MINIMUM SAMPLE — RD FROM BOTH ERAS
# ══════════════════════════════════════════════════════════════════════════════
cat("\n\n=== STEP 2: Download minimum sample (RD from both eras) ===\n\n")

# Use DF (Distrito Federal) — small UF for testing
# Modern era: RDDF2301.dbc (Jan 2023) — recent, should have full schema
# Legacy era: RDDF0501.dbc (Jan 2005) — mid-era, expected schema
# Deep legacy: RDDF9501.dbc (Jan 1995) — early era

samples_to_download <- tibble(
  era    = c("modern",      "legacy_mid",   "legacy_early"),
  ftp    = c(FTP_MODERN,    FTP_LEGACY,     FTP_LEGACY),
  file   = c("RDDF2301.dbc", "RDDF0501.dbc", "RDDF9501.dbc"),
  label  = c("RD DF Jan/2023 (modern)", "RD DF Jan/2005 (legacy mid)",
             "RD DF Jan/1995 (legacy early)")
)

downloaded <- list()

for (i in seq_len(nrow(samples_to_download))) {
  row <- samples_to_download[i, ]
  cat(glue("Downloading: {row$label} ({row$file})...\n"))
  
  result <- download_dbc(row$ftp, row$file)
  
  if (result$status == "ok") {
    cat(glue("  OK — {round(result$size / 1024, 1)} KB\n"))
    downloaded[[row$era]] <- result$path
  } else {
    cat(glue("  FAILED: {result$error}\n"))
    # Try alternative years if file not found
    alt_files <- switch(row$era,
      "modern"       = c("RDDF2201.dbc", "RDDF2101.dbc"),
      "legacy_mid"   = c("RDDF0401.dbc", "RDDF0601.dbc"),
      "legacy_early" = c("RDDF9601.dbc", "RDDF9701.dbc"),
      character(0)
    )
    for (alt in alt_files) {
      cat(glue("  Trying alternative: {alt}...\n"))
      result2 <- download_dbc(row$ftp, alt)
      if (result2$status == "ok") {
        cat(glue("  OK — {round(result2$size / 1024, 1)} KB\n"))
        downloaded[[row$era]] <- result2$path
        break
      }
    }
  }
}

cat(glue("\nSuccessfully downloaded: {length(downloaded)} of {nrow(samples_to_download)}\n"))

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: READ AND INSPECT SAMPLES
# ══════════════════════════════════════════════════════════════════════════════
cat("\n\n=== STEP 3: Read and inspect samples ===\n\n")

sample_dfs <- list()

for (era_name in names(downloaded)) {
  fpath <- downloaded[[era_name]]
  cat(glue("\n--- Reading {era_name}: {basename(fpath)} ---\n"))
  
  df <- tryCatch(
    read.dbc::read.dbc(fpath),
    error = function(e) {
      cat(glue("read.dbc error: {e$message}\n"))
      NULL
    }
  )
  
  if (is.null(df)) next
  sample_dfs[[era_name]] <- df
  
  cat(glue("Shape: {nrow(df)} rows × {ncol(df)} cols\n\n"))
  
  # Column names
  cat("Column names:\n")
  cat(paste(names(df), collapse = " | "), "\n\n")
  
  # Data types
  cat("Data types:\n")
  types <- sapply(df, function(x) paste(class(x), collapse = "/"))
  type_tbl <- tibble(col = names(types), type = unname(types))
  print(type_tbl, n = Inf)
  
  # First 3 rows
  cat("\nFirst 3 rows (transposed for readability):\n")
  for (j in seq_len(min(3, nrow(df)))) {
    cat(glue("\n  Row {j}:\n"))
    for (col in names(df)) {
      val <- as.character(df[[col]][j])
      if (is.na(val)) val <- "<NA>"
      if (nchar(val) > 60) val <- paste0(substr(val, 1, 57), "...")
      cat(glue("    {col}: {val}\n"))
    }
  }
  
  # Unique values for low-cardinality columns
  cat("\nUnique value counts per column:\n")
  for (col in names(df)) {
    n_unique <- n_distinct(df[[col]], na.rm = TRUE)
    n_na     <- sum(is.na(df[[col]]))
    pct_na   <- round(n_na / nrow(df) * 100, 1)
    cat(glue("  {col}: {n_unique} unique, {n_na} NA ({pct_na}%)\n"))
    
    # Show values if few unique
    if (n_unique <= 20 && n_unique > 0) {
      vals <- sort(unique(as.character(df[[col]])))
      vals <- vals[!is.na(vals)]
      if (length(vals) > 0) {
        cat(glue("    Values: {paste(head(vals, 15), collapse=', ')}\n"))
      }
    }
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: COMPARE SCHEMAS ACROSS ERAS
# ══════════════════════════════════════════════════════════════════════════════
cat("\n\n=== STEP 4: Compare schemas across eras ===\n\n")

if (length(sample_dfs) >= 2) {
  era_names <- names(sample_dfs)
  
  # Column comparison
  all_cols <- unique(unlist(lapply(sample_dfs, names)))
  cat(glue("Total unique columns across all eras: {length(all_cols)}\n\n"))
  
  # Presence matrix
  presence <- sapply(sample_dfs, function(df) all_cols %in% names(df))
  rownames(presence) <- all_cols
  
  cat("Column presence by era (TRUE = present):\n")
  print(as.data.frame(presence))
  
  # Columns unique to each era
  for (era in era_names) {
    only_here <- all_cols[presence[, era] & !apply(presence[, setdiff(era_names, era), drop=FALSE], 1, any)]
    if (length(only_here) > 0) {
      cat(glue("\nColumns ONLY in {era}: {paste(only_here, collapse=', ')}\n"))
    }
  }
  
  # Common columns
  common <- all_cols[apply(presence, 1, all)]
  cat(glue("\nColumns in ALL eras ({length(common)}): {paste(common, collapse=', ')}\n"))
  
  # Type comparison for common columns
  cat("\nType comparison for common columns:\n")
  type_comp <- tibble(column = common)
  for (era in era_names) {
    type_comp[[era]] <- sapply(common, function(col) {
      paste(class(sample_dfs[[era]][[col]]), collapse = "/")
    })
  }
  print(type_comp, n = Inf)
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: IDENTIFY ARTIFACTS AND PROBLEMS
# ══════════════════════════════════════════════════════════════════════════════
cat("\n\n=== STEP 5: Identify artifacts and problems ===\n\n")

for (era_name in names(sample_dfs)) {
  df <- sample_dfs[[era_name]]
  cat(glue("\n--- Artifact check: {era_name} ---\n"))
  
  # 5a. Check key code fields for leading zero issues
  code_fields <- c("MUNIC_RES", "MUNIC_MOV", "CEP", "CNES", "CO_CIDADINTERNACAO",
                   "DIAG_PRINC", "DIAG_SECUN", "PROC_REA", "PROC_SOLIC",
                   "IDENT", "COMPLEX")
  
  present_codes <- intersect(code_fields, names(df))
  if (length(present_codes) > 0) {
    cat("Code field analysis (leading zeros, lengths):\n")
    for (col in present_codes) {
      vals <- as.character(df[[col]])
      vals <- vals[!is.na(vals) & vals != ""]
      if (length(vals) > 0) {
        lens <- nchar(vals)
        cat(glue("  {col}: lengths {min(lens)}-{max(lens)} (mean {round(mean(lens),1)}), ",
                 "{sum(lens < 6)} values with <6 chars, ",
                 "sample: {paste(head(unique(vals), 5), collapse=', ')}\n"))
      }
    }
  }
  
  # 5b. Check for float suffixes in character columns
  char_cols <- names(df)[sapply(df, is.character)]
  float_pattern <- "\\.[0-9]+$"
  float_issues <- character(0)
  for (col in char_cols) {
    vals <- df[[col]][!is.na(df[[col]])]
    n_float <- sum(grepl(float_pattern, vals))
    if (n_float > 0) {
      float_issues <- c(float_issues, glue("{col}: {n_float} values with float suffix"))
    }
  }
  if (length(float_issues) > 0) {
    cat("Float suffix issues:\n")
    cat(paste("  ", float_issues, collapse = "\n"), "\n")
  } else {
    cat("No float suffix issues detected (expected for .dbc)\n")
  }
  
  # 5c. Check encoding in character fields
  cat("Encoding check (sample character values):\n")
  for (col in head(char_cols, 5)) {
    vals <- unique(df[[col]][!is.na(df[[col]])])
    cat(glue("  {col}: {paste(head(vals, 5), collapse=' | ')}\n"))
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: CHECK FOR SP, RJ, ER TYPES (brief)
# ══════════════════════════════════════════════════════════════════════════════
cat("\n\n=== STEP 6: Brief check of SP, RJ, ER types ===\n\n")

# Download one SP file from modern era to see column count
sp_sample <- download_dbc(FTP_MODERN, "SPDF2301.dbc")
if (sp_sample$status == "ok") {
  df_sp <- tryCatch(read.dbc::read.dbc(sp_sample$path), error = function(e) NULL)
  if (!is.null(df_sp)) {
    cat(glue("SP (Serv.Profissionais): {nrow(df_sp)} rows × {ncol(df_sp)} cols\n"))
    cat(glue("  Columns: {paste(names(df_sp), collapse=' | ')}\n\n"))
  }
}

# Download one RJ file
rj_sample <- download_dbc(FTP_MODERN, "RJDF2301.dbc")
if (rj_sample$status == "ok") {
  df_rj <- tryCatch(read.dbc::read.dbc(rj_sample$path), error = function(e) NULL)
  if (!is.null(df_rj)) {
    cat(glue("RJ (Rejeitadas): {nrow(df_rj)} rows × {ncol(df_rj)} cols\n"))
    cat(glue("  Columns: {paste(names(df_rj), collapse=' | ')}\n\n"))
  }
}

# Download one ER file
er_sample <- download_dbc(FTP_MODERN, "ERDF2301.dbc")
if (er_sample$status == "ok") {
  df_er <- tryCatch(read.dbc::read.dbc(er_sample$path), error = function(e) NULL)
  if (!is.null(df_er)) {
    cat(glue("ER (Erros): {nrow(df_er)} rows × {ncol(df_er)} cols\n"))
    cat(glue("  Columns: {paste(names(df_er), collapse=' | ')}\n\n"))
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: PARQUET CONVERSION TEST
# ══════════════════════════════════════════════════════════════════════════════
cat("\n\n=== STEP 7: Parquet conversion test ===\n\n")

if (length(sample_dfs) > 0) {
  test_df <- sample_dfs[[1]]
  era_test <- names(sample_dfs)[1]
  
  # Convert all to character (project standard: all string)
  df_str <- test_df |> mutate(across(everything(), as.character))
  
  parquet_path <- file.path(DIR_TEMP, "test_rd.parquet")
  arrow::write_parquet(df_str, parquet_path)
  
  # Read back
  df_readback <- arrow::read_parquet(parquet_path)
  
  cat(glue("Parquet conversion test ({era_test}):\n"))
  cat(glue("  Original: {nrow(test_df)} rows × {ncol(test_df)} cols\n"))
  cat(glue("  Parquet:  {nrow(df_readback)} rows × {ncol(df_readback)} cols\n"))
  cat(glue("  File size: {round(file.size(parquet_path)/1024, 1)} KB\n"))
  cat(glue("  Row count match: {nrow(test_df) == nrow(df_readback)}\n"))
  cat(glue("  Col count match: {ncol(test_df) == ncol(df_readback)}\n"))
}

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
cat("\n\n=== EXPLORATION SUMMARY ===\n\n")
cat(glue("Files in modern era (all types): {length(modern_files)}\n"))
cat(glue("Files in legacy era (all types): {length(legacy_files)}\n"))
cat(glue("RD modern: {length(rd_modern)} files\n"))
cat(glue("RD legacy: {length(rd_legacy)} files\n"))
cat(glue("Samples downloaded and read: {length(sample_dfs)}\n"))
for (era_name in names(sample_dfs)) {
  df <- sample_dfs[[era_name]]
  cat(glue("  {era_name}: {nrow(df)} rows × {ncol(df)} cols\n"))
}
cat(glue("\nWorking directory: {DIR_TEMP}\n"))
cat("\nSession info:\n")
print(sessionInfo())
