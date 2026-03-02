# ==============================================================================
# sipni-agregados-doses-missing-12.R — Process only the 12 missing large files
# ==============================================================================
#
# Targeted re-run for 12 DBF files from BA, MG, SP (2013-2018) that were
# skipped by the original pipeline due to FTP timeouts on large files.
#
# Differences from the full pipeline:
#   - Only processes the 12 specific missing files (no full grid scan)
#   - Higher FTP timeout (600s vs 120s) for large files (100-216 MB)
#   - Uploads each file individually (no year-batch grouping)
#
# Usage:
#   cd /root/healthbr-data
#   Rscript scripts/pipeline/sipni-agregados-doses-missing-12.R
# ==============================================================================

if (!require("pacman")) install.packages("pacman")
pacman::p_load(foreign, arrow, dplyr, readr, fs, glue, curl, digest)

# --- Config (same as main pipeline) ------------------------------------------

DIR_TEMP     <- file.path(tempdir(), "sipni_missing12")
CONTROLE_CSV <- "data/controle_versao_sipni_agregados_doses.csv"
FTP_BASE     <- "ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/"
RCLONE_REMOTE <- "r2"
R2_BUCKET     <- "healthbr-data"
R2_PREFIX     <- "sipni/agregados/doses"

# --- The 12 missing files ----------------------------------------------------

MISSING <- tribble(
  ~uf,  ~ano,
  "BA", 2014,
  "BA", 2015,
  "BA", 2016,
  "MG", 2013,
  "MG", 2014,
  "MG", 2015,
  "MG", 2016,
  "MG", 2018,
  "SP", 2013,
  "SP", 2014,
  "SP", 2015,
  "SP", 2016
)

MISSING <- MISSING |>
  mutate(arquivo = paste0("DPNI", uf, sprintf("%02d", ano %% 100), ".DBF"))

# --- Functions ---------------------------------------------------------------

baixar_dbf <- function(nome_arq, destino, tentativas = 5) {
  url <- paste0(FTP_BASE, nome_arq)

  for (i in seq_len(tentativas)) {
    cat(glue("    Tentativa {i}/{tentativas}..."), "\n")
    resultado <- tryCatch({
      curl::curl_download(
        url, destino, quiet = FALSE,
        handle = curl::new_handle(
          connecttimeout = 60,
          timeout = 600,        # 10 min timeout for large files
          low_speed_limit = 1000,
          low_speed_time = 120
        )
      )
      TRUE
    }, error = function(e) {
      cat(glue("    Erro: {e$message}"), "\n")
      if (i < tentativas) Sys.sleep(5 * i)
      FALSE
    })
    if (resultado && file_exists(destino) && file.info(destino)$size > 0) {
      return(TRUE)
    }
  }
  return(FALSE)
}

ler_dbf_como_character <- function(caminho) {
  foreign::read.dbf(caminho, as.is = TRUE) |>
    as_tibble() |>
    mutate(across(everything(), as.character))
}

gravar_parquet <- function(df, ano, uf, dir_staging) {
  dir_part <- file.path(dir_staging, paste0("ano=", ano), paste0("uf=", uf))
  dir_create(dir_part)
  caminho <- file.path(dir_part, "part-0.parquet")
  arrow::write_parquet(df, caminho)
  caminho
}

upload_para_r2 <- function(dir_staging) {
  destino <- glue("{RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/")
  args <- c("copy", shQuote(dir_staging), destino,
            "--transfers", "16", "--checkers", "32",
            "--s3-no-check-bucket", "--stats", "0", "-v")
  resultado <- system2("rclone", args, stdout = TRUE, stderr = TRUE)
  status <- attr(resultado, "status")
  if (!is.null(status) && status != 0) {
    cat(paste(resultado, collapse = "\n"), "\n")
    stop("Upload para R2 falhou")
  }
  TRUE
}

carregar_controle <- function() {
  if (file_exists(CONTROLE_CSV)) {
    readr::read_csv(CONTROLE_CSV, show_col_types = FALSE) |>
      mutate(data_processamento = as.character(data_processamento))
  } else {
    stop("Controle CSV nao encontrado: ", CONTROLE_CSV)
  }
}

salvar_controle <- function(df) {
  readr::write_csv(df, CONTROLE_CSV)
}

# --- Verify rclone -----------------------------------------------------------

cat("\n")
cat(strrep("=", 70), "\n")
cat("  Targeted run: 12 missing agregados-doses files\n")
cat("  BA(3) + MG(5) + SP(4) — 2013-2018\n")
cat(strrep("=", 70), "\n\n")

rclone_ok <- tryCatch({
  res <- system2("rclone", "--version", stdout = TRUE, stderr = TRUE)
  length(res) > 0
}, error = function(e) FALSE)
if (!rclone_ok) stop("rclone nao encontrado.")
cat("rclone OK\n\n")

