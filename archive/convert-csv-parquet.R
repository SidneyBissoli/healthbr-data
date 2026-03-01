
# Etapa 1: converter CSVs → Parquet particionado ###############################

# Este script roda na VPS (Hetzner). Ele:
#   1. Baixa CSV zip mensal do OpenDATASUS
#   2. Lê sem header, encoding Latin-1, delimitador ;
#   3. Atribui os 55 nomes oficiais do dicionário tb_ria_rotina
#   4. Salva como Parquet particionado: ano=YYYY/mes=MM/uf=XX/
#   5. Registra hash MD5 para controle de versão (evita reprocessamento)
#
# Após rodar, os Parquets estão prontos para upload ao R2 (script 02).
#
# Arquitetura:
#   VPS (este script) → R2 (Cloudflare) → HF (espelho) → healthbR (consumo)

# 1, Configurações #############################################################

# instalar e/ou carregar pacotes
if (!require("pacman")) install.packages("pacman")
p_load(
  arrow, 
  dplyr, 
  readr, 
  fs, 
  glue, 
  curl, 
  digest
)

data <- "parquet_pni"
dir_temp    <- "temp_csv"
arquivo_controle <- "controle_versao.csv"

# Período a processar
anos <- 2024          # Comece com 1 ano! Depois: anos <- 2020:2025
meses <- 1:12

meses_pt <- c(
  "jan", "fev", "mar", "abr", "mai", "jun",
  "jul", "ago", "set", "out", "nov", "dez"
  )

# 2. Mapeamento das 55 colunas ################################################# 
# validado contra JSON e dicionário 

nomes_colunas <- c(
  "co_documento",                        #  1
  "co_paciente",                         #  2
  "tp_sexo_paciente",                    #  3
  "co_raca_cor_paciente",                #  4
  "no_raca_cor_paciente",                #  5
  "co_municipio_paciente",               #  6
  "co_pais_paciente",                    #  7
  "no_municipio_paciente",               #  8
  "no_pais_paciente",                    #  9
  "sg_uf_paciente",                      # 10
  "nu_cep_paciente",                     # 11
  "ds_nacionalidade_paciente",           # 12
  "no_etnia_indigena_paciente",          # 13
  "co_etnia_indigena_paciente",          # 14
  "co_cnes_estabelecimento",             # 15
  "no_razao_social_estabelecimento",     # 16
  "no_fantasia_estalecimento",           # 17
  "co_municipio_estabelecimento",        # 18
  "no_municipio_estabelecimento",        # 19
  "sg_uf_estabelecimento",               # 20
  "co_troca_documento",                  # 21
  "co_vacina",                           # 22
  "sg_vacina",                           # 23
  "dt_vacina",                           # 24
  "co_dose_vacina",                      # 25
  "ds_dose_vacina",                      # 26
  "co_local_aplicacao",                  # 27
  "ds_local_aplicacao",                  # 28
  "co_via_administracao",                # 29
  "ds_via_administracao",                # 30
  "co_lote_vacina",                      # 31
  "ds_vacina_fabricante",                # 32
  "dt_entrada_rnds",                     # 33
  "co_sistema_origem",                   # 34
  "ds_sistema_origem",                   # 35
  "st_documento",                        # 36
  "co_estrategia_vacinacao",             # 37
  "ds_estrategia_vacinacao",             # 38
  "co_origem_registro",                  # 39
  "ds_origem_registro",                  # 40
  "co_vacina_grupo_atendimento",         # 41
  "ds_vacina_grupo_atendimento",         # 42
  "co_vacina_categoria_atendimento",     # 43
  "ds_vacina_categoria_atendimento",     # 44
  "co_vacina_fabricante",                # 45
  "ds_vacina",                           # 46
  "ds_condicao_maternal",                # 47
  "co_tipo_estabelecimento",             # 48
  "ds_tipo_estabelecimento",             # 49
  "co_natureza_estabelecimento",         # 50
  "ds_natureza_estabelecimento",         # 51
  "nu_idade_paciente",                   # 52
  "co_condicao_maternal",                # 53
  "no_uf_paciente",                      # 54
  "no_uf_estabelecimento"                # 55
)

# 3. Funções auxiliares ########################################################

# Construir URL do CSV de um mês/ano
construir_url <- function(ano, mes) {
  glue("https://arquivosdadosabertos.saude.gov.br/dados/dbbni/",
       "vacinacao_{meses_pt[mes]}_{ano}_csv.zip")
}

# Baixar zip para diretório temporário (pula se já existe)
baixar_zip <- function(url, dir_destino = dir_temp) {
  dir_create(dir_destino)
  nome <- basename(url)
  caminho <- path(dir_destino, nome)

  if (file_exists(caminho)) {
    cat(glue("  Já existe: {nome}"), "\n")
    return(caminho)
  }

  cat(glue("  Baixando: {nome}..."), "\n")
  tryCatch({
    curl::curl_download(url, caminho, quiet = FALSE)
    cat(glue("  OK: {round(file_size(caminho) / 1e6)} MB"), "\n")
    caminho
  }, error = function(e) {
    cat(glue("  ERRO no download: {e$message}"), "\n")
    if (file_exists(caminho)) file_delete(caminho)
    return(NULL)
  })
}

# Ler controle de versão
ler_controle <- function() {
  if (file_exists(arquivo_controle)) {
    read_csv(arquivo_controle, show_col_types = FALSE)
  } else {
    tibble(
      arquivo = character(), hash_md5 = character(),
      n_registros = integer(), data_processamento = character(),
      ano = integer(), mes = integer(), url_origem = character()
    )
  }
}

