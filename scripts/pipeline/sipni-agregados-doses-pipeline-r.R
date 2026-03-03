# ==============================================================================
# sipni-agregados-doses-pipeline-r.R — Pipeline: DBF (FTP DATASUS) → Parquet → R2
# ==============================================================================
#
# Pipeline de produção para os dados agregados de doses aplicadas (DPNI)
# do antigo SI-PNI (1994–2019).
#
# Para cada combinação ano × UF:
#   1. Baixa o .dbf do FTP do DATASUS
#   2. Lê com foreign::read.dbf(as.is = TRUE)
#   3. Converte todos os campos para character (decisão do projeto)
#   4. Grava como Parquet particionado (ano=/uf=/) no staging local
#   5. Sobe para o R2 via rclone
#   6. Atualiza controle de versão
#
# Schemas por era (publicados exatamente como o Ministério fornece):
#   Era 1 (1994–2003): 7 colunas — ANO, UF, MUNIC, FX_ETARIA, IMUNO, DOSE, QT_DOSE
#   Era 2–3 (2004–2019): 12 colunas — + ANOMES, MES, DOSE1, DOSEN, DIFER
#
# Código de município preservado como na fonte:
#   1994–2012: 7 dígitos (com verificador IBGE)
#   2013–2019: 6 dígitos (sem verificador)
#
# Referências:
#   - docs/sipni-agregados/exploration-pt.md (exploração e decisões)
#   - docs/reference-pipelines-pt.md (infraestrutura compartilhada)
#   - docs/strategy-expansion-pt.md (ciclo de vida do módulo)
#
# ==============================================================================

# --- Pacotes ------------------------------------------------------------------

if (!require("pacman")) install.packages("pacman")
pacman::p_load(
  foreign,
  arrow,
  dplyr,
  readr,
  fs,
  glue,
  curl,
  digest,
  jsonlite
)

# --- Configurações ------------------------------------------------------------

# Diretório temporário (fora do OneDrive no Windows)
DIR_TEMP     <- file.path(tempdir(), "sipni_agregados_pipeline")
CONTROLE_CSV <- "data/controle_versao_sipni_agregados_doses.csv"

# FTP
FTP_BASE <- "ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/"

# R2
RCLONE_REMOTE <- "r2"
R2_BUCKET     <- "healthbr-data"
R2_PREFIX     <- "sipni/agregados/doses"

# Período
ANO_INICIO <- 1994
ANO_FIM    <- 2019

# UFs: apenas os 27 estados
# Consolidados (UF, BR, IG) excluídos — ver exploration-pt.md, decisão 9.9:
#   - DPNIIG não existe no FTP (retorna status 550)
#   - DPNIBR é redundante (soma dos 27 estaduais, sem informação nova)
#   - DPNIUF tem schema diferente (6 colunas, sem MUNIC) e é redundante
#     (agregação trivial dos dados municipais)
UFS <- c(
  "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO",
  "MA", "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR",
  "RJ", "RN", "RO", "RR", "RS", "SC", "SE", "SP", "TO"
)

# ==============================================================================
# FUNÇÕES: UTILITÁRIOS
# ==============================================================================

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

#' Converter ano de 4 dígitos para sufixo de 2 dígitos do DATASUS
ano_para_sufixo <- function(ano) {
  sprintf("%02d", ano %% 100)
}

#' Construir nome do arquivo DPNI
nome_arquivo <- function(uf, ano) {
  paste0("DPNI", uf, ano_para_sufixo(ano), ".DBF")
}

#' Verificar rclone
verificar_rclone <- function() {
  rclone_ok <- tryCatch({
    res <- system2("rclone", "--version", stdout = TRUE, stderr = TRUE)
    length(res) > 0
  }, error = function(e) FALSE)

  if (!rclone_ok) stop("rclone nao encontrado.")

  remotes <- system2("rclone", "listremotes", stdout = TRUE, stderr = TRUE)
  if (!any(grepl(paste0(RCLONE_REMOTE, ":"), remotes, fixed = TRUE))) {
    stop(glue("Remote '{RCLONE_REMOTE}' nao encontrado no rclone."))
  }

  teste <- system2("rclone",
                    c("lsd", shQuote(glue("{RCLONE_REMOTE}:{R2_BUCKET}"))),
                    stdout = TRUE, stderr = TRUE)
  status <- attr(teste, "status")
  if (!is.null(status) && status != 0) {
    stop(glue("Bucket '{R2_BUCKET}' nao acessivel."))
  }

  cat(glue("  rclone OK: {RCLONE_REMOTE}:{R2_BUCKET}"), "\n")
}

