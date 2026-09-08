# =============================================================================
# build-population.R — denominadores populacionais do canal sih/cubos/
# Projeto: healthbr-data (pipeline sih-cubos; veio do sih-br-mcp
# scripts/build-population.R em 2026-09-08 — item sih:populacao-no-canal)
#
# Gera os TRES arquivos de populacao que o consumidor (sih-br-mcp) usa como
# denominador das taxas por 100 mil, mais um sidecar de proveniencia:
#
#   pop_municipios.parquet   municipio x sexo x faixa etaria, 1991-2024
#                            (DATASUS FTP: IBGE/POP/POPBR{aa}.zip ate 2012 e
#                            IBGE/POPSVS/POPSBR{aa}.zip de 2013, lidos por
#                            csapAIH::ler_popbr)
#   pop_uf.parquet           UF x sexo x idade simples (0..90+), 2000..LAST_YEAR
#                            (planilha oficial da Projecao da Populacao 2024 do
#                            IBGE: projecoes_2024_tab1_idade_simples.xlsx)
#   pop_uf_agregado.parquet  UF x sexo x faixa etaria, 1991-1999 (soma dos
#                            municipios — unica operacao permitida)
#   pop_provenance.json      safra: built_at, fontes (URLs), anos, linhas e
#                            totais de cada arquivo, versao dos pacotes
#
# REGRAS (CONTEXT.md do sih-br-mcp, "Regras para dados populacionais"):
#   - NAO interpolar; NAO inventar valor que IBGE/DATASUS nao publicam
#   - NAO incluir ano alem do ultimo cubo FECHADO do SIH: POP_UF_ULTIMO_ANO e
#     uma constante explicita (decisao humana, nao derivada do canal); o
#     workflow confere que ela nao passa do maior ano com window_complete
#   - Agregar municipio -> UF e permitido (soma simples)
#
# GATES (abortam o build — nada sobe se falhar):
#   - os 34 anos de POPBR/POPSVS (1991-2024) tem de ser lidos; um ano ausente
#     ou vazio aborta (o tryCatch original so avisava e um ano faltando passava
#     em silencio); cada download tem 3 tentativas (o FTP do DATASUS cai)
#   - pop_uf: planilha no leiaute esperado, todos os anos 2000..LAST_YEAR
#     presentes, Homens + Mulheres = Ambos por UF x ano, Brasil 2024 =
#     212.583.750 (valor da planilha), 27 UFs, idades 0..90
#   - pop_uf_agregado: exatamente 1991-1999, 27 UFs
#
# USO:
#   Rscript scripts/pipeline/sih-cubos/build-population.R [--out <dir>]
#   <out> = --out, senao env SIH_CUBOS_OUT, senao data/sih-population/ na raiz
#   do repo (gitignored). ~4 min e ~150 MB baixados.
#   source() do arquivo so define as funcoes (build_population() roda tudo).
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(arrow)
  library(cli)
})

BUILDER_VERSION <- "1.0.0"

# =============================================================================
# CONFIGURACAO
# =============================================================================

script_path <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE))
PIPELINE_DIR <- if (length(script_path) > 0) {
  normalizePath(dirname(script_path[1]), winslash = "/")
} else {
  normalizePath(getwd(), winslash = "/")
}
REPO_ROOT <- normalizePath(file.path(PIPELINE_DIR, "..", "..", ".."), winslash = "/", mustWork = FALSE)

cli_args <- commandArgs(trailingOnly = TRUE)
opt <- function(flag, default = NULL) {
  i <- match(flag, cli_args)
  if (is.na(i) || i == length(cli_args)) return(default)
  cli_args[[i + 1L]]
}

OUTPUT_DIR <- opt("--out", Sys.getenv("SIH_CUBOS_OUT", unset = ""))
if (!nzchar(OUTPUT_DIR)) OUTPUT_DIR <- file.path(REPO_ROOT, "data", "sih-population")
OUTPUT_DIR <- normalizePath(OUTPUT_DIR, winslash = "/", mustWork = FALSE)
dir.create(OUTPUT_DIR, showWarnings = FALSE, recursive = TRUE)

