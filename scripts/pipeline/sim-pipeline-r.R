# ==============================================================================
# sim-pipeline-r.R — Pipeline: DBC (FTP DATASUS) → Parquet → R2
# ==============================================================================
#
# *** PROPOSTA (rascunho, 18/ago/2026) — ainda não rodado em produção. ***
# Ver docs/sim/exploration-pt.md §9 para as decisões que este script implementa
# e §10 para as que ainda aguardam confirmação (caixa de contador/CONTADOR,
# preliminares).
#
# Pipeline de produção para os microdados do SIM (Sistema de Informações
# sobre Mortalidade), 1979–presente, no molde do SINASC (anual × UF) com a
# mecânica de resolução por listagem e o breaker de FTP do SIH.
#
# Dois sub-datasets, escolhidos por SIM_TIPO:
#   DORES (default) — óbitos não fetais por UF de residência
#                     r2: sim/dores/ano=YYYY/uf=XX/part-0.parquet
#                     controle: data/controle_versao_sim_dores.csv
#   DOFET           — óbitos fetais, 1 arquivo nacional por ano
#                     r2: sim/dofet/ano=YYYY/part-0.parquet
#                     controle: data/controle_versao_sim_dofet.csv
#
# Para cada arquivo-fonte:
#   1. Resolve a URL a partir da listagem do FTP (três diretórios; o final
#      tem precedência sobre o preliminar)
#   2. Baixa o .dbc, lê com read.dbc::read.dbc(), converte tudo para character
#      (sem renomear, sem recodificar — schema do arquivo é o schema do Parquet)
#   3. Grava Parquet no staging com o metadado `healthbr` embutido
#   4. Por ano: rclone → R2, manifest.json, CSV de controle (checkpoint)
#
# Fontes (FTP DATASUS, base ftp://ftp.datasus.gov.br/dissemin/publicos/SIM/):
#   CID9/DORES/DOR{UF}{AA}.DBC      1979–1995   (TO só a partir de 1989)
#   CID10/DORES/DO{UF}{AAAA}.dbc    1996–último ano final (extensão .DBC em
#                                   2007 e 2010–2012; o servidor é case-insensitive)
#   PRELIM/DORES/DO{UF}{AAAA}.dbc   anos preliminares (mesmo nome; regravados)
#   CID9|CID10|PRELIM/DOFET/DOFET{AA}.DBC   fetais, nacional
#   Ignorados de propósito: DOBR* (união das UFs), DOEXT/DOINF/DOMAT
#   (subconjuntos do DORES), DOREXT (fora do escopo por ora), DOIGN.
#
# Env vars:
#   SIM_TIPO=DORES|DOFET        sub-dataset (default DORES)
#   SIM_ANO_FIM=YYYY            teto opcional (default: maior ano na listagem)
#   SIM_ANOS=1979,1996,2024     restringe a grade (testes)
#   SIM_UFS=AC,DF               restringe a grade (testes; só DORES)
#   SIM_INCLUIR_PRELIM=0        exclui PRELIM/ (default 1 = inclui)
#   SIM_FTP_FALHAS_LIMIAR / SIM_FTP_PROBE_TENTATIVAS / SIM_FTP_PROBE_ESPERA
#                               breaker de FTP (default 5 / 3 / 120 s)
#   HEALTHBR_GIT_COMMIT         commit quando fora de um clone git
#
# Códigos de saída: 0 ok; 75 FTP indisponível (progresso persistido; a
# orquestração trata como "retomar na próxima rodada", como no SIH).
#
# Referências:
#   - docs/sim/exploration-pt.md (exploração e decisões)
#   - docs/policy-reproducibility-pt.md (metadado, manifesto, controle)
#   - scripts/pipeline/sinasc-pipeline-r.R, sih-pipeline-r.R (modelos)
# ==============================================================================

# --- Pacotes ------------------------------------------------------------------

