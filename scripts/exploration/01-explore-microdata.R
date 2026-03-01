
# Etapa 0: explorar amostra dos microdados #####################################

# Objetivo: Baixar UMA amostra, confirmar estrutura e mapeamento de colunas.
#
# O que sabemos sobre os CSVs do OpenDATASUS (PNI rotina):
#   - Sem header (col_names = FALSE)
#   - Encoding Latin-1
#   - Delimitador: ;
#   - 56 colunas posicionais (55 reais + 1 artefato do ; final)
#   - Nomes oficiais do dicionário tb_ria_rotina, validados contra JSON
#   - Todos os campos armazenados como VARCHAR no banco original
#
# Fonte: OpenDATASUS / SI-PNI (Novo PNI / RNDS)
# Cobertura: 2020 em diante (microdados individuais, 1 linha = 1 dose)

# carregar e/ou instalar pacotes 
if (!require("pacman")) install.packages("pacman")
p_load(
  arrow, 
  dplyr, 
  readr, 
  fs, 
  glue, 
  curl
  )

--------------------------------------------------------------------------------

# 1. Mapeamento oficial das 55 colunas #########################################

# Validado contra:
#   - Dicionario_tb_ria_rotina.pdf (60 campos) - no projeto: "Dicionário.pdf"
#   - Primeiros registros do arquivo JSON (campos nomeados)
#
# 5 campos do dicionário AUSENTES no CSV:
#   Dict 13: st_vida_paciente
#   Dict 34: dt_entrada_datalake
#   Dict 38: co_identificador_sistema
#   Dict 58: dt_deleted (presente no JSON como dt_deletado_rnds)
#   Dict 59: ds_identificador_sistema

NOMES_COLUNAS <- c(
 
   # --- Paciente (14 campos) ---
  "co_documento",                        #  1 | Código documento RNDS (UUID)
  "co_paciente",                         #  2 | Identificador paciente RNDS (hash)
  "tp_sexo_paciente",                    #  3 | Sexo biológico (M/F)
  "co_raca_cor_paciente",                #  4 | Código raça/cor (01-05, 99)
  "no_raca_cor_paciente",                #  5 | Nome raça/cor
  "co_municipio_paciente",               #  6 | Código IBGE município
  "co_pais_paciente",                    #  7 | Código país (10=Brasil)
  "no_municipio_paciente",               #  8 | Nome município
  "no_pais_paciente",                    #  9 | Nome país
  "sg_uf_paciente",                      # 10 | Sigla UF
  "nu_cep_paciente",                     # 11 | CEP (5 dígitos)
  "ds_nacionalidade_paciente",           # 12 | Nacionalidade (B/E)
  "no_etnia_indigena_paciente",          # 13 | Nome etnia indígena
  "co_etnia_indigena_paciente",          # 14 | Código etnia indígena
  
  # --- Estabelecimento (6 campos) ---
  "co_cnes_estabelecimento",             # 15 | Código CNES
  "no_razao_social_estabelecimento",     # 16 | Razão social
  "no_fantasia_estalecimento",           # 17 | Nome fantasia (typo oficial)
  "co_municipio_estabelecimento",        # 18 | Código IBGE município
  "no_municipio_estabelecimento",        # 19 | Nome município
  "sg_uf_estabelecimento",               # 20 | Sigla UF
  
  # --- Vacinação (12 campos) ---
  "co_troca_documento",                  # 21 | Documento substituído/alterado
  "co_vacina",                           # 22 | Código vacina (imunobiológico)
  "sg_vacina",                           # 23 | Sigla vacina
  "dt_vacina",                           # 24 | Data vacinação (YYYY-MM-DD)
  "co_dose_vacina",                      # 25 | Código dose
  "ds_dose_vacina",                      # 26 | Descrição dose
  "co_local_aplicacao",                  # 27 | Código local aplicação
  "ds_local_aplicacao",                  # 28 | Descrição local aplicação
  "co_via_administracao",                # 29 | Código via administração
  "ds_via_administracao",                # 30 | Descrição via administração
  "co_lote_vacina",                      # 31 | Lote
  "ds_vacina_fabricante",                # 32 | Fabricante
  
  # --- Sistema/Controle (4 campos) ---
  "dt_entrada_rnds",                     # 33 | Timestamp entrada RNDS
  "co_sistema_origem",                   # 34 | Código sistema origem
  "ds_sistema_origem",                   # 35 | Descrição sistema origem
  "st_documento",                        # 36 | Status (final/entered-in-error)
  
  # --- Estratégia/Grupo (8 campos) ---
  "co_estrategia_vacinacao",             # 37 | Código estratégia
  "ds_estrategia_vacinacao",             # 38 | Descrição estratégia
  "co_origem_registro",                  # 39 | Código transcrição
  "ds_origem_registro",                  # 40 | Descrição transcrição
  "co_vacina_grupo_atendimento",         # 41 | Código grupo atendimento
  "ds_vacina_grupo_atendimento",         # 42 | Descrição grupo atendimento
  "co_vacina_categoria_atendimento",     # 43 | Código categoria
  "ds_vacina_categoria_atendimento",     # 44 | Descrição categoria
  
  # --- Fabricante/Vacina (2 campos) ---
  "co_vacina_fabricante",                # 45 | Código fabricante
  "ds_vacina",                           # 46 | Descrição vacina
  
  # --- Condição maternal (1 campo) ---
  "ds_condicao_maternal",                # 47 | Descrição condição maternal
  
  # --- Tipo/Natureza estabelecimento (4 campos) ---
  "co_tipo_estabelecimento",             # 48 | Código tipo CNES
  "ds_tipo_estabelecimento",             # 49 | Descrição tipo CNES
  "co_natureza_estabelecimento",         # 50 | Código natureza CNES
  "ds_natureza_estabelecimento",         # 51 | Descrição natureza CNES
  
  # --- Idade/Condição/UF (4 campos) ---
  "nu_idade_paciente",                   # 52 | Idade
  "co_condicao_maternal",                # 53 | Código condição maternal
  "no_uf_paciente",                      # 54 | Nome UF paciente
  "no_uf_estabelecimento"                # 55 | Nome UF estabelecimento

  )

