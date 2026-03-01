# ==============================================================================
# download_json_parquet.R — Pipeline completo: JSON → Parquet → R2
# ==============================================================================
#
# Pipeline de produção: JSON (OpenDATASUS) → Parquet → Cloudflare R2
#
# Para cada mês de 2020 até o mês corrente:
#   1. HEAD request no S3 do Ministério → compara com controle local
#   2. Se novo ou atualizado:
#      a. Baixa o zip
#      b. Lista TODOS os JSONs dentro do zip (pode haver múltiplas partes)
#      c. Para cada parte: extrai → lê chunked → grava Parquet → deleta JSON
#      d. Sobe o Parquet completo para o R2 via rclone
#      e. Verifica upload, atualiza controle, deleta tudo localmente
#
# Múltiplas partes por zip:
#   Os JSONs de 2020-2024 são paginados em partes de ~400 mil registros
#   dentro do mesmo zip (ex: _00001.json, _00002.json, ..., _00017.json).
#   Um mês de pico COVID pode ter 17+ partes = ~6.8 milhões de registros.
#   Os JSONs de 2025+ vêm num único arquivo por zip.
#   O script processa uma parte por vez: nunca mais que ~1 GB de JSON
#   em disco e ~400 mil registros em memória simultaneamente.
#
# Gerenciamento de disco:
#   Diretório temporário fora do OneDrive (%TEMP%/sipni_pipeline).
#   Pico: ~2 GB (zip + 1 JSON extraído). Após cada mês: zero.
#
# Pré-requisitos:
#   - rclone instalado e configurado com remote "r2" → Cloudflare R2
#   - Testar: rclone lsd r2:healthbr-data
#
# ==============================================================================

# --- Pacotes ------------------------------------------------------------------

if (!require("pacman")) install.packages("pacman")
pacman::p_load(
  here,
  arrow,
  dplyr,
  readr,
  jsonlite,
  fs,
  glue,
  curl,
  digest
)

# --- Configurações ------------------------------------------------------------

# Temporários FORA do OneDrive
DIR_TEMP     <- file.path(Sys.getenv("TEMP"), "sipni_pipeline")
CONTROLE_CSV <- here::here("data", "controle_versao_microdata.csv")

# R2
RCLONE_REMOTE <- "r2"
R2_BUCKET     <- "healthbr-data"
R2_PREFIX     <- "sipni/microdados"
# Endpoint: https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com

ANO_INICIO <- 2020

MESES_PT <- c("jan", "fev", "mar", "abr", "mai", "jun",
              "jul", "ago", "set", "out", "nov", "dez")

CHUNK_SIZE <- 200 * 1024 * 1024  # 200 MB

# ==============================================================================
# FUNÇÕES: UTILITÁRIOS
# ==============================================================================

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

#' Deleção robusta com retry
deletar_com_retry <- function(caminho, tentativas = 5) {
  for (i in seq_len(tentativas)) {
    resultado <- tryCatch({
      if (dir_exists(caminho)) {
        dir_delete(caminho)
      } else if (file_exists(caminho)) {
        file_delete(caminho)
      }
      TRUE
    }, error = function(e) {
      if (i < tentativas) {
        Sys.sleep(2 * i)
      } else {
        cat(glue("  AVISO: nao conseguiu deletar {basename(caminho)}: ",
                 "{e$message}"), "\n")
      }
      FALSE
    })
    if (resultado) return(invisible(TRUE))
  }
  invisible(FALSE)
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
      etag_servidor      = character(),
      content_length     = numeric(),
      hash_md5_zip       = character(),
      n_registros        = integer(),
      n_partes_json      = integer(),
      data_processamento = character(),
      ano                = integer(),
      mes                = integer(),
      url_origem         = character()
    )
  }
}

salvar_controle <- function(df) {
  dir_create(dirname(CONTROLE_CSV))
  readr::write_csv(df, CONTROLE_CSV)
}

# ==============================================================================
# FUNÇÕES: SERVIDOR DO MINISTÉRIO
# ==============================================================================

