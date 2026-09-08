# =============================================================================
# build-aggregations.R
# Gera os cubos Parquet de sih/cubos/ a partir dos microdados SIH-RD
# redistribuídos em Parquet em sih/rd/ (espelho do FTP do DATASUS).
# Projeto: healthbr-data (pipeline sih-cubos). Até a 2.6.1 vivia no
# sih-br-mcp (scripts/build-aggregations.R, commit a3284c0); desde a 2.7.0
# (2026-09-08) o produtor é este repositório e o sih-br-mcp é consumidor do
# canal público — ver README.md desta pasta e docs/reference-pipelines-pt.md §16.
#
# CADEIA DE PROVENIÊNCIA (registrada em data/sih_provenance_<ano>.json):
#   Ministério da Saúde / DATASUS (RD<UF><AA><MM>.dbc no FTP)
#     -> healthbr-data (Parquet 1:1, sem transformação; manifesto com hash e
#        data de download de cada .dbc; CC-BY-4.0)
#     -> este script (agrega em três cubos por ano de competência)
#
# USO:
#   source("scripts/build-aggregations.R")
#   build_data(years = 2023, ufs = "RR")           # 1 ano, 1 UF de arquivo
#   build_data(years = 2020:2024, ufs = "all")     # 5 anos, todas as UFs
#   build_data(years = "all", ufs = "all")         # TUDO (demorado)
#
# `ufs` é a UF do ARQUIVO (estabelecimento), como no FTP; a coluna `uf` dos
# cubos é a UF de RESIDÊNCIA (MUNIC_RES) de 1998 em diante e a UF do ARQUIVO
# até 1997 (ver ERA ANTIGA abaixo).
#
# JANELA DE COMPETÊNCIAS (decidida nos dados em 2026-09-05, ver
# docs/analise-001-janela-competencia.md): o cubo do ano Y contém as
# internações com DT_INTER em Y, lidas das competências Y-01..Y-12 e dos
# MESES_SEGUINTES primeiros meses de Y+1. Com 4 meses: 99,7–99,9% das
# internações do ano (dezembro 99,3–99,7%) em todas as UFs; o que falta é
# reapresentação tardia difusa, que nem +12 meses recupera. O cubo de Y fica
# FECHADO quando a competência (Y+1)-04 é publicada: partições posteriores não
# o alteram, só reedições dentro da janela.
#
# Acesso ao R2: pelo pacote healthbR (>= 0.3.1.9000, dev de 2026-09-05):
# `healthbR::sih_status()` diz quais partições existem e de que .dbc vieram;
# `healthbR::sih_data(source = "r2", lazy = TRUE)` abre o espelho como dataset
# arrow remoto, com a projeção das 10 colunas empurrada para o Parquet. O token
# público somente-leitura vive no pacote; outro bucket entra por
# `r2_credentials` (ver ?healthbR::sih_data). Este script não tem código S3
# próprio desde a v2.2.0.
#
# RAÇA/COR ANTES DE 2008 (v2.4.0, 2026-09-07): RACA_COR só entra no leiaute da
# AIH em 2008. Para 1998–2007 a coluna é OPCIONAL: o cubo sai com `race` NULO
# em todas as linhas (decisão do usuário: não "ignorado", não valor próprio) e
# o sidecar registra `columns_missing = ["RACA_COR"]` + nota. O healthbR impõe
# ao prefixo o esquema do ano MAIS NOVO pedido, então o cubo de 1998 (lê
# 1998+1999) não vê a coluna e o de 2007 (lê 2007+2008) a vê com NA nas linhas
# de 2007 — os dois caminhos têm de dar o mesmo cubo (ver ler_particoes()).
# Exige healthbR >= 0.4.0.9000 (sih_years() desde 1992).
#
# ERA ANTIGA 1992–1997 (v2.5.0, 2026-09-07; docs/analise-002 e analise-003,
# CONTEXT decisões 21–23). O SIH-RD de 1992–1997 difere do de 1998+ e o builder
# trata as diferenças por linha, sem ramo separado:
#   - DIAG_PRINC em CID-9 (6 dígitos: prefixo + categoria + subcategoria + DV),
#     decodificado por TABELA (tables/cid9-codes.json; a tabela tem 2
#     exceções à fórmula do DV). `cid_revision` (9/10) é CHAVE nos três cubos
#     em TODOS os anos (constante 10 em 1998+); em 1997 a janela traz as
#     competências 1998-01..04, já em CID-10 — as duas revisões convivem no
#     mesmo cubo e a coluna as separa. `cid_group` em CID-9 = categoria de 3
#     dígitos ("466", "E883", "V01"); `cid_chapter` = capítulo CID-10
#     equivalente (tables/cid9-chapters.json). Código fora da tabela (os da
#     CID9XINV.CNV, que o DATASUS marca inválidos — ~0,1 % das AIH — e os 3
#     com DV errado) sai com cid_group e cid_chapter NULOS, como hoje o CID-10
#     inválido; conta em records_in_cube e nas séries.
#   - ICSAP por tabela nas duas revisões: CID-9 pela lista DERIVADA e não
#     oficial de tables/csap-groups-cid9.json (analise-003; g03 e g05 não
#     comparáveis com 1998+); CID-10 pela Portaria 221/2008.
#   - DT_INTER tem 6 dígitos (AAMMDD) até 1997 e 8 (AAAAMMDD) de 1998; é
#     lido pelo comprimento. Vazio (1992-01..04 e 1993-01, 6,3 M AIH) → data =
#     competência do arquivo (dia 1), contado em `records_date_imputed`.
#   - MUNIC_RES não existe em 1992–93 e é vazio até nov/1994: nos anos
#     <= 1997 `uf` é a UF DO ARQUIVO (estabelecimento) e `municipality_code`
#     é nulo (sidecar `uf_basis = "arquivo"`, `municipality_available = false`).
#     De 1998 em diante nada muda (uf de residência).
#   - `value` é NOMINAL na moeda da competência (Cr$ até 1993-06, CR$
#     1993-07..1994-06, R$ desde 1994-07); o sidecar registra `currency`.
#   - SEXO "2" (feminino no CNV da era; <= 616 AIH/ano) → "F".
#   - COD_IDADE: 2 = DIAS, 3 = MESES (as versões < 2.5.0 invertiam os dois e
#     davam idade 1–2 anos a neonatos de 12–30 dias — sih:cod-idade). Ambos
#     dão 0 anos; por isso os 28 anos de 1998+ foram reconstruídos.
#   - CUBO ICSAP com TODOS os estratos: além de uma linha por (estrato × grupo
#     CSAP), uma linha por estrato SEM ICSAP (csap_group nulo, n = 0), ambas
#     com n_total = total do estrato. O denominador do % ICSAP é n_total
#     somado sobre estratos DISTINTOS (servidor >= 0.9.0); somar linha a
#     linha multiplica pelo número de grupos e omite os estratos sem ICSAP
#     (defeito do servidor <= 0.8.0: 2023/RR dava 3,65 % em vez de 19,75 %).
#
# UNIVERSO DO % ICSAP COMO O csapAIH (v2.6.0, 2026-09-07; decisão do usuário:
# a metodologia consagrada na literatura brasileira é a do pacote R csapAIH,
# de Fúlvio B. Nedel). O csapAIH classifica pela mesma lista da Portaria 221
# (idêntica à tabela deste projeto, código por código), mas ANTES exclui do
# numerador e do denominador: internações por procedimento obstétrico
# (procobst.rm), com diagnóstico de parto O80–O84 (parto.rm) e AIH de longa
# permanência IDENT = 5 (longa.rm). Aqui cada internação recebe a marca
# `exclusion` (procedimento_obstetrico | parto | longa_permanencia | nulo),
# gravada como CHAVE nos cubos de causas e ICSAP SEM apagar a classificação
# CSAP — o servidor calcula o % ICSAP sobre `exclusion IS NULL` por padrão e
# pode incluir tudo a pedido. Tabelas em tables/csap-universe.json
# (scripts/csap-universe-tables.py): SIGTAP 2008+ = os 10 códigos do csapAIH;
# tabela antiga 1992–2007 = grupos partos normais/cesáreos/abortamentos de
# PROCOBST.CNV do DATASUS; parto em CID-9 = 650 e 669.5–669.7.
# =============================================================================

library(dplyr)
library(tidyr)
library(purrr)
library(arrow)      # write_parquet dos cubos
library(stringr)
library(cli)
library(jsonlite)

if (!requireNamespace("healthbR", quietly = TRUE) ||
    !exists("sih_status", asNamespace("healthbR"))) {
  stop(paste(
    "Este script precisa do healthbR com sih_status() (versao dev >= 2026-09-05).",
    "Instale com: devtools::install('C:/dev/r-packages/healthbR', upgrade = FALSE)"
  ), call. = FALSE)
}

# =============================================================================
# CONFIGURACAO
# =============================================================================