# --- Load control and filter truly missing -----------------------------------

controle <- carregar_controle()
ja_processados <- controle$arquivo
realmente_faltam <- MISSING |> filter(!(arquivo %in% ja_processados))

cat(glue("Arquivos no controle: {nrow(controle)}"), "\n")
cat(glue("Faltam processar:     {nrow(realmente_faltam)} de {nrow(MISSING)}"), "\n\n")

if (nrow(realmente_faltam) == 0) {
  cat("Nada a fazer — todos os 12 ja estao no controle.\n")
  quit(status = 0)
}

# --- Process each missing file -----------------------------------------------

t_inicio <- Sys.time()
n_ok <- 0
n_erro <- 0

for (i in seq_len(nrow(realmente_faltam))) {
  row <- realmente_faltam[i, ]
  nome_arq <- row$arquivo
  ano <- row$ano
  uf  <- row$uf

  cat(strrep("-", 70), "\n")
  cat(glue("[{i}/{nrow(realmente_faltam)}] {nome_arq} (UF={uf}, ano={ano})"), "\n")
  cat(strrep("-", 70), "\n")

  dir_create(DIR_TEMP)
  destino_dbf <- file.path(DIR_TEMP, nome_arq)
  dir_staging <- file.path(DIR_TEMP, "staging_parquet")
  if (dir_exists(dir_staging)) fs::dir_delete(dir_staging)
  dir_create(dir_staging)

  # Download
  cat("  Baixando do FTP...\n")
  t_dl <- Sys.time()
  ok <- baixar_dbf(nome_arq, destino_dbf)
  if (!ok) {
    cat(glue("  FALHOU download de {nome_arq}"), "\n\n")
    n_erro <- n_erro + 1
    next
  }
  tamanho <- file.info(destino_dbf)$size
  t_dl_fim <- Sys.time()
  cat(glue("  Baixado: {round(tamanho / 1e6, 1)} MB em {round(difftime(t_dl_fim, t_dl, units='secs'))}s"), "\n")

  # Read DBF
  cat("  Lendo DBF...\n")
  df <- tryCatch(
    ler_dbf_como_character(destino_dbf),
    error = function(e) {
      cat(glue("  ERRO ao ler: {e$message}"), "\n")
      NULL
    }
  )
  if (is.null(df) || nrow(df) == 0) {
    cat("  Arquivo vazio ou ilegivel.\n\n")
    if (file_exists(destino_dbf)) file_delete(destino_dbf)
    n_erro <- n_erro + 1
    next
  }

  n_registros <- nrow(df)
  n_colunas   <- ncol(df)
  hash_md5    <- digest::digest(file = destino_dbf, algo = "md5")
  cat(glue("  {format(n_registros, big.mark = '.')} registros, {n_colunas} colunas"), "\n")

  # Write Parquet
  cat("  Gravando Parquet...\n")
  gravar_parquet(df, ano, uf, dir_staging)
  file_delete(destino_dbf)
  rm(df); gc(verbose = FALSE)

  # Upload to R2
  cat("  Upload para R2...\n")
  tryCatch({
    upload_para_r2(dir_staging)
    cat("  Upload OK\n")
  }, error = function(e) {
    cat(glue("  ERRO upload: {e$message}"), "\n")
    n_erro <- n_erro + 1
    next
  })

  # Update control CSV
  novo_registro <- tibble(
    arquivo            = nome_arq,
    ano                = ano,
    uf                 = uf,
    n_registros        = n_registros,
    n_colunas          = n_colunas,
    hash_md5           = hash_md5,
    tamanho_bytes      = tamanho,
    data_processamento = as.character(Sys.time())
  )
  controle <- controle |>
    filter(arquivo != nome_arq) |>
    bind_rows(novo_registro)
  salvar_controle(controle)

  n_ok <- n_ok + 1
  cat(glue("  Controle atualizado ({nrow(controle)} total)"), "\n\n")
}

# Cleanup
if (dir_exists(DIR_TEMP)) fs::dir_delete(DIR_TEMP)

t_fim <- Sys.time()
duracao <- round(difftime(t_fim, t_inicio, units = "mins"), 1)

# --- Summary -----------------------------------------------------------------

cat("\n")
cat(strrep("=", 70), "\n")
cat("  RESUMO\n")
cat(strrep("=", 70), "\n\n")
cat(glue("Processados OK:  {n_ok}"), "\n")
cat(glue("Erros:           {n_erro}"), "\n")
cat(glue("Tempo total:     {duracao} min"), "\n")
cat(glue("Controle final:  {nrow(controle)} arquivos"), "\n\n")
cat("Concluido.\n")
