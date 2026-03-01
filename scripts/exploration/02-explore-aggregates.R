
# ==============================================================================
# EXPLORAÇÃO: Evolução dos códigos de vacina e faixa etária (1994-2019) ########
# ==============================================================================
#
# O QUE JÁ SABEMOS:
#   - 752 arquivos CPNI (cobertura) + 752 DPNI (doses)
#   - Estrutura municipal estável: ANO|UF|MUNIC|FX_ETARIA|IMUNO|DOSE|QT_DOSE|POP|COBERT
#   - Arquivos "UF" (sem MUNIC) são agregados estaduais, "BR" nacional, "IG" ignorado
#   - Período: 1994 a 2019
#   - Vacina identificada por código (IMUNO)
#
# O QUE PRECISAMOS DESCOBRIR AGORA:
#   1. Como os valores de IMUNO mudam ao longo do tempo?
#      (DTP -> Tetravalente -> Pentavalente? Sarampo -> Tríplice Viral?)
#   2. Como os valores de FX_ETARIA mudam?
#   3. Como os valores de DOSE mudam?
#   4. Os .cnv fazem o de-para código -> descrição?
#   5. Quantas linhas por ano/UF para estimar volume total?
#
# ==============================================================================

# --- 0. Dependências ---------------------------------------------------------

if (!requireNamespace("pacman", quietly = TRUE)) install.packages("pacman")
pacman::p_load(foreign, RCurl, dplyr, tibble, stringr, tidyr)

# --- Config ------------------------------------------------------------------

ftp_pni   <- "ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/"
dir_local <- file.path(tempdir(), "pni_exploracao")
dir.create(dir_local, showWarnings = FALSE, recursive = TRUE)

cat("Diretório de trabalho:", dir_local, "\n\n")

# --- Funções auxiliares ------------------------------------------------------

baixar <- function(nome_arquivo) {
  destino <- file.path(dir_local, nome_arquivo)
  if (file.exists(destino) && file.size(destino) > 100) return(destino)

  cat("  Baixando:", nome_arquivo, "...")
  tryCatch({
    download.file(paste0(ftp_pni, nome_arquivo), destino,
                  mode = "wb", quiet = TRUE)
    cat(" OK\n")
    destino
  }, error = function(e) {
    cat(" FALHOU\n")
    NULL
  })
}

ler_dbf <- function(caminho) {
  if (is.null(caminho) || !file.exists(caminho)) return(NULL)
  foreign::read.dbf(caminho, as.is = TRUE)
}


# ==============================================================================
# PARTE 1: Mapear IMUNO ao longo do tempo (Acre como amostra)
# ==============================================================================

cat("========================================\n")
cat("PARTE 1: Evolução de IMUNO no tempo\n")
cat("========================================\n\n")

# Usar Acre (AC) — estado pequeno, download rápido
# Baixar todos os anos disponíveis para AC (cobertura)
anos <- 94:99  # 1994-1999
anos <- c(anos, sprintf("%02d", 0:19))  # 2000-2019

cat("Baixando CPNI do Acre (1994-2019)...\n")
dados_ac <- list()

for (a in anos) {
  nome <- paste0("CPNIAC", a, ".DBF")
  cam  <- baixar(nome)
  df   <- ler_dbf(cam)
  if (!is.null(df)) {
    dados_ac[[nome]] <- df
  }
}

cat("\nArquivos lidos:", length(dados_ac), "\n\n")

# Extrair IMUNO únicos por ano
cat("--- IMUNO por ano ---\n\n")

imuno_por_ano <- list()
for (nome in names(dados_ac)) {
  df  <- dados_ac[[nome]]
  ano <- unique(df$ANO)[1]
  imunos <- sort(unique(df$IMUNO))
  imuno_por_ano[[as.character(ano)]] <- imunos
  cat(sprintf("  %s (%2d vacinas): %s\n",
              ano, length(imunos), paste(imunos, collapse = ", ")))
}

# Mostrar quais vacinas aparecem e desaparecem
cat("\n--- Vacinas que aparecem/desaparecem ---\n\n")