# Pasta desta pipeline (tabelas em PIPELINE_DIR/tables). rebuild-cubes.R a
# define pelo próprio caminho; ao dar source() direto, vale a raiz do repo.
if (!exists("PIPELINE_DIR")) PIPELINE_DIR <- here::here("scripts", "pipeline", "sih-cubos")

# Saída: SIH_CUBOS_OUT (o workflow e `rebuild-cubes.R --out` a definem), senão
# data/sih-cubos/ na raiz do repo — gitignored: o estado dos cubos é o canal
# público (sih/cubos/ no R2), não o git.
OUTPUT_DIR <- Sys.getenv("SIH_CUBOS_OUT", unset = here::here("data", "sih-cubos"))
dir.create(OUTPUT_DIR, showWarnings = FALSE, recursive = TRUE)

# 2.7.0: mesma agregação da 2.6.1; só mudou de casa (caminhos das tabelas e
# do sidecar; `builder.repository` no sidecar). Cubos byte a byte iguais aos
# da 2.6.1 — provado no primeiro dispatch (2025, delta zero).
BUILDER_VERSION <- "2.7.0"

# Meses de Y+1 lidos para fechar as internações de Y (ver cabeçalho)
MESES_SEGUINTES <- 4L

# Identidade do distribuidor, registrada no sidecar (o acesso é do healthbR)
HEALTHBR_BUCKET <- "healthbr-data"
HEALTHBR_PREFIX <- "sih/rd"
# 2.6.1: domínio próprio do bucket (sih:canal-acabamento); o servidor lê o
# sidecar e, se o domínio falhar, cai no r2.dev sozinho (src/freshness.ts)
HEALTHBR_MANIFEST_URL <- "https://data.sidneybissoli.com/sih/rd/manifest.json"
HEALTHBR_REPO_URL <- "https://github.com/SidneyBissoli/healthbr-data"
HEALTHBR_LICENSE <- "CC-BY-4.0"

DATASUS_FTP_DIR <- "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/200801_/Dados/"

# Colunas cruas do SIH-RD que os cubos usam (projeção na leitura do R2).
# As OPCIONAIS podem faltar no Parquet de um ano (RACA_COR: só de 2008 em
# diante; MUNIC_RES: só de 1994); saem nulas no cubo e registradas em
# `columns_missing` no sidecar.
COLUNAS_OBRIGATORIAS <- c("DT_INTER", "DIAG_PRINC", "SEXO", "IDADE",
                          "COD_IDADE", "DIAS_PERM", "VAL_TOT", "MORTE",
                          "PROC_REA", "IDENT")  # 2.6.0: universo do % ICSAP
COLUNAS_OPCIONAIS <- c("MUNIC_RES", "RACA_COR")
COLUNAS_SIH <- c(COLUNAS_OBRIGATORIAS, COLUNAS_OPCIONAIS)

# Até este ano `uf` dos cubos é a UF DO ARQUIVO e `municipality_code` é nulo
# (MUNIC_RES ausente em 1992–93 e vazio até nov/1994; decisão iv da analise-002
# §5: um critério só para os seis anos, bem documentado, em vez de um cubo com
# base de eixo diferente a cada ano).
UF_ARQUIVO_ATE_ANO <- 1997L

# Todas as UFs brasileiras
ALL_UFS <- c("AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA",
             "MT", "MS", "MG", "PA", "PB", "PR", "PE", "PI", "RJ", "RN",
             "RS", "RO", "RR", "SC", "SP", "SE", "TO")

# Ano inicial: primeiro ano do SIH-RD no espelho (CID-9 até 1997, ver cabeçalho)
FIRST_YEAR <- 1992

# =============================================================================
# TABELAS CID / ICSAP (2.5.0) — contrato versionado em tables/ desta pasta e
# publicado no canal em sih/cubos/tables/ (sha256 no manifesto); o sih-br-mcp
# mantém cópias em src/data/ conferidas no CI dele contra o canal
# =============================================================================

TABELAS_DIR <- file.path(PIPELINE_DIR, "tables")

#' Carrega, uma vez por sessão, as tabelas versionadas em tables/:
#'   cid9   — 8.240 códigos de 6 dígitos → categoria e capítulo CID-10
#'            equivalente (cid9-codes.json; gerado por scripts/cid9-tables.py)
#'   csap9  — código de 6 dígitos → grupo ICSAP (csap-groups-cid9.json; lista
#'            derivada, não oficial)
#'   csap10 — código CID-10 (3 ou 4 caracteres, sem ponto) → grupo ICSAP
#'            (csap-groups.json, Portaria 221/2008); classificar_csap() fica
#'            como referência da prova provar_csap_cid10_tabela()
carregar_tabelas <- function() {
  cid9 <- jsonlite::fromJSON(file.path(TABELAS_DIR, "cid9-codes.json"))$codes
  if (anyDuplicated(cid9$code6)) cli_abort("cid9-codes.json: code6 repetido")

  csap9_json <- jsonlite::fromJSON(file.path(TABELAS_DIR, "csap-groups-cid9.json"),
                                   simplifyVector = FALSE)
  csap9 <- dplyr::bind_rows(lapply(csap9_json$groups, function(g) {
    codes <- unique(unlist(lapply(g$diagnoses, function(d) d$codes6)))
    data.frame(code6 = codes, csap_group = g$code, stringsAsFactors = FALSE)
  }))
  if (anyDuplicated(csap9$code6)) cli_abort("csap-groups-cid9.json: código em mais de um grupo")
  comparabilidade <- setNames(
    lapply(csap9_json$groups, function(g) g$comparability),
    vapply(csap9_json$groups, function(g) g$code, "")
  )

  csap10_json <- jsonlite::fromJSON(file.path(TABELAS_DIR, "csap-groups.json"),
                                    simplifyVector = FALSE)
  csap10 <- dplyr::bind_rows(lapply(csap10_json$groups, function(g) {
    codes <- unique(unlist(lapply(g$diagnoses, function(d) d$cid10)))
    data.frame(code = gsub(".", "", toupper(codes), fixed = TRUE), csap_group = g$code,
               stringsAsFactors = FALSE)
  }))

  # 2.6.0: universo do % ICSAP (csapAIH) — procedimentos obstétricos por era,
  # diagnóstico de parto por revisão da CID, AIH de longa permanência
  univ <- jsonlite::fromJSON(file.path(TABELAS_DIR, "csap-universe.json"), simplifyVector = FALSE)
  universo <- list(
    proc_obst = c(vapply(univ$procedures_sigtap, function(p) p$code, ""),
                  vapply(univ$procedures_old_table, function(p) p$code, "")),
    parto_cid10 = unlist(univ$delivery_diagnosis_cid10),
    parto_cid9 = vapply(univ$delivery_diagnosis_cid9$codes6, function(p) p$code6, ""),
    ident_longa = unlist(univ$long_stay_ident),
    method = univ$metadata$method_source
  )

  list(cid9 = cid9, csap9 = csap9, csap10 = csap10,
       icsap9_comparability = comparabilidade,
       icsap9_list_revision = csap9_json$metadata$icsap_list_revision,
       universo = universo)
}
TABELAS <- carregar_tabelas()

ICSAP_LIST_REVISION <- c("9" = TABELAS$icsap9_list_revision, "10" = "portaria-221-2008")

# =============================================================================
# FUNCOES AUXILIARES
# =============================================================================

#' Extrai capitulo CID-10 do codigo
extrair_capitulo_cid <- function(cid) {
  if (is.na(cid) || nchar(cid) < 1) return(NA_integer_)

  letra <- toupper(substr(cid, 1, 1))
  num <- suppressWarnings(as.integer(substr(cid, 2, 3)))
  if (is.na(num)) num <- 0

  capitulo <- dplyr::case_when(
    letra %in% c("A", "B") ~ 1L,
    letra == "C" | (letra == "D" & num <= 48) ~ 2L,
    letra == "D" & num >= 50 ~ 3L,
    letra == "E" ~ 4L,
    letra == "F" ~ 5L,
    letra == "G" ~ 6L,
    letra == "H" & num <= 59 ~ 7L,
    letra == "H" & num >= 60 ~ 8L,
    letra == "I" ~ 9L,
    letra == "J" ~ 10L,
    letra == "K" ~ 11L,
    letra == "L" ~ 12L,
    letra == "M" ~ 13L,
    letra == "N" ~ 14L,
    letra == "O" ~ 15L,
    letra == "P" ~ 16L,
    letra == "Q" ~ 17L,
    letra == "R" ~ 18L,
    letra %in% c("S", "T") ~ 19L,
    letra %in% c("V", "W", "X", "Y") ~ 20L,
    letra == "Z" ~ 21L,
    letra == "U" ~ 22L,
    TRUE ~ NA_integer_
  )

  return(capitulo)
}

