## ============================================================================
## comparar_formatos_csv_json_xml.R
## Objetivo: Verificar se os sufixos ".0" e perda de zeros à esquerda em
##           campos como co_municipio_paciente e nu_cep_paciente são artefatos
##           do CSV ou existem também no JSON e XML.
## ============================================================================

library(readr)
library(jsonlite)
library(xml2)

# Campos suspeitos (vieram com .0 ou zeros à esquerda perdidos no CSV)
campos_suspeitos <- c(
  "co_municipio_paciente",      # 110001.0 no CSV (deveria ser 110001 ou 0110001?)
  "co_pais_paciente",           # 10.0 no CSV
  "nu_cep_paciente",            # 1001.0 no CSV (deveria ser 00001001?)
  "co_estrategia_vacinacao",    # 1.0 no CSV
  "co_origem_registro",         # 1.0 no CSV
  "co_vacina_grupo_atendimento",# 0.0, 210.0, etc no CSV
  "co_vacina_categoria_atendimento", # 15.0 no CSV
  "co_vacina_fabricante",       # 142.0 no CSV
  "co_condicao_maternal",       # 1.0 no CSV
  "co_municipio_estabelecimento" # 110001 (sem .0, comparar)
)

# ── 1. BAIXAR OS TRÊS FORMATOS DO MESMO MÊS ────────────────────────────────

mes <- "jan"
ano <- "2020"

urls <- list(
  csv  = paste0("https://arquivosdadosabertos.saude.gov.br/dados/dbbni/vacinacao_", mes, "_", ano, "_csv.zip"),
  json = paste0("https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_", mes, "_", ano, "_json.zip"),
  xml  = paste0("https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/xml/vacinacao_", mes, "_", ano, "_xml.zip")
)

dir_trabalho <- file.path(tempdir(), "comparar_formatos")
dir.create(dir_trabalho, showWarnings = FALSE)

# Nomes oficiais das 55 colunas do CSV
nomes_csv <- c(
  "co_documento", "co_paciente", "tp_sexo_paciente",
  "co_raca_cor_paciente", "no_raca_cor_paciente",
  "co_municipio_paciente", "co_pais_paciente",
  "no_municipio_paciente", "no_pais_paciente",
  "sg_uf_paciente", "nu_cep_paciente",
  "ds_nacionalidade_paciente", "no_etnia_indigena_paciente",
  "co_etnia_indigena_paciente", "co_cnes_estabelecimento",
  "no_razao_social_estabelecimento", "no_fantasia_estalecimento",
  "co_municipio_estabelecimento", "no_municipio_estabelecimento",
  "sg_uf_estabelecimento", "co_troca_documento",
  "co_vacina", "sg_vacina", "dt_vacina",
  "co_dose_vacina", "ds_dose_vacina",
  "co_local_aplicacao", "ds_local_aplicacao",
  "co_via_administracao", "ds_via_administracao",
  "co_lote_vacina", "ds_vacina_fabricante",
  "dt_entrada_rnds", "co_sistema_origem", "ds_sistema_origem",
  "st_documento", "co_estrategia_vacinacao", "ds_estrategia_vacinacao",
  "co_origem_registro", "ds_origem_registro",
  "co_vacina_grupo_atendimento", "ds_vacina_grupo_atendimento",
  "co_vacina_categoria_atendimento", "ds_vacina_categoria_atendimento",
  "co_vacina_fabricante", "ds_vacina",
  "ds_condicao_maternal", "co_tipo_estabelecimento",
  "ds_tipo_estabelecimento", "co_natureza_estabelecimento",
  "ds_natureza_estabelecimento", "nu_idade_paciente",
  "co_condicao_maternal", "no_uf_paciente", "no_uf_estabelecimento"
)


# ── 2. LER CSV ──────────────────────────────────────────────────────────────

cat("\n========================================\n")
cat("BAIXANDO E LENDO CSV...\n")
cat("========================================\n")

zip_csv <- file.path(dir_trabalho, "csv.zip")
download.file(urls$csv, zip_csv, mode = "wb", quiet = TRUE)
unzip(zip_csv, exdir = file.path(dir_trabalho, "csv"))
csv_file <- list.files(file.path(dir_trabalho, "csv"), pattern = "\\.csv$",
                       full.names = TRUE, recursive = TRUE)[1]