# ==============================================================================
# FUNÇÕES: CONTROLE DE VERSÃO
# ==============================================================================

carregar_controle <- function() {
  if (file_exists(CONTROLE_CSV)) {
    readr::read_csv(CONTROLE_CSV, show_col_types = FALSE) |>
      mutate(data_processamento = as.character(data_processamento))
  } else {
    tibble(
      arquivo            = character(),
      ano                = integer(),
      uf                 = character(),
      n_registros        = integer(),
      n_colunas          = integer(),
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
# FUNÇÕES: DOWNLOAD E LEITURA
# ==============================================================================

#' Download .dbf from FTP with robust retry and timeout
#' Tuned for large files (100-216 MB): 600s timeout, 5 attempts,
#' low-speed detection. See sipni-agregados-doses-missing-12.R for context.
baixar_dbf <- function(nome_arq, destino, tentativas = 5) {
  url <- paste0(FTP_BASE, nome_arq)

  for (i in seq_len(tentativas)) {
    resultado <- tryCatch({
      curl::curl_download(
        url, destino, quiet = TRUE,
        handle = curl::new_handle(
          connecttimeout = 60,
          timeout = 600,
          low_speed_limit = 1000,
          low_speed_time = 120
        )
      )
      TRUE
    }, error = function(e) {
      if (i < tentativas) {
        cat(glue("    Tentativa {i}/{tentativas} falhou: {e$message}"), "\n")
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

#' Ler .dbf e converter todos os campos para character
ler_dbf_como_character <- function(caminho) {
  df <- foreign::read.dbf(caminho, as.is = TRUE)
  df |>
    as_tibble() |>
    mutate(across(everything(), as.character))
}

# ==============================================================================
# FUNÇÕES: GRAVAÇÃO E UPLOAD
# ==============================================================================

#' Gravar Parquet em partição Hive ano=/uf=/
gravar_parquet <- function(df, ano, uf, dir_staging) {
  dir_part <- file.path(dir_staging, paste0("ano=", ano), paste0("uf=", uf))
  dir_create(dir_part)
  caminho <- file.path(dir_part, "part-0.parquet")
  arrow::write_parquet(df, caminho)
  caminho
}

#' Update manifest.json on R2 via rclone
#' Called after each year's upload to keep manifest in sync.
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
    cat(glue("  manifest: could not load, starting fresh: {e$message}"), "\n")
    list(
      manifest_version = "1.0.0",
      dataset = R2_PREFIX,
      last_updated = NULL,
      pipeline_version = "1.0.0",
      partitions = list()
    )
  })

  # Update partitions for each UF processed this year
  ufs_this_year <- controle |> filter(ano == !!ano)

  for (i in seq_len(nrow(ufs_this_year))) {
    row <- ufs_this_year[i, ]
    partition_key <- paste0(row$ano, "-", row$uf)

    # Collect output file info from staging
    part_dir <- file.path(dir_staging, paste0("ano=", ano), paste0("uf=", row$uf))
    output_files <- list()
    if (dir_exists(part_dir)) {
      parquet_files <- fs::dir_ls(part_dir, glob = "*.parquet")
      for (pf in parquet_files) {
        output_files <- c(output_files, list(list(
          path = paste0(R2_PREFIX, "/ano=", ano, "/uf=", row$uf, "/", basename(pf)),
          size_bytes = file.info(pf)$size,
          sha256 = digest::digest(file = pf, algo = "sha256"),
          record_count = as.integer(row$n_registros)
        )))
      }
    }

    manifest$partitions[[partition_key]] <- list(
      source_url = paste0(FTP_BASE, row$arquivo),
      source_size_bytes = as.integer(row$tamanho_bytes),
      source_etag = NULL,
      source_last_modified = NULL,
      processing_timestamp = row$data_processamento,
      output_files = output_files,
      total_records = as.integer(row$n_registros),
      total_size_bytes = sum(sapply(output_files, function(f) f$size_bytes))
    )
  }

  manifest$last_updated <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S", tz = "UTC")

  # Write and upload
  jsonlite::write_json(manifest, tmp_manifest, auto_unbox = TRUE, pretty = TRUE)
  system2("rclone", c("copyto", shQuote(tmp_manifest), shQuote(manifest_r2),
                      "--transfers", "16", "--checkers", "32"))
  cat(glue("  manifest: updated {manifest_key} ({nrow(ufs_this_year)} partitions)"), "\n")
}

#' Upload para R2
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

# ==============================================================================
# FUNÇÃO PRINCIPAL: PROCESSAR UM ARQUIVO
# ==============================================================================

processar_arquivo <- function(uf, ano, controle) {
  nome_arq <- nome_arquivo(uf, ano)

  # Verificar se já processado
  registro <- controle |> filter(arquivo == nome_arq)
  if (nrow(registro) > 0) {
    return(list(status = "inalterado", n = 0))
  }

  # Preparar temp
  dir_create(DIR_TEMP)
  destino_dbf <- file.path(DIR_TEMP, nome_arq)

  # Download
  ok <- baixar_dbf(nome_arq, destino_dbf)
  if (!ok) {
    return(list(status = "indisponivel", n = 0))
  }

  # Ler e converter
  df <- tryCatch(
    ler_dbf_como_character(destino_dbf),
    error = function(e) {
      cat(glue("    ERRO ao ler {nome_arq}: {e$message}"), "\n")
      NULL
    }
  )

  if (is.null(df) || nrow(df) == 0) {
    file_delete(destino_dbf)
    return(list(status = "vazio", n = 0))
  }

  n_registros <- nrow(df)
  n_colunas   <- ncol(df)
  hash_md5    <- digest::digest(file = destino_dbf, algo = "md5")
  tamanho     <- file.info(destino_dbf)$size

  # Gravar Parquet no staging
  dir_staging <- file.path(DIR_TEMP, "staging_parquet")
  gravar_parquet(df, ano, uf, dir_staging)

  # Limpar
  file_delete(destino_dbf)
  rm(df)
  gc(verbose = FALSE)

  return(list(
    status     = "novo",
    n          = n_registros,
    n_colunas  = n_colunas,
    hash_md5   = hash_md5,
    tamanho    = tamanho,
    nome_arq   = nome_arq
  ))
}

# ==============================================================================
# EXECUÇÃO
# ==============================================================================

cat("\n")
cat(strrep("=", 70), "\n")
cat("  Pipeline: DBF (FTP DATASUS) -> Parquet -> Cloudflare R2\n")
cat("  Modulo: SI-PNI Agregados — Doses (1994-2019)\n")
cat(strrep("=", 70), "\n\n")

cat("Verificando pre-requisitos...\n")
verificar_rclone()
cat("\n")

cat(glue("Temp:     {DIR_TEMP}"), "\n")
cat(glue("Destino:  {RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/"), "\n")
cat(glue("Periodo:  {ANO_INICIO}-{ANO_FIM}"), "\n")
cat(glue("UFs:      {length(UFS)} estados (consolidados excluidos)"), "\n\n")

t_inicio <- Sys.time()

# --- Fase 1: Construir grade de arquivos a processar -------------------------

grade <- expand.grid(
  uf  = UFS,
  ano = ANO_INICIO:ANO_FIM,
  stringsAsFactors = FALSE
) |>
  arrange(ano, uf)

cat(glue("Combinacoes ano x UF: {nrow(grade)}"), "\n\n")

controle <- carregar_controle()
n_ja_processados <- controle |> nrow()
cat(glue("Ja processados (controle): {n_ja_processados}"), "\n\n")

# --- Fase 2: Download, conversão e upload por lote ---------------------------

# Processar em lotes por ano para upload eficiente
dir_staging <- file.path(DIR_TEMP, "staging_parquet")

n_total_registros <- 0
n_novos     <- 0
n_indisponiveis <- 0
n_inalterados <- 0
n_erros     <- 0

for (ano in ANO_INICIO:ANO_FIM) {

  cat(strrep("-", 70), "\n")
  cat(glue("ANO {ano}"), "\n")
  cat(strrep("-", 70), "\n")

  # Limpar staging do ano anterior
  if (dir_exists(dir_staging)) {
    fs::dir_delete(dir_staging)
  }
  dir_create(dir_staging)

  ufs_novas_no_ano <- 0
  registros_no_ano <- 0

  for (uf in UFS) {

    resultado <- processar_arquivo(uf, ano, controle)

    if (resultado$status == "inalterado") {
      n_inalterados <- n_inalterados + 1
      next
    }

    if (resultado$status == "indisponivel") {
      cat(glue("  {nome_arquivo(uf, ano)}: indisponivel apos {5} tentativas"), "\n")
      n_indisponiveis <- n_indisponiveis + 1
      next
    }

    if (resultado$status == "vazio") {
      cat(glue("  {nome_arquivo(uf, ano)}: vazio"), "\n")
      n_erros <- n_erros + 1
      next
    }

    # status == "novo"
    cat(glue("  {resultado$nome_arq}: {format(resultado$n, big.mark = '.')} ",
             "registros ({resultado$n_colunas} cols)"), "\n")

    ufs_novas_no_ano <- ufs_novas_no_ano + 1
    registros_no_ano <- registros_no_ano + resultado$n
    n_total_registros <- n_total_registros + resultado$n
    n_novos <- n_novos + 1

    # Atualizar controle
    novo_registro <- tibble(
      arquivo            = resultado$nome_arq,
      ano                = ano,
      uf                 = uf,
      n_registros        = resultado$n,
      n_colunas          = resultado$n_colunas,
      hash_md5           = resultado$hash_md5,
      tamanho_bytes      = resultado$tamanho,
      data_processamento = as.character(Sys.time())
    )

    controle <- controle |>
      filter(arquivo != resultado$nome_arq) |>
      bind_rows(novo_registro)
  }

  # Upload do ano completo para R2
  if (ufs_novas_no_ano > 0) {
    cat(glue("\n  Subindo ano {ano}: {ufs_novas_no_ano} UFs, ",
             "{format(registros_no_ano, big.mark = '.')} registros..."), "\n")
    tryCatch({
      upload_para_r2(dir_staging)
      cat(glue("  Upload {ano} concluido."), "\n")

      # Update manifest on R2
      tryCatch({
        update_manifest_r2(ano, dir_staging, controle)
      }, error = function(e) {
        cat(glue("  manifest: WARNING - failed to update: {e$message}"), "\n")
      })
    }, error = function(e) {
      cat(glue("  ERRO upload {ano}: {e$message}"), "\n")
      n_erros <<- n_erros + 1
    })

    # Salvar controle após cada ano (checkpoint)
    salvar_controle(controle)
  } else {
    cat("  Nenhum arquivo novo neste ano.\n")
  }

  cat("\n")
}

# Limpar staging final
if (dir_exists(dir_staging)) {
  fs::dir_delete(dir_staging)
}

t_fim <- Sys.time()
duracao <- round(difftime(t_fim, t_inicio, units = "mins"), 1)

# --- Resumo final -------------------------------------------------------------

cat("\n")
cat(strrep("=", 70), "\n")
cat("  RESUMO FINAL\n")
cat(strrep("=", 70), "\n\n")

cat(glue("Novos:           {n_novos}"), "\n")
cat(glue("Inalterados:     {n_inalterados}"), "\n")
cat(glue("Indisponiveis:   {n_indisponiveis}"), "\n")
cat(glue("Erros/vazios:    {n_erros}"), "\n")
cat(glue("Registros novos: {format(n_total_registros, big.mark = '.')}"), "\n")
cat(glue("Tempo total:     {duracao} min"), "\n\n")

# Controle final
if (file_exists(CONTROLE_CSV)) {
  ctrl <- readr::read_csv(CONTROLE_CSV, show_col_types = FALSE)
  cat(glue("Arquivos no controle: {nrow(ctrl)}"), "\n")
  cat(glue("Registros totais:     {format(sum(ctrl$n_registros), big.mark = '.')}"), "\n")

  cat("\nRegistros por ano:\n")
  ctrl |>
    group_by(ano) |>
    summarise(
      n_arquivos  = n(),
      n_registros = sum(n_registros),
      .groups     = "drop"
    ) |>
    arrange(ano) |>
    print(n = 30)
}

# --- Verificacao: arquivos esperados vs processados ---------------------------

cat("\n")
cat(strrep("=", 70), "\n")
cat("  VERIFICACAO DE INTEGRIDADE\n")
cat(strrep("=", 70), "\n\n")

ctrl_final <- carregar_controle()
arquivos_processados <- ctrl_final$arquivo

# Build expected file list (only files that exist on FTP)
# Known: some early years don't have all UFs (e.g. TO starts in 1994 but
# some small states may be missing in 1994-1996). We check against the
# full grid and report any gaps.
arquivos_esperados <- grade |>
  mutate(arquivo = paste0("DPNI", uf, sprintf("%02d", ano %% 100), ".DBF"))

faltantes <- arquivos_esperados |>
  filter(!(arquivo %in% arquivos_processados))

if (nrow(faltantes) == 0) {
  cat("Todos os arquivos da grade estao no controle. Nenhum faltante.\n")
} else {
  cat(glue("ATENCAO: {nrow(faltantes)} arquivo(s) NAO estao no controle:\n"), "\n")
  for (i in seq_len(nrow(faltantes))) {
    cat(glue("  - {faltantes$arquivo[i]} (UF={faltantes$uf[i]}, ano={faltantes$ano[i]})"), "\n")
  }
  cat("\n")
  cat("Esses arquivos podem nao existir no FTP (esperado para anos iniciais)\n")
  cat("ou podem ter falhado por timeout. Verifique manualmente se necessario.\n")
}

cat("\nPipeline concluido.\n")
