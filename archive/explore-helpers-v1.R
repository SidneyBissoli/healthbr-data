# ============================================================================
# explorar_auxiliares_pni.R
# Objetivo: Baixar e ler os arquivos auxiliares do PNI (dicionários .cnv e .def)
# Fonte: ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/
# ============================================================================

library(curl)

# --- Configuração ---
ftp_base <- "ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/"
dir_local <- "auxiliares_pni"
dir.create(dir_local, showWarnings = FALSE)

# ============================================================================
# PARTE 1: Listar TODO o conteúdo do diretório AUXILIARES (recursivo)
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 1: Listando conteúdo de AUXILIARES/\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

# Listar raiz
h <- new_handle(dirlistonly = TRUE)
con <- curl(ftp_base, handle = h)
raiz <- readLines(con)
close(con)

cat("Itens na raiz de AUXILIARES/:\n")
print(raiz)
cat("\n")

# Para cada subdiretório, listar conteúdo
todos_arquivos <- data.frame(pasta = character(), arquivo = character(),
                              stringsAsFactors = FALSE)

for (item in raiz) {
  url_sub <- paste0(ftp_base, item, "/")
  tryCatch({
    h2 <- new_handle(dirlistonly = TRUE)
    con2 <- curl(url_sub, handle = h2)
    conteudo <- readLines(con2)
    close(con2)
    cat(sprintf("  %s/ → %d arquivos\n", item, length(conteudo)))
    for (arq in conteudo) {
      todos_arquivos <- rbind(todos_arquivos,
                               data.frame(pasta = item, arquivo = arq,
                                          stringsAsFactors = FALSE))
    }
  }, error = function(e) {
    # Pode ser um arquivo, não diretório
    todos_arquivos <<- rbind(todos_arquivos,
                              data.frame(pasta = "(raiz)", arquivo = item,
                                         stringsAsFactors = FALSE))
    cat(sprintf("  %s (arquivo na raiz)\n", item))
  })
}

cat(sprintf("\nTotal de arquivos encontrados: %d\n\n", nrow(todos_arquivos)))

# Mostrar todos
print(todos_arquivos, right = FALSE)
cat("\n")

# ============================================================================
# PARTE 2: Identificar e baixar TODOS os .cnv e .def
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 2: Baixando arquivos .cnv e .def\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

# Filtrar .cnv e .def (case insensitive)
auxiliares <- todos_arquivos[grepl("\\.(cnv|def|CNV|DEF)$",
                                    todos_arquivos$arquivo,
                                    ignore.case = TRUE), ]

cat(sprintf("Arquivos .cnv e .def encontrados: %d\n\n", nrow(auxiliares)))

# Baixar cada um
for (i in seq_len(nrow(auxiliares))) {
  pasta <- auxiliares$pasta[i]
  arq   <- auxiliares$arquivo[i]

  if (pasta == "(raiz)") {
    url_arq <- paste0(ftp_base, arq)
  } else {
    url_arq <- paste0(ftp_base, pasta, "/", arq)
  }

  destino <- file.path(dir_local, arq)
  tryCatch({
    curl_download(url_arq, destino)
    cat(sprintf("  ✓ %s/%s → %s (%s bytes)\n",
                pasta, arq, destino, file.size(destino)))
  }, error = function(e) {
    cat(sprintf("  ✗ ERRO ao baixar %s/%s: %s\n", pasta, arq, e$message))
  })
}

cat("\n")

# ============================================================================
# PARTE 3: Ler e imprimir TODOS os .cnv (dicionários de conversão)
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 3: Conteúdo dos arquivos .cnv\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

cnv_files <- list.files(dir_local, pattern = "\\.cnv$", ignore.case = TRUE,
                         full.names = TRUE)

cat(sprintf("Total de .cnv baixados: %d\n\n", length(cnv_files)))

for (f in cnv_files) {
  cat("-" |> rep(60) |> paste(collapse = ""), "\n")
  cat(sprintf("ARQUIVO: %s (tamanho: %s bytes)\n", basename(f), file.size(f)))
  cat("-" |> rep(60) |> paste(collapse = ""), "\n")

  # Tentar ler com encoding Latin-1 (padrão DATASUS)
  linhas <- tryCatch(
    readLines(f, encoding = "latin1", warn = FALSE),
    error = function(e) {
      cat(sprintf("  ERRO ao ler: %s\n", e$message))
      return(NULL)
    }
  )

  if (!is.null(linhas)) {
    cat(sprintf("  Linhas: %d\n\n", length(linhas)))
    # Imprimir todas (esses arquivos costumam ser pequenos)
    for (l in linhas) {
      cat("  ", l, "\n", sep = "")
    }
  }
  cat("\n\n")
}

# ============================================================================
# PARTE 4: Ler e imprimir TODOS os .def (definições de tabulação)
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 4: Conteúdo dos arquivos .def\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

def_files <- list.files(dir_local, pattern = "\\.def$", ignore.case = TRUE,
                         full.names = TRUE)

cat(sprintf("Total de .def baixados: %d\n\n", length(def_files)))

for (f in def_files) {
  cat("-" |> rep(60) |> paste(collapse = ""), "\n")
  cat(sprintf("ARQUIVO: %s (tamanho: %s bytes)\n", basename(f), file.size(f)))
  cat("-" |> rep(60) |> paste(collapse = ""), "\n")

  linhas <- tryCatch(
    readLines(f, encoding = "latin1", warn = FALSE),
    error = function(e) {
      cat(sprintf("  ERRO ao ler: %s\n", e$message))
      return(NULL)
    }
  )

  if (!is.null(linhas)) {
    cat(sprintf("  Linhas: %d\n\n", length(linhas)))
    for (l in linhas) {
      cat("  ", l, "\n", sep = "")
    }
  }
  cat("\n\n")
}

# ============================================================================
# PARTE 5: Baixar TAMBÉM quaisquer outros arquivos (txt, dbf, zip, etc.)
# ============================================================================
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("PARTE 5: Outros arquivos no diretório AUXILIARES\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n\n")

outros <- todos_arquivos[!grepl("\\.(cnv|def)$",
                                  todos_arquivos$arquivo,
                                  ignore.case = TRUE), ]

if (nrow(outros) > 0) {
  cat(sprintf("Outros arquivos encontrados: %d\n", nrow(outros)))
  for (i in seq_len(nrow(outros))) {
    pasta <- outros$pasta[i]
    arq   <- outros$arquivo[i]

    if (pasta == "(raiz)") {
      url_arq <- paste0(ftp_base, arq)
    } else {
      url_arq <- paste0(ftp_base, pasta, "/", arq)
    }

    destino <- file.path(dir_local, arq)
    tryCatch({
      curl_download(url_arq, destino)
      tamanho <- file.size(destino)
      cat(sprintf("  ✓ %s/%s → %s bytes\n", pasta, arq, tamanho))

      # Se for texto, imprimir conteúdo
      if (grepl("\\.(txt|csv|tsv|log)$", arq, ignore.case = TRUE)) {
        linhas <- readLines(destino, encoding = "latin1", warn = FALSE)
        cat(sprintf("    Conteúdo (%d linhas):\n", length(linhas)))
        for (l in linhas) cat("    ", l, "\n", sep = "")
        cat("\n")
      }
    }, error = function(e) {
      cat(sprintf("  ✗ ERRO: %s\n", e$message))
    })
  }
} else {
  cat("Nenhum outro arquivo além de .cnv e .def.\n")
}

cat("\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
cat("FIM. Todos os arquivos salvos em: ", dir_local, "/\n")
cat("=" |> rep(70) |> paste(collapse = ""), "\n")
