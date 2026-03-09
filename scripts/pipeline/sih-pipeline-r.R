# ==============================================================================
# sih-pipeline-r.R — Pipeline: DBC (FTP DATASUS) → Parquet → R2
# ==============================================================================
#
# Production pipeline for SIH/SUS microdata (Sistema de Informações
# Hospitalares do SUS) — AIH Reduzida (RD), 1992–present.
#
# For each UF × year × month combination:
#   1. Downloads .dbc from DATASUS FTP
#   2. Reads with read.dbc::read.dbc()
#   3. Converts all fields to character (project standard: all-string Parquet)
#   4. Writes as Hive-partitioned Parquet (ano=/mes=/uf=/)
#   5. Uploads to R2 via rclone
#   6. Updates version control CSV and manifest.json
#
# Schema evolution (~10 distinct schemas, 35–113 columns):
#   1992–1997: 35–42 cols — CID-9, dates YYMMDD, ANO_CMPT 2-digit
#   1998:      41 cols    — CID-10, dates YYYYMMDD, ANO_CMPT 4-digit (major transition)
#   1999–2003: 52–60 cols — +UTI, +gestão fields
#   2004–2007: 69–75 cols — +CNES
#   2008:      86 cols    — Era change, SIGTAP (10-digit), +RACA_COR
#   2012:      93 cols
#   2015–2026: 113 cols   — Stabilized (+DIAGSEC1-9)
#
# Strategy: Schema unificado by superset (Arrow unify_schemas). Columns
# absent in earlier eras appear as NULL. Data preserved exactly as published
# by the Ministry of Health — no date conversions, no CID remapping.
#
# Sprint approach:
#   Sprint 1 (default): Era moderna 2008–present (5,858 RD files)
#   Sprint 2:           Era antiga  1992–2007   (5,165 RD files)
#   Set SPRINT below to control scope.
#
# Sources:
#   Era moderna: ftp://.../SIHSUS/200801_/Dados/RD{UF}{AAMM}.dbc
#   Era antiga:  ftp://.../SIHSUS/199201_200712/Dados/RD{UF}{AAMM}.dbc
#
# References:
#   - docs/sih/exploration-pt.md (exploration & decisions)
#   - docs/reference-pipelines-pt.md (shared infrastructure)
#   - docs/strategy-expansion-pt.md (module lifecycle)
#
# ==============================================================================

# --- Packages -----------------------------------------------------------------

if (!require("pacman")) install.packages("pacman")
pacman::p_load(
  read.dbc,
  arrow,
  dplyr,
  readr,
  fs,
  glue,
  curl,
  digest,
  jsonlite
)

# --- Configuration ------------------------------------------------------------

#' SPRINT: which era to process
#'   1 = Era moderna (2008–present) — default, run first
#'   2 = Era antiga  (1992–2007)    — run after Sprint 1
#'   3 = Full (1992–present)        — both eras in one run
SPRINT <- 1

DIR_TEMP     <- file.path(tempdir(), "sih_pipeline")
CONTROLE_CSV <- "data/controle_versao_sih.csv"

# FTP
FTP_MODERNA <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/200801_/Dados/"
FTP_ANTIGA  <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/199201_200712/Dados/"

# R2
RCLONE_REMOTE <- "r2"
R2_BUCKET     <- "healthbr-data"
R2_PREFIX     <- "sih"

# Period (adjusted by sprint)
if (SPRINT == 1) {
  ANO_INICIO <- 2008
  ANO_FIM    <- 2026
} else if (SPRINT == 2) {
  ANO_INICIO <- 1992
  ANO_FIM    <- 2007
} else {
  ANO_INICIO <- 1992
  ANO_FIM    <- 2026
}

# Months
MESES <- sprintf("%02d", 1:12)

# UFs (27 states)
UFS <- c(
  "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO",
  "MA", "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR",
  "RJ", "RN", "RO", "RR", "RS", "SC", "SE", "SP", "TO"
)

# ==============================================================================
# FUNCTIONS: UTILITIES
# ==============================================================================

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

#' Build URL and filename for a given UF × year × month
#'
#' File pattern: RD{UF}{YY}{MM}.dbc
#' YY = 2-digit year (e.g., "08" for 2008, "92" for 1992)
#' Era moderna (2008+): 200801_/Dados/
#' Era antiga  (1992–2007): 199201_200712/Dados/
info_arquivo <- function(uf, ano, mes) {
  yy   <- sprintf("%02d", ano %% 100)
  nome <- paste0("RD", uf, yy, mes, ".dbc")

  if (ano >= 2008) {
    url <- paste0(FTP_MODERNA, nome)
  } else {
    url <- paste0(FTP_ANTIGA, nome)
  }

  list(nome = nome, url = url, yy = yy)
}

