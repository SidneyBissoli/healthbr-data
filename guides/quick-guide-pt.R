
# =============================================================================
# GUIA RÁPIDO: Pipeline SI-PNI → Parquet → R2 → sipni
# =============================================================================
#
# v02 — 2026-02-24
# Atualizado para refletir: JSON como fonte primária, pipeline Python
# (jq + polars), escopo expandido 1994-2025+, sincronização via HEAD requests.
#
# ARQUITETURA
# ===========
#
#   ┌──────────────────────────────────────────────────────────────────┐
#   │                                                                  │
#   │  VPS (Hetzner)                                                   │
#   │    ├── Bootstrap: CPX42 (8 vCPU, 16 GB RAM, x86) — $21.99/mês  │
#   │    ├── Manutenção: CX22 ($3.99/mês) ou sob demanda             │
#   │    ├── Baixa JSONs do OpenDATASUS (sincronização via HEAD)      │
#   │    ├── jq (C) + polars (Rust) + Python orquestrador            │
#   │    ├── Converte para Parquet particionado (ano/mes/uf)          │
#   │    └── Sobe para R2 via rclone                                  │
#   │                                                                  │
#   │  Cloudflare R2 (armazenamento primário)                         │
#   │    ├── Bucket: healthbr-data                                    │
#   │    ├── Prefixo: sipni/microdados/ano=YYYY/mes=MM/uf=XX/        │
#   │    ├── Egress gratuito                                          │
#   │    └── Serve Parquets via protocolo S3                          │
#   │                                                                  │
#   │  Hugging Face (espelho para descobribilidade)                   │
#   │    └── README aponta para R2 como fonte primária                │
#   │                                                                  │
#   │  sipni (pacote R)                                               │
#   │    └── arrow::open_dataset() direto do R2                       │
#   │    └── Harmoniza vacinas, calcula cobertura, séries temporais   │
#   │                                                                  │
#   │  GitHub (código-fonte)                                          │
#   │    └── Versiona pipeline + pacote (repos separados)             │
#   │                                                                  │
#   └──────────────────────────────────────────────────────────────────┘
#
# PIPELINE DE PRODUÇÃO
# ====================
#
#   pipeline_rapido.py — Script único, orquestra tudo:
#     1. HEAD requests em todos os meses (2020 até atual)
#     2. Compara ETag + Content-Length com controle local
#     3. Classifica cada mês: novo / atualizado / inalterado / indisponível
#     4. Baixa e processa apenas novos/atualizados
#     5. jq: JSON array → JSONL (~2s por parte de 800MB)
#     6. polars: JSONL → Parquet particionado (multi-threaded)
#     7. rclone: upload para R2
#     8. Atualiza controle CSV
#
# =============================================================================
# PRÉ-REQUISITOS
# =============================================================================
#
# Na VPS (pipeline de produção):
#   apt install -y jq python3-pip
#   pip3 install polars --break-system-packages
#   curl https://rclone.org/install.sh | bash
#   rclone config create r2 s3 provider Cloudflare \
#     access_key_id XXX secret_access_key YYY \
#     endpoint https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com
#
# No R (consumo dos dados):
#   install.packages(c("arrow", "dplyr"))
#
# =============================================================================
# SOBRE OS DADOS
# =============================================================================
#
# ESCOPO COMPLETO DO PROJETO
# --------------------------
# O projeto integra três fontes numa série histórica contínua 1994-2025+:
#   1. Dados agregados históricos (1994-2019) — .dbf do FTP DATASUS
#   2. Microdados individuais (2020-2025+) — JSON do OpenDATASUS
#   3. Denominadores populacionais — SINASC (nascidos vivos) + IBGE
#
# MICRODADOS (2020-2025+)
# -----------------------
# Fonte primária: JSON (não CSV)
# URLs:
#   2020-2024: https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{mes}_{ano}.json.zip
#   2025+:     https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{mes}_{ano}_json.zip
#   ATENÇÃO: padrão de URL mudou em 2025. O pipeline testa ambos.
#
# Por que JSON e não CSV?
#   Os CSVs de 2020-2024 têm artefatos de exportação:
#     - Campos numéricos serializados como float (ex: 420750.0 em vez de 420750)
#     - Zeros à esquerda perdidos em códigos (raça/cor: "3" em vez de "03")
#   O JSON preserva todos os valores como strings com zeros intactos.
#   O CSV de 2025 foi corrigido, mas o JSON é preferido por consistência.
#
# Características do JSON:
#   - Encoding: UTF-8
#   - Estrutura: array JSON em linha única (pode exceder 2GB descomprimido)
#   - 56 colunas reais (campos nomeados)
#   - Todos os campos como string (zeros à esquerda preservados)
#   - Header implícito (nomes dos campos nos objetos JSON)
#   - ~1.8 GB/mês comprimido (zip)
#
# Características do CSV (fonte alternativa/fallback):
#   - Encoding: Latin-1
#   - COM header (col_names = TRUE)
#   - Delimitador: ;
#   - 56 colunas reais (+ 1 artefato vazio do ; final ao parsear)
#   - Artefatos de float nos anos 2020-2024 (corrigido em 2025)
#   - ~1.3 GB/mês comprimido (zip)
#
# Decisão sobre tipos:
#   TUDO character no Parquet. Códigos como IBGE, CNES, CEP têm
#   zeros à esquerda significativos. Tipagem forte (Date, integer)
#   será feita no pacote R sipni, não nos dados publicados.
#
# Dicionário oficial: Dicionario_tb_ria_rotina.pdf (60 campos, 56 nos dados)
# Typo oficial: coluna 17 = "no_fantasia_estalecimento" (sem "b")
# Campos ausentes: st_vida_paciente, dt_entrada_datalake,
#   co_identificador_sistema, ds_identificador_sistema
#
# DADOS AGREGADOS (1994-2019)
# ---------------------------
# Origem: ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/
# Formato: .dbf (dBase III), 1504 arquivos (752 cobertura + 752 doses)
# ATENÇÃO: cobertura e doses usam sistemas de códigos IMUNO diferentes
#   - Doses (DPNI) → IMUNO.CNV (85 vacinas individuais)
#   - Cobertura (CPNI) → IMUNOCOB.DBF (26 indicadores compostos)
#
# =============================================================================
# PASSO A PASSO
# =============================================================================
#
# 1. Rodar o pipeline na VPS:
#    nohup python3 -u /root/pipeline_rapido.py > /root/pipeline.log 2>&1 &
#    tail -f /root/pipeline.log
#
# 2. Monitorar:
#    tail -30 /root/pipeline.log
#    grep "✓" /root/pipeline.log
#    cat /root/data/controle_versao_microdata.csv
#
# 3. Testar acesso remoto (R):
#    library(arrow)
#    ds <- open_dataset("s3://healthbr-data/sipni/microdados/")
#    ds |>
#      filter(ano == "2024", mes == "01", uf == "AC") |>
#      count(ds_vacina) |>
#      collect()
#
# =============================================================================
# SINCRONIZAÇÃO INTELIGENTE
# =============================================================================
#
# O pipeline NÃO usa janelas arbitrárias (ex: "rebaixa os últimos 6 meses").
#
# Em vez disso:
#   1. Faz HEAD request no S3 do Ministério para TODOS os meses (2020–atual)
#   2. Compara ETag + Content-Length com controle CSV local
#   3. Classifica: novo, atualizado, inalterado, indisponível
#   4. Só baixa/reprocessa o necessário
#
# HEAD requests são praticamente gratuitos (~73 requests em poucos segundos).
# Controle persiste entre execuções → retoma de onde parou.
#
# =============================================================================
# ESTRUTURA NO R2
# =============================================================================
#
#   s3://healthbr-data/sipni/
#     microdados/                        ← Novo SI-PNI (2020-2025+)
#       ano=2024/mes=01/uf=AC/
#         part-00001.parquet
#     agregados/                         ← Antigo SI-PNI (1994-2019)
#       doses/
#         ano=1998/uf=AC/part-0.parquet
#       cobertura/
#         ano=2005/uf=SP/part-0.parquet
#     populacao/                         ← Denominadores
#       sinasc/                          ← Nascidos vivos por município
#       ibge/                            ← Estimativas populacionais
#     dicionarios/                       ← Referência (originais do MS)
#
# =============================================================================
# AUTOMAÇÃO NA VPS
# =============================================================================
#
# Cron mensal (ex: dia 15 de cada mês às 3h):
#   0 3 15 * * python3 -u /root/pipeline_rapido.py >> /root/pipeline.log 2>&1
#
# O pipeline detecta automaticamente meses novos/atualizados via HEAD.
# Só processa dados novos.
#
# Para manutenção: servidor CX22 ($3.99/mês) ou criar/destruir sob demanda.
#
# =============================================================================
# NÚMEROS DE REFERÊNCIA
# =============================================================================
#
# Série: jan/2020 – fev/2026 (~73 meses)
# Meses de pico COVID (2021-2022): 17-34 partes por zip, 6-12M reg/mês
# Meses normais (2020, 2023-2024): 15-27 partes, 5-11M reg/mês
# Meses de 2025+: arquivo único grande (até 29GB descomprimido)
# Total estimado: ~500M+ registros
# Velocidade do pipeline: ~12 min/mês (4.4x mais rápido que versão R)
#
# =============================================================================
# PROBLEMAS COMUNS
# =============================================================================
#
# "jq não encontrado"
#   → apt install -y jq
#
# "polars: got non-null value for NULL-typed column"
#   → Forçar schema Utf8 no polars (read_ndjson com schema explícito)
#
# "Disco cheio"
#   → O pipeline mantém pico de ~4GB (zip + 1 JSON extraído)
#   → Verificar se staging foi limpo após upload
#   → Nenhum arquivo deve permanecer após processamento completo
#
# "rclone: access denied"
#   → Verificar token R2: rclone lsd r2:healthbr-data
#   → Token precisa de scope específico ao bucket
#
# "HEAD request retorna 403"
#   → Normal: S3 do governo retorna 403 (não 404) para URLs inexistentes
#   → O pipeline já trata isso como "indisponível"
#
# "SSH: host key verification failed"
#   → Se recriou servidor com mesmo IP: ssh-keygen -R IP
#
# "Memória estourada com múltiplos workers"
#   → Para arquivos grandes (>1.5GB): pipeline usa jq --stream automaticamente
#   → jq --stream usa memória constante (~600MB) independente do tamanho
#
# =============================================================================
# DECISÕES ESTRATÉGICAS
# =============================================================================
#
# 1. JSON em vez de CSV: CSV 2020-2024 tem artefatos. JSON preserva tudo.
# 2. Bucket único healthbr-data: prefixos para cada sistema (sipni/, sim/, etc.)
# 3. Dados exatamente como o governo fornece: sem decodificar. Dicionários à parte.
# 4. Servidor temporário: bootstrap pesado, depois destrói. Manutenção sob demanda.
# 5. Python para pipeline, R para pacote: velocidade na produção, público-alvo no consumo.
# 6. Tudo character no Parquet: fidelidade à fonte, tipagem no pacote.
# 7. Município normalizado em 6 dígitos: padrão IBGE (sem verificador).
#
# =============================================================================