if (!require("pacman")) install.packages("pacman")
pacman::p_load(read.dbc, arrow, dplyr, readr, fs, glue, curl, digest, jsonlite, stringr)

# --- Configurações ------------------------------------------------------------

#' Embutida no schema metadata de cada Parquet, no manifesto e no CSV.
#' 1.2.0: nasce já com a política de reprodutibilidade (git_commit + MD5 da
#'        fonte nos três artefatos) e com `source_status` (final|preliminar).
PIPELINE_VERSION <- "1.2.0"
PIPELINE_SCRIPT  <- "scripts/pipeline/sim-pipeline-r.R"

resolver_git_commit <- function() {
  env <- Sys.getenv("HEALTHBR_GIT_COMMIT", "")
  if (nzchar(env)) return(env)
  out <- tryCatch(suppressWarnings(system2("git", c("rev-parse", "HEAD"),
                                           stdout = TRUE, stderr = TRUE)),
                  error = function(e) character(0))
  if (length(out) >= 1 && grepl("^[0-9a-f]{40}$", out[1])) out[1] else "unknown"
}
GIT_COMMIT <- resolver_git_commit()

TIPO <- toupper(Sys.getenv("SIM_TIPO", "DORES"))
TIPO_CFG <- list(
  DORES = list(label = "Óbitos não fetais por UF de residência (DORES)",
               r2_prefix = "sim/dores", controle = "data/controle_versao_sim_dores.csv",
               subdir = "DORES/", por_uf = TRUE),
  DOFET = list(label = "Óbitos fetais, arquivo nacional (DOFET)",
               r2_prefix = "sim/dofet", controle = "data/controle_versao_sim_dofet.csv",
               subdir = "DOFET/", por_uf = FALSE)
)
if (!TIPO %in% names(TIPO_CFG)) stop(glue("SIM_TIPO invalido: '{TIPO}' (use DORES ou DOFET)"))
CFG <- TIPO_CFG[[TIPO]]

FTP_SIM <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SIM/"
#' Ordem = precedência: um nome presente em mais de um diretório fica com o
#' primeiro (final CID10 > CID9 > preliminar).
FTP_DIRS <- c(final = "CID10/", final = "CID9/", preliminar = "PRELIM/")
INCLUIR_PRELIM <- Sys.getenv("SIM_INCLUIR_PRELIM", "1") == "1"

DIR_TEMP      <- file.path(tempdir(), "sim_pipeline")
CONTROLE_CSV  <- CFG$controle
RCLONE_REMOTE <- "r2"
R2_BUCKET     <- "healthbr-data"
R2_PREFIX     <- CFG$r2_prefix

ANO_INICIO <- 1979L
ANO_FIM_ENV <- suppressWarnings(as.integer(Sys.getenv("SIM_ANO_FIM", "")))
UFS <- c("AC","AL","AM","AP","BA","CE","DF","ES","GO","MA","MG","MS","MT","PA",
         "PB","PE","PI","PR","RJ","RN","RO","RR","RS","SC","SE","SP","TO")
filtro_env <- function(var) { v <- Sys.getenv(var, ""); if (nzchar(v)) toupper(trimws(strsplit(v, ",")[[1]])) else NULL }
SO_ANOS <- filtro_env("SIM_ANOS")
SO_UFS  <- filtro_env("SIM_UFS")

# Breaker de FTP (mesma semântica do SIH: falhas transientes seguidas → probe → exit 75)
FTP_FALHAS_LIMIAR     <- as.integer(Sys.getenv("SIM_FTP_FALHAS_LIMIAR", "5"))
FTP_PROBE_TENTATIVAS  <- as.integer(Sys.getenv("SIM_FTP_PROBE_TENTATIVAS", "3"))
FTP_PROBE_ESPERA_S    <- as.integer(Sys.getenv("SIM_FTP_PROBE_ESPERA", "120"))
EXIT_FTP_INDISPONIVEL <- 75L
.ftp <- new.env(); .ftp$falhas_seguidas <- 0L; .ftp$indisponivel <- FALSE

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

