# ==============================================================================
# sinasc-pipeline-r.R — Pipeline: DBC (FTP DATASUS) → Parquet → R2
# ==============================================================================
#
# Pipeline de produção para os microdados do SINASC
# (Sistema de Informações sobre Nascidos Vivos), 1994–2022.
#
# Para cada combinação ano × UF:
#   1. Baixa o .dbc do FTP do DATASUS
#   2. Lê com read.dbc::read.dbc()
#   3. Aplica schema unificado (mapeamento de nomenclatura 1994–1995 → moderna)
#   4. Converte todos os campos para character
#   5. Grava como Parquet particionado (ano=/uf=/) no staging local
#   6. Sobe para o R2 via rclone
#   7. Atualiza controle de versão e manifesto
#
# Schemas históricos (12 identificados na Fase 2):
#   Schema 1  (1994–1995): 30 cols — nomenclatura distinta, prefixo DNR{UF}
#   Schema 2  (1996–1998): 21 cols
#   Schema 3  (1999–2000): 20 cols
#   Schema 4  (2001):      23 cols
#   Schema 5  (2002–2005): 26 cols
#   Schema 6  (2006–2009): 29 cols
#   Schema 7  (2010):      55 cols
#   Schema 8  (2011):      56 cols
#   Schema 9  (2012):      56 cols
#   Schema 10 (2013):      59 cols
#   Schema 11 (2014–2017): 61 cols
#   Schema 12 (2018–2022): 61 cols (difere do 11 apenas por case: contador → CONTADOR)
#
# Estratégia de schema:
#   - Schema unificado: rename() nos 20 campos mapeados da era 1994–1995
#   - DATA_NASC (YYYYMMDD) convertido para DTNASC (DDMMYYYY)
#   - DATA_CART (YYYYMMDD) convertido para DDMMYYYY ao ser mantido como coluna extra
#   - Campos locais de 1994–1995 sem equivalente nacional mantidos como colunas extras
#   - Campos de controle interno descartados (ETNIA, FIL_ABORT, NUMEXPORT, CRITICA)
#   - CONTADOR/contador padronizado para CONTADOR (uppercase)
#
# Fontes:
#   Era moderna (1996–2022): ftp://.../SINASC/NOV/DNRES/DN{UF}{AAAA}.dbc
#   Era antiga  (1994–1995): ftp://.../SINASC/ANT/DNRES/DNR{UF}{AAAA}.dbc
#   (OpenDATASUS S3 bloqueado — HTTP 403; FTP é a única via viável)
#
# Referências:
#   - docs/sinasc/exploration-pt.md (exploração e decisões)
#   - docs/reference-pipelines-pt.md (infraestrutura compartilhada)
#   - docs/strategy-expansion-pt.md (ciclo de vida do módulo)
#
# ==============================================================================

# --- Pacotes ------------------------------------------------------------------

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

# --- Configurações ------------------------------------------------------------

DIR_TEMP     <- file.path(tempdir(), "sinasc_pipeline")
CONTROLE_CSV <- "data/controle_versao_sinasc.csv"

# FTP
FTP_NOV <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/NOV/DNRES/"
FTP_ANT <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/ANT/DNRES/"

# R2
RCLONE_REMOTE <- "r2"
R2_BUCKET     <- "healthbr-data"
R2_PREFIX     <- "sinasc"

# Período
ANO_INICIO <- 1994
ANO_FIM    <- 2022

# UFs (27 estados)
UFS <- c(
  "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO",
  "MA", "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR",
  "RJ", "RN", "RO", "RR", "RS", "SC", "SE", "SP", "TO"
)

# ==============================================================================
# MAPEAMENTO DE NOMENCLATURA: ERA 1994–1995 → ERA MODERNA
# ==============================================================================
# Baseado em NASC98.HLP (FTP DATASUS ANT/DOCS/) e
# Estrutura_SINASC_para_CD.pdf (FTP DATASUS NOV/DOCS/)
# Documentação completa: docs/sinasc/exploration-pt.md, seção 9.5

