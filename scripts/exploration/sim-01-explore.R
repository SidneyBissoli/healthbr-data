# SIM Exploration — Phase 2
# Goal: map the SIM tree on the DATASUS FTP (CID9 / CID10 / PRELIM; DORES,
#       DOFET and derived files), download a minimal sample of .dbc from all
#       eras, compare schemas year by year, inventory volume, check what the
#       BR / DOEXT / DOINF / DOMAT / DOFET / DOREXT files really are, and
#       measure the .dbc -> Parquet size ratio.
#
# Outputs feed docs/sim/exploration-pt.md (Phase 2 artifact).
#
# This is the canonical R version (read.dbc, as the pipelines use). The numbers
# in the doc were produced on 2026-08-18 with the Python twin
# (sim-01-explore.py — datasus-dbc + dbfread), because read.dbc is not
# installed on the maintainer's Windows PC; run this one on the VPS/RStudio.
#
# Date: 2026-08-18

# ── Packages ──────────────────────────────────────────────────────────────────
if (!require("pacman")) install.packages("pacman")
pacman::p_load(read.dbc, arrow, dplyr, fs, glue, curl, purrr, tibble, stringr, tidyr)

# ── Paths ─────────────────────────────────────────────────────────────────────
DIR_TEMP <- if (.Platform$OS.type == "unix") "/tmp/sim-exploration" else "C:/Temp/sim-exploration"
fs::dir_create(file.path(DIR_TEMP, "dbc"))

# ── FTP ───────────────────────────────────────────────────────────────────────
FTP_SIM   <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SIM/"
DIRS <- c(
  cid10_dores = "CID10/DORES/", cid10_dofet = "CID10/DOFET/",
  cid9_dores  = "CID9/DORES/",  cid9_dofet  = "CID9/DOFET/", cid9_doign = "CID9/DOIGN/",
  prelim_dores = "PRELIM/DORES/", prelim_dofet = "PRELIM/DOFET/",
  cid10_docs = "CID10/DOCS/", cid10_tab = "CID10/TAB/", cid10_tabelas = "CID10/TABELAS/",
  cid9_docs = "CID9/DOCS/", cid9_tab = "CID9/TAB/", cid9_tabelas = "CID9/TABELAS/"
)
UFS <- c("AC","AL","AM","AP","BA","CE","DF","ES","GO","MA","MG","MS","MT","PA",
         "PB","PE","PI","PR","RJ","RN","RO","RR","RS","SC","SE","SP","TO")

