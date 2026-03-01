
# =============================================================================
# GUIA RÁPIDO: Pipeline SI-PNI → Parquet → R2 → healthbR
# =============================================================================
#
# ARQUITETURA
# ===========
#
#   ┌──────────────────────────────────────────────────────────────────┐
#   │                                                                  │
#   │  VPS (Hetzner, €4/mês)                                          │
#   │    ├── Baixa CSVs do OpenDATASUS (mensalmente via cron)          │
#   │    ├── Converte para Parquet particionado (ano/mes/uf)           │
#   │    └── Sobe para R2 via rclone                                   │
#   │                                                                  │
#   │  Cloudflare R2 (armazenamento primário)                          │
#   │    └── Serve Parquets via protocolo S3 (egress gratuito)         │
#   │                                                                  │
#   │  Hugging Face (espelho / vitrine)                                │
#   │    └── Descobribilidade para pesquisadores                       │
#   │                                                                  │
#   │  healthbR (pacote R)                                             │
#   │    └── arrow::open_dataset("s3://...") direto do R2              │
#   │                                                                  │
#   │  GitHub (código-fonte)                                           │
#   │    └── Versiona os scripts. A VPS faz git pull e executa.        │
#   │                                                                  │
#   └──────────────────────────────────────────────────────────────────┘
#
# SCRIPTS
# =======
#
#   00_explorar_dados.R     ← Baixa amostra, confirma estrutura
#         ↓
#   01_converter_parquet.R  ← CSV → Parquet particionado (script principal)
#         ↓
#   02_upload_r2.R          ← Parquet → R2 + espelho HF
#
# =============================================================================
# PRÉ-REQUISITOS
# =============================================================================
#
# No R:
#   install.packages(c("arrow", "dplyr", "readr", "fs", "glue",
#                       "curl", "digest"))
#
# Na VPS (para upload):
#   - rclone instalado e configurado com endpoint R2
#   - git instalado (para pull do código)
#   - Conta Cloudflare com R2 + token de API
#
# Para o espelho HF:
#   - Conta no Hugging Face: https://huggingface.co/join
#   - Token de escrita: https://huggingface.co/settings/tokens
#   - git-lfs instalado
#
# =============================================================================
# SOBRE OS DADOS
# =============================================================================
#
# Fonte: OpenDATASUS / SI-PNI (Novo PNI integrado à RNDS)
# URL:   https://arquivosdadosabertos.saude.gov.br/dados/dbbni/
# Formato original: CSV comprimido (zip), ~1.3 GB/mês
#
# Características do CSV:
#   - SEM header (col_names = FALSE)
#   - Encoding: Latin-1
#   - Delimitador: ;
#   - 56 colunas (55 reais + 1 artefato do ; final)
#   - Todos os campos são VARCHAR no banco original
#
# Mapeamento das 55 colunas:
#   Validado contra o dicionário oficial (Dicionario_tb_ria_rotina.pdf)
#   e confirmado independentemente pelo arquivo JSON com campos nomeados.
#   Ver vetor NOMES_COLUNAS no script 01.
#
# Decisão sobre tipos:
#   TUDO character no Parquet. Códigos como IBGE, CNES, CEP têm
#   zeros à esquerda significativos. Converter para integer perderia
#   informação. Tipagem será refinada depois com inspeção local.
#
# =============================================================================
# PASSO A PASSO
# =============================================================================
#
# 1. Rode 00_explorar_dados.R
#    → Baixa 10.000 linhas de um mês
#    → Confirma que o mapeamento está correto
#    → Se alguma coluna não bater, PARE e investigue
#
# 2. Rode 01_converter_parquet.R
#    → Comece com ANOS <- 2024, MESES <- 1:2 (poucos meses)
#    → Download ~1.3 GB por mês, pode demorar
#    → Parquets ficam em parquet_pni/ano=YYYY/mes=MM/uf=XX/
#    → Controle de versão em controle_versao.csv
#    → Depois expanda: ANOS <- 2020:2025, MESES <- 1:12
#
# 3. Rode 02_upload_r2.R
#    → Sobe Parquets para R2 via rclone
#    → Gera README para espelho no Hugging Face
#    → Siga instruções na tela para o espelho HF
#
# 4. Teste o acesso remoto:
#    library(arrow)
#    ds <- open_dataset("s3://healthbr-data/sipni/")
#    ds |> filter(uf == "AC", ano == "2024") |> count(ds_vacina) |> collect()
#
# =============================================================================
# AUTOMAÇÃO NA VPS (futuro)
# =============================================================================
#
# Cron mensal (ex: dia 15 de cada mês às 3h):
#   0 3 15 * * cd /path/to/repo && git pull && Rscript 01_converter_parquet.R && Rscript 02_upload_r2.R
#
# O script 01 detecta hashes idênticos e pula meses já processados.
# Só processa dados novos.
#
# =============================================================================
# PROBLEMAS COMUNS
# =============================================================================
#
# "Timeout no download"
#   → Servidores do DATASUS são lentos. Tente novamente.
#   → Ou baixe manualmente e coloque em temp_csv/
#
# "56 colunas esperadas, N encontradas"
#   → O CSV pode ter mudado de estrutura. Compare com o JSON:
#     https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/
#
# "Encoding errado (caracteres estranhos)"
#   → Confirme que está usando locale(encoding = "Latin1")
#
# "Memória insuficiente"
#   → Arrow lê como Table (não data.frame) por padrão
#   → Se persistir, processe um mês por vez
#
# =============================================================================
