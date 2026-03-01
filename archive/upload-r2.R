

# Etapa 2: upload dos Parquets para Cloudflare R2 ##############################

# Este script sobe os Parquets para o R2 via protocolo S3.
# O Hugging Face espelha o R2 como vitrine (descobribilidade).
# O healthbR consome direto do R2 via arrow::open_dataset("s3://...").

# Pré-requisitos:
#   1. Conta Cloudflare com R2 habilitado
#   2. Bucket criado (ex: "healthbr-data")
#   3. Token de API R2 com permissão de escrita
#   4. rclone instalado na VPS (ou pacote aws.s3 no R)
#
# Arquitetura:
#   Parquet local → R2 (armazenamento S3) → HF (espelho) → healthbR (consumo)

if (!require("pacman")) install.packages("pacman")
p_load(
  fs, 
  glue
  )


# 1. Configurações #############################################################

# Cloudflare R2
R2_ACCOUNT_ID  <- Sys.getenv("R2_ACCOUNT_ID", "SEU_ACCOUNT_ID")
R2_ACCESS_KEY  <- Sys.getenv("R2_ACCESS_KEY", "SUA_ACCESS_KEY")
R2_SECRET_KEY  <- Sys.getenv("R2_SECRET_KEY", "SUA_SECRET_KEY")
R2_BUCKET      <- "healthbr-data"
R2_ENDPOINT    <- glue("https://{R2_ACCOUNT_ID}.r2.cloudflarestorage.com")

# Diretório local com os Parquets
DIR_PARQUET <- "parquet_pni"

# Prefixo no bucket (organização por sistema)
R2_PREFIX <- "sipni"

# Hugging Face (espelho)
HF_USER <- "SEU_USUARIO_HF"
HF_DATASET <- "vacinacao-pni-brasil"

# Opção 1: upload via rclone (recomendado para VPS) ############################

# rclone é mais robusto para uploads grandes e suporta sync incremental.

# Configurar uma vez na VPS:
#   rclone config
#     → New remote → name: r2
#     → Type: Amazon S3 Compliant → Provider: Cloudflare R2
#     → access_key_id: SUA_ACCESS_KEY
#     → secret_access_key: SUA_SECRET_KEY
#     → endpoint: https://ACCOUNT_ID.r2.cloudflarestorage.com

# Depois é só sync:

upload_rclone <- function() {
  cat("Sincronizando Parquets com R2 via rclone...\n\n")

  cmd <- glue("rclone sync {DIR_PARQUET}/ r2:{R2_BUCKET}/{R2_PREFIX}/ ",
              "--progress ",
              "--transfers 16 ",
              "--checkers 32 ",
              "--s3-chunk-size 64M")

  cat("Comando:\n", cmd, "\n\n")
  system(cmd)

  cat("\n✅ Sync concluído.\n")
  cat(glue("Dados em: s3://{R2_BUCKET}/{R2_PREFIX}/"), "\n\n")
}

# =============================================================================
# OPÇÃO 2: UPLOAD VIA aws.s3 (alternativa em R puro)
# =============================================================================

upload_aws_s3 <- function() {
  if (!require("aws.s3")) install.packages("aws.s3")
  library(aws.s3)

  Sys.setenv(
    "AWS_ACCESS_KEY_ID" = R2_ACCESS_KEY,
    "AWS_SECRET_ACCESS_KEY" = R2_SECRET_KEY,
    "AWS_S3_ENDPOINT" = R2_ENDPOINT,
    "AWS_DEFAULT_REGION" = "auto"
  )

  arquivos <- dir_ls(DIR_PARQUET, recurse = TRUE, glob = "*.parquet")
  cat(glue("Arquivos para upload: {length(arquivos)}"), "\n\n")

  for (i in seq_along(arquivos)) {
    # Caminho relativo dentro do bucket
    chave <- path(R2_PREFIX, path_rel(arquivos[i], DIR_PARQUET))

    cat(glue("[{i}/{length(arquivos)}] {chave}"), "\n")

    put_object(
      file = arquivos[i],
      object = as.character(chave),
      bucket = R2_BUCKET,
      multipart = TRUE
    )
  }

  cat(glue("\n✅ {length(arquivos)} arquivos enviados para R2."), "\n")
  cat(glue("Dados em: s3://{R2_BUCKET}/{R2_PREFIX}/"), "\n\n")
}

# =============================================================================
# VERIFICAR UPLOAD
# =============================================================================

verificar_r2 <- function() {
  cat("Verificando acesso ao R2 via Arrow...\n\n")

  # Configurar acesso S3 para Arrow
  Sys.setenv(
    "AWS_ACCESS_KEY_ID" = R2_ACCESS_KEY,
    "AWS_SECRET_ACCESS_KEY" = R2_SECRET_KEY,
    "AWS_ENDPOINT_OVERRIDE" = R2_ENDPOINT,
    "AWS_DEFAULT_REGION" = "auto"
  )

  library(arrow)
  library(dplyr)

  ds <- open_dataset(glue("s3://{R2_BUCKET}/{R2_PREFIX}/"))

  cat(glue("Total: {format(nrow(ds), big.mark = '.')} registros"), "\n")
  cat(glue("Colunas: {ncol(ds)}"), "\n\n")

  cat("Teste: AC, janeiro 2024...\n")
  ac <- ds |>
    filter(uf == "AC", ano == "2024", mes == "01") |>
    collect()
  cat(glue("  {format(nrow(ac), big.mark = '.')} registros"), "\n")
  cat(glue("  {round(object.size(ac) / 1e6, 1)} MB em memória"), "\n")

  cat("\n✅ R2 funcionando.\n")
}

