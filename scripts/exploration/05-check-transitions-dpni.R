# ============================================================================
# verificar_transicoes_dpni.R
# Objetivo: Identificar em que ano exato ocorrem as transições estruturais:
#   1) Colunas: 7 → 12 (quando surgem ANOMES, MES, DOSE1, DOSEN, DIFER?)
#   2) Código de município: 7 dígitos → 6 dígitos (quando perde o dígito verificador?)
#   3) Tipo de ANO: integer → character (quando muda?)
# Estratégia: baixar 1 arquivo DPNI do Acre para cada ano (1994-2019)
# ============================================================================

library(foreign)
library(curl)

ftp_base <- "ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/"
dir_local <- "transicoes_pni"
dir.create(dir_local, showWarnings = FALSE)

# ============================================================================
# PARTE 1: Download de todos os DPNI do Acre (1994-2019)
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 1: Download DPNIAC para todos os anos\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

anos <- 1994:2019
arquivos <- sprintf("DPNIAC%02d.DBF", anos %% 100)

for (i in seq_along(anos)) {
  url <- paste0(ftp_base, arquivos[i])
  destino <- file.path(dir_local, arquivos[i])

  if (file.exists(destino)) {
    cat(sprintf("  ✓ %s (já existe)\n", arquivos[i]))
    next
  }

  tryCatch({
    curl_download(url, destino)
    cat(sprintf("  ✓ %s (%s bytes)\n", arquivos[i], file.size(destino)))
  }, error = function(e) {
    cat(sprintf("  ✗ %s — %s\n", arquivos[i], e$message))
  })
}

# Fazer o mesmo para CPNI (cobertura) — verificar se também muda
cat("\nBaixando CPNIAC para comparação:\n")
arquivos_cob <- sprintf("CPNIAC%02d.DBF", anos %% 100)

for (i in seq_along(anos)) {
  url <- paste0(ftp_base, arquivos_cob[i])
  destino <- file.path(dir_local, arquivos_cob[i])

  if (file.exists(destino)) {
    cat(sprintf("  ✓ %s (já existe)\n", arquivos_cob[i]))
    next
  }

  tryCatch({
    curl_download(url, destino)
    cat(sprintf("  ✓ %s (%s bytes)\n", arquivos_cob[i], file.size(destino)))
  }, error = function(e) {
    cat(sprintf("  ✗ %s — %s\n", arquivos_cob[i], e$message))
  })
}

cat("\n")

# ============================================================================
# PARTE 2: Diagnóstico estrutural de cada DPNI por ano
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 2: Estrutura dos DPNI (doses) por ano\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

cat(sprintf("%-6s %-5s %-40s %-12s %-10s %-10s %-10s\n",
            "ANO", "NCOL", "COLUNAS", "TIPO_ANO", "MUNIC_LEN", "NLINHAS", "IMUNO_EX"))
cat("-" |> rep(100) |> paste(collapse = ""), "\n")

resultados_dpni <- list()

for (i in seq_along(anos)) {
  caminho <- file.path(dir_local, arquivos[i])
  if (!file.exists(caminho)) {
    cat(sprintf("%-6d  — ARQUIVO NÃO ENCONTRADO\n", anos[i]))
    next
  }

  tryCatch({
    df <- read.dbf(caminho, as.is = TRUE)

    ncol_df <- ncol(df)
    colunas <- paste(names(df), collapse = ", ")
    tipo_ano <- class(df$ANO)[1]
    nlinhas <- nrow(df)

    # Comprimento do código de município
    if ("MUNIC" %in% names(df)) {
      munic_lens <- unique(nchar(as.character(df$MUNIC)))
      munic_str <- paste(munic_lens, collapse = "/")
    } else {
      munic_str <- "N/A"
    }

    # Exemplo de IMUNO
    imuno_ex <- paste(head(sort(unique(df$IMUNO)), 5), collapse = ",")

    cat(sprintf("%-6d %-5d %-40s %-12s %-10s %-10d %s\n",
                anos[i], ncol_df, substr(colunas, 1, 40),
                tipo_ano, munic_str, nlinhas, imuno_ex))

    resultados_dpni[[as.character(anos[i])]] <- list(
      ncol = ncol_df,
      colunas = names(df),
      tipo_ano = tipo_ano,
      munic_lens = munic_lens,
      nlinhas = nlinhas
    )
  }, error = function(e) {
    cat(sprintf("%-6d  — ERRO: %s\n", anos[i], e$message))
  })
}