#' Mapa de codigo UF para sigla. `unname()` porque `uf_map[codigo]` devolve
#' vetor NOMEADO (um nome por linha) e o arrow grava atributos de R nos
#' metadados do Parquet: o cubo de causas de 5 UFs carregava 5,5 MB de
#' metadado só de nomes (1,5 MB depois de tirar o Vectorize; ~0 depois disto).
#' Medido em 2026-09-06. O conteúdo das colunas não muda.
uf_codigo_para_sigla <- function(codigo) {
  uf_map <- c(
    "11" = "RO", "12" = "AC", "13" = "AM", "14" = "RR", "15" = "PA",
    "16" = "AP", "17" = "TO", "21" = "MA", "22" = "PI", "23" = "CE",
    "24" = "RN", "25" = "PB", "26" = "PE", "27" = "AL", "28" = "SE",
    "29" = "BA", "31" = "MG", "32" = "ES", "33" = "RJ", "35" = "SP",
    "41" = "PR", "42" = "SC", "43" = "RS", "50" = "MS", "51" = "MT",
    "52" = "GO", "53" = "DF"
  )
  unname(uf_map[codigo])
}

#' Classifica codigo CID-10 como CSAP
#' Baseado na Portaria MS/SAS 221/2008
#' @param cid Codigo CID-10 (3 ou 4 caracteres, sem ponto)
#' @return Codigo do grupo CSAP (g01-g19) ou NA
classificar_csap <- function(cid) {
  if (is.na(cid) || cid == "") return(NA_character_)

  cid <- toupper(trimws(cid))
  cid3 <- substr(cid, 1, 3)
  cid4 <- substr(cid, 1, 4)

  # g01: Doencas preveniveis por imunizacao
  g01_prefixos <- c("A33", "A34", "A35", "A36", "A37", "A95", "B05", "B06",
                    "B16", "B26", "A19", "A15", "A16", "A18", "I00", "I01",
                    "I02", "A51", "A52", "A53", "B50", "B51", "B52", "B53",
                    "B54", "B77")
  g01_especificos <- c("G000", "A170", "A171", "A178", "A179")
  if (cid3 %in% g01_prefixos || cid4 %in% g01_especificos) return("g01")

  # g02: Gastroenterites infecciosas
  g02_prefixos <- c("E86", "A00", "A01", "A02", "A03", "A04", "A05", "A06",
                    "A07", "A08", "A09")
  if (cid3 %in% g02_prefixos) return("g02")

  # g03: Anemia
  if (cid3 == "D50") return("g03")

  # g04: Deficiencias nutricionais
  g04_prefixos <- c("E40", "E41", "E42", "E43", "E44", "E45", "E46", "E50",
                    "E51", "E52", "E53", "E54", "E55", "E56", "E58", "E59",
                    "E60", "E61", "E63", "E64")
  if (cid3 %in% g04_prefixos) return("g04")

  # g05: Infeccoes de ouvido, nariz e garganta
  g05_prefixos <- c("H66", "J00", "J01", "J02", "J03", "J06", "J31")
  if (cid3 %in% g05_prefixos) return("g05")

  # g06: Pneumonias bacterianas
  g06_prefixos <- c("J13", "J14")
  g06_especificos <- c("J153", "J154", "J158", "J159", "J181")
  if (cid3 %in% g06_prefixos || cid4 %in% g06_especificos) return("g06")

  # g07: Asma
  g07_prefixos <- c("J45", "J46")
  if (cid3 %in% g07_prefixos) return("g07")

  # g08: Doencas pulmonares
  g08_prefixos <- c("J20", "J21", "J40", "J41", "J42", "J43", "J44", "J47")
  if (cid3 %in% g08_prefixos) return("g08")

  # g09: Hipertensao
  g09_prefixos <- c("I10", "I11")
  if (cid3 %in% g09_prefixos) return("g09")

  # g10: Angina
  if (cid3 == "I20") return("g10")

  # g11: Insuficiencia cardiaca
  g11_prefixos <- c("I50", "J81")
  if (cid3 %in% g11_prefixos) return("g11")

  # g12: Doencas cerebrovasculares
  g12_prefixos <- c("I63", "I64", "I65", "I66", "I67", "I69", "G45", "G46")
  if (cid3 %in% g12_prefixos) return("g12")

  # g13: Diabetes mellitus
  g13_prefixos <- c("E10", "E11", "E12", "E13", "E14")
  if (cid3 %in% g13_prefixos) return("g13")

  # g14: Epilepsias
  g14_prefixos <- c("G40", "G41")
  if (cid3 %in% g14_prefixos) return("g14")

  # g15: Infeccao no rim e trato urinario
  g15_prefixos <- c("N10", "N11", "N12", "N30", "N34")
  g15_especificos <- c("N390")
  if (cid3 %in% g15_prefixos || cid4 %in% g15_especificos) return("g15")

  # g16: Infeccao da pele e tecido subcutaneo
  g16_prefixos <- c("A46", "L01", "L02", "L03", "L04", "L08")
  if (cid3 %in% g16_prefixos) return("g16")

  # g17: Doenca inflamatoria dos orgaos pelvicos femininos
  g17_prefixos <- c("N70", "N71", "N72", "N73", "N75", "N76")
  if (cid3 %in% g17_prefixos) return("g17")

  # g18: Ulcera gastrointestinal
  g18_prefixos <- c("K25", "K26", "K27", "K28")
  g18_especificos <- c("K920", "K921", "K922")
  if (cid3 %in% g18_prefixos || cid4 %in% g18_especificos) return("g18")

  # g19: Doencas relacionadas ao pre-natal e parto
  g19_prefixos <- c("O23", "A50")
  g19_especificos <- c("P350")
  if (cid3 %in% g19_prefixos || cid4 %in% g19_especificos) return("g19")

  return(NA_character_)
}

#' Classifica vetor de CIDs como CSAP (vetorizado)
classificar_csap_vec <- Vectorize(classificar_csap)

#' Aplica uma função escalar a um vetor PELOS VALORES ÚNICOS e espalha o
#' resultado de volta (match). extrair_capitulo_cid() e classificar_csap()
#' custam milissegundos por chamada (case_when e uma cadeia de %in% por
#' elemento); linha a linha, 393 mil internações levavam mais de 10 minutos e
#' um ano nacional (~14 milhões) levaria horas — enquanto os CIDs distintos
#' num ano são poucos milhares. Medido em 2026-09-06 (build 2.2.1). O
#' resultado é idêntico ao de map_int/Vectorize: mesma função, mesmos valores.
por_valor_unico <- function(x, f, tipo) {
  u <- unique(x)
  v <- unname(vapply(u, f, tipo, USE.NAMES = FALSE))
  v[match(x, u)]
}

#' Classifica CID-10 como CSAP pela TABELA tables/csap-groups.json (código de
#' 4 caracteres exato tem precedência sobre o de 3). Serve à prova
#' provar_csap_cid10_tabela(); a produção usa classificar_csap().
classificar_csap_cid10_tabela <- function(cid4) {
  cid4 <- toupper(trimws(cid4))
  t3 <- TABELAS$csap10[nchar(TABELAS$csap10$code) == 3L, ]
  t4 <- TABELAS$csap10[nchar(TABELAS$csap10$code) == 4L, ]
  g4 <- t4$csap_group[match(cid4, t4$code)]
  g3 <- t3$csap_group[match(substr(cid4, 1, 3), t3$code)]
  ifelse(is.na(g4), g3, g4)
}

#' PROVA: a tabela e a função hardcoded dão o mesmo grupo para todos os códigos
#' de `cids`. Devolve os que divergem (data.frame vazio = prova passou).
provar_csap_cid10_tabela <- function(cids) {
  cids <- unique(toupper(trimws(cids)))
  funcao <- unname(vapply(cids, classificar_csap, NA_character_, USE.NAMES = FALSE))
  tabela <- classificar_csap_cid10_tabela(cids)
  dif <- !(is.na(funcao) & is.na(tabela)) & (is.na(funcao) | is.na(tabela) | funcao != tabela)
  data.frame(cid = cids[dif], funcao = funcao[dif], tabela = tabela[dif], stringsAsFactors = FALSE)
}