# Verificar se a primeira linha é header
primeira_linha <- readLines(csv_file, n = 1, encoding = "Latin1")
cat("Primeira linha do CSV (primeiros 200 chars):\n")
cat(substr(primeira_linha, 1, 200), "\n\n")

# Ler primeiras 100 linhas (tudo character, sem header)
csv_raw <- read_delim(csv_file, delim = ";", col_names = FALSE,
                      col_types = cols(.default = col_character()),
                      locale = locale(encoding = "Latin1"),
                      n_max = 100, show_col_types = FALSE)
if (ncol(csv_raw) >= 56) csv_raw <- csv_raw[, 1:55]
names(csv_raw) <- nomes_csv

# Checar se a linha 1 parece header
cat("Linha 1, co_documento:", csv_raw$co_documento[1], "\n")
cat("Linha 2, co_documento:", csv_raw$co_documento[2], "\n\n")

# Se a primeira linha for header, remover
if (csv_raw$co_documento[1] == "co_documento") {
  cat(">>> CONFIRMADO: a primeira linha É header. Removendo.\n\n")
  csv_data <- csv_raw[-1, ]
} else {
  cat(">>> A primeira linha NÃO é header.\n\n")
  csv_data <- csv_raw
}


# ── 3. LER JSON ─────────────────────────────────────────────────────────────

cat("\n========================================\n")
cat("BAIXANDO E LENDO JSON...\n")
cat("========================================\n")

zip_json <- file.path(dir_trabalho, "json.zip")
tryCatch({
  download.file(urls$json, zip_json, mode = "wb", quiet = TRUE)
  unzip(zip_json, exdir = file.path(dir_trabalho, "json"))
  json_file <- list.files(file.path(dir_trabalho, "json"), pattern = "\\.json$",
                          full.names = TRUE, recursive = TRUE)[1]

  # JSON pode ser enorme — ler apenas primeiras linhas
  # Tentar streaming (cada linha é um objeto JSON)
  json_lines <- readLines(json_file, n = 110, encoding = "UTF-8")

  # Verificar formato: array [ ] ou ndjson (uma linha por registro)
  cat("Primeiros 200 chars do JSON:\n")
  cat(substr(json_lines[1], 1, 200), "\n\n")

  # Tentar parsear como array JSON
  json_text <- paste(json_lines, collapse = "\n")

  # Se começa com [, é array
  if (grepl("^\\s*\\[", json_lines[1])) {
    # Fechar o array truncado para parsear
    json_text_closed <- paste0(json_text, "\n]")
    json_data <- tryCatch(
      fromJSON(json_text_closed, flatten = TRUE),
      error = function(e) {
        # Tentar parsear o texto original
        fromJSON(json_text, flatten = TRUE)
      }
    )
  } else {
    # ndjson — parsear linha a linha
    json_data <- stream_in(textConnection(paste(json_lines, collapse = "\n")),
                           verbose = FALSE)
  }

  cat("JSON lido:", nrow(json_data), "registros\n")
  cat("Colunas do JSON:", paste(head(names(json_data), 20), collapse = ", "), "...\n\n")

  has_json <- TRUE
}, error = function(e) {
  cat("ERRO ao baixar/ler JSON:", e$message, "\n")
  cat("Tentando abordagem alternativa...\n\n")
  has_json <<- FALSE
})

# Se falhou acima, tentar ler só as primeiras linhas manualmente
if (!has_json) {
  tryCatch({
    con <- file(json_file, "r", encoding = "UTF-8")
    raw <- readLines(con, n = 200)
    close(con)

    # Remover [ do início e extrair objetos JSON individuais
    raw_text <- paste(raw, collapse = "")
    raw_text <- gsub("^\\s*\\[\\s*", "", raw_text)
    # Separar por }{ ou },{ pattern
    registros <- strsplit(raw_text, "\\}\\s*,\\s*\\{")[[1]]
    # Remontar cada registro como JSON válido
    registros <- paste0("{", registros, "}")
    registros[1] <- sub("^\\{\\{", "{", registros[1])

    json_data <- do.call(rbind, lapply(head(registros, 50), function(x) {
      tryCatch(as.data.frame(fromJSON(x), stringsAsFactors = FALSE),
               error = function(e) NULL)
    }))

    cat("JSON (alternativo) lido:", nrow(json_data), "registros\n")
    cat("Colunas:", paste(head(names(json_data), 20), collapse = ", "), "...\n\n")
    has_json <- TRUE
  }, error = function(e) {
    cat("JSON indisponível ou formato não suportado:", e$message, "\n\n")
    has_json <<- FALSE
  })
}