# ==============================================================================
# FUNÇÕES: LISTAGEM E RESOLUÇÃO DE ARQUIVOS
# ==============================================================================

#' Lista um diretório do FTP (IIS: "MM-DD-YY HH:MMAM <size|<DIR>> nome").
#' Retorna tibble(nome, tamanho) ou erro.
listar_ftp <- function(rel, timeout = 180) {
  h <- curl::new_handle(ftp_use_epsv = FALSE, connecttimeout = 60, timeout = timeout)
  raw <- rawToChar(curl::curl_fetch_memory(paste0(FTP_SIM, rel), handle = h)$content)
  linhas <- strsplit(raw, "\r?\n")[[1]]
  m <- str_match(linhas[nzchar(linhas)], "^\\S+\\s+\\S+\\s+(<DIR>|\\d+)\\s+(.+)$")
  m <- m[!is.na(m[, 1]) & m[, 2] != "<DIR>", , drop = FALSE]
  tibble(nome = m[, 3], tamanho = as.numeric(m[, 2]))
}

#' Interpreta o nome de um arquivo do SIM. Retorna NULL se não for do tipo
#' pedido (DO{UF}{AAAA} / DOR{UF}{AA} para DORES; DOFET{AA} para DOFET).
interpretar_nome <- function(nome) {
  up <- toupper(nome)
  if (TIPO == "DORES") {
    if (grepl("^DOR[A-Z]{2}[0-9]{2}\\.DBC$", up)) {
      return(list(uf = substr(up, 4, 5), ano = 1900L + as.integer(substr(up, 6, 7))))
    }
    if (grepl("^DO[A-Z]{2}[0-9]{4}\\.DBC$", up)) {
      return(list(uf = substr(up, 3, 4), ano = as.integer(substr(up, 5, 8))))
    }
    return(NULL)
  }
  if (grepl("^DOFET[0-9]{2}\\.DBC$", up)) {
    aa <- as.integer(substr(up, 6, 7))
    return(list(uf = "BR", ano = if (aa >= 79L) 1900L + aa else 2000L + aa))
  }
  NULL
}

#' Monta o catálogo de fontes: uma linha por (ano, uf) com url, tamanho e
#' status (final|preliminar). Precedência pela ordem de FTP_DIRS.
montar_catalogo <- function() {
  cat <- list()
  for (i in seq_along(FTP_DIRS)) {
    status <- names(FTP_DIRS)[i]
    if (status == "preliminar" && !INCLUIR_PRELIM) next
    rel <- paste0(FTP_DIRS[[i]], CFG$subdir)
    lst <- tryCatch(listar_ftp(rel), error = function(e) {
      cat(glue("  listagem {rel}: FALHOU ({e$message})"), "\n"); NULL
    })
    if (is.null(lst)) {
      # Sem a listagem de um diretório final não dá para garantir a precedência
      # final > preliminar: aborta como FTP indisponível (progresso preservado).
      if (status == "final") { .ftp$indisponivel <- TRUE; return(NULL) }
      next
    }
    for (j in seq_len(nrow(lst))) {
      p <- interpretar_nome(lst$nome[j]); if (is.null(p)) next
      if (p$uf == "BR" && TIPO == "DORES") next          # DOBR = união das UFs
      chave <- paste0(p$ano, "-", p$uf)
      if (!is.null(cat[[chave]])) next                    # precedência
      cat[[chave]] <- tibble(ano = p$ano, uf = p$uf, arquivo = lst$nome[j],
                             url = paste0(FTP_SIM, rel, lst$nome[j]),
                             tamanho_fonte = lst$tamanho[j], status = status)
    }
    cat(glue("  listagem {rel}: {nrow(lst)} entradas"), "\n")
  }
  bind_rows(cat) |> arrange(ano, uf)
}

