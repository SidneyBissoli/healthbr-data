# =============================================================================
# rebuild-cubes.R — linha de comando de build-aggregations.R
# Projeto: healthbr-data (pipeline sih-cubos; veio do sih-br-mcp a3284c0 em
# 2026-09-08 — ver README.md desta pasta)
#
# É o que o workflow `.github/workflows/rebuild-sih-cubes.yml` roda no runner,
# e o que se roda à mão para reconstruir um cubo: recebe os anos por argumento,
# decide as UFs de arquivo pelo SIDECAR anterior do ano, que o workflow baixa
# do canal público para a pasta de saída antes do build (o escopo de cada cubo
# é explícito e sobrevive ao rebuild — 2023/RR continua 2023/RR até alguém
# mandar outra coisa), chama build_data() um ano por vez e sai com status 1 se
# QUALQUER ano falhar. build_data() sozinho engole o erro de um ano (retorna
# FALSE para ele e segue): num runner isso seria verde por engano.
#
# USO:
#   Rscript scripts/pipeline/sih-cubos/rebuild-cubes.R --years 2023
#   Rscript scripts/pipeline/sih-cubos/rebuild-cubes.R --years 2023,2024 --ufs RR,AC
#   Rscript scripts/pipeline/sih-cubos/rebuild-cubes.R --years 2024 --ufs all
#       # ano novo: sem sidecar anterior, --ufs é obrigatório
#
# Saída: <out>/sih_{causas,series,icsap}_<ano>.parquet + <out>/sih_provenance_<ano>.json,
# onde <out> é `--out <dir>`, senão a env SIH_CUBOS_OUT, senão data/sih-cubos/
# na raiz do repo (gitignored). O sidecar anterior do ano é procurado em <out>.
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)

opt <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) return(default)
  args[[i + 1L]]
}
split_csv <- function(x) {
  if (is.null(x) || !nzchar(x)) return(character())
  trimws(strsplit(x, ",", fixed = TRUE)[[1]])
}

years <- suppressWarnings(as.integer(split_csv(opt("--years"))))
if (length(years) == 0 || anyNA(years)) {
  stop("Uso: Rscript scripts/pipeline/sih-cubos/rebuild-cubes.R --years 2023[,2024] [--ufs RR,AC|all] [--out <dir>]", call. = FALSE)
}
ufs_arg <- split_csv(opt("--ufs"))
out_arg <- opt("--out")

# Este arquivo vive em scripts/pipeline/sih-cubos/; a raiz do repo é três
# níveis acima. build-aggregations.R lê as tabelas de PIPELINE_DIR/tables e
# grava em OUTPUT_DIR (ver lá).
script_path <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE))
PIPELINE_DIR <- normalizePath(dirname(script_path[1]), winslash = "/")
repo_root <- normalizePath(file.path(PIPELINE_DIR, "..", "..", ".."), winslash = "/")
setwd(repo_root)
if (!is.null(out_arg)) Sys.setenv(SIH_CUBOS_OUT = normalizePath(out_arg, winslash = "/", mustWork = FALSE))
source(file.path(PIPELINE_DIR, "build-aggregations.R"))

ufs_do_ano <- function(ano) {
  if (length(ufs_arg) > 0) return(if (identical(ufs_arg, "all")) "all" else toupper(ufs_arg))
  sidecar <- file.path(OUTPUT_DIR, sprintf("sih_provenance_%d.json", ano))
  if (!file.exists(sidecar)) {
    stop(sprintf(
      "Ano %d nao tem sidecar anterior em %s e nenhum --ufs foi dado: o escopo (UFs de arquivo) de um cubo novo tem de ser explicito (o workflow baixa o sidecar do canal antes do build).",
      ano, OUTPUT_DIR), call. = FALSE)
  }
  ufs <- jsonlite::fromJSON(sidecar)$ufs_arquivo
  if (length(ufs) == 27) "all" else ufs
}

falhas <- character()
t0 <- Sys.time()
for (ano in years) {
  ufs <- ufs_do_ano(ano)
  cli::cli_alert_info("rebuild {ano}: UFs de arquivo = {if (identical(ufs, 'all')) 'todas (27)' else paste(ufs, collapse = ', ')}")
  res <- build_data(years = ano, ufs = ufs)
  ok <- isTRUE(res[[as.character(ano)]])
  if (!ok) falhas <- c(falhas, as.character(ano))
}
cli::cli_rule()
cli::cli_alert_info("rebuild-cubes: {length(years)} ano(s) em {format(round(Sys.time() - t0, 1))}")
if (length(falhas) > 0) {
  cli::cli_alert_danger("Anos com falha: {paste(falhas, collapse = ', ')}")
  quit(status = 1L)
}
cli::cli_alert_success("rebuild-cubes: todos os anos concluidos")
