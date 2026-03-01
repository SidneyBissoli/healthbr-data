# Resumo: Pipeline de Microdados SI-PNI → Parquet → Cloudflare R2

## Objetivo

Baixar microdados de vacinação do SI-PNI (2020–2026) do S3 do Ministério da Saúde (OpenDATASUS), converter de JSON para Parquet particionado (ano/mes/uf), e armazenar no Cloudflare R2 para redistribuição via pacote R.

## Arquitetura Final

```
S3 do Ministério (JSON zips)
        ↓ download
VPS Hetzner (processamento temporário)
        ↓ jq (C) + polars (Rust) + Python orquestrador
        ↓ upload via rclone
Cloudflare R2 (armazenamento permanente)
        ↓ leitura via Arrow
Pesquisadores (pacote R sipni)
```

## Infraestrutura

### Cloudflare R2
- Bucket: `healthbr-data`
- Estrutura: `sipni/microdados/ano=YYYY/mes=MM/uf=XX/*.parquet`
- Endpoint: `https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com`
- Custo: ~$0.015/GB/mês, zero egress
- Token: criado em R2 → Manage R2 API Tokens → scope específico ao bucket

### Hetzner VPS (bootstrap)
- Plano para bootstrap pesado: CPX42 (8 vCPU, 16 GB RAM, x86 AMD) — $21.99/mês
- Plano para manutenção mensal: CX22 ($3.99/mês) ou nenhum (criar/destruir sob demanda)
- Location: Nuremberg, Alemanha
- Image: Ubuntu 24.04
- Acesso: SSH com chave ed25519 (gerada via `ssh-keygen -t ed25519`)

### Conexão Hetzner ↔ R2
- rclone configurado com remote `r2` tipo S3/Cloudflare
- Configuração rápida: `rclone config create r2 s3 provider Cloudflare access_key_id XXX secret_access_key YYY endpoint https://...`
- Teste: `rclone lsd r2:healthbr-data`

## Evolução do Pipeline (lições aprendidas)

### Versão 1: R no PC local
- **Problema:** R single-threaded, `jsonlite::fromJSON()` lento, parsing de 800MB JSON levava ~4 min por parte
- **Problema:** `unzip()` do R extremamente lento no Windows para arquivos grandes
- **Problema:** OneDrive travava deleção de arquivos temporários (EPERM) → solução: DIR_TEMP fora do OneDrive (`%TEMP%/sipni_pipeline`)
- **Problema:** Espaços no caminho do Windows quebravam `system2("rclone", ...)` → solução: `shQuote()`
- **Problema:** RStudio consumia ~500MB RAM só existindo → solução: rodar via `Rscript` no terminal
- **Velocidade:** ~53 min/mês

### Versão 2: R no Hetzner (ARM)
- Servidor ARM (CAX21, 8GB) escolhido por custo
- **Problema:** Arrow C++ não tem binário pré-compilado para ARM, compilação demorou >30 min e falhou várias vezes
- **Solução:** Instalar libarrow-dev + libparquet-dev + libarrow-dataset-dev + libarrow-acero-dev via apt, depois `ARROW_USE_PKG_CONFIG=true` para o pacote R detectar
- **Velocidade:** ~42 min/mês (gargalo era parsing JSON no R, não rede)

### Versão 3: Python no Hetzner (x86) — VERSÃO FINAL
- Servidor x86 (CPX42, 16GB) para ter binários pré-compilados
- **Stack:** jq (C) para parsing JSON + polars (Rust) para DataFrame/Parquet + Python para orquestração
- **Problema:** `jq -c '.[]'` carrega JSON inteiro em memória (~4GB por arquivo de 800MB). Com múltiplos workers, estoura RAM
- **Solução:** `jq -cn --stream 'fromstream(1|truncate_stream(inputs))'` usa memória constante
- **Problema:** polars infere tipo NULL para colunas vazias no início → `got non-null value for NULL-typed column`
- **Solução:** Função `read_ndjson_safe()` que lê a primeira linha, extrai schema, e força tudo como Utf8
- **Velocidade:** ~12 min/mês (4.4x mais rápido que R local)

## Descoberta Crítica: Múltiplas Partes por ZIP

Os ZIPs do Ministério contêm **múltiplos JSONs** paginados em partes de ~400K registros:
- `vacinacao_jan_2021_00001.json` (800MB, 400K registros)
- `vacinacao_jan_2021_00002.json` (800MB, 400K registros)
- ...
- `vacinacao_jan_2021_00017.json` (589MB, ~360K registros)

Um mês pode ter 1 parte (2025+, arquivo único grande) ou 30+ partes (pico COVID 2022). O primeiro pipeline R pegava apenas `list.files(...)[1]`, resultando em dados com apenas 400K registros por mês em vez de milhões. **Sempre listar TODOS os arquivos dentro do zip.**