consultar_servidor <- function(ano, mes) {
  mes_pt <- MESES_PT[mes]
  urls <- c(
    antigo = glue("https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/",
                  "PNI/json/vacinacao_{mes_pt}_{ano}.json.zip"),
    novo   = glue("https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/",
                  "PNI/json/vacinacao_{mes_pt}_{ano}_json.zip")
  )

  for (padrao in names(urls)) {
    url <- urls[[padrao]]
    for (tentativa in 1:3) {
      resp <- tryCatch({
        h <- curl::new_handle(
          nobody = TRUE, connecttimeout = 15,
          timeout = 30, followlocation = TRUE
        )
        curl::curl_fetch_memory(url, handle = h)
      }, error = function(e) NULL)
      if (!is.null(resp)) break
      Sys.sleep(1 * tentativa)
    }
    if (!is.null(resp) && resp$status_code == 200) {
      headers <- curl::parse_headers_list(resp$headers)
      return(list(
        url            = url,
        padrao         = padrao,
        etag           = headers[["etag"]] %||% NA_character_,
        content_length = as.numeric(headers[["content-length"]] %||% NA)
      ))
    }
  }
  return(NULL)
}

classificar_mes <- function(ano, mes, info_servidor, controle) {
  if (is.null(info_servidor)) return("indisponivel")
  nome_zip <- glue("vacinacao_{MESES_PT[mes]}_{ano}_json.zip")
  registro <- controle |> filter(arquivo == nome_zip)
  if (nrow(registro) == 0) return("novo")

  etag_igual <- !is.na(registro$etag_servidor[1]) &&
    !is.na(info_servidor$etag) &&
    registro$etag_servidor[1] == info_servidor$etag
  cl_igual <- !is.na(registro$content_length[1]) &&
    !is.na(info_servidor$content_length) &&
    registro$content_length[1] == info_servidor$content_length

  if (etag_igual && cl_igual) return("inalterado")
  return("atualizado")
}

# ==============================================================================
# FUNÇÕES: LEITURA DO JSON (chunked)
# ==============================================================================

ler_json_chunked <- function(filepath) {
  file_size <- file.info(filepath)$size
  cat(glue("    Tamanho: {round(file_size / 1e9, 2)} GB"), "\n")

  con <- file(filepath, "rb")
  on.exit(close(con), add = TRUE)

  resultado <- list()
  sobra <- ""
  bytes_lidos <- 0
  chunk_num <- 0
  total_registros <- 0

  repeat {
    chunk_raw <- readBin(con, "raw", n = CHUNK_SIZE)
    if (length(chunk_raw) == 0) break

    chunk_num <- chunk_num + 1
    bytes_lidos <- bytes_lidos + length(chunk_raw)
    pct <- round(100 * bytes_lidos / file_size, 1)

    texto <- paste0(sobra, rawToChar(chunk_raw))
    sobra <- ""

    if (chunk_num == 1) texto <- sub("^\\s*\\[\\s*", "", texto)

    posicoes <- gregexpr("\\},\\s*\\{", texto)[[1]]

    if (posicoes[1] == -1) {
      sobra <- texto
      next
    }

    ultimo_delim <- posicoes[length(posicoes)]
    parte_parseavel <- substr(texto, 1, ultimo_delim)
    sobra <- substr(texto, ultimo_delim + 1, nchar(texto))
    sobra <- sub("^\\s*,\\s*", "", sobra)

    parte_parseavel <- sub("^\\s*,\\s*", "", parte_parseavel)
    parte_parseavel <- paste0("[", parte_parseavel, "]")

    df_chunk <- tryCatch(
      fromJSON(parte_parseavel, flatten = TRUE, simplifyDataFrame = TRUE),
      error = function(e) { cat(glue("    AVISO chunk {chunk_num}: {e$message}"), "\n"); NULL }
    )

    if (!is.null(df_chunk) && nrow(df_chunk) > 0) {
      df_chunk <- df_chunk |> mutate(across(everything(), as.character))
      resultado[[length(resultado) + 1]] <- df_chunk
      total_registros <- total_registros + nrow(df_chunk)
    }

    cat(glue("    Chunk {chunk_num}: {pct}% | ",
             "{format(total_registros, big.mark = '.')} registros"), "\n")
  }

  # Sobra final
  if (nchar(trimws(sobra)) > 2) {
    sobra_limpa <- sub("^\\s*,\\s*", "", sobra)
    sobra_limpa <- sub("\\s*\\]\\s*$", "", sobra_limpa)
    if (nchar(trimws(sobra_limpa)) > 2) {
      sobra_json <- paste0("[", sobra_limpa, "]")
      df_sobra <- tryCatch(
        fromJSON(sobra_json, flatten = TRUE, simplifyDataFrame = TRUE),
        error = function(e) { cat(glue("    AVISO sobra: {e$message}"), "\n"); NULL }
      )
      if (!is.null(df_sobra) && nrow(df_sobra) > 0) {
        df_sobra <- df_sobra |> mutate(across(everything(), as.character))
        resultado[[length(resultado) + 1]] <- df_sobra
        total_registros <- total_registros + nrow(df_sobra)
      }
    }
  }

  cat(glue("    Total: {format(total_registros, big.mark = '.')} registros"), "\n")
  if (length(resultado) == 0) stop("Nenhum registro parseado do JSON")
  bind_rows(resultado)
}