# Ultimo ano de populacao a gravar = ultimo ano de cubo FECHADO do SIH.
# Constante explicita: mudar so quando o cubo do ano seguinte fechar
# (competencia N+1/04 publicada). O workflow confere contra o manifesto.
POP_UF_ULTIMO_ANO <- 2025L

# Municipios: 1991-2024 e o que o DATASUS publica (POPBR ate 2012, POPSVS
# desde 2013). Cada ano e obrigatorio.
POP_MUN_ANOS <- 1991:2024

# Planilha oficial da Projecao da Populacao, Revisao 2024 (IBGE): uma linha por
# IDADE (0..90, 90 = 90+) x SEXO (Ambos/Homens/Mulheres) x LOCAL (BR, regioes e
# UFs, com SIGLA), colunas 2000..2070. Cabecalho na 6a linha.
IBGE_PROJECAO_2024_URL <- "https://ftp.ibge.gov.br/Projecao_da_Populacao/Projecao_da_Populacao_2024/projecoes_2024_tab1_idade_simples.xlsx"
IBGE_BRASIL_2024 <- 212583750L

DATASUS_POP_FTP <- "ftp://ftp.datasus.gov.br/dissemin/publicos/IBGE/"

DOWNLOAD_TENTATIVAS <- 3L

# Mapeamento codigo UF -> sigla
UF_CODIGO_SIGLA <- c(
  "11" = "RO", "12" = "AC", "13" = "AM", "14" = "RR", "15" = "PA",
  "16" = "AP", "17" = "TO", "21" = "MA", "22" = "PI", "23" = "CE",
  "24" = "RN", "25" = "PB", "26" = "PE", "27" = "AL", "28" = "SE",
  "29" = "BA", "31" = "MG", "32" = "ES", "33" = "RJ", "35" = "SP",
  "41" = "PR", "42" = "SC", "43" = "RS", "50" = "MS", "51" = "MT",
  "52" = "GO", "53" = "DF"
)

git_commit <- function() {
  out <- tryCatch(
    suppressWarnings(system2("git", c("-C", shQuote(REPO_ROOT), "rev-parse", "HEAD"), stdout = TRUE, stderr = FALSE)),
    error = function(e) character()
  )
  if (length(out) == 1 && nzchar(out)) out else NA_character_
}

pkg_version <- function(p) {
  if (requireNamespace(p, quietly = TRUE)) as.character(utils::packageVersion(p)) else NA_character_
}

# =============================================================================
# FUNCAO 1: build_pop_municipios()
# Dados municipais 1991-2024 via DATASUS/csapAIH
# =============================================================================

#' Le um ano do POPBR/POPSVS com tentativas (o FTP do DATASUS cai no meio).
ler_popbr_com_retry <- function(ano) {
  ultimo_erro <- NULL
  for (tentativa in seq_len(DOWNLOAD_TENTATIVAS)) {
    res <- tryCatch(
      suppressWarnings(csapAIH::ler_popbr(ano)),
      error = function(e) e
    )
    if (!inherits(res, "error") && !is.null(res) && nrow(res) > 0) return(res)
    ultimo_erro <- if (inherits(res, "error")) conditionMessage(res) else "retorno vazio"
    cli_alert_warning("  {ano}: tentativa {tentativa}/{DOWNLOAD_TENTATIVAS} falhou ({ultimo_erro})")
    if (tentativa < DOWNLOAD_TENTATIVAS) Sys.sleep(5 * tentativa)
  }
  cli_abort("Ano {ano} do POPBR/POPSVS nao foi lido apos {DOWNLOAD_TENTATIVAS} tentativas: {ultimo_erro}")
}

