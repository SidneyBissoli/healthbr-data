## ============================================================================
## verificar_json_disponivel.R (v3)
## Objetivo: (1) Mapear quais meses/anos têm JSON disponível no S3
##           (2) Baixar um JSON disponível e comparar com CSV do mesmo mês
##
## NOTA: Os JSONs do Ministério podem ser uma única linha gigantesca (>2GB),
##       impossibilitando readLines(). Usamos leitura binária parcial.
## ============================================================================

library(jsonlite)
library(httr)

options(timeout = 600)  # 10 minutos para downloads grandes

# ── PARTE 1: TESTAR DISPONIBILIDADE DO JSON POR ANO ────────────────────────

cat("================================================================\n")
cat("PARTE 1: MAPEANDO DISPONIBILIDADE DE JSON\n")
cat("================================================================\n\n")

meses <- c("jan", "fev", "mar", "abr", "mai", "jun",
           "jul", "ago", "set", "out", "nov", "dez")
anos <- 2020:2025

# Dois padrões de URL observados:
#   2020-2024: vacinacao_jan_2024.json.zip   (ponto antes de json)
#   2025:      vacinacao_jan_2025_json.zip    (underscore antes de json)
padrao_antigo <- "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_%s_%s.json.zip"
padrao_novo   <- "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_%s_%s_json.zip"

# CSV (arquivosdadosabertos)
padrao_csv <- "https://arquivosdadosabertos.saude.gov.br/dados/dbbni/vacinacao_%s_%s_csv.zip"

# Função: HEAD request → status code
url_exists <- function(url) {
  tryCatch({
    resp <- HEAD(url, timeout(15))
    status_code(resp)
  }, error = function(e) NA)
}

# Função: testa ambos os padrões JSON, retorna o que funcionar
json_url_check <- function(mes, ano) {
  url1 <- sprintf(padrao_antigo, mes, ano)
  url2 <- sprintf(padrao_novo, mes, ano)
  s1 <- url_exists(url1)
  if (!is.na(s1) && s1 == 200) return(list(status = 200, url = url1, padrao = "antigo (.json.zip)"))
  s2 <- url_exists(url2)
  if (!is.na(s2) && s2 == 200) return(list(status = 200, url = url2, padrao = "novo (_json.zip)"))
  s <- ifelse(!is.na(s1), s1, ifelse(!is.na(s2), s2, NA))
  return(list(status = s, url = NA, padrao = NA))
}

# ── Testar jan de cada ano ──
cat("Testando jan de cada ano (JSON ambos padrões + CSV):\n\n")
cat(sprintf("%-10s  %-8s  %-25s  %-8s\n", "Mês/Ano", "JSON", "Padrão URL", "CSV"))
cat(paste(rep("-", 60), collapse = ""), "\n")

for (ano in anos) {
  res <- json_url_check("jan", ano)
  csv_status <- url_exists(sprintf(padrao_csv, "jan", ano))

  cat(sprintf("%-10s  %-8s  %-25s  %-8s\n",
              paste0("jan/", ano),
              ifelse(is.na(res$status), "ERRO", as.character(res$status)),
              ifelse(is.na(res$padrao), "-", res$padrao),
              ifelse(is.na(csv_status), "ERRO", as.character(csv_status))))
}

# ── Testar todos os meses de 2024 e 2025 ──
cat("\n\nTodos os meses de 2024 e 2025 (JSON):\n\n")
cat(sprintf("%-12s  %-8s  %-25s\n", "Mês/Ano", "Status", "Padrão"))
cat(paste(rep("-", 50), collapse = ""), "\n")

for (ano in 2024:2025) {
  for (mes in meses) {
    res <- json_url_check(mes, ano)
    cat(sprintf("%-12s  %-8s  %-25s\n",
                paste0(mes, "/", ano),
                ifelse(is.na(res$status), "ERRO",
                       ifelse(res$status == 200, "200 ✓",
                              paste0(res$status, " ✗"))),
                ifelse(is.na(res$padrao), "-", res$padrao)))
  }
}


# ── PARTE 2: COMPARAR JSON vs CSV DO MESMO MÊS ─────────────────────────────

cat("\n\n================================================================\n")
cat("PARTE 2: COMPARANDO JSON vs CSV (jan/2025)\n")
cat("================================================================\n\n")

dir_trabalho <- file.path(tempdir(), "json_vs_csv")
dir.create(dir_trabalho, showWarnings = FALSE, recursive = TRUE)