todos_anos <- sort(names(imuno_por_ano))
if (length(todos_anos) >= 2) {
  for (i in 2:length(todos_anos)) {
    ano_ant <- todos_anos[i - 1]
    ano_atu <- todos_anos[i]
    novas   <- setdiff(imuno_por_ano[[ano_atu]], imuno_por_ano[[ano_ant]])
    saiu    <- setdiff(imuno_por_ano[[ano_ant]], imuno_por_ano[[ano_atu]])

    if (length(novas) > 0 || length(saiu) > 0) {
      cat(sprintf("  %s -> %s:\n", ano_ant, ano_atu))
      if (length(novas) > 0) cat("    + Entraram:", paste(novas, collapse = ", "), "\n")
      if (length(saiu) > 0)  cat("    - Saíram:  ", paste(saiu, collapse = ", "), "\n")
    }
  }
}

# Tabela consolidada: vacina × ano (presença)
cat("\n--- Matriz vacina × ano (presença) ---\n\n")

todas_vacinas <- sort(unique(unlist(imuno_por_ano)))
matriz <- tibble(IMUNO = todas_vacinas)

for (ano in todos_anos) {
  matriz[[ano]] <- ifelse(todas_vacinas %in% imuno_por_ano[[ano]], "X", ".")
}

print(matriz, n = 100, width = Inf)


# ==============================================================================
# PARTE 2: Mapear FX_ETARIA ao longo do tempo
# ==============================================================================

cat("\n\n========================================\n")
cat("PARTE 2: Evolução de FX_ETARIA no tempo\n")
cat("========================================\n\n")

fx_por_ano <- list()
for (nome in names(dados_ac)) {
  df  <- dados_ac[[nome]]
  ano <- unique(df$ANO)[1]
  fxs <- sort(unique(df$FX_ETARIA))
  fx_por_ano[[as.character(ano)]] <- fxs
  cat(sprintf("  %s (%2d faixas): %s\n",
              ano, length(fxs), paste(fxs, collapse = ", ")))
}

# Mudanças
cat("\n--- Faixas que aparecem/desaparecem ---\n\n")
if (length(todos_anos) >= 2) {
  for (i in 2:length(todos_anos)) {
    ano_ant <- todos_anos[i - 1]
    ano_atu <- todos_anos[i]
    novas   <- setdiff(fx_por_ano[[ano_atu]], fx_por_ano[[ano_ant]])
    saiu    <- setdiff(fx_por_ano[[ano_ant]], fx_por_ano[[ano_atu]])

    if (length(novas) > 0 || length(saiu) > 0) {
      cat(sprintf("  %s -> %s:\n", ano_ant, ano_atu))
      if (length(novas) > 0) cat("    + Entraram:", paste(novas, collapse = ", "), "\n")
      if (length(saiu) > 0)  cat("    - Saíram:  ", paste(saiu, collapse = ", "), "\n")
    }
  }
}


# ==============================================================================
# PARTE 3: Mapear DOSE ao longo do tempo
# ==============================================================================

cat("\n\n========================================\n")
cat("PARTE 3: Evolução de DOSE no tempo\n")
cat("========================================\n\n")

dose_por_ano <- list()
for (nome in names(dados_ac)) {
  df  <- dados_ac[[nome]]
  ano <- unique(df$ANO)[1]
  doses <- sort(unique(df$DOSE))
  dose_por_ano[[as.character(ano)]] <- doses
  cat(sprintf("  %s (%2d doses): %s\n",
              ano, length(doses), paste(doses, collapse = ", ")))
}


# ==============================================================================
# PARTE 4: Decodificar os .cnv
# ==============================================================================

cat("\n\n========================================\n")
cat("PARTE 4: Dicionários .cnv\n")
cat("========================================\n\n")

# Listar FTP para pegar nomes dos .cnv
arquivos_ftp <- tryCatch({
  raw <- RCurl::getURL(ftp_pni, ftp.use.epsv = FALSE, dirlistonly = TRUE,
                       .opts = list(timeout = 120))
  arqs <- unlist(strsplit(raw, "\r?\n"))
  arqs[nchar(arqs) > 0]
}, error = function(e) character(0))

cnv_files <- sort(arquivos_ftp[grepl("\\.cnv$", arquivos_ftp, ignore.case = TRUE)])
def_files <- sort(arquivos_ftp[grepl("\\.def$", arquivos_ftp, ignore.case = TRUE)])

