## ============================================================================
## diagnostico_tipagem.R
## Objetivo: Baixar amostras dos dois bancos (microdados 2020+ e agregados
##           1994-2019) e sintetizar valores de cada variável para decidir
##           a tipagem correta no Parquet.
## ============================================================================

library(readr)
library(foreign)

# ── 1. MICRODADOS (novo SI-PNI, 2020+) ──────────────────────────────────────

cat("\n========================================\n")
cat("PARTE 1: MICRODADOS (2020+)\n")
cat("========================================\n")

# Baixar um mês pequeno (jan/2020 — início da série, menor volume)
url_micro <- "https://arquivosdadosabertos.saude.gov.br/dados/dbbni/vacinacao_jan_2020_csv.zip"
zip_micro <- tempfile(fileext = ".zip")
csv_micro <- tempdir()

cat("\nBaixando microdados jan/2020...\n")
download.file(url_micro, zip_micro, mode = "wb", quiet = TRUE)
unzip(zip_micro, exdir = csv_micro)

# Identificar o CSV extraído
csv_file <- list.files(csv_micro, pattern = "\\.csv$", full.names = TRUE,
                       recursive = TRUE)[1]
cat("Arquivo:", csv_file, "\n")

# Nomes oficiais das 55 colunas
nomes_oficiais <- c(
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

# Ler amostra de 50.000 linhas (tudo character)
cat("Lendo amostra de 50.000 linhas...\n")
amostra <- read_delim(
  csv_file,
  delim = ";",
  col_names = FALSE,
  col_types = cols(.default = col_character()),
  locale = locale(encoding = "Latin1"),
  n_max = 50000,
  show_col_types = FALSE
)

# Remover coluna 56 (artefato do ; final)
if (ncol(amostra) >= 56) amostra <- amostra[, 1:55]
names(amostra) <- nomes_oficiais

cat("Dimensões:", nrow(amostra), "linhas x", ncol(amostra), "colunas\n\n")

# ── Diagnóstico de cada variável ──

diagnostico_micro <- data.frame(
  posicao    = 1:55,
  variavel   = nomes_oficiais,
  n_na       = integer(55),
  n_vazio    = integer(55),
  n_distintos = integer(55),
  tem_zero_esq = character(55),
  parece_data  = character(55),
  parece_inteiro = character(55),
  parece_numerico = character(55),
  amostra_valores = character(55),
  stringsAsFactors = FALSE
)

for (i in 1:55) {
  vals <- amostra[[i]]

  # Contagens básicas
  diagnostico_micro$n_na[i]       <- sum(is.na(vals))
  diagnostico_micro$n_vazio[i]    <- sum(!is.na(vals) & vals == "")
  vals_nna <- vals[!is.na(vals) & vals != ""]
  diagnostico_micro$n_distintos[i] <- length(unique(vals_nna))

  if (length(vals_nna) == 0) {
    diagnostico_micro$tem_zero_esq[i]   <- "N/A"
    diagnostico_micro$parece_data[i]     <- "N/A"
    diagnostico_micro$parece_inteiro[i]  <- "N/A"
    diagnostico_micro$parece_numerico[i] <- "N/A"
    diagnostico_micro$amostra_valores[i] <- "(tudo vazio/NA)"
    next
  }

  # Zero à esquerda? (valor começa com 0 e tem mais de 1 caractere)
  tem_zero <- any(grepl("^0[0-9]", vals_nna))
  diagnostico_micro$tem_zero_esq[i] <- ifelse(tem_zero, "SIM", "nao")

  # Parece data? (YYYY-MM-DD ou DD/MM/YYYY ou similar)
  pct_data <- mean(grepl("^\\d{4}-\\d{2}-\\d{2}", vals_nna) |
                   grepl("^\\d{2}/\\d{2}/\\d{4}", vals_nna))
  diagnostico_micro$parece_data[i] <- ifelse(pct_data > 0.9, "SIM",
                                     ifelse(pct_data > 0.5, "parcial", "nao"))

  # Parece inteiro? (só dígitos, sem zeros à esquerda problemáticos)
  eh_digito <- grepl("^-?\\d+$", vals_nna)
  pct_int <- mean(eh_digito)
  diagnostico_micro$parece_inteiro[i] <- ifelse(pct_int > 0.9 & !tem_zero,
                                                "SIM",
                                        ifelse(pct_int > 0.9 & tem_zero,
                                                "inteiro_mas_zero_esq", "nao"))

  # Parece numérico (com decimal)?
  eh_num <- grepl("^-?\\d+\\.?\\d*$", vals_nna)
  pct_num <- mean(eh_num)
  diagnostico_micro$parece_numerico[i] <- ifelse(pct_num > 0.9 & pct_int < 0.9,
                                                  "SIM", "nao")

  # Amostra de até 8 valores únicos
  uniq <- sort(unique(vals_nna))
  if (length(uniq) > 8) {
    amostra_str <- paste(c(head(uniq, 4), "...", tail(uniq, 4)), collapse = " | ")
  } else {
    amostra_str <- paste(uniq, collapse = " | ")
  }
  diagnostico_micro$amostra_valores[i] <- substr(amostra_str, 1, 120)
}

cat("─── DIAGNÓSTICO DOS MICRODADOS (50.000 linhas de jan/2020) ───\n\n")
for (i in 1:55) {
  d <- diagnostico_micro[i, ]
  cat(sprintf("[%02d] %s\n", d$posicao, d$variavel))
  cat(sprintf("     NAs: %d | Vazios: %d | Distintos: %d\n",
              d$n_na, d$n_vazio, d$n_distintos))
  cat(sprintf("     Zero_esq: %s | Data: %s | Inteiro: %s | Numerico: %s\n",
              d$tem_zero_esq, d$parece_data, d$parece_inteiro, d$parece_numerico))
  cat(sprintf("     Valores: %s\n\n", d$amostra_valores))
}


# ── 2. DADOS AGREGADOS (antigo SI-PNI, 1994-2019) ──────────────────────────

cat("\n========================================\n")
cat("PARTE 2: DADOS AGREGADOS (1994-2019)\n")
cat("========================================\n")

# Baixar 3 amostras representativas de cada era

ftp_base <- "ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/"
amostras_agreg <- list(
  # COBERTURA
  list(arquivo = "CPNIAC98.DBF", tipo = "COBERTURA", era = "1994-2003"),
  list(arquivo = "CPNIAC08.DBF", tipo = "COBERTURA", era = "2004-2012"),
  list(arquivo = "CPNIAC18.DBF", tipo = "COBERTURA", era = "2013-2019"),
  # DOSES
  list(arquivo = "DPNIAC98.DBF", tipo = "DOSES",     era = "1994-2003"),
  list(arquivo = "DPNIAC08.DBF", tipo = "DOSES",     era = "2004-2012"),
  list(arquivo = "DPNIAC18.DBF", tipo = "DOSES",     era = "2013-2019")
)

for (a in amostras_agreg) {
  cat(sprintf("\n─── %s - %s (%s) ───\n", a$tipo, a$era, a$arquivo))

  url <- paste0(ftp_base, a$arquivo)
  destino <- file.path(tempdir(), a$arquivo)

  tryCatch({
    download.file(url, destino, mode = "wb", quiet = TRUE)
    df <- read.dbf(destino, as.is = TRUE)

    cat(sprintf("Dimensões: %d linhas x %d colunas\n", nrow(df), ncol(df)))
    cat(sprintf("Colunas: %s\n\n", paste(names(df), collapse = ", ")))

    for (col in names(df)) {
      vals <- df[[col]]
      vals_nna <- vals[!is.na(vals)]
      if (is.character(vals_nna[1]) || is.factor(vals_nna[1])) {
        vals_nna <- as.character(vals_nna)
        vals_nna <- vals_nna[vals_nna != ""]
      }

      n_dist <- length(unique(vals_nna))
      tipo_r <- class(vals)[1]

      # Zero à esquerda
      zero_esq <- "N/A"
      if (is.character(vals_nna[1]) && length(vals_nna) > 0) {
        zero_esq <- ifelse(any(grepl("^0[0-9]", vals_nna)), "SIM", "nao")
      }

      # Amostra de valores
      uniq <- sort(unique(vals_nna))
      if (length(uniq) > 8) {
        amostra_str <- paste(c(head(uniq, 4), "...", tail(uniq, 4)), collapse=" | ")
      } else {
        amostra_str <- paste(uniq, collapse = " | ")
      }
      amostra_str <- substr(amostra_str, 1, 120)

      cat(sprintf("  %s [%s] — %d distintos — zero_esq: %s\n",
                  col, tipo_r, n_dist, zero_esq))
      cat(sprintf("    Valores: %s\n", amostra_str))
    }
  }, error = function(e) {
    cat(sprintf("  ERRO ao baixar/ler: %s\n", e$message))
  })
}


# ── 3. RESUMO PARA DECISÃO ──────────────────────────────────────────────────

cat("\n\n========================================\n")
cat("PARTE 3: RESUMO PARA DECISÃO DE TIPAGEM\n")
cat("========================================\n\n")

cat("MICRODADOS — Sugestão automática de tipo:\n\n")

for (i in 1:55) {
  d <- diagnostico_micro[i, ]
  nome <- d$variavel

  # Regra 1: campos dt_ → Date
  if (grepl("^dt_", nome) && d$parece_data == "SIM") {
    tipo_sugerido <- "Date"
  # Regra 2: parece inteiro sem zero à esquerda → integer
  } else if (d$parece_inteiro == "SIM") {
    tipo_sugerido <- "integer"
  # Regra 3: inteiro mas com zero à esquerda → character
  } else if (d$parece_inteiro == "inteiro_mas_zero_esq") {
    tipo_sugerido <- "character (zero à esquerda)"
  # Regra 4: tudo o mais → character
  } else {
    tipo_sugerido <- "character"
  }

  cat(sprintf("  [%02d] %-45s → %s\n", i, nome, tipo_sugerido))
}

cat("\nAGREGADOS — Ver output acima para cada era/tipo.\n")
cat("Campos numéricos: ANO (integer), QT_DOSE (integer), POP (numeric), COBERT/COB (numeric)\n")
cat("Campos código: UF, MUNIC, FX_ETARIA, IMUNO, DOSE → character (preservar zeros)\n")

cat("\n\nScript concluído. Use o output acima para definir a tipagem final.\n")