# ── 4. LER XML ──────────────────────────────────────────────────────────────

cat("\n========================================\n")
cat("BAIXANDO E LENDO XML...\n")
cat("========================================\n")

has_xml <- FALSE
zip_xml <- file.path(dir_trabalho, "xml.zip")
tryCatch({
  download.file(urls$xml, zip_xml, mode = "wb", quiet = TRUE)
  unzip(zip_xml, exdir = file.path(dir_trabalho, "xml"))
  xml_file <- list.files(file.path(dir_trabalho, "xml"), pattern = "\\.xml$",
                         full.names = TRUE, recursive = TRUE)[1]

  # XML é gigante — ler só o início para entender a estrutura
  xml_head <- readLines(xml_file, n = 200, encoding = "UTF-8")
  cat("Primeiros 500 chars do XML:\n")
  cat(substr(paste(xml_head, collapse = "\n"), 1, 500), "\n\n")

  # Tentar parsear o início como XML parcial
  # Procurar tags de registro
  xml_text <- paste(xml_head, collapse = "\n")

  # Identificar padrão dos registros
  cat("Estrutura (primeiras tags):\n")
  tags <- regmatches(xml_text, gregexpr("<[^/!?][^>]*>", xml_text))[[1]]
  cat(paste(head(unique(tags), 20), collapse = "\n"), "\n\n")

  # Tentar parsear com xml2 (se o arquivo não for muito grande)
  # Para arquivos muito grandes, extrair manualmente
  if (file.size(xml_file) < 500e6) {
    doc <- read_xml(xml_file)
    registros_xml <- xml_find_all(doc, ".//row|.//record|.//item|.//vacinacao")
    if (length(registros_xml) == 0) {
      # Tentar encontrar qualquer elemento repetido
      filhos <- xml_children(xml_root(doc))
      registros_xml <- head(filhos, 50)
    }
    cat("Registros XML encontrados:", length(registros_xml), "(mostrando até 50)\n")

    if (length(registros_xml) > 0) {
      # Extrair campos do primeiro registro
      primeiro <- registros_xml[[1]]
      campos_xml <- xml_children(primeiro)
      cat("Campos no primeiro registro XML:\n")
      for (campo in campos_xml) {
        cat(sprintf("  <%s>%s</%s>\n",
                    xml_name(campo),
                    substr(xml_text(campo), 1, 60),
                    xml_name(campo)))
      }
      cat("\n")

      # Converter primeiros 50 registros para data.frame
      xml_data <- do.call(rbind, lapply(head(registros_xml, 50), function(reg) {
        filhos <- xml_children(reg)
        vals <- setNames(xml_text(filhos), xml_name(filhos))
        as.data.frame(t(vals), stringsAsFactors = FALSE)
      }))

      has_xml <- TRUE
      cat("XML lido:", nrow(xml_data), "registros x", ncol(xml_data), "colunas\n\n")
    }
  } else {
    cat("Arquivo XML muito grande (", file.size(xml_file) / 1e9, " GB). ",
        "Extraindo manualmente primeiros registros...\n")
  }
}, error = function(e) {
  cat("ERRO ao baixar/ler XML:", e$message, "\n\n")
})


# ── 5. COMPARAÇÃO DOS CAMPOS SUSPEITOS ──────────────────────────────────────

cat("\n========================================\n")
cat("COMPARAÇÃO DOS CAMPOS SUSPEITOS\n")
cat("========================================\n\n")