# =============================================================================
# GERAR README PARA HUGGING FACE (espelho)
# =============================================================================

gerar_readme_hf <- function() {
  repo_id <- glue("{HF_USER}/{HF_DATASET}")

  readme <- glue('---
license: cc-by-4.0
language:
  - pt
tags:
  - health
  - vaccination
  - brazil
  - public-health
  - datasus
  - pni
  - immunization
  - parquet
pretty_name: "Vacinação de Rotina — PNI Brasil (Microdados)"
size_categories:
  - 100M<n<1B
---

# Vacinação de Rotina — SI-PNI — Microdados em Parquet

Microdados individuais de vacinação do calendário nacional de rotina do SUS.
Cada registro representa uma dose aplicada.

**Fonte primária (R2):** acesse via `arrow::open_dataset("s3://...")`
para máxima velocidade. Este repositório é um espelho para descobribilidade.

## Fonte dos dados

- **Origem:** [OpenDATASUS](https://opendatasus.saude.gov.br/)
- **Sistema:** SI-PNI (Sistema de Informação do Programa Nacional de Imunizações)
- **Dicionário:** `Dicionario_tb_ria_rotina.pdf` (60 campos, tabela `tb_ria_rotina`)
- **Cobertura temporal:** 2020 em diante
- **Granularidade:** 1 linha = 1 dose aplicada
- **Variáveis:** 55 campos + 3 colunas de partição (ano, mes, uf)
- **Tipos:** todos character (preserva zeros à esquerda em códigos)

## Estrutura

```
sipni/ano=2024/mes=01/uf=AC/part-0.parquet
sipni/ano=2024/mes=01/uf=AL/part-0.parquet
...
```

Particionado por ano, mês e UF do estabelecimento.

## Como usar

### R

```r
library(arrow)
library(dplyr)

# Leitura seletiva — só baixa o que filtrar
ds <- open_dataset("s3://...", format = "parquet")

# Acre, janeiro 2024
ac <- ds |>
  filter(uf == "AC", ano == "2024", mes == "01") |>
  collect()

# Tríplice viral no Brasil inteiro, 2024
triplice <- ds |>
  filter(grepl("TRIPLICE VIRAL", ds_vacina), ano == "2024") |>
  count(uf, mes) |>
  collect()
```

### Python

```python
import pyarrow.dataset as ds

dataset = ds.dataset("s3://...", format="parquet")
df = dataset.to_table(
    filter=(ds.field("uf") == "AC") & (ds.field("ano") == "2024")
).to_pandas()
```

## Notas

- **Não inclui COVID-19.** Dados de COVID estão em dataset separado no OpenDATASUS.
- **Dados anonimizados** — sem identificação do cidadão.
- **Dados preliminares** — meses recentes podem ser revisados pelo Ministério da Saúde.
- **Todos os campos são character** — preserva zeros à esquerda em códigos IBGE, CNES, etc.

## Changelog

| Data | Descrição |
|------|-----------|
| {Sys.Date()} | Primeira carga |

## Licença

Dados abertos sob [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Fonte: Ministério da Saúde / DATASUS / SI-PNI.
')

  writeLines(readme, "README_HF.md")
  cat("README_HF.md gerado.\n\n")
}

# =============================================================================
# INSTRUÇÕES DE ESPELHO NO HUGGING FACE
# =============================================================================

instrucoes_hf <- function() {
  repo_id <- glue("{HF_USER}/{HF_DATASET}")

  cat("============================================================\n")
  cat("ESPELHAR NO HUGGING FACE (rodar no terminal da VPS)\n")
  cat("============================================================\n\n")

  cat(glue("
# 1. Criar dataset no HF
curl -X POST https://huggingface.co/api/repos/create \\
  -H 'Authorization: Bearer SEU_TOKEN_HF' \\
  -H 'Content-Type: application/json' \\
  -d '{{\"type\": \"dataset\", \"name\": \"{HF_DATASET}\"}}'

# 2. Clonar e configurar LFS
git clone https://huggingface.co/datasets/{repo_id}
cd {HF_DATASET}
git lfs install
git lfs track '*.parquet'
git add .gitattributes
git commit -m 'Configurar LFS'

# 3. Copiar README e Parquets
cp ../README_HF.md README.md
cp -r ../{DIR_PARQUET}/* .

# 4. Push
git add .
git commit -m 'Upload: microdados PNI vacinacao de rotina'
git push
"), "\n\n")

  cat(glue("Depois do push: https://huggingface.co/datasets/{repo_id}"), "\n")
}

# =============================================================================
# EXECUTAR
# =============================================================================

# Verificar que os Parquets existem
if (!dir_exists(DIR_PARQUET)) {
  stop("Diretório '", DIR_PARQUET, "' não encontrado. Rode 01_converter_parquet.R primeiro.")
}

arquivos <- dir_ls(DIR_PARQUET, recurse = TRUE, glob = "*.parquet")
tamanho <- sum(file_size(arquivos))
cat(glue("Parquets: {length(arquivos)} arquivos, {round(tamanho / 1e9, 2)} GB"), "\n\n")

# Escolha o método de upload:
upload_rclone()      # Recomendado para VPS
# upload_aws_s3()    # Alternativa em R puro

# Verificar
# verificar_r2()

# Gerar README para HF
gerar_readme_hf()

# Instruções para espelhar no HF
instrucoes_hf()

cat("\n✅ Upload concluído.\n")
cat(glue("Dados no R2: s3://{R2_BUCKET}/{R2_PREFIX}/"), "\n")
cat("🎯 Agora espelhe no Hugging Face seguindo as instruções acima.\n")