#' List an FTP directory (IIS listing: "MM-DD-YY  HH:MMAM  <size|<DIR>>  name")
#' Returns tibble(name, size, mtime_raw, is_dir).
list_ftp <- function(path, timeout = 120) {
  h <- curl::new_handle(ftp_use_epsv = FALSE, connecttimeout = 60, timeout = timeout)
  raw <- rawToChar(curl::curl_fetch_memory(paste0(FTP_SIM, path), handle = h)$content)
  lines <- strsplit(raw, "\r?\n")[[1]]
  lines <- lines[nzchar(lines)]
  m <- str_match(lines, "^(\\S+\\s+\\S+)\\s+(<DIR>|\\d+)\\s+(.+)$")
  tibble(name = m[, 4], size = suppressWarnings(as.numeric(m[, 3])),
         mtime_raw = m[, 2], is_dir = m[, 3] == "<DIR>")
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: MAP FTP DIRECTORY STRUCTURE
# ══════════════════════════════════════════════════════════════════════════════
cat("=== STEP 1: FTP structure ===\n")
print(list_ftp(""))
listings <- map(DIRS, ~ tryCatch(list_ftp(.x), error = function(e) tibble()))
for (n in names(listings)) {
  l <- listings[[n]]
  cat(glue("{n}: {nrow(l)} entries, {round(sum(l$size, na.rm = TRUE)/2^20, 1)} MiB"), "\n")
}

parse_do <- function(l) {
  # DO{UF}{AAAA}.dbc (CID10/PRELIM) | DOR{UF}{AA}.DBC (CID9)
  l |>
    mutate(up = toupper(name),
           tipo = case_when(str_detect(up, "^DOR[A-Z]{2}\\d{2}\\.DBC$") ~ "DOR",
                            str_detect(up, "^DO[A-Z]{2}\\d{4}\\.DBC$")  ~ "DO",
                            TRUE ~ NA_character_),
           uf  = if_else(tipo == "DOR", substr(up, 4, 5), substr(up, 3, 4)),
           ano = case_when(tipo == "DOR" ~ 1900L + as.integer(substr(up, 6, 7)),
                           tipo == "DO"  ~ as.integer(substr(up, 5, 8)))) |>
    filter(!is.na(tipo))
}
dores <- bind_rows(
  parse_do(listings$cid9_dores)   |> mutate(era = "CID9"),
  parse_do(listings$cid10_dores)  |> mutate(era = "CID10"),
  parse_do(listings$prelim_dores) |> mutate(era = "PRELIM"))

cat("\n--- DORES: files and MiB per era, UF vs BR ---\n")
dores |> mutate(br = uf == "BR") |> group_by(era, br) |>
  summarise(n = n(), mib = round(sum(size)/2^20), anos = paste(range(ano), collapse = "-"), .groups = "drop") |> print()
cat("\n--- files per year (UF only) ---\n")
dores |> filter(uf != "BR") |> count(ano) |> print(n = 60)
cat("\n--- extension case per year (CID10) ---\n")
dores |> filter(era == "CID10", uf != "BR") |> mutate(ext = str_extract(name, "\\.[dD][bB][cC]$")) |>
  count(ano, ext) |> filter(ext == ".DBC") |> print()

cat("\n--- DOFET family (CID10 / CID9 / PRELIM): type x years ---\n")
fam <- bind_rows(listings$cid10_dofet |> mutate(era = "CID10"),
                 listings$cid9_dofet  |> mutate(era = "CID9"),
                 listings$prelim_dofet |> mutate(era = "PRELIM")) |>
  mutate(up = toupper(name), tipo = str_extract(up, "^[A-Z]+"), yy = str_extract(up, "\\d{2}"))
fam |> group_by(era, tipo) |> summarise(n = n(), mib = round(sum(size)/2^20, 1),
                                        anos = paste(sort(unique(yy)), collapse = " "), .groups = "drop") |> print()

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: DOWNLOAD SAMPLES
# ══════════════════════════════════════════════════════════════════════════════
cat("\n=== STEP 2: samples ===\n")
UPPER_YEARS <- c(2007, 2010, 2011, 2012)
path_cid10 <- function(uf, y) glue("CID10/DORES/DO{uf}{y}{if (y %in% UPPER_YEARS) '.DBC' else '.dbc'}")
path_cid9  <- function(uf, yy) glue("CID9/DORES/DOR{uf}{sprintf('%02d', yy)}.DBC")
path_prel  <- function(uf, y) glue("PRELIM/DORES/DO{uf}{y}.dbc")

targets <- c(
  map_chr(79:95, ~ path_cid9("AC", .x)), map_chr(1996:2024, ~ path_cid10("AC", .x)),
  path_prel("AC", 2025), path_prel("AC", 2026),                       # AC: every year (schema evolution)
  map_chr(c(79, 85, 90, 95), ~ path_cid9("DF", .x)),
  map_chr(c(1996, 2000, 2005, 2010, 2015, 2020, 2024), ~ path_cid10("DF", .x)), path_prel("DF", 2025),
  "CID10/DOFET/DOFET24.DBC", "CID10/DOFET/DOEXT24.DBC", "CID10/DOFET/DOINF24.DBC",
  "CID10/DOFET/DOMAT24.DBC", "CID10/DOFET/DOREXT24.DBC", "CID10/DOFET/DOFET96.DBC",
  "CID9/DOFET/DOFET95.DBC", "CID9/DOIGN/DORIG95.DBC",
  map_chr(UFS, ~ path_cid10(.x, 1996)), path_cid10("BR", 1996),      # BR vs sum of UFs (CID10)
  map_chr(UFS, ~ path_cid9(.x, 94)),  path_cid9("BR", 94),           # idem (CID9)
  path_cid10("SP", 2024), path_cid10("BR", 2024)                      # biggest UF + national 2024
)

download_dbc <- function(rel, retries = 3) {
  dest <- file.path(DIR_TEMP, "dbc", basename(rel))
  if (file_exists(dest) && file.info(dest)$size > 0) return(dest)
  for (i in seq_len(retries)) {
    ok <- tryCatch({
      curl::curl_download(paste0(FTP_SIM, rel), dest, quiet = TRUE,
                          handle = curl::new_handle(connecttimeout = 60, timeout = 600,
                                                    low_speed_limit = 1000, low_speed_time = 60))
      TRUE
    }, error = function(e) { Sys.sleep(2 * i); FALSE })
    if (ok) break
  }
  if (file_exists(dest)) dest else NA_character_
}
paths <- map_chr(targets, download_dbc)
cat(glue("downloaded {sum(!is.na(paths))}/{length(targets)} files"), "\n")

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: SCHEMA EVOLUTION (AC, 1979–2026)
# ══════════════════════════════════════════════════════════════════════════════
cat("\n=== STEP 3: schema evolution (AC) ===\n")
read_chr <- function(p) read.dbc::read.dbc(p) |> as_tibble() |> mutate(across(everything(), as.character))
year_of <- function(f) { y <- as.integer(gsub("\\D", "", basename(f))); ifelse(y > 100, y, ifelse(y >= 79, 1900 + y, 2000 + y)) }

ac_files <- fs::dir_ls(file.path(DIR_TEMP, "dbc"), regexp = "DOR?AC\\d+\\.dbc$", ignore.case = TRUE)
ac_files <- ac_files[order(year_of(ac_files))]
schemas <- list(); prev <- NULL
for (f in ac_files) {
  d <- read_chr(f); y <- year_of(f); schemas[[as.character(y)]] <- names(d)
  added <- setdiff(names(d), prev); removed <- setdiff(prev, names(d))
  cat(glue("{y}: {ncol(d)} cols, {nrow(d)} rows"),
      if (length(added) && !is.null(prev)) glue("  +[{paste(added, collapse = ',')}]") else "",
      if (length(removed)) glue("  -[{paste(removed, collapse = ',')}]") else "", "\n")
  prev <- names(d)
}
sig <- split(names(schemas), map_chr(schemas, ~ paste(.x, collapse = "|")))
cat("\ndistinct schemas:", length(sig), "\n")
for (s in sig) cat("  ", length(strsplit(names(sig)[match(list(s), sig)], "\\|")[[1]]), "cols:", paste(s, collapse = " "), "\n")
cat("\ncommon to all years:", paste(reduce(schemas, intersect), collapse = ", "), "\n")

# value formats per year (nchar profile + examples) for the key fields
fmt <- function(v) { v <- v[!is.na(v)]; if (!length(v)) return("NA"); paste0("n", paste(sort(unique(nchar(v))), collapse = "/"), " ex=", paste(head(unique(v), 2), collapse = "|")) }
cat("\n--- value formats per year (AC) ---\n")
for (f in ac_files) {
  d <- read_chr(f); g <- function(...) { for (n in c(...)) if (n %in% names(d)) return(fmt(d[[n]])); "-" }
  cat(sprintf("%d  dt=%s  nasc=%s  mun=%s  cid=%s  idade=%s  ocup=%s  contador=%s\n", year_of(f),
              g("DTOBITO", "DATAOBITO"), g("DTNASC", "DATANASC"), g("CODMUNRES", "MUNIRES"),
              g("CAUSABAS"), g("IDADE"), g("OCUP", "OCUPACAO"), g("contador", "CONTADOR")))
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: ROW COUNTS, BR vs UF, DERIVED FILES
# ══════════════════════════════════════════════════════════════════════════════
cat("\n=== STEP 4: counts / BR vs UFs / derived files ===\n")
dbc_dir <- file.path(DIR_TEMP, "dbc")
nrows <- function(f) nrow(read.dbc::read.dbc(file.path(dbc_dir, f)))
for (yr in list(list(pat = "^DO(?!BR)[A-Z]{2}1996\\.dbc$", br = "DOBR1996.dbc"),
                list(pat = "^DOR(?!BR)[A-Z]{2}94\\.DBC$", br = "DORBR94.DBC"))) {
  ufs <- fs::dir_ls(dbc_dir, regexp = yr$pat, perl = TRUE)
  cat(glue("{yr$br}: BR rows = {nrows(yr$br)} ; sum of {length(ufs)} UF files = {sum(map_int(basename(ufs), nrows))}"), "\n")
}
sp <- read_chr(file.path(dbc_dir, "DOSP2024.dbc"))
cat("DOSP2024: CODMUNRES UF prefixes:", paste(names(table(substr(sp$CODMUNRES, 1, 2))), collapse = ","),
    "| CODMUNOCOR distinct UF prefixes:", length(unique(substr(sp$CODMUNOCOR, 1, 2))), "\n")

br <- read_chr(file.path(dbc_dir, "DOBR2024.dbc"))
cat(glue("DOBR2024: {nrow(br)} rows, {ncol(br)} cols, TIPOBITO = {paste(unique(br$TIPOBITO), collapse = ',')}"), "\n")
for (f in c("DOEXT24.DBC", "DOINF24.DBC", "DOMAT24.DBC", "DOFET24.DBC", "DOREXT24.DBC")) {
  d <- read_chr(file.path(dbc_dir, f))
  inbr <- if ("CONTADOR" %in% names(d)) mean(paste(d$CONTADOR, d$DTOBITO) %in% paste(br$CONTADOR, br$DTOBITO)) else NA
  cat(glue("{f}: {nrow(d)} rows, {ncol(d)} cols, extra cols = [{paste(setdiff(names(d), names(br)), collapse = ',')}], ",
           "TIPOBITO = {paste(unique(d$TIPOBITO), collapse = ',')}, share of (CONTADOR,DTOBITO) found in DOBR2024 = {round(100*inbr)}%"), "\n")
}
cat("DOBR2024 rows with CAUSABAS V-Y:", sum(substr(br$CAUSABAS, 1, 1) %in% c("V","W","X","Y")),
    "| IDADE < 1 year:", sum(substr(br$IDADE, 1, 1) %in% c("0","1","2","3") | br$IDADE == "400"),
    "| TIPOBITO == 1:", sum(br$TIPOBITO == "1"), "\n")

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: PARQUET SIZE TEST
# ══════════════════════════════════════════════════════════════════════════════
cat("\n=== STEP 5: Parquet (all string) ===\n")
for (f in c("DODF2024.dbc", "DOSP2024.dbc", "DOBR2024.dbc", "DORDF95.DBC", "DODF1996.dbc")) {
  d <- read_chr(file.path(dbc_dir, f)); out <- file.path(DIR_TEMP, sub("\\.dbc$", ".parquet", f, ignore.case = TRUE))
  arrow::write_parquet(d, out)
  cat(glue("{f}: {nrow(d)} rows; dbc {round(file.info(file.path(dbc_dir, f))$size/1024)} KiB -> parquet {round(file.info(out)$size/1024)} KiB (ratio {round(file.info(out)$size/file.info(file.path(dbc_dir, f))$size, 2)})"), "\n")
}
cat("\nDone. Update docs/sim/exploration-pt.md with the findings.\n")
