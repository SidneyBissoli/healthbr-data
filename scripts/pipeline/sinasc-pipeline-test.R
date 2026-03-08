# ==============================================================================
# sinasc-pipeline-test.R — Teste de amostra mínima (DF × 2022 e DF × 1994–1995)
# ==============================================================================
#
# Valida as duas ramificações de schema antes do bootstrap completo:
#   - Era moderna (NOV/DNRES/): DNDF2022.dbc
#   - Era antiga  (ANT/DNRES/): DNRDF1994.dbc, DNRDF1995.dbc
#
# Executar no Hetzner:
#   Rscript /opt/sinasc/sinasc-pipeline-test.R
#
# ==============================================================================

source("/opt/sinasc/sinasc-pipeline-r.R", local = TRUE)

# Override: rodar apenas DF, anos 1994, 1995, 2022
UFS         <- c("DF")
ANO_INICIO  <- 1994
ANO_FIM     <- 1994   # começa apenas com 1994 para validar a era antiga

cat("\n")
cat(strrep("=", 70), "\n")
cat("  TESTE: era antiga — DNRDF1994.dbc\n")
cat(strrep("=", 70), "\n\n")

# Teste direto de leitura sem rodar o pipeline completo
dir_create(DIR_TEMP)
arq_ant <- info_arquivo("DF", 1994)
cat("URL:", arq_ant$url, "\n")
cat("Nome:", arq_ant$nome, "\n\n")

destino <- file.path(DIR_TEMP, arq_ant$nome)
ok <- baixar_dbc(arq_ant$url, destino)

if (!ok) {
  cat("FALHOU: download da era antiga nao funcionou\n")
} else {
  df <- ler_dbc_como_character(destino, 1994)
  cat(glue("Shape: {nrow(df)} linhas x {ncol(df)} colunas\n"))
  cat("Colunas:\n")
  print(names(df))
  cat("\nPrimeiras 3 linhas:\n")
  print(head(df, 3))
  cat("\nTipos:\n")
  print(sapply(df, class))
  file_delete(destino)
}

cat("\n")
cat(strrep("=", 70), "\n")
cat("  TESTE: era moderna — DNDF2022.dbc\n")
cat(strrep("=", 70), "\n\n")

arq_mod <- info_arquivo("DF", 2022)
cat("URL:", arq_mod$url, "\n")
cat("Nome:", arq_mod$nome, "\n\n")

destino <- file.path(DIR_TEMP, arq_mod$nome)
ok <- baixar_dbc(arq_mod$url, destino)

if (!ok) {
  cat("FALHOU: download da era moderna nao funcionou\n")
} else {
  df <- ler_dbc_como_character(destino, 2022)
  cat(glue("Shape: {nrow(df)} linhas x {ncol(df)} colunas\n"))
  cat("Colunas:\n")
  print(names(df))
  cat("\nPrimeiras 3 linhas:\n")
  print(head(df, 3))
  cat("\nTipos:\n")
  print(sapply(df, class))
  file_delete(destino)
}

cat("\nTeste concluido.\n")
