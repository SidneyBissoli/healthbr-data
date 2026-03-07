# ============================================================
# SI-PNI Dicionários — Pipeline
# Converts .cnv and .dbf dictionary files to Parquet
#
# Source: ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/
# Output: sipni/dicionarios/ on R2 (Parquet + originals)
#
# Usage:
#   1. Run this script in RStudio (working dir = project root)
#   2. Run rclone command printed at the end
#
# Dependencies: arrow, foreign, curl
# ============================================================

library(arrow)
library(foreign)
library(curl)

# --- Configuration ---
FTP_URL   <- "ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/"
DIR_RAW   <- "data/exploration/auxiliares"
DIR_OUT   <- "data/exploration/auxiliares/r2_staging/sipni/dicionarios"
CNV_TARGETS <- c("IMUNO.CNV", "DOSE.CNV", "FXET.CNV", "ANO.CNV", "MES.CNV")

# --- Step 0: Create directories ---
dir.create(DIR_RAW, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(DIR_OUT, "originais"), recursive = TRUE, showWarnings = FALSE)

# --- Step 1: Download all files from FTP ---
cat("=== Step 1: Download from FTP ===\n")

h <- new_handle()
req <- curl_fetch_memory(FTP_URL, handle = h)
listing <- rawToChar(req$content)
lines <- strsplit(listing, "\r\n")[[1]]
lines <- lines[nchar(lines) > 0]
filenames <- trimws(sub(".*\\s+", "", lines))

# Filter: only .cnv and .dbf (skip .def — config files, not data)
filenames <- filenames[grepl("\\.(cnv|dbf)$", filenames, ignore.case = TRUE)]

cat("Files to download:", length(filenames), "\n")
for (f in filenames) {
  dest <- file.path(DIR_RAW, f)
  if (!file.exists(dest)) {
    tryCatch({
      curl_download(paste0(FTP_URL, f), dest, handle = new_handle())
      cat("  Downloaded:", f, "\n")
    }, error = function(e) {
      cat("  ERROR:", f, "-", e$message, "\n")
    })
  }
}
cat("Download complete.\n\n")

# --- Step 2: Parse .cnv format ---
# TabWin proprietary fixed-width format:
#   Line 1: N_ENTRIES FIELD_WIDTH [FLAGS]
#   Data:   [5 spaces][CODE][2 spaces][LABEL padded][SOURCE_CODES]
# Encoding: Latin-1

parse_cnv <- function(filepath) {
  raw <- readBin(filepath, "raw", file.info(filepath)$size)
  content <- iconv(rawToChar(raw), from = "latin1", to = "UTF-8")
  lines <- strsplit(content, "\r\n|\n")[[1]]
  lines <- lines[nchar(lines) > 0]
  
  header_parts <- strsplit(trimws(lines[1]), "\\s+")[[1]]
  n_entries <- as.integer(header_parts[1])
  field_width <- as.integer(header_parts[2])
  
  data_lines <- lines[-1]
  data_lines <- data_lines[nchar(trimws(data_lines)) > 0]
  
  results <- lapply(data_lines, function(line) {
    code <- trimws(substr(line, 6, 5 + field_width))
    rest <- trimws(substr(line, 5 + field_width + 1, nchar(line)))
    
    m <- gregexpr("\\s{2,}", rest)[[1]]
    if (length(m) > 0 && m[1] > 0) {
      last_gap <- m[length(m)]
      label <- trimws(substr(rest, 1, last_gap - 1))
      source_codes <- trimws(substr(rest, last_gap, nchar(rest)))
    } else {
      label <- rest
      source_codes <- NA_character_
    }
    
    list(code = code, label = label, source_codes = source_codes)
  })
  
  df <- data.frame(
    code = sapply(results, `[[`, "code"),
    label = sapply(results, `[[`, "label"),
    source_codes = sapply(results, `[[`, "source_codes"),
    stringsAsFactors = FALSE
  )
  
  stopifnot(n_entries == nrow(df))
  list(n_entries = n_entries, field_width = field_width, data = df)
}

# --- Step 3: Convert to Parquet ---
cat("=== Step 3: Convert to Parquet ===\n")

for (f in CNV_TARGETS) {
  parsed <- parse_cnv(file.path(DIR_RAW, f))
  out_name <- tolower(tools::file_path_sans_ext(f))
  out_path <- file.path(DIR_OUT, paste0(out_name, ".parquet"))
  
  tbl <- arrow::arrow_table(
    code = parsed$data$code,
    label = parsed$data$label,
    source_codes = parsed$data$source_codes
  )
  arrow::write_parquet(tbl, out_path)
  cat(sprintf("  %-12s -> %-18s  %3d rows\n", f, paste0(out_name, ".parquet"), nrow(parsed$data)))
}

# IMUNOCOB.DBF
imunocob <- read.dbf(file.path(DIR_RAW, "IMUNOCOB.DBF"), as.is = TRUE)
for (col in names(imunocob)) {
  if (is.character(imunocob[[col]])) {
    imunocob[[col]] <- iconv(imunocob[[col]], from = "latin1", to = "UTF-8")
  }
}
names(imunocob) <- tolower(names(imunocob))

tbl_dbf <- arrow::arrow_table(imuno = imunocob$imuno, nome = imunocob$nome)
arrow::write_parquet(tbl_dbf, file.path(DIR_OUT, "imunocob.parquet"))
cat(sprintf("  %-12s -> %-18s  %3d rows\n", "IMUNOCOB.DBF", "imunocob.parquet", nrow(imunocob)))

# --- Step 4: Copy originals ---
cat("\n=== Step 4: Copy originals ===\n")

cnv_all <- list.files(DIR_RAW, "\\.cnv$", full.names = TRUE, ignore.case = TRUE)
dbf_all <- list.files(DIR_RAW, "\\.dbf$", full.names = TRUE, ignore.case = TRUE)

for (f in c(cnv_all, dbf_all)) {
  file.copy(f, file.path(DIR_OUT, "originais", basename(f)), overwrite = TRUE)
}
cat("Copied", length(c(cnv_all, dbf_all)), "original files.\n")

# --- Step 5: Validate ---
cat("\n=== Step 5: Validate ===\n")

for (pq in list.files(DIR_OUT, "\\.parquet$", full.names = TRUE)) {
  df <- arrow::read_parquet(pq)
  has_bad_encoding <- any(grepl("\xc3", unlist(df), fixed = TRUE))
  cat(sprintf("  %-20s %3d rows  encoding_ok: %s\n", basename(pq), nrow(df), !has_bad_encoding))
}

# --- Step 6: Print rclone command ---
cat("\n=== Step 6: Upload to R2 ===\n")
cat("Run in terminal:\n\n")
cat("rclone copy", DIR_OUT, "r2:healthbr-data/sipni/dicionarios/ --transfers 16 --checkers 32 --progress\n\n")
cat("Verify:\n")
cat("rclone ls r2:healthbr-data/sipni/dicionarios/ --transfers 16 --checkers 32\n")