RENAME_1994_1995 <- c(
  NUMERODN  = "CODIGO",
  LOCNASC   = "LOCAL_OCOR",
  CODMUNNASC = "MUNI_OCOR",
  CODESTAB  = "ESTAB_OCOR",
  # DTNASC tratado separadamente (conversão de formato)
  SEXO      = "SEXO",
  PESO      = "PESO",
  RACACOR   = "RACACOR",
  APGAR1    = "APGAR1",
  APGAR5    = "APGAR5",
  GESTACAO  = "GESTACAO",
  GRAVIDEZ  = "TIPO_GRAV",
  PARTO     = "TIPO_PARTO",
  CONSULTAS = "PRE_NATAL",
  IDADEMAE  = "IDADE_MAE",
  ESCMAE    = "INSTR_MAE",
  CODMUNRES = "MUNI_MAE",
  QTDFILVIVO = "FIL_VIVOS",
  QTDFILMORT = "FIL_MORTOS",
  UFINFORM  = "UFINFORM"
)

# Campos de controle interno a descartar na era 1994–1995
DESCARTAR_1994_1995 <- c("ETNIA", "FIL_ABORT", "NUMEXPORT", "CRITICA")

# ==============================================================================
# FUNÇÕES: UTILITÁRIOS
# ==============================================================================

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

#' Construir URL e nome do arquivo .dbc
info_arquivo <- function(uf, ano) {
  if (ano <= 1995) {
    # Era antiga: ANT/DNRES/, prefixo DNR
    nome <- paste0("DNR", uf, ano, ".dbc")
    url  <- paste0(FTP_ANT, nome)
  } else {
    # Era moderna: NOV/DNRES/, prefixo DN
    nome <- paste0("DN", uf, ano, ".dbc")
    url  <- paste0(FTP_NOV, nome)
  }
  list(nome = nome, url = url)
}

#' Verificar rclone e acesso ao bucket
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
# FUNÇÕES: DOWNLOAD
# ==============================================================================