#' Gera pop_municipios.parquet
#'
#' Baixa dados populacionais municipais do DATASUS (via csapAIH::ler_popbr),
#' 1991-2024, por municipio, sexo e faixa etaria quinquenal. Todos os anos de
#' POP_MUN_ANOS sao obrigatorios.
#'
#' Colunas de ler_popbr(): munic_res (IBGE 6 digitos), sexo ("masc"/"fem"),
#' fxetar5 (faixa quinquenal; NA quando o POPBR traz "I000" = idade ignorada,
#' ~0,3 % em 1993-1999 — fica no total, sai de qualquer recorte etario),
#' populacao.
#'
#' @return Invisivel: o data frame gravado.
build_pop_municipios <- function() {
  cli_h1("Gerando pop_municipios.parquet")
  cli_alert_info("Fonte: DATASUS FTP ({DATASUS_POP_FTP}POP/, POPSVS/) via csapAIH::ler_popbr")
  cli_alert_info("Periodo: {min(POP_MUN_ANOS)}-{max(POP_MUN_ANOS)} ({length(POP_MUN_ANOS)} anos, todos obrigatorios)")

  if (!requireNamespace("csapAIH", quietly = TRUE)) {
    cli_abort("Pacote 'csapAIH' necessario (nao esta no CRAN): remotes::install_github('fulvionedel/csapAIH')")
  }

  dados_todos <- list()
  for (ano in POP_MUN_ANOS) {
    cli_alert_info("  Ano {ano}...")
    pop_ano <- ler_popbr_com_retry(ano)

    if (ano == POP_MUN_ANOS[1]) {
      cli_alert_info("  Colunas do ler_popbr(): {paste(names(pop_ano), collapse = ', ')}")
    }

    fonte <- dplyr::case_when(
      ano %in% c(1991, 2000, 2010, 2022) ~ "censo",
      ano == 1996 ~ "contagem",
      TRUE ~ "estimativa"
    )

    mun_vec <- as.character(pop_ano[["munic_res"]])

    if ("sexo" %in% names(pop_ano)) {
      sexo_raw <- tolower(as.character(pop_ano[["sexo"]]))
      sex_vec <- dplyr::case_when(
        sexo_raw %in% c("masc", "masculino", "m") ~ "M",
        sexo_raw %in% c("fem", "feminino", "f") ~ "F",
        TRUE ~ "total"
      )
    } else {
      sex_vec <- rep("total", nrow(pop_ano))
    }

    if ("fxetar5" %in% names(pop_ano)) {
      age_group_vec <- as.character(pop_ano[["fxetar5"]])
    } else if ("fxetaria" %in% names(pop_ano)) {
      age_group_vec <- as.character(pop_ano[["fxetaria"]])
    } else {
      age_group_vec <- rep("total", nrow(pop_ano))
    }

    pop_vec <- as.integer(pop_ano[["populacao"]])

    pop_processado <- data.frame(
      year = as.integer(ano),
      source = fonte,
      municipality_code = mun_vec,
      uf = unname(UF_CODIGO_SIGLA[substr(mun_vec, 1, 2)]),
      sex = sex_vec,
      age_group = age_group_vec,
      population = pop_vec,
      stringsAsFactors = FALSE
    ) %>%
      dplyr::filter(!is.na(uf), !is.na(population), population > 0)

    if (nrow(pop_processado) == 0) cli_abort("Ano {ano}: nenhuma linha valida apos o filtro de UF/populacao")
    dados_todos[[as.character(ano)]] <- pop_processado
    cli_alert_success("  {ano}: {format(nrow(pop_processado), big.mark = '.')} registros; populacao {format(sum(pop_processado$population[pop_processado$sex != 'total']), big.mark = '.')}")
  }

  faltam <- setdiff(POP_MUN_ANOS, as.integer(names(dados_todos)))
  if (length(faltam) > 0) cli_abort("Anos ausentes no POPBR/POPSVS: {paste(faltam, collapse = ', ')}")

  dados_final <- dplyr::bind_rows(dados_todos) %>%
    dplyr::group_by(year, source, municipality_code, uf, sex, age_group) %>%
    dplyr::summarise(population = sum(population, na.rm = TRUE), .groups = "drop") %>%
    dplyr::arrange(year, municipality_code, sex, age_group) %>%
    as.data.frame()

  stopifnot(
    length(unique(dados_final$uf)) == 27,
    identical(sort(unique(dados_final$year)), as.integer(POP_MUN_ANOS))
  )

  arquivo_saida <- file.path(OUTPUT_DIR, "pop_municipios.parquet")
  arrow::write_parquet(dados_final, arquivo_saida)

  cli_h2("Resumo pop_municipios.parquet")
  cli_alert_success("Arquivo: {.path {arquivo_saida}}")
  cli_alert_success("Registros: {.val {format(nrow(dados_final), big.mark = '.')}}")
  cli_alert_success("Anos: {.val {min(dados_final$year)}} a {.val {max(dados_final$year)}}")
  cli_alert_success("UFs: {.val {length(unique(dados_final$uf))}}")
  cli_alert_success("Tamanho: {.val {round(file.info(arquivo_saida)$size / 1024 / 1024, 2)}} MB")

  invisible(dados_final)
}