# --- Baixar JSON ---
cat("Baixando JSON...\n")
url_json <- sprintf(padrao_novo, "jan", "2025")
zip_json <- file.path(dir_trabalho, "json.zip")
has_json <- tryCatch({
  download.file(url_json, zip_json, mode = "wb", quiet = TRUE)
  unzip(zip_json, exdir = file.path(dir_trabalho, "json"), overwrite = TRUE)
  TRUE
}, error = function(e) { cat("ERRO JSON:", e$message, "\n"); FALSE })

# --- Baixar CSV ---
cat("Baixando CSV...\n")
url_csv <- sprintf(padrao_csv, "jan", "2025")
zip_csv <- file.path(dir_trabalho, "csv.zip")
has_csv <- tryCatch({
  download.file(url_csv, zip_csv, mode = "wb", quiet = TRUE)
  unzip(zip_csv, exdir = file.path(dir_trabalho, "csv"), overwrite = TRUE)
  TRUE
}, error = function(e) { cat("ERRO CSV:", e$message, "\n"); FALSE })

# --- Localizar arquivos ---
json_file <- list.files(file.path(dir_trabalho, "json"), pattern = "\\.(json|JSON)$",
                        full.names = TRUE, recursive = TRUE)[1]
csv_file  <- list.files(file.path(dir_trabalho, "csv"), pattern = "\\.(csv|CSV)$",
                        full.names = TRUE, recursive = TRUE)[1]

if (has_json) cat("JSON:", json_file, "\n")
if (has_csv)  cat("CSV: ", csv_file, "\n")
cat("\n")


# --- Ler JSON (primeiros registros) ---
# NOTA: O JSON do Ministério é frequentemente um array inteiro em uma única
#       linha, excedendo o limite de 2^31-1 bytes do R para strings.
#       Solução: leitura binária parcial dos primeiros N bytes,
#       corte no último registro completo, e parse do fragmento.
json_data <- NULL
if (has_json && !is.na(json_file)) {
  cat("Inspecionando JSON via leitura binária...\n")

  con <- file(json_file, "rb")
  chunk_raw <- readBin(con, "raw", n = 100000)  # 100KB
  close(con)
  chunk_text <- rawToChar(chunk_raw)

  cat("Primeiros 200 chars:\n", substr(chunk_text, 1, 200), "\n\n")

  json_data <- tryCatch({
    # Localizar os primeiros ~10 registros completos (terminam em },)
    pos <- gregexpr("\\},", chunk_text)[[1]]
    if (pos[1] == -1) stop("Não encontrei delimitador }, no chunk")

    n_registros <- min(10, length(pos))
    corte <- pos[n_registros]
    chunk_parcial <- substr(chunk_text, 1, corte)

    # Garantir que começa com [ e termina com }]
    chunk_parcial <- sub("^\\s*\\[?\\s*", "[", chunk_parcial)
    chunk_parcial <- paste0(chunk_parcial, "}]")

    df <- fromJSON(chunk_parcial, flatten = TRUE)
    cat("JSON parseado:", nrow(df), "registros x", ncol(df), "colunas\n\n")
    df
  }, error = function(e) {
    cat("Erro ao parsear JSON:", e$message, "\n")
    NULL
  })
}


# --- Ler CSV como texto puro ---
csv_linhas <- NULL
if (has_csv && !is.na(csv_file)) {
  # CSV também pode ter linhas muito longas, mas tipicamente tem quebras.
  # Usar leitura binária por segurança.
  con <- file(csv_file, "rb")
  chunk_raw <- readBin(con, "raw", n = 50000)  # 50KB
  close(con)
  chunk_text <- rawToChar(chunk_raw)

  # Dividir por quebra de linha
  csv_linhas <- strsplit(chunk_text, "\r?\n")[[1]]
  csv_linhas <- csv_linhas[nchar(csv_linhas) > 0]

  cat("CSV: ", length(csv_linhas), "linhas lidas do chunk\n")
  cat("CSV header (primeiros 200 chars):\n", substr(csv_linhas[1], 1, 200), "\n\n")
}