# ==============================================================================
# FUNÇÕES: UTILITÁRIOS, CONTROLE, DOWNLOAD (SINASC/SIH)
# ==============================================================================

verificar_rclone <- function() {
  ok <- tryCatch(length(system2("rclone", "--version", stdout = TRUE, stderr = TRUE)) > 0,
                 error = function(e) FALSE)
  if (!ok) stop("rclone nao encontrado.")
  remotes <- system2("rclone", "listremotes", stdout = TRUE, stderr = TRUE)
  if (!any(grepl(paste0(RCLONE_REMOTE, ":"), remotes, fixed = TRUE)))
    stop(glue("Remote '{RCLONE_REMOTE}' nao encontrado no rclone."))
  teste <- system2("rclone", c("lsd", shQuote(glue("{RCLONE_REMOTE}:{R2_BUCKET}"))),
                   stdout = TRUE, stderr = TRUE)
  st <- attr(teste, "status")
  if (!is.null(st) && st != 0) stop(glue("Bucket '{R2_BUCKET}' nao acessivel."))
  cat(glue("  rclone OK: {RCLONE_REMOTE}:{R2_BUCKET}"), "\n")
}

carregar_controle <- function() {
  if (file_exists(CONTROLE_CSV)) {
    readr::read_csv(CONTROLE_CSV, show_col_types = FALSE,
                    col_types = readr::cols(.default = readr::col_character(),
                                            ano = readr::col_integer(),
                                            n_registros = readr::col_integer(),
                                            n_colunas_fonte = readr::col_integer(),
                                            n_colunas_parquet = readr::col_integer(),
                                            tamanho_bytes = readr::col_double()))
  } else {
    tibble(arquivo = character(), ano = integer(), uf = character(),
           n_registros = integer(), n_colunas_fonte = integer(), n_colunas_parquet = integer(),
           hash_md5 = character(), tamanho_bytes = numeric(), data_processamento = character(),
           pipeline_version = character(), git_commit = character(),
           source_status = character(), source_url = character())
  }
}

salvar_controle <- function(df) {
  dir_create(dirname(CONTROLE_CSV))
  readr::write_csv(df, CONTROLE_CSV)
  invisible(tryCatch(
    system2("rclone", c("copyto", shQuote(CONTROLE_CSV),
                        shQuote(glue("{RCLONE_REMOTE}:{R2_BUCKET}/maintenance/checkpoints/{basename(CONTROLE_CSV)}")),
                        "--s3-no-check-bucket"), stdout = FALSE, stderr = FALSE),
    error = function(e) NULL))
}

classificar_erro_ftp <- function(msg) {
  if (grepl("not found|does not exist|no such file|\\b550\\b", msg, ignore.case = TRUE)) "missing" else "transient"
}

#' Download com retry. Retorna list(ok, motivo = ok|missing|transient).
baixar_dbc <- function(url, destino, tentativas = 5) {
  motivo <- "transient"
  for (i in seq_len(tentativas)) {
    err <- tryCatch({
      curl::curl_download(url, destino, quiet = TRUE,
                          handle = curl::new_handle(connecttimeout = 60, timeout = 900,
                                                    low_speed_limit = 1000, low_speed_time = 120))
      NULL
    }, error = function(e) conditionMessage(e))
    if (is.null(err) && file_exists(destino) && file.info(destino)$size > 0)
      return(list(ok = TRUE, motivo = "ok"))
    motivo <- classificar_erro_ftp(err %||% "")
    if (motivo == "missing") break
    if (i < tentativas) { cat(glue("    tentativa {i}/{tentativas} falhou: {err}"), "\n"); Sys.sleep(5 * i) }
  }
  list(ok = FALSE, motivo = motivo)
}