#' Download .dbc do FTP com retry e detecção de stall
baixar_dbc <- function(url, destino, tentativas = 5) {
  for (i in seq_len(tentativas)) {
    resultado <- tryCatch({
      curl::curl_download(
        url, destino, quiet = TRUE,
        handle = curl::new_handle(
          connecttimeout = 60,
          timeout        = 600,
          low_speed_limit = 1000,
          low_speed_time  = 120
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

# ==============================================================================
# FUNÇÕES: LEITURA E TRANSFORMAÇÃO
# ==============================================================================

#' Converter data de YYYYMMDD para DDMMYYYY (para harmonizar eras)
inverter_data_yyyymmdd <- function(x) {
  # "19940810" -> "10081994"; preserva valores inválidos/ausentes como estão
  ifelse(
    !is.na(x) & nchar(x) == 8 & grepl("^[0-9]{8}$", x),
    paste0(substr(x, 7, 8), substr(x, 5, 6), substr(x, 1, 4)),
    x
  )
}

#' Aplicar schema unificado para arquivos da era 1994–1995
aplicar_schema_1994_1995 <- function(df) {
  # 1. Descartar campos de controle interno
  df <- df |> select(-any_of(DESCARTAR_1994_1995))

  # 2. Converter DATA_NASC (YYYYMMDD) para DDMMYYYY antes do rename
  if ("DATA_NASC" %in% names(df)) {
    df <- df |> mutate(DATA_NASC = inverter_data_yyyymmdd(as.character(DATA_NASC)))
  }

  # 3. Converter DATA_CART (YYYYMMDD) para DDMMYYYY (mantida como coluna extra)
  if ("DATA_CART" %in% names(df)) {
    df <- df |> mutate(DATA_CART = inverter_data_yyyymmdd(as.character(DATA_CART)))
  }

  # 4. Aplicar renomeações: novo_nome = nome_antigo
  # Apenas renomear o que existe no df
  rename_map <- RENAME_1994_1995[RENAME_1994_1995 %in% names(df)]
  if (length(rename_map) > 0) {
    df <- df |> rename(!!!rename_map)
  }

  # 5. Renomear DATA_NASC (já convertido) para DTNASC
  if ("DATA_NASC" %in% names(df)) {
    df <- df |> rename(DTNASC = DATA_NASC)
  }

  df
}

#' Padronizar CONTADOR/contador para CONTADOR (uppercase)
padronizar_contador <- function(df) {
  if ("contador" %in% names(df) && !("CONTADOR" %in% names(df))) {
    df <- df |> rename(CONTADOR = contador)
  }
  df
}

#' Ler .dbc, aplicar schema e converter todos os campos para character
ler_dbc_como_character <- function(caminho, ano) {
  # read.dbc retorna data.frame com fatores por padrão; as.is não é suficiente
  # para garantir character em todos os casos — converter explicitamente
  df <- read.dbc::read.dbc(caminho) |>
    as_tibble() |>
    mutate(across(everything(), ~ as.character(.x)))

  # Aplicar transformações por era
  if (ano <= 1995) {
    df <- aplicar_schema_1994_1995(df)
  } else {
    # Era moderna: apenas padronizar case de CONTADOR
    df <- padronizar_contador(df)
  }

  df
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

#' Atualizar manifest.json no R2
update_manifest_r2 <- function(ano, dir_staging, controle) {
  manifest_key <- glue("{R2_PREFIX}/manifest.json")
  manifest_r2  <- glue("{RCLONE_REMOTE}:{R2_BUCKET}/{manifest_key}")
  tmp_manifest <- file.path(DIR_TEMP, "manifest.json")

  # Carregar manifesto existente do R2
  manifest <- tryCatch({
    raw <- system2("rclone", c("cat", shQuote(manifest_r2)),
                   stdout = TRUE, stderr = TRUE)
    jsonlite::fromJSON(paste(raw, collapse = "\n"), simplifyVector = FALSE)
  }, error = function(e) {
    cat(glue("  manifest: nao encontrado, iniciando novo: {e$message}"), "\n")
    list(
      manifest_version = "1.0.0",
      dataset          = R2_PREFIX,
      last_updated     = NULL,
      pipeline_version = "1.0.0",
      partitions       = list()
    )
  })

  ufs_this_year <- controle |> filter(ano == !!ano)

  for (i in seq_len(nrow(ufs_this_year))) {
    row <- ufs_this_year[i, ]
    partition_key <- paste0(row$ano, "-", row$uf)

    part_dir <- file.path(dir_staging,
                          paste0("ano=", ano),
                          paste0("uf=", row$uf))
    output_files <- list()
    if (dir_exists(part_dir)) {
      parquet_files <- fs::dir_ls(part_dir, glob = "*.parquet")
      for (pf in parquet_files) {
        output_files <- c(output_files, list(list(
          path         = paste0(R2_PREFIX, "/ano=", ano, "/uf=", row$uf,
                                "/", basename(pf)),
          size_bytes   = file.info(pf)$size,
          sha256       = digest::digest(file = pf, algo = "sha256"),
          record_count = as.integer(row$n_registros)
        )))
      }
    }

    manifest$partitions[[partition_key]] <- list(
      source_url         = info_arquivo(row$uf, row$ano)$url,
      source_size_bytes  = as.integer(row$tamanho_bytes),
      source_etag        = NULL,
      source_last_modified = NULL,
      processing_timestamp = row$data_processamento,
      output_files       = output_files,
      total_records      = as.integer(row$n_registros),
      total_size_bytes   = sum(sapply(output_files, function(f) f$size_bytes))
    )
  }

  manifest$last_updated <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S", tz = "UTC")

  jsonlite::write_json(manifest, tmp_manifest, auto_unbox = TRUE, pretty = TRUE)
  system2("rclone", c("copyto", shQuote(tmp_manifest), shQuote(manifest_r2),
                      "--transfers", "16", "--checkers", "32",
                      "--s3-no-check-bucket"))
  cat(glue("  manifest: atualizado ({nrow(ufs_this_year)} particoes no ano {ano})"), "\n")
}

#' Upload do staging para R2
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
  arq  <- info_arquivo(uf, ano)
  nome <- arq$nome
  url  <- arq$url

  # Já processado?
  if (nrow(controle |> filter(arquivo == nome)) > 0) {
    return(list(status = "inalterado", n = 0))
  }

  dir_create(DIR_TEMP)
  destino_dbc <- file.path(DIR_TEMP, nome)

  # Download
  ok <- baixar_dbc(url, destino_dbc)
  if (!ok) {
    return(list(status = "indisponivel", n = 0))
  }

  # Leitura e transformação
  df <- tryCatch(
    ler_dbc_como_character(destino_dbc, ano),
    error = function(e) {
      cat(glue("    ERRO ao ler {nome}: {e$message}"), "\n")
      NULL
    }
  )

  if (is.null(df) || nrow(df) == 0) {
    file_delete(destino_dbc)
    return(list(status = "vazio", n = 0))
  }

  n_registros       <- nrow(df)
  n_colunas_fonte   <- ncol(df)  # colunas após transformação de schema
  hash_md5          <- digest::digest(file = destino_dbc, algo = "md5")
  tamanho           <- file.info(destino_dbc)$size

  # Gravar Parquet no staging
  dir_staging <- file.path(DIR_TEMP, "staging_parquet")
  caminho_parquet <- gravar_parquet(df, ano, uf, dir_staging)

  n_colunas_parquet <- ncol(arrow::read_parquet(caminho_parquet, as_data_frame = FALSE))

  # Limpar
  file_delete(destino_dbc)
  rm(df)
  gc(verbose = FALSE)

  list(
    status           = "novo",
    n                = n_registros,
    n_colunas_fonte  = n_colunas_fonte,
    n_colunas_parquet = n_colunas_parquet,
    hash_md5         = hash_md5,
    tamanho          = tamanho,
    nome             = nome
  )
}

# ==============================================================================
# EXECUÇÃO
# ==============================================================================

cat("\n")
cat(strrep("=", 70), "\n")
cat("  Pipeline: DBC (FTP DATASUS) -> Parquet -> Cloudflare R2\n")
cat("  Modulo: SINASC — Nascidos Vivos (1994-2022)\n")
cat(strrep("=", 70), "\n\n")

cat("Verificando pre-requisitos...\n")
verificar_rclone()
cat("\n")

cat(glue("Temp:     {DIR_TEMP}"), "\n")
cat(glue("Destino:  {RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/"), "\n")
cat(glue("Periodo:  {ANO_INICIO}–{ANO_FIM}"), "\n")
cat(glue("UFs:      {length(UFS)} estados"), "\n\n")

t_inicio <- Sys.time()

# --- Grade de arquivos -------------------------------------------------------

grade <- expand.grid(
  uf  = UFS,
  ano = ANO_INICIO:ANO_FIM,
  stringsAsFactors = FALSE
) |>
  arrange(ano, uf) |>
  mutate(arquivo = mapply(function(u, a) info_arquivo(u, a)$nome, uf, ano))

cat(glue("Combinacoes ano x UF: {nrow(grade)}"), "\n")

controle <- carregar_controle()
cat(glue("Ja processados (controle): {nrow(controle)}"), "\n\n")

# --- Processamento por lote (ano a ano) ---------------------------------------

dir_staging <- file.path(DIR_TEMP, "staging_parquet")

n_total_registros  <- 0
n_novos            <- 0
n_indisponiveis    <- 0
n_inalterados      <- 0
n_erros            <- 0

for (ano in ANO_INICIO:ANO_FIM) {

  cat(strrep("-", 70), "\n")
  era <- if (ano <= 1995) "era 1994-1995 (ANT/DNRES/, prefixo DNR)" else "era moderna (NOV/DNRES/)"
  cat(glue("ANO {ano} — {era}"), "\n")
  cat(strrep("-", 70), "\n")

  if (dir_exists(dir_staging)) fs::dir_delete(dir_staging)
  dir_create(dir_staging)

  ufs_novas_no_ano  <- 0
  registros_no_ano  <- 0

  for (uf in UFS) {

    resultado <- processar_arquivo(uf, ano, controle)

    if (resultado$status == "inalterado") {
      n_inalterados <- n_inalterados + 1
      next
    }

    if (resultado$status == "indisponivel") {
      cat(glue("  {info_arquivo(uf, ano)$nome}: indisponivel"), "\n")
      n_indisponiveis <- n_indisponiveis + 1
      next
    }

    if (resultado$status == "vazio") {
      cat(glue("  {info_arquivo(uf, ano)$nome}: vazio"), "\n")
      n_erros <- n_erros + 1
      next
    }

    # status == "novo"
    cat(glue("  {resultado$nome}: {format(resultado$n, big.mark = '.')} registros ",
             "({resultado$n_colunas_fonte} cols fonte, {resultado$n_colunas_parquet} cols parquet)"),
        "\n")

    ufs_novas_no_ano  <- ufs_novas_no_ano + 1
    registros_no_ano  <- registros_no_ano + resultado$n
    n_total_registros <- n_total_registros + resultado$n
    n_novos           <- n_novos + 1

    novo_registro <- tibble(
      arquivo            = resultado$nome,
      ano                = ano,
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

  # Upload do ano completo
  if (ufs_novas_no_ano > 0) {
    cat(glue("\n  Subindo ano {ano}: {ufs_novas_no_ano} UFs, ",
             "{format(registros_no_ano, big.mark = '.')} registros..."), "\n")

    tryCatch({
      upload_para_r2(dir_staging)
      cat(glue("  Upload {ano} concluido."), "\n")

      tryCatch({
        update_manifest_r2(ano, dir_staging, controle)
      }, error = function(e) {
        cat(glue("  manifest: WARNING - falhou: {e$message}"), "\n")
      })
    }, error = function(e) {
      cat(glue("  ERRO upload {ano}: {e$message}"), "\n")
      n_erros <<- n_erros + 1
    })

    salvar_controle(controle)
  } else {
    cat("  Nenhum arquivo novo neste ano.\n")
  }

  cat("\n")
}

# Limpar staging
if (dir_exists(dir_staging)) fs::dir_delete(dir_staging)

t_fim     <- Sys.time()
duracao   <- round(difftime(t_fim, t_inicio, units = "mins"), 1)

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

if (file_exists(CONTROLE_CSV)) {
  ctrl <- readr::read_csv(CONTROLE_CSV, show_col_types = FALSE)
  cat(glue("Arquivos no controle: {nrow(ctrl)}"), "\n")
  cat(glue("Registros totais:     {format(sum(ctrl$n_registros), big.mark = '.')}"), "\n")

  cat("\nRegistros e schemas por ano:\n")
  ctrl |>
    group_by(ano) |>
    summarise(
      n_arquivos       = n(),
      n_registros      = sum(n_registros),
      n_colunas_parquet = max(n_colunas_parquet),
      .groups = "drop"
    ) |>
    arrange(ano) |>
    print(n = 30)
}

# --- Verificação de integridade -----------------------------------------------

cat("\n")
cat(strrep("=", 70), "\n")
cat("  VERIFICACAO DE INTEGRIDADE\n")
cat(strrep("=", 70), "\n\n")

ctrl_final          <- carregar_controle()
arquivos_processados <- ctrl_final$arquivo

faltantes <- grade |>
  filter(!(arquivo %in% arquivos_processados))

if (nrow(faltantes) == 0) {
  cat("Todos os arquivos da grade estao no controle.\n")
} else {
  cat(glue("ATENCAO: {nrow(faltantes)} arquivo(s) NAO estao no controle:\n"), "\n")
  for (i in seq_len(min(nrow(faltantes), 50))) {
    cat(glue("  - {faltantes$arquivo[i]} (UF={faltantes$uf[i]}, ano={faltantes$ano[i]})"), "\n")
  }
  if (nrow(faltantes) > 50) {
    cat(glue("  ... e mais {nrow(faltantes) - 50} arquivos."), "\n")
  }
  cat("\nArquivos ausentes podem nao existir no FTP ou ter falhado por timeout.\n")
  cat("Verifique o FTP manualmente se necessario.\n")
}

cat("\nPipeline concluido.\n")