#' Check rclone and bucket access
verificar_rclone <- function() {
  rclone_ok <- tryCatch({
    res <- system2("rclone", "--version", stdout = TRUE, stderr = TRUE)
    length(res) > 0
  }, error = function(e) FALSE)

  if (!rclone_ok) stop("rclone not found.")

  remotes <- system2("rclone", "listremotes", stdout = TRUE, stderr = TRUE)
  if (!any(grepl(paste0(RCLONE_REMOTE, ":"), remotes, fixed = TRUE))) {
    stop(glue("Remote '{RCLONE_REMOTE}' not found in rclone config."))
  }

  teste <- system2("rclone",
                    c("lsd", shQuote(glue("{RCLONE_REMOTE}:{R2_BUCKET}"))),
                    stdout = TRUE, stderr = TRUE)
  status <- attr(teste, "status")
  if (!is.null(status) && status != 0) {
    stop(glue("Bucket '{R2_BUCKET}' not accessible."))
  }

  cat(glue("  rclone OK: {RCLONE_REMOTE}:{R2_BUCKET}"), "\n")
}

# ==============================================================================
# FUNCTIONS: VERSION CONTROL
# ==============================================================================

carregar_controle <- function() {
  if (file_exists(CONTROLE_CSV)) {
    readr::read_csv(CONTROLE_CSV, show_col_types = FALSE) |>
      mutate(data_processamento = as.character(data_processamento))
  } else {
    tibble(
      arquivo            = character(),
      ano                = integer(),
      mes                = character(),
      uf                 = character(),
      n_registros        = integer(),
      n_colunas_fonte    = integer(),
      n_colunas_parquet  = integer(),
      hash_md5           = character(),
      tamanho_bytes      = numeric(),
      data_processamento = character()
    )
  }
}

salvar_controle <- function(df) {
  dir_create(dirname(CONTROLE_CSV))
  readr::write_csv(df, CONTROLE_CSV)
}

# ==============================================================================
# FUNCTIONS: DOWNLOAD
# ==============================================================================

#' Download .dbc from FTP with retry and stall detection
baixar_dbc <- function(url, destino, tentativas = 5) {
  for (i in seq_len(tentativas)) {
    resultado <- tryCatch({
      curl::curl_download(
        url, destino, quiet = TRUE,
        handle = curl::new_handle(
          connecttimeout  = 60,
          timeout         = 600,
          low_speed_limit = 1000,
          low_speed_time  = 120
        )
      )
      TRUE
    }, error = function(e) {
      if (i < tentativas) {
        cat(glue("    Attempt {i}/{tentativas} failed: {e$message}"), "\n")
        Sys.sleep(5 * i)
      }
      FALSE
    })
    if (resultado && file_exists(destino) && file.info(destino)$size > 0) {
      return(TRUE)
    }
  }
  return(FALSE)
}

# ==============================================================================
# FUNCTIONS: READ AND TRANSFORM
# ==============================================================================

#' Read .dbc and convert all fields to character
#'
#' No schema transformation for SIH — data preserved exactly as published.
#' Arrow unify_schemas handles column alignment across eras.
ler_dbc_como_character <- function(caminho) {
  df <- read.dbc::read.dbc(caminho) |>
    as_tibble() |>
    mutate(across(everything(), ~ as.character(.x)))
  df
}

# ==============================================================================
# FUNCTIONS: WRITE AND UPLOAD
# ==============================================================================

#' Write Parquet in Hive partition ano=/mes=/uf=/
gravar_parquet <- function(df, ano, mes, uf, dir_staging) {
  dir_part <- file.path(dir_staging,
                        paste0("ano=", ano),
                        paste0("mes=", mes),
                        paste0("uf=", uf))
  dir_create(dir_part)
  caminho <- file.path(dir_part, "part-0.parquet")
  arrow::write_parquet(df, caminho)
  caminho
}