#' Deriva, de DIAG_PRINC, tudo o que os cubos precisam — pelos valores únicos
#' (ver por_valor_unico) e por revisão da CID:
#'   revisao  9 se o código tem 6 dígitos (SIH até 1997), 10 caso contrário
#'   grupo    CID-10: 3 caracteres; CID-9: categoria de 3 dígitos da tabela
#'   capitulo CID-10: extrair_capitulo_cid(); CID-9: capítulo CID-10 equivalente
#'            da tabela (código fora da tabela, p.ex. DV errado → NA)
#'   csap     CID-10: classificar_csap(); CID-9: lista derivada (csap9)
derivar_diagnostico <- function(diag) {
  u <- unique(diag)
  u_chr <- ifelse(is.na(u), "", u)
  revisao <- ifelse(grepl("^[0-9]{6}$", u_chr), 9L, 10L)

  cid3 <- substr(u_chr, 1, 3)
  cid4 <- substr(u_chr, 1, 4)
  grupo <- ifelse(nzchar(cid3), cid3, NA_character_)
  capitulo <- unname(vapply(cid3, extrair_capitulo_cid, NA_integer_, USE.NAMES = FALSE))
  # ICSAP CID-10 pela TABELA (csap-groups.json): provado idêntico a
  # classificar_csap() nos 11.757 códigos das CID10_*.CNV do DATASUS em
  # 2026-09-07 (provar_csap_cid10_tabela; 0 divergências) — a função fica
  # como referência da prova.
  csap <- classificar_csap_cid10_tabela(cid4)
  csap[!nzchar(cid4)] <- NA_character_

  i9 <- which(revisao == 9L)
  if (length(i9) > 0) {
    m <- match(u_chr[i9], TABELAS$cid9$code6)
    grupo[i9] <- TABELAS$cid9$category[m]
    capitulo[i9] <- as.integer(TABELAS$cid9$chapter[m])
    csap[i9] <- TABELAS$csap9$csap_group[match(u_chr[i9], TABELAS$csap9$code6)]
  }

  idx <- match(diag, u)
  list(revisao = revisao[idx], grupo = grupo[idx], capitulo = capitulo[idx], csap = csap[idx])
}

#' Marca de EXCLUSÃO do universo do % ICSAP, como csapAIH::csapAIH() com os
#' padrões procobst.rm, parto.rm e longa.rm (nesta ordem de precedência):
#'   "procedimento_obstetrico" PROC_REA na lista (SIGTAP 2008+ ou tabela antiga)
#'   "parto"                   diagnóstico O80–O84 (CID-10) ou 650/669.5–.7 (CID-9)
#'   "longa_permanencia"       IDENT = 5
#'   NA                        entra no numerador e no denominador
#' A classificação CSAP é feita para TODAS as linhas; a marca é chave à parte.
derivar_exclusao <- function(proc, ident, diag, revisao) {
  proc <- trimws(dplyr::coalesce(as.character(proc), ""))
  ident <- trimws(dplyr::coalesce(as.character(ident), ""))
  diag <- dplyr::coalesce(diag, "")
  obst <- proc %in% TABELAS$universo$proc_obst
  parto <- ifelse(revisao == 9L,
                  diag %in% TABELAS$universo$parto_cid9,
                  toupper(substr(diag, 1, 3)) %in% TABELAS$universo$parto_cid10)
  longa <- ident %in% TABELAS$universo$ident_longa
  dplyr::case_when(
    obst ~ "procedimento_obstetrico",
    parto ~ "parto",
    longa ~ "longa_permanencia",
    TRUE ~ NA_character_
  )
}

#' Moedas das competências da janela do ano (por MÊS DE FATURAMENTO, medido em
#' VAL_TOT — analise-002 §3): Cr$ cruzeiro até 1993-06, CR$ cruzeiro real
#' 1993-07..1994-06, R$ real desde 1994-07. `value` dos cubos é nominal.
moedas_do_ano <- function(ano) {
  periodos <- list(
    list(from = "1992-01", to = "1993-06", code = "BRE", symbol = "Cr$", name = "cruzeiro"),
    list(from = "1993-07", to = "1994-06", code = "BRR", symbol = "CR$", name = "cruzeiro real"),
    list(from = "1994-07", to = "9999-12", code = "BRL", symbol = "R$", name = "real")
  )
  janela <- janela_competencias(ano)
  ini <- min(janela)
  fim <- max(janela)
  dentro <- Filter(function(p) p$from <= fim && p$to >= ini, periodos)
  lapply(dentro, function(p) {
    p$from <- max(p$from, ini)
    p$to <- min(p$to, fim)
    p
  })
}

# =============================================================================
# ACESSO AO HEALTHBR-DATA (via healthbR)
# =============================================================================

.healthbr <- new.env(parent = emptyenv())

#' Estado do espelho: uma linha por partição publicada (competência x UF de
#' arquivo), com o .dbc de origem, o Parquet gerado e a versão do pipeline.
#' `attr(, "last_updated")` é a data do manifesto. Memorizado por sessão.
healthbr_status <- function() {
  if (is.null(.healthbr$status)) {
    cli_alert_info("Lendo o manifesto do healthbr-data pelo healthbR ({.fn healthbR::sih_status})")
    st <- healthbR::sih_status()
    precisa <- c("year", "month", "uf", "records", "processing_timestamp",
                 "source_url", "source_hash_md5", "source_size_bytes",
                 "parquet_path", "parquet_sha256", "pipeline_version", "git_commit")
    faltam <- setdiff(precisa, names(st))
    if (nrow(st) == 0 || length(faltam) > 0) {
      cli_abort(c(
        "healthbR::sih_status() não trouxe o que o sidecar precisa.",
        "x" = if (nrow(st) == 0) "Manifesto vazio ou inacessível." else
          "Colunas ausentes: {paste(faltam, collapse = ', ')} (healthbR dev >= 2026-09-05)."
      ))
    }
    .healthbr$status <- st
    cli_alert_success("Manifesto: {.val {nrow(st)}} partições, atualizado em {.val {attr(st, 'last_updated')}}")
  }
  .healthbr$status
}

#' Competências "AAAA-MM" da janela do ano Y: Y-01..Y-12 + MESES_SEGUINTES de Y+1
janela_competencias <- function(ano) {
  c(sprintf("%d-%02d", ano, 1:12),
    if (MESES_SEGUINTES > 0) sprintf("%d-%02d", ano + 1L, seq_len(MESES_SEGUINTES)))
}

#' Partições publicadas na janela de um ano, para as UFs de arquivo: linhas
#' de healthbr_status() com a chave "AAAA-MM-UF", ordenadas por chave.
healthbr_particoes <- function(ano, ufs, status) {
  status %>%
    dplyr::mutate(competencia = sprintf("%04d-%02d", year, month),
                  chave = paste(competencia, uf, sep = "-")) %>%
    dplyr::filter(competencia %in% janela_competencias(ano), uf %in% ufs) %>%
    dplyr::arrange(chave)
}

#' Lê as partições (só as colunas dos cubos) pelo healthbR, em modo lazy: a
#' projeção e o filtro da janela são empurrados para o Parquet no R2. Confere,
#' partição a partição, que as linhas lidas batem com o manifesto, e monta o
#' registro de proveniência de cada arquivo.
ler_particoes <- function(ano, ufs, particoes) {
  anos <- sort(unique(particoes$year))
  ds <- healthbR::sih_data(year = anos, uf = ufs, source = "r2",
                           lazy = TRUE, parse = FALSE)
  faltam <- setdiff(COLUNAS_OBRIGATORIAS, names(ds))
  if (length(faltam) > 0) {
    cli_abort("Colunas ausentes no Parquet do healthbr-data: {paste(faltam, collapse = ', ')}")
  }
  # Opcionais (2.4.0): o healthbR impõe ao prefixo o esquema do ano MAIS NOVO
  # pedido. Para o cubo de 1998 (lê 1998+1999) RACA_COR não está no esquema;
  # para o de 2007 (lê 2007+2008) está, mas toda linha da competência de 2007
  # vem NA. Os dois têm de dar o mesmo cubo: a coluna conta como AUSENTE no ano
  # quando nenhuma linha das competências do ano a traz, e sai nula em TODAS as
  # linhas do lote (inclusive nas de Y+1 que já a trazem). O mesmo vale para
  # MUNIC_RES em 1992 (lê 1993, sem a coluna) e 1993 (lê 1994, com ela e NA).
  presentes <- intersect(COLUNAS_OPCIONAIS, names(ds))
  dados <- ds %>%
    dplyr::filter(year == ano | (year == ano + 1L & month <= MESES_SEGUINTES)) %>%
    dplyr::select(dplyr::all_of(c("year", "month", "uf_source", COLUNAS_OBRIGATORIAS, presentes))) %>%
    dplyr::collect()
  ausentes <- setdiff(COLUNAS_OPCIONAIS, presentes)
  no_ano <- dados$year == ano
  for (col in presentes) {
    if (any(no_ano) && all(is.na(dados[[col]][no_ano]))) ausentes <- c(ausentes, col)
  }
  for (col in ausentes) dados[[col]] <- NA_character_

  # Cada partição lida tem de ter exatamente as linhas que o manifesto declara
  lidas <- dados %>%
    dplyr::count(year, month, uf = uf_source, name = "linhas") %>%
    dplyr::mutate(chave = sprintf("%04d-%02d-%s", year, month, uf))
  conferencia <- particoes %>%
    dplyr::select(chave, records) %>%
    dplyr::full_join(lidas %>% dplyr::select(chave, linhas), by = "chave") %>%
    dplyr::mutate(linhas = dplyr::coalesce(linhas, 0L),
                  records = dplyr::coalesce(records, 0))
  divergentes <- conferencia %>% dplyr::filter(linhas != records)
  if (nrow(divergentes) > 0) {
    detalhe <- sprintf("%s: manifesto %s, lidas %s", divergentes$chave,
                       format(divergentes$records, big.mark = "."),
                       format(divergentes$linhas, big.mark = "."))
    cli_abort(c("Partições com contagem diferente do manifesto:", setNames(detalhe, rep("x", length(detalhe)))))
  }
  # 2.5.0: a competência do arquivo fica (imputa DT_INTER vazio) e uf_source
  # também (é o `uf` dos cubos até UF_ARQUIVO_ATE_ANO)
  dados <- dados %>% dplyr::rename(comp_year = year, comp_month = month)

  registro <- lapply(seq_len(nrow(particoes)), function(i) {
    p <- particoes[i, ]
    list(
      partition = p$chave,
      parquet_path = p$parquet_path,
      parquet_sha256 = p$parquet_sha256,
      record_count = as.integer(p$records),
      source_file = basename(p$source_url),
      source_url = p$source_url,
      source_hash_md5 = p$source_hash_md5,
      source_size_bytes = p$source_size_bytes,
      processing_timestamp = p$processing_timestamp,
      healthbr_pipeline_version = p$pipeline_version,
      healthbr_git_commit = p$git_commit
    )
  })

  list(dados = dados, particoes = registro, colunas_ausentes = ausentes)
}