# --- Comparação lado a lado ---
if (!is.null(json_data) && !is.null(csv_linhas)) {

  cat("═══════════════════════════════════════════════════════════════\n")
  cat("COMPARAÇÃO CAMPO A CAMPO: JSON vs CSV BRUTO\n")
  cat("═══════════════════════════════════════════════════════════════\n\n")

  # Detectar header CSV
  header_csv <- strsplit(csv_linhas[1], ";")[[1]]
  header_csv <- gsub('^"|"$', "", header_csv)
  data_start <- if (any(grepl("co_documento|co_vacina", header_csv))) 2 else 1

  # Campos de interesse
  campos <- c("co_documento", "co_municipio_paciente", "co_pais_paciente",
              "nu_cep_paciente", "co_raca_cor_paciente",
              "co_cnes_estabelecimento", "co_municipio_estabelecimento",
              "co_vacina", "co_dose_vacina",
              "co_estrategia_vacinacao", "co_vacina_grupo_atendimento",
              "co_vacina_categoria_atendimento", "co_vacina_fabricante",
              "nu_idade_paciente", "dt_vacina", "dt_nascimento_paciente")

  for (campo in campos) {
    cat(sprintf("─── %s ───\n", campo))

    # CSV: localizar posição pelo header
    csv_pos <- which(header_csv == campo)
    csv_vals <- character(0)
    if (length(csv_pos) == 0) {
      cat("  CSV: campo não encontrado no header\n")
    } else {
      for (j in data_start:min(length(csv_linhas), data_start + 4)) {
        parts <- strsplit(csv_linhas[j], ";")[[1]]
        if (length(parts) >= csv_pos) {
          csv_vals <- c(csv_vals, gsub('^"|"$', "", parts[csv_pos]))
        }
      }
      cat(sprintf("  CSV (bruto):  %s\n", paste(csv_vals, collapse = " | ")))
    }

    # JSON: buscar coluna
    json_col <- NULL
    if (campo %in% names(json_data)) {
      json_col <- campo
    } else {
      candidatos <- grep(gsub("co_|nu_", "", campo), names(json_data),
                         value = TRUE, ignore.case = TRUE)
      if (length(candidatos) > 0) json_col <- candidatos[1]
    }

    json_vals <- character(0)
    if (!is.null(json_col)) {
      json_vals <- head(as.character(json_data[[json_col]]), 5)
      json_vals <- json_vals[!is.na(json_vals)]
      cat(sprintf("  JSON (%s): %s\n", json_col, paste(json_vals, collapse = " | ")))
    } else {
      cat("  JSON: campo não encontrado\n")
    }

    # Diagnóstico
    if (length(csv_vals) > 0 && length(json_vals) > 0) {
      csv_tem_float <- any(grepl("\\.0$", csv_vals))
      json_tem_float <- any(grepl("\\.0$", json_vals))
      csv_tem_zero  <- any(grepl("^0", csv_vals))
      json_tem_zero <- any(grepl("^0", json_vals))

      if (csv_tem_float && !json_tem_float) cat("  ⚠ CSV tem .0, JSON não\n")
      if (!csv_tem_zero && json_tem_zero)   cat("  ⚠ JSON preserva zeros líderes, CSV não\n")
      if (!csv_tem_float && !json_tem_float) cat("  ✓ Ambos sem .0\n")
      if (csv_tem_zero && json_tem_zero)     cat("  ✓ Ambos preservam zeros líderes\n")
    }
    cat("\n")
  }

  # Resumo colunas JSON
  cat("\n═══════════════════════════════════════════════════════════════\n")
  cat("TODAS AS COLUNAS DO JSON (nome, tipo R, amostra)\n")
  cat("═══════════════════════════════════════════════════════════════\n\n")

  for (col in sort(names(json_data))) {
    vals <- json_data[[col]]
    tipo <- class(vals)[1]
    vals_nna <- vals[!is.na(vals) & as.character(vals) != ""]
    amostra <- if (length(vals_nna) > 0) {
      paste(head(unique(as.character(vals_nna)), 4), collapse = " | ")
    } else { "(vazio)" }
    cat(sprintf("  %-45s [%-10s] %s\n", col, tipo, substr(amostra, 1, 80)))
  }

  # Comparação de colunas entre formatos
  cat("\n═══════════════════════════════════════════════════════════════\n")
  cat("COLUNAS: JSON vs CSV\n")
  cat("═══════════════════════════════════════════════════════════════\n\n")

  cols_json <- sort(names(json_data))
  cols_csv  <- sort(header_csv)

  em_ambos   <- intersect(cols_json, cols_csv)
  so_json    <- setdiff(cols_json, cols_csv)
  so_csv     <- setdiff(cols_csv, cols_json)

  cat("Em ambos (", length(em_ambos), "):", paste(em_ambos, collapse = ", "), "\n\n")
  cat("Só no JSON (", length(so_json), "):", paste(so_json, collapse = ", "), "\n\n")
  cat("Só no CSV  (", length(so_csv), "):", paste(so_csv, collapse = ", "), "\n\n")
}

cat("\n\nScript concluído.\n")