registrar_resultado_ftp <- function(motivo) {
  .ftp$falhas_seguidas <- if (motivo == "transient") .ftp$falhas_seguidas + 1L else 0L
  invisible(.ftp$falhas_seguidas)
}

ftp_responde <- function() {
  tryCatch({ listar_ftp(paste0("CID10/", CFG$subdir), timeout = 120); TRUE }, error = function(e) FALSE)
}

verificar_saude_ftp <- function(probe = ftp_responde, esperar = Sys.sleep) {
  if (.ftp$indisponivel) return(FALSE)
  if (.ftp$falhas_seguidas < FTP_FALHAS_LIMIAR) return(TRUE)
  cat(glue("  FTP: {.ftp$falhas_seguidas} falhas transientes seguidas — sondando..."), "\n")
  for (i in seq_len(FTP_PROBE_TENTATIVAS)) {
    if (probe()) { cat("  FTP: respondeu — retomando.\n"); .ftp$falhas_seguidas <- 0L; return(TRUE) }
    if (i < FTP_PROBE_TENTATIVAS) esperar(FTP_PROBE_ESPERA_S)
  }
  cat("  FTP: indisponivel — parando limpo (progresso persistido; proxima rodada retoma).\n")
  .ftp$indisponivel <- TRUE
  FALSE
}

# ==============================================================================
# FUNÇÕES: LEITURA, GRAVAÇÃO, MANIFESTO, UPLOAD
# ==============================================================================

#' Lê o .dbc e converte tudo para character. Sem rename, sem recode: o
#' schema do arquivo-fonte é o schema do Parquet (decisão §9.5/§9.6 da
#' exploração; se a opção B de §9.6 for adotada, é aqui que entraria um
#' `padronizar_contador()` como no SINASC).
ler_dbc_como_character <- function(caminho) {
  read.dbc::read.dbc(caminho) |>
    as_tibble() |>
    mutate(across(everything(), ~ as.character(.x)))
}

dir_particao <- function(base, ano, uf) {
  if (CFG$por_uf) file.path(base, paste0("ano=", ano), paste0("uf=", uf))
  else            file.path(base, paste0("ano=", ano))
}
chave_particao <- function(ano, uf) if (CFG$por_uf) paste0(ano, "-", uf) else as.character(ano)
r2_path_particao <- function(ano, uf, arquivo) {
  if (CFG$por_uf) paste0(R2_PREFIX, "/ano=", ano, "/uf=", uf, "/", arquivo)
  else            paste0(R2_PREFIX, "/ano=", ano, "/", arquivo)
}

gravar_parquet <- function(df, ano, uf, dir_staging, meta) {
  dir_part <- dir_particao(dir_staging, ano, uf)
  dir_create(dir_part)
  caminho <- file.path(dir_part, "part-0.parquet")
  tbl <- arrow::arrow_table(df)
  tbl$metadata$healthbr <- as.character(jsonlite::toJSON(meta, auto_unbox = TRUE))
  arrow::write_parquet(tbl, caminho)
  caminho
}