# Para cada campo suspeito, mostrar os primeiros valores em cada formato
for (campo in campos_suspeitos) {

  cat(sprintf("─── %s ───\n", campo))

  # CSV
  if (campo %in% names(csv_data)) {
    vals_csv <- head(csv_data[[campo]][!is.na(csv_data[[campo]]) &
                                       csv_data[[campo]] != ""], 5)
    cat(sprintf("  CSV:  %s\n", paste(vals_csv, collapse = " | ")))
  } else {
    cat("  CSV:  (campo não encontrado)\n")
  }

  # JSON
  if (has_json) {
    # Tentar nome exato e variantes
    campo_json <- campo
    if (!campo_json %in% names(json_data)) {
      # Tentar com prefixo/sufixo diferente
      matches <- grep(gsub("co_|no_|ds_|sg_|nu_|tp_|st_|dt_", "", campo),
                      names(json_data), value = TRUE, ignore.case = TRUE)
      if (length(matches) > 0) campo_json <- matches[1]
    }

    if (campo_json %in% names(json_data)) {
      vals_json <- head(json_data[[campo_json]][!is.na(json_data[[campo_json]]) &
                                                 json_data[[campo_json]] != ""], 5)
      cat(sprintf("  JSON: %s\n", paste(vals_json, collapse = " | ")))
    } else {
      cat(sprintf("  JSON: (campo '%s' não encontrado. Disponíveis: %s)\n",
                  campo, paste(head(names(json_data), 10), collapse = ", ")))
    }
  } else {
    cat("  JSON: (indisponível)\n")
  }

  # XML
  if (has_xml) {
    campo_xml <- campo
    if (!campo_xml %in% names(xml_data)) {
      matches <- grep(gsub("co_|no_|ds_|sg_|nu_|tp_|st_|dt_", "", campo),
                      names(xml_data), value = TRUE, ignore.case = TRUE)
      if (length(matches) > 0) campo_xml <- matches[1]
    }

    if (campo_xml %in% names(xml_data)) {
      vals_xml <- head(xml_data[[campo_xml]][!is.na(xml_data[[campo_xml]]) &
                                              xml_data[[campo_xml]] != ""], 5)
      cat(sprintf("  XML:  %s\n", paste(vals_xml, collapse = " | ")))
    } else {
      cat(sprintf("  XML:  (campo '%s' não encontrado)\n", campo))
    }
  } else {
    cat("  XML:  (indisponível)\n")
  }

  cat("\n")
}


# ── 6. RESUMO DE NOMES DE CAMPOS POR FORMATO ───────────────────────────────

cat("\n========================================\n")
cat("NOMES DE CAMPOS POR FORMATO\n")
cat("========================================\n\n")

cat("CSV (55 colunas, nomes atribuídos por nós):\n")
cat(paste(nomes_csv, collapse = "\n"), "\n\n")

if (has_json) {
  cat("JSON (", ncol(json_data), " colunas, nomes nativos):\n")
  cat(paste(names(json_data), collapse = "\n"), "\n\n")
}

if (has_xml) {
  cat("XML (", ncol(xml_data), " colunas, nomes nativos):\n")
  cat(paste(names(xml_data), collapse = "\n"), "\n\n")
}


# ── 7. TIPAGEM DO JSON (referência) ────────────────────────────────────────

if (has_json) {
  cat("\n========================================\n")
  cat("TIPOS NATIVOS NO JSON (typeof de cada campo)\n")
  cat("========================================\n\n")

  for (col in names(json_data)) {
    vals <- json_data[[col]]
    vals_nna <- vals[!is.na(vals)]
    if (length(vals_nna) == 0) {
      cat(sprintf("  %s: (tudo NA)\n", col))
      next
    }
    tipo_r <- class(vals_nna)[1]
    amostra <- paste(head(unique(vals_nna), 5), collapse = " | ")
    cat(sprintf("  %s [%s]: %s\n", col, tipo_r, substr(amostra, 1, 100)))
  }
}

cat("\n\nScript concluído.\n")
cat("DECISÃO PENDENTE: se JSON tiver '110001' (sem .0), o .0 é artefato do CSV.\n")
cat("Se JSON também tiver '110001.0', o problema é da fonte original.\n")
