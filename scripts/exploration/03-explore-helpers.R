# ============================================================================
# explorar_auxiliares_pni_v2.R
# Objetivo: Inspecionar arquivos complementares do diretório AUXILIARES
#   - IMUNOCOB.DBF (possível dicionário de referência dos códigos de cobertura)
#   - Arquivos .def (definições de tabulação TabWin → vinculam .cnv aos campos)
# Pré-requisito: ter rodado explorar_auxiliares_pni.R (que baixou tudo em auxiliares_pni/)
# ============================================================================

library(foreign)

dir_local <- "auxiliares_pni"

# ============================================================================
# PARTE 1: IMUNOCOB.DBF — possível tabela de referência código × vacina
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 1: IMUNOCOB.DBF\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

dbf_path <- file.path(dir_local, "IMUNOCOB.DBF")

if (file.exists(dbf_path)) {
  imunocob <- read.dbf(dbf_path, as.is = TRUE)
  cat(sprintf("Dimensões: %d linhas × %d colunas\n", nrow(imunocob), ncol(imunocob)))
  cat(sprintf("Colunas: %s\n\n", paste(names(imunocob), collapse = ", ")))

  # Estrutura
  cat("Estrutura:\n")
  str(imunocob)
  cat("\n")

  # Imprimir TUDO (arquivo auxiliar, deve ser pequeno)
  cat("Conteúdo completo:\n\n")
  print(imunocob, right = FALSE)
  cat("\n")
} else {
  cat("ARQUIVO NÃO ENCONTRADO:", dbf_path, "\n")
  cat("Verifique se explorar_auxiliares_pni.R rodou com sucesso.\n\n")
}

# ============================================================================
# PARTE 2: Arquivos .def — definições de tabulação do TabWin
# Mostram quais .cnv se aplicam a quais campos dos .dbf
# Vamos ler um .def de cobertura (cpnibr) e um de doses (dpnibr)
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 2: Arquivos .def (definições de tabulação)\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

defs_interesse <- c(
  "cpnibr.def",   # Cobertura - nível Brasil
  "dpnibr.def",   # Doses - nível Brasil
  "cpniac.def",   # Cobertura - nível estado (Acre como exemplo)
  "dpniac.def",   # Doses - nível estado (Acre como exemplo)
  "cpniuf.def",   # Cobertura - consolidado UF
  "dpniuf.def"    # Doses - consolidado UF
)

for (def_file in defs_interesse) {
  def_path <- file.path(dir_local, def_file)

  cat("-" |> rep(60) |> paste(collapse = ""), "\n")
  cat(sprintf("ARQUIVO: %s\n", def_file))
  cat("-" |> rep(60) |> paste(collapse = ""), "\n")

  if (file.exists(def_path)) {
    linhas <- readLines(def_path, encoding = "latin1", warn = FALSE)
    cat(sprintf("Linhas: %d\n\n", length(linhas)))
    for (l in linhas) {
      cat("  ", l, "\n", sep = "")
    }
  } else {
    cat("  ARQUIVO NÃO ENCONTRADO\n")
  }
  cat("\n\n")
}

# ============================================================================
# PARTE 3: Resumo — inventário de todos os .cnv e o que mapeiam
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 3: Inventário resumido dos .cnv disponíveis\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

cnv_files <- list.files(dir_local, pattern = "\\.cnv$", ignore.case = TRUE)
cat(sprintf("Total de .cnv: %d\n\n", length(cnv_files)))

for (f in cnv_files) {
  full_path <- file.path(dir_local, f)
  linhas <- readLines(full_path, encoding = "latin1", warn = FALSE)
  # Primeira linha do .cnv tem o número de entradas e largura do campo
  cat(sprintf("  %-20s → %3d linhas | header: '%s'\n",
              f, length(linhas), trimws(linhas[1])))
}

cat("\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("FIM\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