#' "AAAA-MM-DD HH:MM:SS.ffffff" (UTC, do manifesto) -> "AAAA-MM-DDTHH:MM:SSZ"
iso_utc <- function(ts) {
  sub("^(\\d{4}-\\d{2}-\\d{2})[ T](\\d{2}:\\d{2}:\\d{2}).*$", "\\1T\\2Z", ts)
}

#' Escreve data/sih_provenance_<ano>.json — o registro de safra do cubo
escrever_sidecar <- function(ano, chaves, particoes, manifest_last_updated, janela_completa, totais, output_dir,
                             columns_missing = character(), records_date_imputed = 0L,
                             cid_revision = list(), csap_excluded = list()) {
  # 2.6.0: universo do % ICSAP (csapAIH) — quantas ficaram fora e por quê
  n_universo <- if (length(csap_excluded) > 0) csap_excluded[["nenhuma"]] else NULL
  fora <- csap_excluded[setdiff(names(csap_excluded), "nenhuma")]
  # 2.5.0: base do eixo `uf`, revisões da CID presentes, moedas da janela
  uf_arquivo <- ano <= UF_ARQUIVO_ATE_ANO
  uf_basis <- if (uf_arquivo) "arquivo" else "residencia"
  tem_cid9 <- "9" %in% names(cid_revision) && cid_revision[["9"]] > 0
  moedas <- moedas_do_ano(ano)
  varias_moedas <- length(moedas) > 1 || any(vapply(moedas, function(m) m$code != "BRL", logical(1)))
  git_commit <- tryCatch(
    trimws(system2("git", c("-C", shQuote(here::here()), "rev-parse", "HEAD"), stdout = TRUE, stderr = FALSE)),
    error = function(e) NA_character_, warning = function(w) NA_character_
  )
  if (length(git_commit) != 1 || is.na(git_commit) || !nzchar(git_commit)) git_commit <- NULL

  # processing_timestamp do manifesto == download_date do rodapé do Parquet ao
  # segundo (o pipeline do healthbr-data grava os dois no mesmo instante)
  processados_em <- iso_utc(vapply(particoes, function(p) p$processing_timestamp, ""))
  sidecar <- list(
    manifest_version = "1.1.0",
    dataset = HEALTHBR_PREFIX,
    cube_year = ano,
    window = list(
      rule = "internações com DT_INTER no ano; competências do ano + meses seguintes de Y+1",
      months_after = MESES_SEGUINTES,
      competencias_expected = I(janela_competencias(ano)),
      complete = janela_completa,
      evidence = "docs/analise-001-janela-competencia.md"
    ),
    competencias = I(sort(unique(substr(chaves, 1, 7)))),
    ufs_arquivo = I(sort(unique(substr(chaves, 9, 10)))),
    built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    builder = list(
      script = "scripts/pipeline/sih-cubos/build-aggregations.R",
      repository = "https://github.com/SidneyBissoli/healthbr-data",
      version = BUILDER_VERSION,
      git_commit = git_commit,
      r_version = R.version.string,
      arrow_version = as.character(packageVersion("arrow")),
      healthbr_version = as.character(packageVersion("healthbR"))
    ),
    source = list(
      name = "Ministério da Saúde — DATASUS, SIH/SUS (AIH reduzida, RD)",
      agency = "Ministério da Saúde",
      database = "SIH/SUS",
      endpoint = DATASUS_FTP_DIR
    ),
    distributor = list(
      name = "healthbr-data",
      url = HEALTHBR_REPO_URL,
      bucket = sprintf("s3://%s/%s/", HEALTHBR_BUCKET, HEALTHBR_PREFIX),
      manifest_url = HEALTHBR_MANIFEST_URL,
      manifest_last_updated = manifest_last_updated,
      license = HEALTHBR_LICENSE
    ),
    retrieved_at = max(processados_em),
    partitions = particoes,
    totals = totais,
    # 2.5.0: AIH que entraram com DT_INTER vazio (data = competência do arquivo)
    records_date_imputed = as.integer(records_date_imputed),
    # 2.5.0: internações do cubo por revisão da CID de DIAG_PRINC (9 = CID-9 de
    # 6 dígitos, até 1997; 10 = CID-10); `cid_revision` é chave nos três cubos
    cid_revision = cid_revision,
    icsap_list_revision = as.list(ICSAP_LIST_REVISION[names(cid_revision)]),
    not_official_icsap = tem_cid9,
    icsap_comparability = if (tem_cid9) TABELAS$icsap9_comparability else NULL,
    uf_basis = uf_basis,
    municipality_available = !uf_arquivo,
    currency = moedas,
    # 2.6.0: universo do % ICSAP como o csapAIH (procobst.rm, parto.rm,
    # longa.rm): a marca `exclusion` é chave nos cubos de causas e ICSAP; o
    # servidor calcula o % sobre exclusion IS NULL por padrão
    csap_universe = list(
      method = "csapAIH",
      method_source = TABELAS$universo$method,
      rules = I(c("procedimento_obstetrico", "parto", "longa_permanencia")),
      tables = "scripts/pipeline/sih-cubos/tables/csap-universe.json",
      records_in_universe = n_universo,
      excluded = fora
    ),
    # 2.4.0: colunas cruas que este ano do SIH-RD não tem (RACA_COR antes de
    # 2008; MUNIC_RES antes de 1994). O servidor lê daqui se `race` existe.
    columns_missing = I(columns_missing),
    notes = I(c(
      "Cubo por ANO DE INTERNAÇÃO (DT_INTER): lê as competências do ano e os meses seguintes de Y+1 (window.months_after) e descarta internações de outros anos. Com 4 meses, 99,7-99,9% das internações do ano (dezembro 99,3-99,7%); o restante é reapresentação tardia difusa.",
      if (uf_arquivo)
        "uf dos cubos = UF DO ARQUIVO (estabelecimento, ufs_arquivo), NÃO de residência: MUNIC_RES não existe no SIH-RD de 1992-1993 e é vazio até nov/1994; para dar aos seis anos 1992-1997 um eixo só, `uf` é a UF do arquivo e `municipality_code` é nulo em todas as linhas (uf_basis = 'arquivo'; decisão iv de docs/analise-002-sih-1992-1997.md §5). De 1998 em diante uf é a de residência: séries por UF não são estritamente comparáveis na fronteira 1997/98 (a diferença é a internação fora da UF de residência)."
      else "uf dos cubos = UF de residência (MUNIC_RES); ufs_arquivo = UF do estabelecimento (nome do arquivo RD no FTP).",
      "retrieved_at = processing_timestamp mais recente, no manifesto do healthbr-data, dos .dbc que alimentaram este cubo (extração no upstream; igual, ao segundo, ao download_date do rodapé do Parquet). Lido por healthbR::sih_status().",
      if (length(columns_missing) > 0) sprintf(
        "Coluna(s) %s não existe(m) no SIH-RD de %d (RACA_COR só entra no leiaute da AIH em 2008; MUNIC_RES só em dez/1994): a coluna derivada (`race` de RACA_COR) é nula em todas as linhas deste cubo, inclusive nas internações faturadas nas competências seguintes de %d, que já trazem a coluna.",
        paste(columns_missing, collapse = ", "), ano, ano + 1L),
      if (records_date_imputed > 0) sprintf(
        "%s internações entraram com DT_INTER VAZIO (o SIH-RD de 1992-01..04 e 1993-01 não traz a data): data de internação = dia 1 da competência do arquivo (decisão ii da analise-002 §5); nelas `month` é o mês de faturamento, não o de internação.",
        format(records_date_imputed, big.mark = ".")),
      if (tem_cid9)
        "DIAG_PRINC em CID-9 (cid_revision = 9): código de 6 dígitos decodificado por tabela (tables/cid9-codes.json); cid_group = categoria de 3 dígitos ('466', 'E883', 'V01'); cid_chapter = capítulo CID-10 equivalente (tables/cid9-chapters.json). ICSAP pela lista DERIVADA e NÃO OFICIAL de tables/csap-groups-cid9.json (docs/analise-003-icsap-cid9.md): g03 (anemia) e g05 (ouvido, nariz e garganta) não são comparáveis com 1998+ (icsap_comparability). Linhas com cid_revision = 10 no mesmo cubo são internações já faturadas em CID-10 (competências de 1998).",
      if (ano == 1997L)
        "As internações de 1997 faturadas em 1998-01 e 1998-02 (cid_revision = 10) têm ICSAP subestimado: a proporção ICSAP caiu para 19-20% nesses dois meses de adaptação à CID-10 e voltou a 24,5% em março (analise-003 §3.4). Efeito da fonte, não corrigido.",
      if (varias_moedas)
        "value é NOMINAL na moeda da competência de faturamento (currency): Cr$ cruzeiro até 1993-06, CR$ cruzeiro real 1993-07..1994-06, R$ real desde 1994-07. Não somar nem comparar valores entre moedas; não comparável com anos posteriores antes de 1994-07 (decisão v da analise-002 §5).",
      "% ICSAP como o pacote R csapAIH (Nedel): a lista de diagnósticos é a da Portaria 221/2008 para TODAS as internações, mas o percentual da literatura exclui do numerador e do denominador as internações por procedimento obstétrico (PROC_REA na lista SIGTAP do csapAIH, ou nos grupos partos/cesáreas/abortamentos da tabela antiga até 2007), as com diagnóstico de parto (O80-O84; em CID-9 650 e 669.5-669.7) e as AIH de longa permanência (IDENT = 5). A coluna `exclusion` (chave nos cubos de causas e ICSAP) marca o motivo; nula = entra no universo (csap_universe.records_in_universe). O servidor usa o universo por padrão e pode incluir tudo a pedido.",
      "age: COD_IDADE 2 (dias) e 3 (meses) valem 0 anos. As versões < 2.5.0 do builder trocavam os dois (neonatos de 12-30 dias saíam com 1-2 anos); corrigido em 2.5.0 (sih:cod-idade) e os cubos de 1998+ reconstruídos."
    ))
  )
  if (!tem_cid9) sidecar$icsap_comparability <- NULL
  destino <- file.path(output_dir, sprintf("sih_provenance_%d.json", ano))
  jsonlite::write_json(sidecar, destino, auto_unbox = TRUE, pretty = TRUE, null = "null", digits = NA)
  cli_alert_success("  sih_provenance_{ano}.json: {.val {length(particoes)}} partições, retrieved_at {.val {sidecar$retrieved_at}}")
  invisible(destino)
}