--------------------------------------------------------------------------------

# 2. Baixar uma amostra ########################################################

MESES_PT <- c(
  "jan", "fev", "mar", "abr", "mai", "jun", 
  "jul", "ago", "set", "out", "nov", "dez"
  )

ano <- 2024
mes <- 1
url <- glue(
  "https://arquivosdadosabertos.saude.gov.br/dados/dbbni/",
  "vacinacao_{MESES_PT[mes]}_{ano}_csv.zip"
  )

cat(glue("Verificando: {basename(url)}"), "\n")
resp <- curl::curl_fetch_memory(url, handle = curl::new_handle(nobody = TRUE))
headers <- curl::parse_headers_list(resp$headers)
tamanho_gb <- round(as.numeric(headers[["content-length"]]) / 1e9, 2)
cat(glue("Tamanho: {tamanho_gb} GB"), "\n\n")

temp_zip <- tempfile(fileext = ".zip")
cat("Baixando...\n")
curl::curl_download(url, temp_zip, quiet = FALSE)

arquivos_zip <- unzip(temp_zip, list = TRUE)
print(arquivos_zip)

dir_temp <- tempdir()
unzip(temp_zip, exdir = dir_temp)
csv_path <- file.path(dir_temp, arquivos_zip$Name[1])

--------------------------------------------------------------------------------

# 3. Ler uma amostra (10 mil linhas) ###########################################

cat("\nLendo amostra (10.000 linhas)...\n")
amostra <- read_delim(
  file      = csv_path,
  delim     = ";",
  col_names = FALSE,
  col_types = cols(.default = "c"),
  n_max     = 10000,
  locale    = locale(encoding = "Latin1")
)

cat(glue("Colunas lidas: {ncol(amostra)}"), "\n")

# Descartar coluna 56 (artefato do ; final)
if (ncol(amostra) == 56) {
  amostra <- amostra[, 1:55]
  cat("Coluna 56 (artefato do ; final) descartada.\n")
}

names(amostra) <- NOMES_COLUNAS
cat(glue("Colunas nomeadas: {ncol(amostra)}"), "\n\n")

--------------------------------------------------------------------------------

# 4. Explorar ##################################################################

cat("========== ESTRUTURA ==========\n")
glimpse(amostra)

cat("\n========== VACINAS MAIS FREQUENTES ==========\n")
amostra |> count(ds_vacina, sort = TRUE) |> print(n = 20)

cat("\n========== DOSES ==========\n")
amostra |> count(ds_dose_vacina, sort = TRUE) |> print(n = 10)

cat("\n========== SEXO ==========\n")
amostra |> count(tp_sexo_paciente, sort = TRUE) |> print()

cat("\n========== UF ESTABELECIMENTO ==========\n")
amostra |> count(sg_uf_estabelecimento, sort = TRUE) |> print(n = 27)

cat("\n========== SISTEMA DE ORIGEM ==========\n")
amostra |> count(ds_sistema_origem, sort = TRUE) |> print(n = 10)

cat("\n========== STATUS DOCUMENTO ==========\n")
amostra |> count(st_documento, sort = TRUE) |> print()

cat("\n========== RANGE DE DATAS ==========\n")
cat("dt_vacina       Min:", min(amostra$dt_vacina, na.rm = TRUE),
    "| Max:", max(amostra$dt_vacina, na.rm = TRUE), "\n")
cat("dt_entrada_rnds Min:", min(amostra$dt_entrada_rnds, na.rm = TRUE),
    "| Max:", max(amostra$dt_entrada_rnds, na.rm = TRUE), "\n")

# Limpar
unlink(temp_zip)
unlink(csv_path)

cat("\n✅ Exploração concluída.\n")
cat("🎯 Próximo passo: rodar 01_converter_parquet.R\n")