update_manifest_r2 <- function(ano, dir_staging, controle) {
  manifest_r2  <- glue("{RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/manifest.json")
  tmp_manifest <- file.path(DIR_TEMP, "manifest.json")
  manifest <- tryCatch({
    raw <- system2("rclone", c("cat", shQuote(manifest_r2)), stdout = TRUE, stderr = TRUE)
    if (!is.null(attr(raw, "status")) && attr(raw, "status") != 0) stop("rclone cat falhou")
    jsonlite::fromJSON(paste(raw, collapse = "\n"), simplifyVector = FALSE)
  }, error = function(e) {
    cat(glue("  manifest: nao encontrado, iniciando novo ({e$message})"), "\n")
    list(manifest_version = "1.0.0", dataset = R2_PREFIX, last_updated = NULL,
         pipeline_version = PIPELINE_VERSION, partitions = list())
  })

  linhas <- controle |> filter(ano == !!ano)
  n_upd <- 0L
  for (i in seq_len(nrow(linhas))) {
    row <- linhas[i, ]
    part_dir <- dir_particao(dir_staging, row$ano, row$uf)
    if (!dir_exists(part_dir)) next          # não reprocessada nesta rodada
    output_files <- list()
    for (pf in fs::dir_ls(part_dir, glob = "*.parquet")) {
      output_files <- c(output_files, list(list(
        path = r2_path_particao(row$ano, row$uf, basename(pf)),
        size_bytes = file.info(pf)$size,
        sha256 = digest::digest(file = pf, algo = "sha256"),
        record_count = as.integer(row$n_registros))))
    }
    if (length(output_files) == 0) next
    manifest$partitions[[chave_particao(row$ano, row$uf)]] <- list(
      source_url = row$source_url, source_file = row$arquivo,
      source_size_bytes = as.numeric(row$tamanho_bytes), source_hash_md5 = row$hash_md5,
      source_status = row$source_status, source_etag = NULL, source_last_modified = NULL,
      processing_timestamp = row$data_processamento,
      pipeline_script = PIPELINE_SCRIPT, pipeline_version = PIPELINE_VERSION, git_commit = GIT_COMMIT,
      output_files = output_files, total_records = as.integer(row$n_registros),
      total_size_bytes = sum(vapply(output_files, function(f) f$size_bytes, numeric(1))))
    n_upd <- n_upd + 1L
  }
  manifest$last_updated     <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  manifest$pipeline_version <- PIPELINE_VERSION
  manifest$git_commit       <- GIT_COMMIT
  jsonlite::write_json(manifest, tmp_manifest, auto_unbox = TRUE, pretty = TRUE, null = "null")
  st <- system2("rclone", c("copyto", shQuote(tmp_manifest), shQuote(manifest_r2), "--s3-no-check-bucket"))
  if (!identical(st, 0L)) stop("rclone copyto do manifest falhou")
  cat(glue("  manifest: {n_upd} particao(oes) atualizada(s) no ano {ano}"), "\n")
}

upload_para_r2 <- function(dir_staging) {
  res <- system2("rclone", c("copy", shQuote(dir_staging), glue("{RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/"),
                             "--transfers", "16", "--checkers", "32", "--s3-no-check-bucket", "--stats", "0", "-v"),
                 stdout = TRUE, stderr = TRUE)
  st <- attr(res, "status")
  if (!is.null(st) && st != 0) { cat(paste(res, collapse = "\n"), "\n"); stop("Upload para R2 falhou") }
  TRUE
}

# ==============================================================================
# PROCESSAR UM ARQUIVO
# ==============================================================================

processar_arquivo <- function(fonte, controle) {
  # fonte: uma linha do catálogo (ano, uf, arquivo, url, tamanho_fonte, status)
  if (nrow(controle |> filter(arquivo == fonte$arquivo, ano == fonte$ano, uf == fonte$uf)) > 0)
    return(list(status = "inalterado"))

  dir_create(DIR_TEMP)
  destino <- file.path(DIR_TEMP, fonte$arquivo)
  dl <- baixar_dbc(fonte$url, destino)
  registrar_resultado_ftp(dl$motivo)
  if (!dl$ok) return(list(status = if (dl$motivo == "missing") "indisponivel" else "transiente"))

  df <- tryCatch(ler_dbc_como_character(destino), error = function(e) {
    cat(glue("    ERRO ao ler {fonte$arquivo}: {e$message}"), "\n"); NULL
  })
  if (is.null(df) || nrow(df) == 0) { file_delete(destino); return(list(status = "vazio")) }

  hash_md5 <- digest::digest(file = destino, algo = "md5")
  tamanho  <- file.info(destino)$size
  meta <- list(
    dataset = R2_PREFIX, source_url = fonte$url, source_file = fonte$arquivo,
    source_hash_md5 = hash_md5, source_size_bytes = tamanho, source_status = fonte$status,
    download_date = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    pipeline_script = PIPELINE_SCRIPT, pipeline_version = PIPELINE_VERSION, git_commit = GIT_COMMIT)
  caminho <- gravar_parquet(df, fonte$ano, fonte$uf, file.path(DIR_TEMP, "staging_parquet"), meta)
  n_cols_pq <- ncol(arrow::read_parquet(caminho, as_data_frame = FALSE))

  file_delete(destino); n <- nrow(df); nc <- ncol(df); rm(df); gc(verbose = FALSE)
  list(status = "novo", n = n, n_colunas_fonte = nc, n_colunas_parquet = n_cols_pq,
       hash_md5 = hash_md5, tamanho = tamanho)
}