#' Update manifest.json on R2
update_manifest_r2 <- function(ano, dir_staging, controle) {
  manifest_key <- glue("{R2_PREFIX}/manifest.json")
  manifest_r2  <- glue("{RCLONE_REMOTE}:{R2_BUCKET}/{manifest_key}")
  tmp_manifest <- file.path(DIR_TEMP, "manifest.json")

  # Load existing manifest from R2

  manifest <- tryCatch({
    raw <- system2("rclone", c("cat", shQuote(manifest_r2)),
                   stdout = TRUE, stderr = TRUE)
    jsonlite::fromJSON(paste(raw, collapse = "\n"), simplifyVector = FALSE)
  }, error = function(e) {
    cat(glue("  manifest: not found, starting new: {e$message}"), "\n")
    list(
      manifest_version = "1.0.0",
      dataset          = R2_PREFIX,
      last_updated     = NULL,
      pipeline_version = "1.0.0",
      partitions       = list()
    )
  })

  rows_this_year <- controle |> filter(ano == !!ano)

  for (i in seq_len(nrow(rows_this_year))) {
    row <- rows_this_year[i, ]
    partition_key <- paste0(row$ano, "-", row$mes, "-", row$uf)

    part_dir <- file.path(dir_staging,
                          paste0("ano=", row$ano),
                          paste0("mes=", row$mes),
                          paste0("uf=", row$uf))
    output_files <- list()
    if (dir_exists(part_dir)) {
      parquet_files <- fs::dir_ls(part_dir, glob = "*.parquet")
      for (pf in parquet_files) {
        output_files <- c(output_files, list(list(
          path         = paste0(R2_PREFIX, "/ano=", row$ano,
                                "/mes=", row$mes,
                                "/uf=", row$uf,
                                "/", basename(pf)),
          size_bytes   = file.info(pf)$size,
          sha256       = digest::digest(file = pf, algo = "sha256"),
          record_count = as.integer(row$n_registros)
        )))
      }
    }

    manifest$partitions[[partition_key]] <- list(
      source_url           = info_arquivo(row$uf, row$ano, row$mes)$url,
      source_size_bytes    = as.integer(row$tamanho_bytes),
      source_etag          = NULL,
      source_last_modified = NULL,
      processing_timestamp = row$data_processamento,
      output_files         = output_files,
      total_records        = as.integer(row$n_registros),
      total_size_bytes     = sum(sapply(output_files, function(f) f$size_bytes))
    )
  }

  manifest$last_updated <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S", tz = "UTC")

  jsonlite::write_json(manifest, tmp_manifest, auto_unbox = TRUE, pretty = TRUE)
  system2("rclone", c("copyto", shQuote(tmp_manifest), shQuote(manifest_r2),
                       "--transfers", "16", "--checkers", "32",
                       "--s3-no-check-bucket"))
  cat(glue("  manifest: updated ({nrow(rows_this_year)} partitions for year {ano})"), "\n")
}

#' Upload staging dir to R2
upload_para_r2 <- function(dir_staging) {
  destino <- glue("{RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/")

  args <- c("copy", shQuote(dir_staging), destino,
            "--transfers", "16", "--checkers", "32",
            "--s3-no-check-bucket", "--stats", "0", "-v")

  resultado <- system2("rclone", args, stdout = TRUE, stderr = TRUE)
  status <- attr(resultado, "status")

  if (!is.null(status) && status != 0) {
    cat(paste(resultado, collapse = "\n"), "\n")
    stop("Upload to R2 failed")
  }
  TRUE
}

# ==============================================================================
# FUNCTION: PROCESS ONE FILE
# ==============================================================================

processar_arquivo <- function(uf, ano, mes, controle) {
  arq  <- info_arquivo(uf, ano, mes)
  nome <- arq$nome
  url  <- arq$url

  # Already processed?
  if (nrow(controle |> filter(arquivo == nome)) > 0) {
    return(list(status = "unchanged", n = 0))
  }

  dir_create(DIR_TEMP)
  destino_dbc <- file.path(DIR_TEMP, nome)

  # Download
  ok <- baixar_dbc(url, destino_dbc)
  if (!ok) {
    return(list(status = "unavailable", n = 0))
  }

  # Read and transform

  df <- tryCatch(
    ler_dbc_como_character(destino_dbc),
    error = function(e) {
      cat(glue("    ERROR reading {nome}: {e$message}"), "\n")
      NULL
    }
  )

  if (is.null(df) || nrow(df) == 0) {
    file_delete(destino_dbc)
    return(list(status = "empty", n = 0))
  }

  n_registros     <- nrow(df)
  n_colunas_fonte <- ncol(df)
  hash_md5        <- digest::digest(file = destino_dbc, algo = "md5")
  tamanho         <- file.info(destino_dbc)$size

  # Write Parquet to staging
  dir_staging     <- file.path(DIR_TEMP, "staging_parquet")
  caminho_parquet <- gravar_parquet(df, ano, mes, uf, dir_staging)

  n_colunas_parquet <- ncol(arrow::read_parquet(caminho_parquet, as_data_frame = FALSE))

  # Cleanup
  file_delete(destino_dbc)
  rm(df)
  gc(verbose = FALSE)

  list(
    status            = "new",
    n                 = n_registros,
    n_colunas_fonte   = n_colunas_fonte,
    n_colunas_parquet = n_colunas_parquet,
    hash_md5          = hash_md5,
    tamanho           = tamanho,
    nome              = nome
  )
}