cat("\n")

# ============================================================================
# PARTE 3: Diagnóstico estrutural de cada CPNI por ano (cobertura)
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 3: Estrutura dos CPNI (cobertura) por ano\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

cat(sprintf("%-6s %-5s %-40s %-12s %-10s %-10s\n",
            "ANO", "NCOL", "COLUNAS", "TIPO_ANO", "MUNIC_LEN", "NLINHAS"))
cat("-" |> rep(90) |> paste(collapse = ""), "\n")

for (i in seq_along(anos)) {
  caminho <- file.path(dir_local, arquivos_cob[i])
  if (!file.exists(caminho)) {
    cat(sprintf("%-6d  — ARQUIVO NÃO ENCONTRADO\n", anos[i]))
    next
  }

  tryCatch({
    df <- read.dbf(caminho, as.is = TRUE)

    ncol_df <- ncol(df)
    colunas <- paste(names(df), collapse = ", ")
    tipo_ano <- class(df$ANO)[1]
    nlinhas <- nrow(df)

    if ("MUNIC" %in% names(df)) {
      munic_lens <- unique(nchar(as.character(df$MUNIC)))
      munic_str <- paste(munic_lens, collapse = "/")
    } else {
      munic_str <- "N/A"
    }

    cat(sprintf("%-6d %-5d %-40s %-12s %-10s %-10d\n",
                anos[i], ncol_df, substr(colunas, 1, 40),
                tipo_ano, munic_str, nlinhas))
  }, error = function(e) {
    cat(sprintf("%-6d  — ERRO: %s\n", anos[i], e$message))
  })
}

cat("\n")

# ============================================================================
# PARTE 4: Resumo das transições detectadas
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 4: Resumo das transições\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

if (length(resultados_dpni) > 0) {
  # Transição de número de colunas
  cat("Transição do número de colunas (DPNI):\n")
  ncol_anterior <- NULL
  for (ano_str in sort(names(resultados_dpni))) {
    ncol_atual <- resultados_dpni[[ano_str]]$ncol
    if (!is.null(ncol_anterior) && ncol_atual != ncol_anterior) {
      cat(sprintf("  *** MUDANÇA em %s: %d → %d colunas\n",
                  ano_str, ncol_anterior, ncol_atual))
      cat(sprintf("      Antes: %s\n",
                  paste(resultados_dpni[[as.character(as.integer(ano_str) - 1)]]$colunas,
                        collapse = ", ")))
      cat(sprintf("      Depois: %s\n",
                  paste(resultados_dpni[[ano_str]]$colunas, collapse = ", ")))
    }
    ncol_anterior <- ncol_atual
  }

  # Transição de tamanho do código de município
  cat("\nTransição do tamanho do código de município (DPNI):\n")
  munic_anterior <- NULL
  for (ano_str in sort(names(resultados_dpni))) {
    munic_atual <- resultados_dpni[[ano_str]]$munic_lens
    munic_str <- paste(sort(munic_atual), collapse = "/")
    if (!is.null(munic_anterior) && munic_str != munic_anterior) {
      cat(sprintf("  *** MUDANÇA em %s: %s → %s dígitos\n",
                  ano_str, munic_anterior, munic_str))
    }
    munic_anterior <- munic_str
  }

  # Transição do tipo de ANO
  cat("\nTransição do tipo de ANO (DPNI):\n")
  tipo_anterior <- NULL
  for (ano_str in sort(names(resultados_dpni))) {
    tipo_atual <- resultados_dpni[[ano_str]]$tipo_ano
    if (!is.null(tipo_anterior) && tipo_atual != tipo_anterior) {
      cat(sprintf("  *** MUDANÇA em %s: %s → %s\n",
                  ano_str, tipo_anterior, tipo_atual))
    }
    tipo_anterior <- tipo_atual
  }
}

cat("\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("FIM\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