# ==============================================================================
# EXECUÇÃO
# ==============================================================================

cat("\n", strrep("=", 70), "\n", sep = "")
cat("  Pipeline: DBC (FTP DATASUS) -> Parquet -> Cloudflare R2\n")
cat(glue("  Modulo: SIM — {CFG$label}"), "\n")
cat(strrep("=", 70), "\n\n")
cat("Verificando pre-requisitos...\n"); verificar_rclone()
cat(glue("  git_commit: {GIT_COMMIT}"), "\n")
if (GIT_COMMIT == "unknown") cat("  AVISO: git_commit desconhecido — rode de um clone ou defina HEALTHBR_GIT_COMMIT\n")

cat("\nListando o FTP...\n")
catalogo <- montar_catalogo()
if (is.null(catalogo) || nrow(catalogo) == 0) {
  cat("FTP indisponivel na listagem inicial — saindo com 75.\n"); quit(status = EXIT_FTP_INDISPONIVEL)
}
ano_fim <- if (!is.na(ANO_FIM_ENV)) ANO_FIM_ENV else max(catalogo$ano)
catalogo <- catalogo |> filter(ano >= ANO_INICIO, ano <= ano_fim)
if (!is.null(SO_ANOS)) catalogo <- catalogo |> filter(ano %in% as.integer(SO_ANOS))
if (!is.null(SO_UFS) && CFG$por_uf) catalogo <- catalogo |> filter(uf %in% SO_UFS)

cat(glue("Temp:     {DIR_TEMP}"), "\n")
cat(glue("Destino:  {RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/"), "\n")
cat(glue("Periodo:  {min(catalogo$ano)}–{max(catalogo$ano)} ",
         "({sum(catalogo$status == 'final')} finais, {sum(catalogo$status == 'preliminar')} preliminares)"), "\n")
cat(glue("Arquivos na grade: {nrow(catalogo)}"), "\n")

controle <- carregar_controle()
cat(glue("Ja processados (controle): {nrow(controle)}"), "\n\n")
t_inicio <- Sys.time()
dir_staging <- file.path(DIR_TEMP, "staging_parquet")
cont <- c(novos = 0L, inalterados = 0L, indisponiveis = 0L, transientes = 0L, erros = 0L, registros = 0L)
parou_por_ftp <- FALSE