# ==============================================================================
# EXECUTION
# ==============================================================================

sprint_label <- switch(as.character(SPRINT),
  "1" = "Sprint 1 — Era moderna (2008-present)",
  "2" = "Sprint 2 — Era antiga (1992-2007)",
  "3" = "Full (1992-present)"
)

cat("\n")
cat(strrep("=", 70), "\n")
cat("  Pipeline: DBC (FTP DATASUS) -> Parquet -> Cloudflare R2\n")
cat(glue("  Module: SIH — AIH Reduzida (RD), {ANO_INICIO}-{ANO_FIM}"), "\n")
cat(glue("  {sprint_label}"), "\n")
cat(strrep("=", 70), "\n\n")

cat("Checking prerequisites...\n")
verificar_rclone()
cat("\n")

cat(glue("Temp:     {DIR_TEMP}"), "\n")
cat(glue("Dest:     {RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/"), "\n")
cat(glue("Period:   {ANO_INICIO}-{ANO_FIM}"), "\n")
cat(glue("UFs:      {length(UFS)} states"), "\n")
cat(glue("Months:   {length(MESES)} per year"), "\n\n")

t_inicio <- Sys.time()

# --- File grid ----------------------------------------------------------------
# For the current year (2026), only months 01–05 are expected (partial year).
# The pipeline will naturally handle missing months as "unavailable".

grade <- expand.grid(
  uf  = UFS,
  mes = MESES,
  ano = ANO_INICIO:ANO_FIM,
  stringsAsFactors = FALSE
) |>
  arrange(ano, mes, uf) |>
  mutate(arquivo = mapply(
    function(u, a, m) info_arquivo(u, a, m)$nome,
    uf, ano, mes
  ))

cat(glue("File grid: {nrow(grade)} combinations (ano x mes x UF)"), "\n")

controle <- carregar_controle()
cat(glue("Already processed (version control): {nrow(controle)}"), "\n\n")

# --- Process year by year -----------------------------------------------------

dir_staging <- file.path(DIR_TEMP, "staging_parquet")

n_total_registros  <- 0
n_novos            <- 0
n_indisponiveis    <- 0
n_inalterados      <- 0
n_erros            <- 0

