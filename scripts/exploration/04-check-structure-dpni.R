# ============================================================================
# verificar_estrutura_dpni.R
# Objetivo: Confirmar nomes e conteúdo das colunas dos .dbf de DOSES (DPNI)
# Questão específica: o campo de tempo é ANO (4 dígitos) ou ANOMES (6 dígitos)?
# ============================================================================

library(foreign)
library(curl)

ftp_base <- "ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/"
dir_local <- "verificacao_pni"
dir.create(dir_local, showWarnings = FALSE)

# Baixar 3 arquivos de DOSES de épocas diferentes
arquivos_doses <- c(
  "DPNIAC98.DBF",   # Doses, Acre, 1998 (época antiga)
  "DPNIAC05.DBF",   # Doses, Acre, 2005 (época intermediária)
  "DPNIAC18.DBF"    # Doses, Acre, 2018 (época recente)
)

# Baixar também 1 de COBERTURA para comparar
arquivos_cobertura <- c(
  "CPNIAC05.DBF"    # Cobertura, Acre, 2005
)

todos <- c(arquivos_doses, arquivos_cobertura)

cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 1: Download dos arquivos de teste\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

for (arq in todos) {
  url <- paste0(ftp_base, arq)
  destino <- file.path(dir_local, arq)
  tryCatch({
    curl_download(url, destino)
    cat(sprintf("  ✓ %s (%s bytes)\n", arq, file.size(destino)))
  }, error = function(e) {
    cat(sprintf("  ✗ %s — ERRO: %s\n", arq, e$message))
  })
}

cat("\n")

# ============================================================================
# PARTE 2: Estrutura dos arquivos de DOSES (DPNI)
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 2: Estrutura dos arquivos de DOSES\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

for (arq in arquivos_doses) {
  caminho <- file.path(dir_local, arq)
  if (!file.exists(caminho)) {
    cat(sprintf("  %s — não encontrado, pulando\n\n", arq))
    next
  }

  cat("-" |> rep(60) |> paste(collapse = ""), "\n")
  cat(sprintf("ARQUIVO: %s\n", arq))
  cat("-" |> rep(60) |> paste(collapse = ""), "\n")

  df <- read.dbf(caminho, as.is = TRUE)

  cat(sprintf("Dimensões: %d linhas × %d colunas\n", nrow(df), ncol(df)))
  cat(sprintf("Colunas: %s\n\n", paste(names(df), collapse = " | ")))

  cat("Estrutura:\n")
  str(df)
  cat("\n")

  cat("Primeiras 5 linhas:\n")
  print(head(df, 5))
  cat("\n")

  # Se existir campo ANO ou ANOMES, mostrar valores únicos
  for (campo in c("ANO", "ANOMES", "ano", "anomes")) {
    if (campo %in% names(df)) {
      vals <- sort(unique(df[[campo]]))
      cat(sprintf("Valores únicos de %s (%d): %s\n",
                  campo, length(vals),
                  paste(head(vals, 20), collapse = ", ")))
      cat(sprintf("Largura dos valores: %d a %d caracteres\n",
                  min(nchar(vals)), max(nchar(vals))))
      cat("\n")
    }
  }

  # Mostrar valores únicos de IMUNO
  if ("IMUNO" %in% names(df)) {
    vals <- sort(unique(df$IMUNO))
    cat(sprintf("Valores únicos de IMUNO (%d): %s\n\n",
                length(vals), paste(vals, collapse = ", ")))
  }
}

# ============================================================================
# PARTE 3: Estrutura do arquivo de COBERTURA (CPNI) para comparação
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 3: Estrutura do arquivo de COBERTURA (para comparação)\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

for (arq in arquivos_cobertura) {
  caminho <- file.path(dir_local, arq)
  if (!file.exists(caminho)) {
    cat(sprintf("  %s — não encontrado, pulando\n\n", arq))
    next
  }

  cat(sprintf("ARQUIVO: %s\n\n", arq))

  df <- read.dbf(caminho, as.is = TRUE)

  cat(sprintf("Dimensões: %d linhas × %d colunas\n", nrow(df), ncol(df)))
  cat(sprintf("Colunas: %s\n\n", paste(names(df), collapse = " | ")))

  cat("Primeiras 5 linhas:\n")
  print(head(df, 5))
  cat("\n")

  # Valores únicos dos campos-chave
  for (campo in c("ANO", "ANOMES", "IMUNO", "DOSE", "FX_ETARIA")) {
    if (campo %in% names(df)) {
      vals <- sort(unique(df[[campo]]))
      cat(sprintf("Valores únicos de %s (%d): %s\n",
                  campo, length(vals),
                  paste(head(vals, 30), collapse = ", ")))
    }
  }
}

cat("\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("FIM\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