# ==============================================================================
# FUNÇÕES: UPLOAD PARA R2
# ==============================================================================

upload_para_r2 <- function(dir_parquet_local) {
  destino <- glue("{RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/")
  cat(glue("  Subindo para R2..."), "\n")

  args <- c("copy", shQuote(dir_parquet_local), destino,
            "--transfers", "16", "--checkers", "32",
            "--s3-no-check-bucket", "--stats", "0", "-v")

  resultado <- system2("rclone", args, stdout = TRUE, stderr = TRUE)
  status <- attr(resultado, "status")

  if (!is.null(status) && status != 0) {
    cat(paste(resultado, collapse = "\n"), "\n")
    stop("Upload para R2 falhou")
  }
  cat("  Upload concluido.\n")
  TRUE
}

verificar_upload <- function(dir_parquet_local) {
  arquivos_local <- dir_ls(dir_parquet_local, recurse = TRUE, glob = "*.parquet")
  n_local <- length(arquivos_local)

  destino <- glue("{RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/")
  resultado <- system2("rclone", c("ls", shQuote(destino)),
                        stdout = TRUE, stderr = TRUE)
  n_r2 <- length(grep("\\.parquet$", resultado))

  cat(glue("  Parquets locais: {n_local} | no R2: {n_r2}"), "\n")
  n_r2 >= n_local
}

# ==============================================================================
# FUNÇÃO PRINCIPAL: PROCESSAR UM MÊS
# ==============================================================================