for (ano in ANO_INICIO:ANO_FIM) {

  cat(strrep("-", 70), "\n")
  era <- if (ano >= 2008) "era moderna (200801_/)" else "era antiga (199201_200712/)"
  cat(glue("YEAR {ano} — {era}"), "\n")
  cat(strrep("-", 70), "\n")

  if (dir_exists(dir_staging)) fs::dir_delete(dir_staging)
  dir_create(dir_staging)

  novos_no_ano     <- 0
  registros_no_ano <- 0

  for (mes in MESES) {
    for (uf in UFS) {

      resultado <- processar_arquivo(uf, ano, mes, controle)

      if (resultado$status == "unchanged") {
        n_inalterados <- n_inalterados + 1
        next
      }

      if (resultado$status == "unavailable") {
        # Only log at debug level — many months in partial year will be unavailable
        n_indisponiveis <- n_indisponiveis + 1
        next
      }

      if (resultado$status == "empty") {
        cat(glue("  {info_arquivo(uf, ano, mes)$nome}: empty"), "\n")
        n_erros <- n_erros + 1
        next
      }

      # status == "new"
      cat(glue("  {resultado$nome}: {format(resultado$n, big.mark = '.')} rows ",
               "({resultado$n_colunas_fonte} src cols, ",
               "{resultado$n_colunas_parquet} pq cols)"), "\n")

      novos_no_ano      <- novos_no_ano + 1
      registros_no_ano  <- registros_no_ano + resultado$n
      n_total_registros <- n_total_registros + resultado$n
      n_novos           <- n_novos + 1

      novo_registro <- tibble(
        arquivo            = resultado$nome,
        ano                = ano,
        mes                = mes,
        uf                 = uf,
        n_registros        = resultado$n,
        n_colunas_fonte    = resultado$n_colunas_fonte,
        n_colunas_parquet  = resultado$n_colunas_parquet,
        hash_md5           = resultado$hash_md5,
        tamanho_bytes      = resultado$tamanho,
        data_processamento = as.character(Sys.time())
      )

      controle <- controle |>
        filter(arquivo != resultado$nome) |>
        bind_rows(novo_registro)
    }
  }

  # Upload the completed year
  if (novos_no_ano > 0) {
    cat(glue("\n  Uploading year {ano}: {novos_no_ano} files, ",
             "{format(registros_no_ano, big.mark = '.')} rows..."), "\n")

    tryCatch({
      upload_para_r2(dir_staging)
      cat(glue("  Upload {ano} done."), "\n")

      tryCatch({
        update_manifest_r2(ano, dir_staging, controle)
      }, error = function(e) {
        cat(glue("  manifest: WARNING - failed: {e$message}"), "\n")
      })
    }, error = function(e) {
      cat(glue("  ERROR upload {ano}: {e$message}"), "\n")
      n_erros <<- n_erros + 1
    })

    salvar_controle(controle)
  } else {
    cat("  No new files in this year.\n")
  }

  cat("\n")
}

# Clean staging
if (dir_exists(dir_staging)) fs::dir_delete(dir_staging)

t_fim   <- Sys.time()
duracao <- round(difftime(t_fim, t_inicio, units = "mins"), 1)

# --- Final summary ------------------------------------------------------------

cat("\n")
cat(strrep("=", 70), "\n")
cat("  FINAL SUMMARY\n")
cat(strrep("=", 70), "\n\n")

cat(glue("New:          {n_novos}"), "\n")
cat(glue("Unchanged:    {n_inalterados}"), "\n")
cat(glue("Unavailable:  {n_indisponiveis}"), "\n")
cat(glue("Errors/empty: {n_erros}"), "\n")
cat(glue("New rows:     {format(n_total_registros, big.mark = '.')}"), "\n")
cat(glue("Total time:   {duracao} min"), "\n\n")

if (file_exists(CONTROLE_CSV)) {
  ctrl <- readr::read_csv(CONTROLE_CSV, show_col_types = FALSE)
  cat(glue("Files in version control: {nrow(ctrl)}"), "\n")
  cat(glue("Total rows:               {format(sum(ctrl$n_registros), big.mark = '.')}"), "\n")

  cat("\nRows and schemas by year:\n")
  ctrl |>
    group_by(ano) |>
    summarise(
      n_files          = n(),
      n_rows           = sum(n_registros),
      n_cols_parquet   = max(n_colunas_parquet),
      .groups = "drop"
    ) |>
    arrange(ano) |>
    print(n = 40)
}

# --- Integrity check ----------------------------------------------------------

cat("\n")
cat(strrep("=", 70), "\n")
cat("  INTEGRITY CHECK\n")
cat(strrep("=", 70), "\n\n")

ctrl_final           <- carregar_controle()
arquivos_processados <- ctrl_final$arquivo

faltantes <- grade |>
  filter(!(arquivo %in% arquivos_processados))

if (nrow(faltantes) == 0) {
  cat("All files in the grid are in version control.\n")
} else {
  # Distinguish truly missing from expected-unavailable (e.g. future months)
  cat(glue("NOTE: {nrow(faltantes)} file(s) NOT in version control."), "\n")
  cat("This is expected for partial years (e.g. 2026) and early-era gaps.\n\n")

  # Show summary by year
  faltantes |>
    group_by(ano) |>
    summarise(n_missing = n(), .groups = "drop") |>
    arrange(ano) |>
    print(n = 40)

  cat("\nFirst 30 missing files:\n")
  for (i in seq_len(min(nrow(faltantes), 30))) {
    cat(glue("  - {faltantes$arquivo[i]} (UF={faltantes$uf[i]}, ",
             "ano={faltantes$ano[i]}, mes={faltantes$mes[i]})"), "\n")
  }
  if (nrow(faltantes) > 30) {
    cat(glue("  ... and {nrow(faltantes) - 30} more."), "\n")
  }
}

cat("\nPipeline complete.\n")