#' Agrega UM LOTE de internações já lidas (as colunas cruas do healthbr-data)
#' nos três cubos parciais do ano. Devolve as agregações do lote e as contagens
#' de controle; quem soma os lotes é processar_ano(). Um lote = uma UF de
#' arquivo: o ano nacional de 2023 são 13,3 milhões de internações e, num
#' único data frame, estourou os 16 GB do runner (run 34038116890, 06/09/2026);
#' por UF o maior lote (SP) fica em ~3,5 milhões. Somar agregados de lotes
#' disjuntos dá o mesmo cubo que agregar tudo de uma vez: n, deaths e days são
#' contagens/inteiros (exatos); value é soma de doubles, igual ao último ulp.
agregar_lote <- function(dados, ano, colunas_ausentes = character()) {
  n_lidos <- nrow(dados)
  uf_arquivo <- ano <= UF_ARQUIVO_ATE_ANO

  # DT_INTER (2.5.0): AAAAMMDD (8 dígitos, 1998+) ou AAMMDD (6, até 1997),
  # lido pelo comprimento. VAZIO → dia 1 da competência do arquivo (contado em
  # records_date_imputed; decisão ii). Qualquer outro conteúdo é inválido e
  # fica fora, como antes. O filtro de ano de internação roda DEPOIS da
  # imputação: AIH sem data de 1993-01 vão para o cubo de 1993.
  dt_chr <- trimws(dplyr::coalesce(as.character(dados$DT_INTER), ""))
  vazio <- !nzchar(dt_chr)
  dt <- rep(as.Date(NA), n_lidos)
  i8 <- nchar(dt_chr) == 8L
  i6 <- nchar(dt_chr) == 6L
  dt[i8] <- as.Date(dt_chr[i8], format = "%Y%m%d")
  dt[i6] <- as.Date(dt_chr[i6], format = "%y%m%d")
  dt[vazio] <- as.Date(sprintf("%04d-%02d-01", dados$comp_year[vazio], dados$comp_month[vazio]))
  dados$dt_inter <- dt
  dados$dt_imputada <- vazio
  n_invalidos <- sum(is.na(dados$dt_inter))
  if (n_invalidos > 0) {
    cli_alert_warning("{n_invalidos} registros com DT_INTER inválido ficam fora dos cubos")
    dados <- dados %>% dplyr::filter(!is.na(dt_inter))
  }
  # O cubo é por ANO DE INTERNAÇÃO: o que a janela trouxe de outros anos
  # (internações de Y-1 faturadas em Y; de Y+1 nas competências extras) sai.
  ano_inter <- as.integer(format(dados$dt_inter, "%Y"))
  n_outros_anos <- sum(ano_inter != ano)
  dados <- dados[ano_inter == ano, , drop = FALSE]
  # Imputadas que FICARAM no cubo (as de 1993-01 lidas na janela de 1992 caem
  # no filtro acima e contam no cubo de 1993)
  n_imputados <- sum(dados$dt_imputada)
  if (n_imputados > 0) {
    cli_alert_info("  {format(n_imputados, big.mark='.')} internações de {ano} com DT_INTER vazio: data = competência do arquivo")
  }

  # Diagnóstico pelos valores únicos e por revisão da CID (2.5.0)
  diag <- derivar_diagnostico(dados$DIAG_PRINC)
  # Universo do % ICSAP (2.6.0, csapAIH): marca por linha, chave à parte
  exclusao <- derivar_exclusao(dados$PROC_REA, dados$IDENT, dados$DIAG_PRINC, diag$revisao)

  dados <- dados %>%
    dplyr::mutate(
      ano = as.integer(format(dt_inter, "%Y")),
      mes = as.integer(format(dt_inter, "%m")),
      ano_mes = sprintf("%04d-%02d", ano, mes),
      # uf: residência (MUNIC_RES) de 1998 em diante; UF DO ARQUIVO até 1997,
      # com município nulo (ver cabeçalho e UF_ARQUIVO_ATE_ANO)
      uf = if (uf_arquivo) uf_source else uf_codigo_para_sigla(substr(MUNIC_RES, 1, 2)),
      municipio_res = if (uf_arquivo) NA_character_ else MUNIC_RES,
      cid_revisao = diag$revisao,
      cid = diag$grupo,
      capitulo_cid = diag$capitulo,
      sexo = dplyr::case_when(
        SEXO == "1" ~ "M",
        SEXO %in% c("2", "3") ~ "F",  # "2" = feminino no CNV de 1992-1997 (<= 616 AIH/ano)
        TRUE ~ "I"
      ),
      # IDADE SIMPLES (em anos completos). COD_IDADE: 2 = dias (0-30), 3 = meses
      # (1-11), 4 = anos, 5 = 100 + anos, 0/1 = ignorado. As versões < 2.5.0
      # trocavam 2 e 3 (sih:cod-idade); os dois valem 0 anos.
      idade = dplyr::case_when(
        COD_IDADE == "2" ~ 0L,  # dias -> 0 anos
        COD_IDADE == "3" ~ 0L,  # meses (< 12) -> 0 anos
        COD_IDADE == "4" ~ as.integer(IDADE),
        COD_IDADE == "5" ~ as.integer(as.numeric(IDADE) + 100),
        TRUE ~ NA_integer_
      ),
      # Ano sem RACA_COR (2.4.0): race NULO, não "ignorado" — ver cabeçalho.
      raca = if ("RACA_COR" %in% colunas_ausentes) NA_character_ else dplyr::case_when(
        RACA_COR == "01" ~ "branca",
        RACA_COR == "02" ~ "preta",
        RACA_COR == "03" ~ "parda",
        RACA_COR == "04" ~ "amarela",
        RACA_COR == "05" ~ "indigena",
        TRUE ~ "ignorado"
      ),
      dias = as.numeric(DIAS_PERM),
      valor = as.numeric(VAL_TOT),
      obito = as.integer(MORTE == "1"),
      grupo_csap = diag$csap,
      is_csap = !is.na(grupo_csap),
      exclusao = exclusao  # coluna: o cubo ICSAP filtra linhas antes de agrupar
    )

  causas <- dados %>%
    dplyr::group_by(
      year = ano,
      month = mes,
      uf,
      cid_chapter = capitulo_cid,
      cid_revision = cid_revisao,
      cid_group = cid,
      sex = sexo,
      age = idade,
      race = raca,
      exclusion = exclusao,
      is_csap,
      csap_group = grupo_csap
    ) %>%
    dplyr::summarise(
      n = dplyr::n(),
      days = sum(dias, na.rm = TRUE),
      value = sum(valor, na.rm = TRUE),
      deaths = sum(obito, na.rm = TRUE),
      .groups = "drop"
    )

  series <- dados %>%
    dplyr::group_by(
      year_month = ano_mes,
      uf,
      cid_chapter = capitulo_cid,
      cid_revision = cid_revisao
    ) %>%
    dplyr::summarise(
      n = dplyr::n(),
      deaths = sum(obito, na.rm = TRUE),
      .groups = "drop"
    )

  # Total de internacoes por estrato
  totais <- dados %>%
    dplyr::group_by(
      year = ano,
      uf,
      municipality_code = municipio_res,
      cid_revision = cid_revisao,
      sex = sexo,
      age = idade,
      race = raca,
      exclusion = exclusao
    ) %>%
    dplyr::summarise(
      n_total = dplyr::n(),
      .groups = "drop"
    )

  # ICSAP por grupo
  icsap <- dados %>%
    dplyr::filter(is_csap) %>%
    dplyr::group_by(
      year = ano,
      uf,
      municipality_code = municipio_res,
      cid_revision = cid_revisao,
      csap_group = grupo_csap,
      sex = sexo,
      age = idade,
      race = raca,
      exclusion = exclusao
    ) %>%
    dplyr::summarise(
      n = dplyr::n(),
      days = sum(dias, na.rm = TRUE),
      value = sum(valor, na.rm = TRUE),
      deaths = sum(obito, na.rm = TRUE),
      .groups = "drop"
    )

  list(
    causas = causas, series = series, totais = totais, icsap = icsap,
    n_lidos = n_lidos, n_invalidos = n_invalidos, n_outros_anos = n_outros_anos,
    n_imputados = n_imputados, n_cubo = nrow(dados)
  )
}