processar_mes <- function(ano, mes, info_servidor) {
  url <- info_servidor$url
  dir_create(DIR_TEMP)
  nome_zip <- glue("vacinacao_{MESES_PT[mes]}_{ano}_json.zip")
  zip_path <- path(DIR_TEMP, nome_zip)

  # --- 1. Download (ou cache) ---
  if (file_exists(zip_path)) {
    tamanho_local <- file.info(zip_path)$size
    if (!is.na(info_servidor$content_length) &&
        tamanho_local == info_servidor$content_length) {
      cat(glue("  Cache local OK ({nome_zip})"), "\n")
    } else {
      cat(glue("  Cache difere. Rebaixando..."), "\n")
      curl::curl_download(url, zip_path, quiet = FALSE,
                          handle = curl::new_handle(connecttimeout = 30,
                                                    timeout = 3600))
    }
  } else {
    cat(glue("  Baixando {nome_zip}..."), "\n")
    tryCatch(
      curl::curl_download(url, zip_path, quiet = FALSE,
                          handle = curl::new_handle(connecttimeout = 30,
                                                    timeout = 3600)),
      error = function(e) stop(glue("Erro no download: {e$message}"))
    )
  }

  hash_zip <- digest::digest(file = zip_path, algo = "md5")
  cat(glue("  MD5: {hash_zip}"), "\n")

  # --- 2. Listar TODAS as partes JSON dentro do zip ---
  conteudo_zip <- unzip(zip_path, list = TRUE)
  json_nomes <- sort(conteudo_zip$Name[grepl("\\.(json|JSON)$",
                                              conteudo_zip$Name)])
  n_partes <- length(json_nomes)

  if (n_partes == 0) stop("Nenhum JSON encontrado dentro do zip")

  cat(glue("  {n_partes} parte(s) JSON no zip"), "\n")

  # --- 3. Preparar diretórios ---
  dir_json <- path(DIR_TEMP, glue("json_{MESES_PT[mes]}_{ano}"))
  dir_create(dir_json)

  dir_staging <- path(DIR_TEMP, "staging_parquet")
  deletar_com_retry(dir_staging)
  dir_create(dir_staging)

  n_total <- 0

  # --- 4. Processar cada parte individualmente ---
  for (p in seq_along(json_nomes)) {
    cat(glue("\n  --- Parte {p}/{n_partes}: {json_nomes[p]} ---"), "\n")

    # Extrair só esta parte
    unzip(zip_path, files = json_nomes[p], exdir = dir_json, overwrite = TRUE)
    json_path <- path(dir_json, json_nomes[p])

    # Ler
    df <- ler_json_chunked(json_path)

    # Deletar JSON extraído imediatamente
    deletar_com_retry(json_path)

    # Preparar
    df <- df |> mutate(across(everything(), as.character))

    df_prep <- df |>
      mutate(
        ano = substr(dt_vacina, 1, 4),
        mes = substr(dt_vacina, 6, 7),
        uf  = sg_uf_estabelecimento
      ) |>
      filter(
        !is.na(uf), nchar(uf) == 2,
        !is.na(ano), nchar(ano) == 4,
        !is.na(mes)
      ) |>
      # Redirect records with invalid years to ano=_invalid
      mutate(
        ano = if_else(ano >= "2020" & ano <= format(Sys.Date(), "%Y"),
                      ano, "_invalid")
      )

    n_parte <- nrow(df_prep)
    n_total <- n_total + n_parte
    cat(glue("    {format(n_parte, big.mark = '.')} registros validos"), "\n")

    # Gravar Parquet com nome único por parte
    # Cada parte gera arquivos em suas partições sem sobrescrever partes anteriores
    sufixo <- sprintf("%05d", p)

    df_prep |>
      dplyr::group_by(ano, mes, uf) |>
      dplyr::group_walk(function(.x, .y) {
        dir_part <- path(dir_staging,
                         paste0("ano=", .y$ano),
                         paste0("mes=", .y$mes),
                         paste0("uf=", .y$uf))
        dir_create(dir_part)
        arrow::write_parquet(
          .x,
          path(dir_part, glue("part-{sufixo}.parquet"))
        )
      })

    rm(df, df_prep)
    gc(verbose = FALSE)
  }

  cat(glue("\n  Total do mes: {format(n_total, big.mark = '.')} registros ",
           "em {n_partes} parte(s)"), "\n")

  # Limpar dir de extração
  deletar_com_retry(dir_json)

  # --- 5. Upload para R2 ---
  upload_para_r2(dir_staging)

  # --- 6. Verificar ---
  upload_ok <- verificar_upload(dir_staging)

  if (!upload_ok) {
    cat("  AVISO: upload pode estar incompleto. Mantendo arquivos locais.\n")
    return(invisible(n_total))
  }

  # --- 7. Atualizar controle ---
  controle <- carregar_controle()

  novo <- tibble(
    arquivo            = nome_zip,
    etag_servidor      = info_servidor$etag %||% NA_character_,
    content_length     = info_servidor$content_length %||% NA_real_,
    hash_md5_zip       = hash_zip,
    n_registros        = n_total,
    n_partes_json      = n_partes,
    data_processamento = as.character(Sys.time()),
    ano                = ano,
    mes                = mes,
    url_origem         = url
  )

  controle <- controle |>
    filter(arquivo != nome_zip) |>
    bind_rows(novo)

  salvar_controle(controle)

  # --- 8. Limpar TUDO ---
  deletar_com_retry(dir_staging)
  deletar_com_retry(zip_path)

  cat(glue("  OK: {MESES_PT[mes]}/{ano} - ",
           "{format(n_total, big.mark = '.')} registros ",
           "({n_partes} partes) -> R2"), "\n")
  invisible(n_total)
}

# ==============================================================================
# EXECUÇÃO
# ==============================================================================

cat("\n")
cat(strrep("=", 70), "\n")
cat("  Pipeline: JSON (OpenDATASUS) -> Parquet -> Cloudflare R2\n")
cat(strrep("=", 70), "\n\n")