# =============================================================================
# FUNCAO 2: build_pop_uf()
# Projecao da Populacao 2024 do IBGE (planilha oficial), 2000..POP_UF_ULTIMO_ANO
# =============================================================================

#' Gera pop_uf.parquet a partir da Projecao da Populacao 2024 do IBGE
#'
#' Le a planilha oficial (idade simples) do FTP do IBGE, filtra as 27 UFs,
#' Homens/Mulheres e os anos 2000..POP_UF_ULTIMO_ANO, e grava
#' (year, uf, sex, age, population; 90 = 90+). Nada e interpolado.
#' Conferencia embutida: Homens + Mulheres = Ambos em cada UF x ano, e o
#' Brasil de 2024 = 212.583.750 (valor da planilha).
#'
#' @param arquivo Caminho local da planilha; se NULL, baixa do FTP do IBGE.
#' @return Invisivel: o data frame gravado.
build_pop_uf <- function(arquivo = NULL) {
  if (!requireNamespace("readxl", quietly = TRUE)) cli_abort("Pacote readxl necessario")
  if (!requireNamespace("tidyr", quietly = TRUE)) cli_abort("Pacote tidyr necessario")
  cli_h1("Gerando pop_uf.parquet (Projecao da Populacao 2024, IBGE)")
  cli_alert_info("Fonte: {IBGE_PROJECAO_2024_URL}")
  cli_alert_info("Periodo: 2000-{POP_UF_ULTIMO_ANO} (ate o ultimo cubo FECHADO do SIH)")

  if (is.null(arquivo)) {
    arquivo <- file.path(tempdir(), basename(IBGE_PROJECAO_2024_URL))
    cli_alert_info("Baixando a planilha...")
    ok <- FALSE
    for (tentativa in seq_len(DOWNLOAD_TENTATIVAS)) {
      st <- tryCatch(utils::download.file(IBGE_PROJECAO_2024_URL, arquivo, mode = "wb", quiet = TRUE), error = function(e) 1L)
      if (identical(st, 0L) && file.exists(arquivo) && file.info(arquivo)$size > 100000) { ok <- TRUE; break }
      cli_alert_warning("  planilha: tentativa {tentativa}/{DOWNLOAD_TENTATIVAS} falhou")
      Sys.sleep(5 * tentativa)
    }
    if (!ok) cli_abort("Planilha do IBGE nao baixada apos {DOWNLOAD_TENTATIVAS} tentativas")
  }

  bruto <- suppressMessages(readxl::read_excel(arquivo, sheet = 1, skip = 5))
  esperadas <- c("IDADE", "SEXO", "SIGLA", "LOCAL")
  if (!all(esperadas %in% names(bruto))) {
    cli_abort("Planilha fora do leiaute esperado; colunas: {paste(names(bruto), collapse = ', ')}")
  }
  anos <- as.character(2000:POP_UF_ULTIMO_ANO)
  faltam <- setdiff(anos, names(bruto))
  if (length(faltam) > 0) cli_abort("Planilha sem os anos {paste(faltam, collapse = ', ')}")

  ufs <- unname(UF_CODIGO_SIGLA)
  longo <- bruto %>%
    dplyr::filter(SIGLA %in% ufs, SEXO %in% c("Homens", "Mulheres", "Ambos")) %>%
    dplyr::select(IDADE, SEXO, uf = SIGLA, dplyr::all_of(anos)) %>%
    tidyr::pivot_longer(dplyr::all_of(anos), names_to = "year", values_to = "population") %>%
    dplyr::mutate(
      year = as.integer(year),
      age = pmin(as.integer(IDADE), 90L),
      population = as.integer(round(population))
    )

  ambos <- longo %>% dplyr::filter(SEXO == "Ambos") %>% dplyr::group_by(uf, year) %>%
    dplyr::summarise(ambos = sum(population), .groups = "drop")
  soma <- longo %>% dplyr::filter(SEXO != "Ambos") %>% dplyr::group_by(uf, year) %>%
    dplyr::summarise(soma = sum(population), .groups = "drop")
  conf <- dplyr::full_join(ambos, soma, by = c("uf", "year")) %>% dplyr::filter(abs(ambos - soma) > 1)
  if (nrow(conf) > 0) {
    cli_abort("Homens + Mulheres != Ambos em {nrow(conf)} UF x ano (ex.: {conf$uf[1]} {conf$year[1]})")
  }
  br_2024 <- bruto %>% dplyr::filter(SIGLA == "BR", SEXO == "Ambos") %>% dplyr::pull("2024") %>% sum()
  if (br_2024 != IBGE_BRASIL_2024) cli_abort("Brasil 2024 na planilha = {br_2024}, esperado {IBGE_BRASIL_2024}")

  dados_final <- longo %>%
    dplyr::filter(SEXO != "Ambos") %>%
    dplyr::mutate(sex = ifelse(SEXO == "Homens", "M", "F")) %>%
    dplyr::group_by(year, uf, sex, age) %>%
    dplyr::summarise(population = sum(population), .groups = "drop") %>%
    dplyr::arrange(year, uf, sex, age) %>%
    as.data.frame()

  stopifnot(
    length(unique(dados_final$uf)) == 27,
    all(0:90 %in% dados_final$age),
    nrow(dados_final) == 27L * 2L * 91L * length(anos)
  )

  arquivo_saida <- file.path(OUTPUT_DIR, "pop_uf.parquet")
  arrow::write_parquet(dados_final, arquivo_saida)
  cli_h2("Resumo pop_uf.parquet")
  cli_alert_success("Arquivo: {.path {arquivo_saida}}")
  cli_alert_success("Registros: {.val {format(nrow(dados_final), big.mark = '.')}}")
  cli_alert_success("Anos: {.val {min(dados_final$year)}} a {.val {max(dados_final$year)}}")
  cli_alert_success("UFs: {.val {length(unique(dados_final$uf))}}; idades 0 a 90+")
  cli_alert_success("Brasil {POP_UF_ULTIMO_ANO}: {.val {format(sum(dados_final$population[dados_final$year == POP_UF_ULTIMO_ANO]), big.mark = '.')}}")
  invisible(dados_final)
}