cat("Arquivos .cnv encontrados:", length(cnv_files), "\n")
cat("Arquivos .def encontrados:", length(def_files), "\n\n")

# Baixar e mostrar todos os .cnv
for (f in cnv_files) {
  cam <- baixar(f)
  if (!is.null(cam) && file.exists(cam)) {
    cat("=== ", f, " ===\n")
    linhas <- readLines(cam, encoding = "latin1", warn = FALSE)
    cat(paste(head(linhas, 100), collapse = "\n"), "\n")
    if (length(linhas) > 100) cat("... (", length(linhas), "linhas total)\n")
    cat("\n")
  }
}

# Baixar e mostrar todos os .def
for (f in def_files) {
  cam <- baixar(f)
  if (!is.null(cam) && file.exists(cam)) {
    cat("=== ", f, " ===\n")
    linhas <- readLines(cam, encoding = "latin1", warn = FALSE)
    cat(paste(linhas, collapse = "\n"), "\n\n")
  }
}


# ==============================================================================
# PARTE 5: Volume de dados
# ==============================================================================

cat("\n\n========================================\n")
cat("PARTE 5: Estimativa de volume\n")
cat("========================================\n\n")

# Linhas por ano no Acre
cat("--- Linhas por ano (Acre, cobertura) ---\n")
for (nome in names(dados_ac)) {
  df  <- dados_ac[[nome]]
  ano <- unique(df$ANO)[1]
  n_mun <- n_distinct(df$MUNIC, na.rm = TRUE)
  cat(sprintf("  %s: %6s linhas  (%d municípios)\n",
              ano, format(nrow(df), big.mark = "."), n_mun))
}

# Estimar total nacional
cat("\n--- Estimativa de volume total ---\n")
# SP é o estado com mais municípios (645), AC tem ~22
# Regra de três grosseira
linhas_ac <- sum(sapply(dados_ac, nrow))
cat("  Linhas Acre (todos os anos):", format(linhas_ac, big.mark = "."), "\n")
cat("  Acre tem ~22 municípios, SP tem ~645\n")
cat("  Brasil tem ~5.570 municípios\n")
cat("  Estimativa grosseira (cobertura): ~",
    format(round(linhas_ac * (5570 / 22)), big.mark = "."), "linhas\n")
cat("  × 2 (cobertura + doses) = ~",
    format(round(linhas_ac * (5570 / 22) * 2), big.mark = "."), "linhas\n")


# ==============================================================================
# PARTE 6: Amostra completa para inspeção visual
# ==============================================================================

cat("\n\n========================================\n")
cat("PARTE 6: Amostras para inspeção visual\n")
cat("========================================\n\n")

# Mostrar amostra de um ano antigo e um recente
if (length(dados_ac) > 0) {
  primeiro <- dados_ac[[1]]
  ultimo   <- dados_ac[[length(dados_ac)]]

  cat("--- Primeiro arquivo:", names(dados_ac)[1], "---\n")
  print(head(primeiro, 20))

  cat("\n--- Último arquivo:", names(dados_ac)[length(dados_ac)], "---\n")
  print(head(ultimo, 20))
}


# ==============================================================================
# PARTE 7: Salvar inventário consolidado
# ==============================================================================

cat("\n\n========================================\n")
cat("PARTE 7: Exportando inventário\n")
cat("========================================\n\n")

# Salvar a matriz vacina × ano como CSV
csv_path <- file.path(dir_local, "inventario_imuno_por_ano.csv")
write.csv(matriz, csv_path, row.names = FALSE)
cat("Matriz IMUNO × ano salva em:", csv_path, "\n")

# Salvar empilhamento de todos os dados do Acre
if (length(dados_ac) > 0) {
  ac_empilhado <- bind_rows(dados_ac)
  csv_ac <- file.path(dir_local, "acre_cobertura_1994_2019.csv")
  write.csv(ac_empilhado, csv_ac, row.names = FALSE)
  cat("Acre empilhado salvo em:", csv_ac, "\n")
  cat("  (", format(nrow(ac_empilhado), big.mark = "."), "linhas)\n")
}

cat("\nDiretório com todos os arquivos:", dir_local, "\n")
cat("\n--- FIM ---\n")