for (ano in sort(unique(catalogo$ano))) {
  fontes_ano <- catalogo |> filter(ano == !!ano)
  cat(strrep("-", 70), "\n", glue("ANO {ano} — {nrow(fontes_ano)} arquivo(s), status {paste(unique(fontes_ano$status), collapse = '/')}"), "\n", sep = "")
  if (dir_exists(dir_staging)) fs::dir_delete(dir_staging)
  dir_create(dir_staging)
  novos_no_ano <- 0L

  for (i in seq_len(nrow(fontes_ano))) {
    if (!verificar_saude_ftp()) { parou_por_ftp <- TRUE; break }
    fonte <- fontes_ano[i, ]
    r <- processar_arquivo(fonte, controle)
    if (r$status == "inalterado")   { cont["inalterados"] <- cont["inalterados"] + 1L; next }
    if (r$status == "indisponivel") { cat(glue("  {fonte$arquivo}: indisponivel (404)"), "\n"); cont["indisponiveis"] <- cont["indisponiveis"] + 1L; next }
    if (r$status == "transiente")   { cat(glue("  {fonte$arquivo}: falha transiente"), "\n"); cont["transientes"] <- cont["transientes"] + 1L; next }
    if (r$status == "vazio")        { cat(glue("  {fonte$arquivo}: vazio"), "\n"); cont["erros"] <- cont["erros"] + 1L; next }

    cat(glue("  {fonte$arquivo} [{fonte$status}]: {format(r$n, big.mark = '.')} registros ",
             "({r$n_colunas_fonte} cols fonte, {r$n_colunas_parquet} cols parquet)"), "\n")
    novos_no_ano <- novos_no_ano + 1L
    cont["novos"] <- cont["novos"] + 1L; cont["registros"] <- cont["registros"] + r$n
    controle <- controle |>
      filter(!(ano == fonte$ano & uf == fonte$uf)) |>   # substitui (ex.: preliminar → final)
      bind_rows(tibble(
        arquivo = fonte$arquivo, ano = fonte$ano, uf = fonte$uf,
        n_registros = r$n, n_colunas_fonte = r$n_colunas_fonte, n_colunas_parquet = r$n_colunas_parquet,
        hash_md5 = r$hash_md5, tamanho_bytes = r$tamanho, data_processamento = as.character(Sys.time()),
        pipeline_version = PIPELINE_VERSION, git_commit = GIT_COMMIT,
        source_status = fonte$status, source_url = fonte$url))
  }

  if (novos_no_ano > 0) {
    cat(glue("\n  Subindo ano {ano}: {novos_no_ano} arquivo(s)..."), "\n")
    tryCatch({
      upload_para_r2(dir_staging)
      tryCatch(update_manifest_r2(ano, dir_staging, controle),
               error = function(e) cat(glue("  manifest: WARNING - falhou: {e$message}"), "\n"))
      salvar_controle(controle)
      cat(glue("  Ano {ano} persistido."), "\n")
    }, error = function(e) { cat(glue("  ERRO upload {ano}: {e$message}"), "\n"); cont["erros"] <<- cont["erros"] + 1L })
  } else cat("  Nenhum arquivo novo neste ano.\n")
  cat("\n")
  if (parou_por_ftp) break
}
if (dir_exists(dir_staging)) fs::dir_delete(dir_staging)

# --- Resumo -------------------------------------------------------------------
cat(strrep("=", 70), "\n  RESUMO FINAL\n", strrep("=", 70), "\n\n", sep = "")
cat(glue("Novos: {cont['novos']} | Inalterados: {cont['inalterados']} | Indisponiveis: {cont['indisponiveis']} | ",
         "Transientes: {cont['transientes']} | Erros/vazios: {cont['erros']}"), "\n")
cat(glue("Registros novos: {format(cont['registros'], big.mark = '.')} | Tempo: {round(difftime(Sys.time(), t_inicio, units = 'mins'), 1)} min"), "\n")

ctrl <- carregar_controle()
faltantes <- catalogo |> anti_join(ctrl |> select(ano, uf, arquivo), by = c("ano", "uf", "arquivo"))
if (nrow(faltantes) == 0) cat("Todos os arquivos da grade estao no controle.\n") else {
  cat(glue("ATENCAO: {nrow(faltantes)} arquivo(s) da grade NAO estao no controle (primeiros 30):"), "\n")
  print(head(faltantes |> select(ano, uf, arquivo, status), 30))
}
if (parou_por_ftp) { cat("\nFTP indisponivel — saindo com 75 (retomar na proxima rodada).\n"); quit(status = EXIT_FTP_INDISPONIVEL) }
cat("\nPipeline concluido.\n")