# =============================================================================
# FUNCAO 3: build_pop_uf_agregado()
# UF 1991-1999 agregado dos municipios (soma)
# =============================================================================

#' Gera pop_uf_agregado.parquet
#'
#' Agrega pop_municipios por UF para os anos sem projecao IBGE por UF com
#' idade (1991-1999). Soma simples — nao e interpolacao.
#'
#' @param pop_municipios Data frame de pop_municipios (ou le do arquivo)
#' @return Invisivel: o data frame gravado.
build_pop_uf_agregado <- function(pop_municipios = NULL) {
  cli_h1("Gerando pop_uf_agregado.parquet")
  cli_alert_info("Fonte: agregacao de pop_municipios.parquet")
  cli_alert_info("Periodo: 1991-1999")

  if (is.null(pop_municipios)) {
    arquivo_mun <- file.path(OUTPUT_DIR, "pop_municipios.parquet")
    if (!file.exists(arquivo_mun)) cli_abort("pop_municipios.parquet nao encontrado em {OUTPUT_DIR}; rode build_pop_municipios() antes")
    pop_municipios <- arrow::read_parquet(arquivo_mun)
  }

  dados_agregado <- pop_municipios %>%
    dplyr::filter(year >= 1991, year <= 1999) %>%
    dplyr::group_by(year, uf, sex, age_group) %>%
    dplyr::summarise(population = sum(population, na.rm = TRUE), .groups = "drop") %>%
    dplyr::arrange(year, uf, sex, age_group) %>%
    as.data.frame()

  stopifnot(
    identical(sort(unique(dados_agregado$year)), 1991:1999),
    length(unique(dados_agregado$uf)) == 27
  )

  arquivo_saida <- file.path(OUTPUT_DIR, "pop_uf_agregado.parquet")
  arrow::write_parquet(dados_agregado, arquivo_saida)

  cli_h2("Resumo pop_uf_agregado.parquet")
  cli_alert_success("Arquivo: {.path {arquivo_saida}}")
  cli_alert_success("Registros: {.val {format(nrow(dados_agregado), big.mark = '.')}}")
  cli_alert_success("Anos: {.val {min(dados_agregado$year)}} a {.val {max(dados_agregado$year)}}")
  cli_alert_success("UFs: {.val {length(unique(dados_agregado$uf))}}")
  invisible(dados_agregado)
}