# Salvar controle de versão
salvar_controle <- function(controle) {
  write_csv(controle, arquivo_controle)
}

# 4. Pipeline principal ########################################################

processar_mes <- function(ano, mes) {

  url <- construir_url(ano, mes)
  cat(glue("\n{'=' |> strrep(60)}"), "\n")
  cat(glue("Processando: {meses_pt[mes]}/{ano}"), "\n")
  cat(glue("{'=' |> strrep(60)}"), "\n")

  # 1. Baixar
  zip_path <- baixar_zip(url)
  if (is.null(zip_path)) return(invisible(NULL))

  # 2. Verificar hash (pular se já processado e idêntico)
  hash_atual <- digest::digest(file = zip_path, algo = "md5")
  controle <- ler_controle()
  registro <- controle |> filter(arquivo == basename(zip_path))

  if (nrow(registro) > 0 && registro$hash_md5[1] == hash_atual) {
    cat("  Hash idêntico ao processamento anterior. Pulando.\n")
    return(invisible(NULL))
  }

  # 3. Extrair CSV do zip
  cat("  Extraindo zip...\n")
  arquivos <- unzip(zip_path, list = TRUE)
  csv_nome <- arquivos$Name[1]
  unzip(zip_path, files = csv_nome, exdir = dir_temp)
  csv_path <- path(dir_temp, csv_nome)

  # 4. Ler CSV com Arrow
  cat("  Lendo CSV...\n")

  # Definir schema: tudo character (55 campos reais + 1 artefato)
  schema_leitura <- do.call(schema, setNames(
    rep(list(utf8()), 56),
    c(nomes_colunas, "ARTEFATO")
  ))

  df <- read_delim_arrow(
    csv_path,
    delim = ";",
    col_names = c(nomes_colunas, "ARTEFATO"),
    col_types = schema_leitura,
    skip = 0,
    as_data_frame = FALSE,
    read_options = CsvReadOptions$create(encoding = "Latin1")
  )

  # Remover coluna artefato
  df <- df |> select(-ARTEFATO)

  n_total <- nrow(df)
  cat(glue("  {format(n_total, big.mark = '.')} registros lidos"), "\n")

  # 5. Adicionar colunas de partição
  cat("  Criando partições...\n")

  df_prep <- df |>
    mutate(
      ano = substr(dt_vacina, 1, 4),
      mes = substr(dt_vacina, 6, 7),
      uf  = sg_uf_estabelecimento
    ) |>
    filter(
      !is.na(uf),  nchar(uf)  == 2,
      !is.na(ano), nchar(ano) == 4,
      !is.na(mes)
    ) |>
    # Redirect records with invalid years to ano=_invalid
    mutate(
      ano = if_else(ano >= "2020" & ano <= format(Sys.Date(), "%Y"),
                    ano, "_invalid")
    )

  n_validos <- nrow(df_prep)
  n_descartados <- n_total - n_validos

  cat(glue("  {format(n_validos, big.mark = '.')} registros válidos"), "\n")
  if (n_descartados > 0) {
    cat(glue("  {format(n_descartados, big.mark = '.')} descartados"), "\n")
  }

  # 6. Salvar Parquet particionado
  cat("  Salvando Parquet...\n")
  dir_create(data)

  write_dataset(
    dataset                = df_prep,
    path                   = data,
    format                 = "parquet",
    partitioning           = c("ano", "mes", "uf"),
    existing_data_behavior = "overwrite",
    max_rows_per_file      = 500000
  )

  # 7. Atualizar controle
  novo <- tibble(
    arquivo = basename(zip_path), hash_md5 = hash_atual,
    n_registros = n_validos,
    data_processamento = as.character(Sys.time()),
    ano = ano, mes = mes, url_origem = url
  )
  controle <- controle |>
    filter(arquivo != basename(zip_path)) |>
    bind_rows(novo)
  salvar_controle(controle)

  # 8. Limpar CSV extraído (manter zip como cache)
  file_delete(csv_path)

  cat(glue("  Concluído: {meses_pt[mes]}/{ano}"), "\n")
  return(invisible(n_validos))
}

# 5. Executar ##################################################################

cat("Iniciando pipeline CSV → Parquet\n")
cat(glue("anos: {paste(anos, collapse = ', ')}"), "\n")
cat(glue("meses: {paste(meses, collapse = ', ')}"), "\n\n")

for (ano in anos) {
  for (mes in meses) {
    tryCatch(
      processar_mes(ano, mes),
      error = function(e) cat(glue("  ERRO: {e$message}"), "\n\n")
    )
  }
}

# 6. Verificar resultado #######################################################

cat("\nVerificando dataset...\n\n")

if (dir_exists(data)) {
  ds <- open_dataset(data)

  cat(glue("Total: {format(nrow(ds), big.mark = '.')} registros"), "\n")
  cat(glue("Colunas: {ncol(ds)}"), "\n\n")

  cat("Schema:\n")
  print(ds$schema)

  cat("\nRegistros por UF:\n")
  ds |> count(uf, sort = TRUE) |> collect() |> print(n = 27)

  cat("\nRegistros por ano/mês:\n")
  ds |> count(ano, mes) |> arrange(ano, mes) |> collect() |> print(n = 50)

  arquivos <- dir_ls(data, recurse = TRUE, glob = "*.parquet")
  tamanho <- sum(file_size(arquivos))
  cat(glue("\nArquivos: {length(arquivos)}"), "\n")
  cat(glue("Tamanho total: {round(tamanho / 1e9, 2)} GB"), "\n")
}

cat("\n✅ Pipeline concluído.\n")
cat("🎯 Próximo passo: rodar 02_upload_r2.R\n")