cat("Verificando pre-requisitos...\n")
verificar_rclone()
cat("\n")

cat(glue("Temp:    {DIR_TEMP}"), "\n")
cat(glue("Destino: {RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/"), "\n")
cat(glue("Chunk:   {CHUNK_SIZE / 1e6} MB"), "\n\n")

t_inicio <- Sys.time()

ano_atual <- as.integer(format(Sys.Date(), "%Y"))
mes_atual <- as.integer(format(Sys.Date(), "%m"))

grade <- expand.grid(
  mes = 1:12,
  ano = ANO_INICIO:ano_atual,
  stringsAsFactors = FALSE
) |>
  filter(!(ano == ano_atual & mes > mes_atual)) |>
  arrange(ano, mes)

cat(glue("Meses a verificar: {nrow(grade)}"), "\n")
cat("Consultando servidor (HEAD requests)...\n\n")

# --- Fase 1: HEAD requests ---------------------------------------------------

controle <- carregar_controle()

plano <- list()
n_novo <- 0; n_atualizado <- 0; n_inalterado <- 0; n_indisponivel <- 0

for (i in seq_len(nrow(grade))) {
  ano <- grade$ano[i]
  mes <- grade$mes[i]

  info <- consultar_servidor(ano, mes)
  status <- classificar_mes(ano, mes, info, controle)

  rotulo <- switch(status,
    novo         = ">> NOVO",
    atualizado   = ">> ATUALIZADO",
    inalterado   = "   inalterado",
    indisponivel = "   indisponivel"
  )
  cat(glue("  {MESES_PT[mes]}/{ano}: {rotulo}"), "\n")

  if (status %in% c("novo", "atualizado")) {
    plano[[length(plano) + 1]] <- list(
      ano = ano, mes = mes, info = info, status = status
    )
  }

  switch(status,
    novo         = { n_novo <- n_novo + 1 },
    atualizado   = { n_atualizado <- n_atualizado + 1 },
    inalterado   = { n_inalterado <- n_inalterado + 1 },
    indisponivel = { n_indisponivel <- n_indisponivel + 1 }
  )
  Sys.sleep(0.3)
}

cat(glue("\nResumo:"), "\n")
cat(glue("  Novos:         {n_novo}"), "\n")
cat(glue("  Atualizados:   {n_atualizado}"), "\n")
cat(glue("  Inalterados:   {n_inalterado}"), "\n")
cat(glue("  Indisponiveis: {n_indisponivel}"), "\n")
cat(glue("  A processar:   {length(plano)}"), "\n\n")

# --- Fase 2: Download, conversão e upload ------------------------------------

if (length(plano) == 0) {
  cat("Nada a fazer. Todos os meses estao atualizados.\n")
} else {
  cat(strrep("-", 70), "\n")
  cat(glue("Processando {length(plano)} meses..."), "\n")
  cat(strrep("-", 70), "\n")

  for (item in plano) {
    cat("\n", strrep("=", 70), "\n")
    cat(glue("{MESES_PT[item$mes]}/{item$ano} ({item$status})"), "\n")
    cat(strrep("=", 70), "\n\n")

    tryCatch(
      processar_mes(item$ano, item$mes, item$info),
      error = function(e) {
        cat(glue("  ERRO: {e$message}"), "\n\n")
      }
    )
  }
}

t_fim <- Sys.time()
cat(glue("\n\nTempo total: {round(difftime(t_fim, t_inicio, units = 'mins'), 1)} min"), "\n")

# --- Verificação final --------------------------------------------------------

cat("\n", strrep("=", 70), "\n")
cat("  Verificacao final\n")
cat(strrep("=", 70), "\n\n")

if (file_exists(CONTROLE_CSV)) {
  ctrl <- readr::read_csv(CONTROLE_CSV, show_col_types = FALSE)

  cat(glue("Meses processados: {nrow(ctrl)}"), "\n")
  cat(glue("Registros totais:  {format(sum(ctrl$n_registros), big.mark = '.')}"), "\n\n")

  ctrl |>
    select(arquivo, n_partes_json, n_registros, data_processamento) |>
    print(n = 100)
}

cat("\nPipeline concluido.\n")