Para verificar: `unzip(zip_path, list = TRUE)` em R ou `zipfile.ZipFile(path).namelist()` em Python.

## Padrões de URL do Ministério

Dois padrões coexistem no S3:
```
https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{mes}_{ano}.json.zip
https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{mes}_{ano}_json.zip
```
O script tenta ambos via HEAD request. O S3 retorna 403 (não 404) para URLs inexistentes.

## Lógica de Sincronização

1. HEAD request em cada mês → obtém ETag + Content-Length
2. Compara com controle CSV local
3. Classifica: novo, atualizado, inalterado, indisponível
4. Processa apenas novos/atualizados
5. Controle CSV persiste entre execuções → retoma de onde parou

## Controle de Versão (CSV)

Colunas: `arquivo, etag_servidor, content_length, hash_md5_zip, n_registros, n_partes_json, data_processamento, ano, mes, url_origem`

## Gerenciamento de Disco

Nenhum arquivo permanece localmente após processamento:
1. Baixa zip → temp
2. Extrai uma parte → temp
3. Processa → Parquet em staging
4. Upload staging → R2
5. Deleta tudo local

Pico de disco: ~4GB (zip + 1 JSON extraído). Se crashar, zip sobrevive como cache e é reaproveitado.

## Comandos Essenciais

### Setup do servidor (tudo de uma vez)
```bash
apt update && apt install -y r-base r-base-dev libcurl4-openssl-dev libssl-dev libxml2-dev jq python3-pip && curl https://rclone.org/install.sh | bash && pip3 install polars --break-system-packages && apt install -y -V ca-certificates lsb-release wget && wget https://apache.jfrog.io/artifactory/arrow/$(lsb_release --id --short | tr 'A-Z' 'a-z')/apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb && apt install -y ./apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb && apt update && apt install -y libarrow-dev libparquet-dev libarrow-dataset-dev libarrow-acero-dev && Rscript -e "install.packages(c('pacman','here','arrow','dplyr','readr','jsonlite','fs','glue','curl','digest'), repos='https://cloud.r-project.org')" && echo "=== TUDO INSTALADO ==="
```

### Configurar rclone
```bash
rclone config create r2 s3 provider Cloudflare access_key_id XXX secret_access_key YYY endpoint https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com
```

### Rodar pipeline
```bash
nohup python3 -u /root/pipeline_rapido.py > /root/pipeline.log 2>&1 &
tail -f /root/pipeline.log
```

### Monitorar
```bash
tail -30 /root/pipeline.log
grep "✓" /root/pipeline.log
cat /root/data/controle_versao_microdata.csv
```

### Enviar arquivos do PC para servidor
```powershell
scp "caminho\local\arquivo" root@IP:/root/
```

## Decisões Estratégicas

1. **JSON em vez de CSV:** CSVs de 2020-2024 têm artefatos de exportação (floats com `.0`, zeros à esquerda perdidos). JSON preserva dados originais.
2. **Bucket único `healthbr-data`:** Prefixos para cada sistema (sipni/, sim/, sinasc/, sih/). Um token, uma config rclone, Arrow navega transparentemente.
3. **Publicar dados exatamente como o governo fornece:** Sem decodificar campos — dicionários separados. Pesquisadores podem rastrear até a fonte original.
4. **Servidor temporário:** Bootstrap pesado em servidor potente, depois destroi. Manutenção mensal em servidor mínimo ou sob demanda.
5. **Python para pipeline, R para pacote:** Pipeline de produção usa Python+jq+polars (velocidade). Pacote de consumo será em R (público-alvo).

## Números de Referência (SI-PNI)

- Série: jan/2020 – fev/2026 (~73 meses)
- Meses de pico COVID (2021-2022): ~17-34 partes por zip, 6-12M registros/mês
- Meses normais (2020, 2023-2024): ~15-27 partes, 5-11M registros/mês
- Meses de 2025+: arquivo único grande (até 29GB descomprimido), 10-30M registros/mês
- Total estimado: ~500M+ registros
- Parquet no R2: ~50-100 GB estimado

## Armadilhas a Evitar no SIH

1. **Nunca pegar só o primeiro arquivo do zip** — sempre listar tudo
2. **Não usar ARM no Hetzner** — x86 tem binários pré-compilados, economia de horas
3. **DIR_TEMP fora do OneDrive** se testar localmente no Windows
4. **jq --stream** em vez de `jq -c '.[]'` para arquivos que cabem na RAM × workers
5. **Forçar schema Utf8** no polars — `read_ndjson_safe()` evita erros de tipo NULL
6. **`python3 -u`** para output unbuffered no nohup
7. **Testar HEAD requests** com followlocation=TRUE e retry — S3 do governo redireciona
8. **SSH key:** se recriar servidor com mesmo IP, rodar `ssh-keygen -R IP` antes de reconectar