# =============================================================================
# SIDECAR: pop_provenance.json
# =============================================================================

#' Grava pop_provenance.json — a safra dos tres arquivos. E o que o
#' cubes-manifest.mjs le (--population) para o bloco `population` do manifesto
#' e confere com DuckDB (--verify) antes de assinar.
write_pop_provenance <- function(municipios, uf, uf_agregado) {
  resumo <- function(df, nome, extra = list()) {
    c(list(
      name = nome,
      size_bytes = as.numeric(file.info(file.path(OUTPUT_DIR, nome))$size),
      rows = nrow(df),
      first_year = min(df$year),
      last_year = max(df$year),
      years = length(unique(df$year)),
      ufs = length(unique(df$uf))
    ), extra)
  }
  pop_total <- function(df, ano) sum(df$population[df$year == ano & df$sex != "total"])

  prov <- list(
    manifest_version = "1.0.0",
    dataset = "sih/cubos population",
    description = "Denominadores populacionais do canal sih/cubos/: projecao por UF, sexo e idade simples (IBGE, Revisao 2024) e populacao municipal por sexo e faixa etaria (DATASUS POPBR/POPSVS), mais a agregacao UF 1991-1999. Nada interpolado; ultimo ano = ultimo cubo FECHADO do SIH.",
    built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    builder = list(
      script = "scripts/pipeline/sih-cubos/build-population.R",
      version = BUILDER_VERSION,
      git_commit = git_commit(),
      packages = list(
        csapAIH = pkg_version("csapAIH"),
        arrow = pkg_version("arrow"),
        readxl = pkg_version("readxl"),
        R = paste(R.version$major, R.version$minor, sep = ".")
      )
    ),
    last_year = POP_UF_ULTIMO_ANO,
    rule = "POP_UF_ULTIMO_ANO = ultimo ano de cubo FECHADO do SIH (janela de competencias completa); nunca alem. Sem interpolacao. Municipio -> UF por soma.",
    sources = list(
      list(
        file = "pop_uf.parquet",
        name = "IBGE — Projecao da Populacao do Brasil e Unidades da Federacao por sexo e idade simples, Revisao 2024",
        agency = "IBGE",
        url = IBGE_PROJECAO_2024_URL,
        years = sprintf("2000-%d", POP_UF_ULTIMO_ANO),
        note = "Planilha oficial do FTP do IBGE (a SIDRA 7358 so carrega a revisao 2018). Ambos = Homens + Mulheres conferido por UF x ano; Brasil 2024 = 212.583.750."
      ),
      list(
        file = "pop_municipios.parquet",
        name = "DATASUS — Populacao residente por municipio, sexo e faixa etaria (POPBR 1991-2012, POPSVS 2013-2024), estimativas e censos do IBGE",
        agency = "Ministerio da Saude / DATASUS (dados do IBGE)",
        url = DATASUS_POP_FTP,
        files = c(sprintf("POP/POPBR%02d.zip", c(91:99, 0:12)), sprintf("POPSVS/POPSBR%02d.zip", 13:24)),
        reader = "csapAIH::ler_popbr",
        years = sprintf("%d-%d", min(POP_MUN_ANOS), max(POP_MUN_ANOS)),
        note = "Linhas com idade ignorada (fxetaria I000, 1993-1999) ficam com age_group nulo: entram no total, saem de qualquer recorte etario."
      ),
      list(
        file = "pop_uf_agregado.parquet",
        name = "Derivado: soma de pop_municipios por UF, sexo e faixa etaria, 1991-1999",
        agency = "healthbr-data (agregacao)",
        url = NULL,
        years = "1991-1999",
        note = "Unica operacao permitida sobre a fonte (soma). Serve os anos sem projecao por UF com idade."
      )
    ),
    files = list(
      pop_uf = resumo(uf, "pop_uf.parquet", list(ages = "0-90 (90 = 90+)", brasil_last_year = pop_total(uf, POP_UF_ULTIMO_ANO))),
      pop_uf_agregado = resumo(uf_agregado, "pop_uf_agregado.parquet", list(brasil_last_year = pop_total(uf_agregado, max(uf_agregado$year)))),
      pop_municipios = resumo(municipios, "pop_municipios.parquet", list(
        municipalities_last_year = length(unique(municipios$municipality_code[municipios$year == max(municipios$year)])),
        brasil_last_year = pop_total(municipios, max(municipios$year))
      ))
    )
  )
  arquivo <- file.path(OUTPUT_DIR, "pop_provenance.json")
  jsonlite::write_json(prov, arquivo, auto_unbox = TRUE, pretty = TRUE, null = "null", digits = NA)
  cli_alert_success("Sidecar: {.path {arquivo}}")
  invisible(prov)
}