#' Soma agregados parciais (um por lote) nas mesmas chaves de grupo:
#' bind_rows + summarise(sum). Com um lote só, devolve o próprio.
somar_lotes <- function(lotes, chaves) {
  x <- dplyr::bind_rows(lotes)
  if (length(lotes) == 1L) return(x)
  x %>%
    dplyr::group_by(dplyr::across(dplyr::all_of(chaves))) %>%
    dplyr::summarise(dplyr::across(dplyr::everything(), ~ sum(.x)), .groups = "drop")
}

#' Processa dados de um ano de competência, UMA UF DE ARQUIVO POR VEZ
processar_ano <- function(ano, ufs_arquivo, output_dir) {

  cli_h2("Ano {ano}")

  tryCatch({
    status <- healthbr_status()
    particoes <- healthbr_particoes(ano, ufs_arquivo, status)
    chaves <- particoes$chave
    esperadas <- length(ufs_arquivo) * length(janela_competencias(ano))
    if (length(chaves) == 0) {
      cli_alert_warning("Sem partições publicadas para {ano} / {paste(ufs_arquivo, collapse=', ')}")
      return(NULL)
    }
    janela_completa <- length(chaves) == esperadas
    if (!janela_completa) {
      cli_alert_warning("{length(chaves)} de {esperadas} partições publicadas na janela de {ano} (competências ainda não divulgadas pelo MS ficam de fora; o cubo sai INCOMPLETO)")
    }

    ufs_com_dados <- sort(unique(particoes$uf))
    cli_alert_info("Lendo {length(chaves)} partições do R2 pelo healthbR, {length(ufs_com_dados)} UF(s) de arquivo em lotes (colunas: {paste(COLUNAS_SIH, collapse=', ')})")
    t0 <- Sys.time()
    lotes <- list()
    registro <- list()
    ausentes_por_lote <- list()
    for (uf in ufs_com_dados) {
      part_uf <- particoes[particoes$uf == uf, , drop = FALSE]
      lido <- ler_particoes(ano, uf, part_uf)
      registro <- c(registro, lido$particoes)
      ausentes_por_lote[[uf]] <- lido$colunas_ausentes
      lote <- agregar_lote(lido$dados, ano, lido$colunas_ausentes)
      cli_alert_info("  {uf}: {format(lote$n_lidos, big.mark='.')} lidas, {format(lote$n_cubo, big.mark='.')} internações de {ano}, {format(nrow(lote$causas), big.mark='.')} linhas de causas ({format(round(Sys.time() - t0, 1))})")
      lotes[[uf]] <- lote
      rm(lido, lote)
      gc()
    }
    colunas_ausentes <- sort(unique(unlist(ausentes_por_lote)))
    if (length(colunas_ausentes) > 0) {
      cli_alert_warning("Coluna(s) ausente(s) no SIH-RD de {ano}: {paste(colunas_ausentes, collapse = ', ')} — a coluna derivada sai NULA neste cubo (sidecar: columns_missing)")
      lotes_diferentes <- names(ausentes_por_lote)[!vapply(ausentes_por_lote, identical, logical(1), colunas_ausentes)]
      if (length(lotes_diferentes) > 0) {
        cli_alert_warning("Lotes com colunas ausentes DIFERENTES do conjunto do ano: {paste(lotes_diferentes, collapse = ', ')} — o cubo mistura NULO e valor; investigar")
      }
    }
    n_lidos <- sum(vapply(lotes, function(l) l$n_lidos, numeric(1)))
    n_invalidos <- sum(vapply(lotes, function(l) l$n_invalidos, numeric(1)))
    n_outros_anos <- sum(vapply(lotes, function(l) l$n_outros_anos, numeric(1)))
    n_imputados <- sum(vapply(lotes, function(l) l$n_imputados, numeric(1)))
    cli_alert_success("{.val {format(n_lidos, big.mark='.')}} registros lidos em {format(round(Sys.time() - t0, 1))}")
    cli_alert_info("{format(n_outros_anos, big.mark='.')} registros de outros anos de internação descartados; {format(n_lidos - n_invalidos - n_outros_anos, big.mark='.')} internações de {ano}; {format(n_imputados, big.mark='.')} com DT_INTER vazio (data = competência)")

    # =========================================================================
    # CUBO 1: sih_causas_{ano}.parquet
    # =========================================================================

    cli_alert_info("Gerando cubo sih_causas_{ano}.parquet...")
    cubo_causas <- somar_lotes(
      lapply(lotes, function(l) l$causas),
      c("year", "month", "uf", "cid_chapter", "cid_revision", "cid_group", "sex", "age", "race", "exclusion", "is_csap", "csap_group")
    )
    write_parquet(cubo_causas, file.path(output_dir, sprintf("sih_causas_%d.parquet", ano)))
    cli_alert_success("  sih_causas_{ano}.parquet: {.val {format(nrow(cubo_causas), big.mark='.')}} linhas")
    # 2.5.0: internações por revisão da CID (sidecar cid_revision)
    por_revisao <- tapply(cubo_causas$n, cubo_causas$cid_revision, sum)
    cid_revision_counts <- as.list(setNames(as.integer(por_revisao), names(por_revisao)))
    # 2.6.0: internações fora do universo do % ICSAP, por motivo (csapAIH)
    excl <- tapply(cubo_causas$n, dplyr::coalesce(cubo_causas$exclusion, "nenhuma"), sum)
    excl_counts <- as.list(setNames(as.integer(excl), names(excl)))
    cli_alert_info("  universo do % ICSAP (csapAIH): {paste(sprintf('%s %s', names(excl), format(as.integer(excl), big.mark='.')), collapse = '; ')}")
    cli_alert_info("  por revisão da CID: {paste(sprintf('CID-%s %s', names(por_revisao), format(as.integer(por_revisao), big.mark='.')), collapse = '; ')}")
    # 2.3.1: o maior objeto do ano (6,5 M linhas) e os lotes de causas não são
    # mais necessários — soltar ANTES do cubo ICSAP. Em 2025 (14,6 M
    # internações) o passo ICSAP estourou os 16 GB do runner com tudo isso
    # ainda na memória (run 34062485932, "The operation was canceled").
    records_in_cube <- sum(cubo_causas$n)
    causas_rows <- nrow(cubo_causas)
    rm(cubo_causas)
    lotes <- lapply(lotes, function(l) { l$causas <- NULL; l })
    gc()

    # =========================================================================
    # CUBO 2: sih_series_{ano}.parquet
    # =========================================================================

    cli_alert_info("Gerando cubo sih_series_{ano}.parquet...")
    cubo_series <- somar_lotes(
      lapply(lotes, function(l) l$series),
      c("year_month", "uf", "cid_chapter", "cid_revision")
    )
    write_parquet(cubo_series, file.path(output_dir, sprintf("sih_series_%d.parquet", ano)))
    cli_alert_success("  sih_series_{ano}.parquet: {.val {format(nrow(cubo_series), big.mark='.')}} linhas")

    # =========================================================================
    # CUBO 3: sih_icsap_{ano}.parquet
    # =========================================================================

    cli_alert_info("Gerando cubo sih_icsap_{ano}.parquet...")
    totais <- somar_lotes(
      lapply(lotes, function(l) l$totais),
      c("year", "uf", "municipality_code", "cid_revision", "sex", "age", "race", "exclusion")
    )
    icsap <- somar_lotes(
      lapply(lotes, function(l) l$icsap),
      c("year", "uf", "municipality_code", "cid_revision", "csap_group", "sex", "age", "race", "exclusion")
    )
    # Junta com totais. 2.5.0: TODOS os estratos entram — os sem ICSAP saem com
    # csap_group NULO e n = 0, carregando n_total. Antes só os estratos com
    # alguma ICSAP existiam no cubo, e o servidor somava n_total (repetido por
    # grupo) linha a linha: o denominador ficava multiplicado pelo número de
    # grupos do estrato e faltavam os estratos sem ICSAP (2023/RR: 3,65 % em
    # vez de 19,75 %). O denominador certo é n_total somado sobre os estratos
    # DISTINTOS (year, uf, municipality_code, cid_revision, sex, age, race);
    # o servidor >= 0.9.0 calcula assim.
    chaves_estrato <- c("year", "uf", "municipality_code", "cid_revision", "sex", "age", "race", "exclusion")
    cubo_icsap <- icsap %>%
      dplyr::full_join(totais, by = chaves_estrato) %>%
      dplyr::mutate(
        n = dplyr::coalesce(n, 0L),
        days = dplyr::coalesce(days, 0),
        value = dplyr::coalesce(value, 0),
        deaths = dplyr::coalesce(deaths, 0L)
      ) %>%
      dplyr::arrange(dplyr::across(dplyr::all_of(c(chaves_estrato, "csap_group"))))
    estratos_sem_icsap <- sum(is.na(cubo_icsap$csap_group))
    write_parquet(cubo_icsap, file.path(output_dir, sprintf("sih_icsap_%d.parquet", ano)))
    cli_alert_success("  sih_icsap_{ano}.parquet: {.val {format(nrow(cubo_icsap), big.mark='.')}} linhas ({format(estratos_sem_icsap, big.mark='.')} estratos sem ICSAP, csap_group nulo)")

    # =========================================================================
    # SIDECAR DE PROVENIÊNCIA
    # =========================================================================

    escrever_sidecar(
      ano, chaves, registro, attr(status, "last_updated"), janela_completa,
      totais = list(
        records_read = n_lidos,
        records_invalid_dt_inter = n_invalidos,
        records_other_year = n_outros_anos,
        records_in_cube = records_in_cube,
        causas_rows = causas_rows,
        series_rows = nrow(cubo_series),
        icsap_rows = nrow(cubo_icsap),
        icsap_rows_without_csap = estratos_sem_icsap
      ),
      output_dir = output_dir,
      columns_missing = colunas_ausentes,
      records_date_imputed = n_imputados,
      cid_revision = cid_revision_counts,
      csap_excluded = excl_counts
    )

    # Limpa memoria
    rm(lotes, registro, cubo_series, totais, icsap, cubo_icsap)
    gc()

    cli_alert_success("Ano {ano} concluido!")

    return(TRUE)

  }, error = function(e) {
    cli_alert_danger("Erro ao processar ano {ano}: {e$message}")
    return(FALSE)
  })
}