# =============================================================================
# FUNCAO PRINCIPAL: build_population()
# =============================================================================

#' Gera os tres arquivos e o sidecar, nesta ordem:
#'   1. build_pop_municipios() -> pop_municipios.parquet
#'   2. build_pop_uf()         -> pop_uf.parquet
#'   3. build_pop_uf_agregado() -> pop_uf_agregado.parquet
#'   4. write_pop_provenance()  -> pop_provenance.json
#' @return Lista invisivel com os 3 data frames e a proveniencia
build_population <- function() {
  cli_h1("healthbr-data / sih-cubos: denominadores populacionais {BUILDER_VERSION}")
  cli_alert_info("Saida: {.path {OUTPUT_DIR}}")
  cli_alert_info("Ultimo ano de populacao (cubo FECHADO do SIH): {POP_UF_ULTIMO_ANO}")
  cli_rule()

  resultado <- list()
  cli_h1("Etapa 1/3: municipios (DATASUS POPBR/POPSVS)")
  resultado$municipios <- build_pop_municipios()
  cli_h1("Etapa 2/3: UF x idade simples (IBGE Projecao 2024)")
  resultado$uf <- build_pop_uf()
  cli_h1("Etapa 3/3: UF agregado 1991-1999")
  resultado$uf_agregado <- build_pop_uf_agregado(resultado$municipios)
  resultado$provenance <- write_pop_provenance(resultado$municipios, resultado$uf, resultado$uf_agregado)

  cli_h1("CONCLUIDO")
  for (arq in c("pop_municipios.parquet", "pop_uf.parquet", "pop_uf_agregado.parquet", "pop_provenance.json")) {
    caminho <- file.path(OUTPUT_DIR, arq)
    if (!file.exists(caminho)) cli_abort("{arq} NAO foi gerado")
    cli_alert_success("  {.path {arq}}: {.val {round(file.info(caminho)$size / 1024, 1)}} KB")
  }
  invisible(resultado)
}

# Rodou pelo Rscript (tem --file=): executa. source() so define as funcoes.
if (length(script_path) > 0 && !isTRUE(getOption("sih.population.no_run"))) {
  build_population()
}