# =============================================================================
# FUNCAO PRINCIPAL: build_data()
# =============================================================================

#' Gera cubos de dados Parquet a partir do SIH-SUS
#'
#' @param years Anos para processar. Pode ser:
#'   - Um ano: 2023
#'   - Vetor de anos: c(2020, 2022, 2024)
#'   - Sequencia: 2020:2024
#'   - "all" para todos os anos (1992 ate ano atual)
#'
#' @param ufs UFs para processar. Pode ser:
#'   - Uma UF: "SP"
#'   - Vetor de UFs: c("SP", "RJ", "AC")
#'   - "all" para todas as 27 UFs
#'
build_data <- function(years, ufs) {

  # Valida e expande parametro years
  if (identical(years, "all")) {
    ano_atual <- as.integer(format(Sys.Date(), "%Y"))
    years <- FIRST_YEAR:ano_atual
  } else {
    years <- as.integer(years)
    if (any(is.na(years))) {
      cli_abort("Parametro 'years' invalido. Use um numero, vetor ou 'all'.")
    }
  }

  # O healthbR instalado tem de aceitar os anos (a 0.4.0 do CRAN limita o SIH a
  # 2008+; 1992–2007 exigem >= 0.4.0.9000, SidneyBissoli/healthbR main)
  anos_healthbr <- healthbR::sih_years(status = "all")
  fora <- setdiff(years, anos_healthbr)
  if (length(fora) > 0) {
    cli_abort(c(
      "O healthbR {packageVersion('healthbR')} instalado não aceita o(s) ano(s) {paste(fora, collapse = ', ')} (sih_years: {min(anos_healthbr)}–{max(anos_healthbr)}).",
      "i" = "Cubos de 1992–2007 precisam do healthbR >= 0.4.0.9000: pak::pak('SidneyBissoli/healthbR')."
    ))
  }

  # Valida e expande parametro ufs
  if (identical(ufs, "all")) {
    ufs <- ALL_UFS
  } else {
    ufs <- toupper(ufs)
    ufs_invalidas <- setdiff(ufs, ALL_UFS)
    if (length(ufs_invalidas) > 0) {
      cli_abort("UF(s) invalida(s): {paste(ufs_invalidas, collapse=', ')}")
    }
  }

  # Alerta para processamento completo. Só PERGUNTA em sessão interativa:
  # num runner (scripts/rebuild-cubes.R) o readline() leria EOF e travaria ou
  # cancelaria em silêncio — lá o aviso fica no log e o build segue.
  if (length(years) > 20 && length(ufs) == 27) {
    cli_alert_warning("Voce solicitou processar {length(years)} anos e TODAS as 27 UFs.")
    cli_alert_warning("Isso le todas as particoes do R2 (colunas projetadas) e pode levar horas.")
    if (interactive()) {
      resposta <- readline(prompt = "Deseja continuar? (S/N): ")
      if (!toupper(resposta) %in% c("S", "SIM", "Y", "YES")) {
        cli_alert_info("Operacao cancelada pelo usuario.")
        return(invisible(NULL))
      }
    } else {
      cli_alert_info("Sessao nao interativa: seguindo sem confirmacao.")
    }
  }

  # Cabecalho
  cli_h1("SIH-BR-MCP: Geracao de Cubos de Dados")
  cli_alert_info("Anos: {.val {paste(range(years), collapse=' a ')}} ({length(years)} anos)")
  cli_alert_info("UFs: {.val {if(length(ufs)==27) 'TODAS (27)' else paste(ufs, collapse=', ')}}")
  cli_alert_info("Diretorio de saida: {.path {OUTPUT_DIR}}")
  cli_rule()

  # Processa cada ano
  resultados <- list()
  total_anos <- length(years)

  for (i in seq_along(years)) {
    ano <- years[i]
    cli_h1("Processando ano {ano} ({i}/{total_anos})")

    resultado <- processar_ano(ano, ufs, OUTPUT_DIR)
    resultados[[as.character(ano)]] <- resultado
  }

  # Resumo final
  sucessos <- sum(unlist(resultados), na.rm = TRUE)
  falhas <- sum(!unlist(resultados), na.rm = TRUE)

  cli_h1("PROCESSAMENTO CONCLUIDO!")
  cli_alert_success("Anos processados com sucesso: {.val {sucessos}}")
  if (falhas > 0) {
    cli_alert_warning("Anos com falha: {.val {falhas}}")
  }
  cli_alert_info("Arquivos salvos em: {.path {OUTPUT_DIR}}")

  return(invisible(resultados))
}

# =============================================================================
# MENSAGEM AO CARREGAR
# =============================================================================

cli_alert_info("Script build-aggregations.R v{BUILDER_VERSION} carregado (origem: healthbr-data s3://{HEALTHBR_BUCKET}/{HEALTHBR_PREFIX}/, lido pelo healthbR {packageVersion('healthbR')}).")
cli_alert_info("Use: build_data(years = ..., ufs = ...)")
cli_alert_info("Exemplos:")
cli_bullets(c(
  " " = "build_data(years = 2023, ufs = 'RR')",
  " " = "build_data(years = 2020:2024, ufs = 'all')",
  " " = "build_data(years = 'all', ufs = 'all')  # TUDO"
))
