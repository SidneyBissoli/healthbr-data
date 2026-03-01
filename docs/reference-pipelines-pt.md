# Referência de Pipelines — healthbr-data

> Manual de operação dos pipelines de produção do projeto healthbr-data.
> Cada pipeline tem sua própria seção com arquitetura, números, comandos
> e particularidades. Novos pipelines devem ser documentados aqui ao
> final da Fase 4 (ver `strategy-expansion-pt.md`).
>
> Criado em 26/fev/2026, a partir do conteúdo operacional do
> `log/status-03.md`.

---

## 1. INFRAESTRUTURA COMPARTILHADA

Todos os pipelines usam a mesma infraestrutura base.

### Cloudflare R2

- Bucket: `healthbr-data`
- Endpoint: `https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com`
- Custo: ~$0.015/GB/mês, zero egress
- Token: criado em R2 → Manage R2 API Tokens → scope específico ao bucket
- Prefixos por sistema: `sipni/`, `sipni/covid/`, `sim/`, `sinasc/`, `sih/`

### Hetzner VPS

- Bootstrap pesado: CPX42 (8 vCPU, 16 GB RAM, x86 AMD) — $21.99/mês
- Manutenção mensal: CX22 ($3.99/mês) ou criar/destruir sob demanda (~$0.50)
- Location: Nuremberg, Alemanha
- Image: Ubuntu 24.04
- Acesso: SSH com chave ed25519 (`ssh-keygen -t ed25519`)
- **Sempre x86, nunca ARM** — binários pré-compilados para Arrow, polars, etc.

### Conexão Hetzner ↔ R2

- rclone configurado com remote `r2` tipo S3/Cloudflare
- Configuração: `rclone config create r2 s3 provider Cloudflare access_key_id XXX secret_access_key YYY endpoint https://...`
- Teste: `rclone lsd r2:healthbr-data`

---

## 2. COMANDOS ESSENCIAIS

### Setup do servidor (tudo de uma vez)

```bash
apt update && apt install -y r-base r-base-dev libcurl4-openssl-dev libssl-dev libxml2-dev jq python3-pip && curl https://rclone.org/install.sh | bash && pip3 install polars --break-system-packages && apt install -y -V ca-certificates lsb-release wget && wget https://apache.jfrog.io/artifactory/arrow/$(lsb_release --id --short | tr 'A-Z' 'a-z')/apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb && apt install -y ./apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb && apt update && apt install -y libarrow-dev libparquet-dev libarrow-dataset-dev libarrow-acero-dev && Rscript -e "install.packages(c('pacman','here','arrow','dplyr','readr','jsonlite','fs','glue','curl','digest'), repos='https://cloud.r-project.org')" && echo "=== TUDO INSTALADO ==="
```

### Configurar rclone

```bash
rclone config create r2 s3 provider Cloudflare access_key_id XXX secret_access_key YYY endpoint https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com
```

### Enviar arquivos do PC para servidor

```powershell
scp "caminho\local\arquivo" root@IP:/root/
```

### Se recriar servidor com mesmo IP

```powershell
ssh-keygen -R IP
```

---

## 3. PIPELINE SI-PNI (ROTINA): JSON → Parquet → R2

### Objetivo

Baixar microdados de vacinação do SI-PNI (2020–2026) do S3 do Ministério
da Saúde (OpenDATASUS), converter de JSON para Parquet particionado
(ano/mes/uf), e armazenar no Cloudflare R2 para redistribuição.

### Arquitetura

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

### Números finais

| Métrica | Valor |
|---------|-------|
| Série | jan/2020 – fev/2026 (73 meses) |
| Total de registros | **736.069.544** |
| Tempo de bootstrap | **21,7 horas** (1.303,5 minutos) |
| Taxa | ~33,9M registros/hora |
| Dados fonte | ~130 GB (JSON zips) |
| Estrutura no R2 | `sipni/microdados/ano=YYYY/mes=MM/uf=XX/*.parquet` |
| Script | `scripts/pipeline/sipni-pipeline-python.py` |
| Controle | `data/controle_versao_microdata.csv` |

### Evolução do pipeline (lições aprendidas)

#### Versão 1: R no PC local

- **Problema:** R single-threaded, `jsonlite::fromJSON()` lento, parsing de 800MB JSON levava ~4 min por parte
- **Problema:** `unzip()` do R extremamente lento no Windows para arquivos grandes
- **Problema:** OneDrive travava deleção de arquivos temporários (EPERM) → solução: DIR_TEMP fora do OneDrive (`%TEMP%/sipni_pipeline`)
- **Problema:** Espaços no caminho do Windows quebravam `system2("rclone", ...)` → solução: `shQuote()`
- **Problema:** RStudio consumia ~500MB RAM só existindo → solução: rodar via `Rscript` no terminal
- **Velocidade:** ~53 min/mês

#### Versão 2: R no Hetzner (ARM)

- Servidor ARM (CAX21, 8GB) escolhido por custo
- **Problema:** Arrow C++ não tem binário pré-compilado para ARM, compilação demorou >30 min e falhou várias vezes
- **Solução:** Instalar libarrow-dev + libparquet-dev + libarrow-dataset-dev + libarrow-acero-dev via apt, depois `ARROW_USE_PKG_CONFIG=true` para o pacote R detectar
- **Velocidade:** ~42 min/mês (gargalo era parsing JSON no R, não rede)

#### Versão 3: Python no Hetzner (x86) — VERSÃO FINAL

- Servidor x86 (CPX42, 16GB) para ter binários pré-compilados
- **Stack:** jq (C) para parsing JSON + polars (Rust) para DataFrame/Parquet + Python para orquestração
- **Problema:** `jq -c '.[]'` carrega JSON inteiro em memória (~4GB por arquivo de 800MB). Com múltiplos workers, estoura RAM
- **Solução:** `jq -cn --stream 'fromstream(1|truncate_stream(inputs))'` usa memória constante
- **Problema:** polars infere tipo NULL para colunas vazias no início → `got non-null value for NULL-typed column`
- **Solução:** Função `read_ndjson_safe()` que lê a primeira linha, extrai schema, e força tudo como Utf8
- **Velocidade:** ~12 min/mês (4.4x mais rápido que R local)

### Descoberta crítica: múltiplas partes por ZIP

Os ZIPs do Ministério contêm **múltiplos JSONs** paginados em partes de ~400K registros:

- `vacinacao_jan_2021_00001.json` (800MB, 400K registros)
- `vacinacao_jan_2021_00002.json` (800MB, 400K registros)
- ...
- `vacinacao_jan_2021_00017.json` (589MB, ~360K registros)

Um mês pode ter 1 parte (2025+, arquivo único grande) ou 30+ partes (pico COVID 2022). O primeiro pipeline R pegava apenas `list.files(...)[1]`, resultando em dados com apenas 400K registros por mês em vez de milhões. **Sempre listar TODOS os arquivos dentro do zip.**

Para verificar: `unzip(zip_path, list = TRUE)` em R ou `zipfile.ZipFile(path).namelist()` em Python.

### Padrões de URL do Ministério

Dois padrões coexistem no S3:

```
https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{mes}_{ano}.json.zip
https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{mes}_{ano}_json.zip
```

O script tenta ambos via HEAD request. O S3 retorna 403 (não 404) para URLs inexistentes.

### Lógica de sincronização

1. HEAD request em cada mês → obtém ETag + Content-Length
2. Compara com controle CSV local
3. Classifica: novo, atualizado, inalterado, indisponível
4. Processa apenas novos/atualizados
5. Controle CSV persiste entre execuções → retoma de onde parou

### Controle de versão (CSV)

Colunas: `arquivo, etag_servidor, content_length, hash_md5_zip, n_registros, n_partes_json, data_processamento, ano, mes, url_origem`

### Gerenciamento de disco

Nenhum arquivo permanece localmente após processamento:

1. Baixa zip → temp
2. Extrai uma parte → temp
3. Processa → Parquet em staging
4. Upload staging → R2
5. Deleta tudo local

Pico de disco: ~4GB (zip + 1 JSON extraído). Se crashar, zip sobrevive como cache e é reaproveitado.

### Rodar e monitorar

```bash
# Rodar
nohup python3 -u /root/pipeline_rapido.py > /root/pipeline.log 2>&1 &

# Monitorar
tail -f /root/pipeline.log
tail -30 /root/pipeline.log
grep "✓" /root/pipeline.log
cat /root/data/controle_versao_microdata.csv
```

---

## 4. PIPELINE SI-PNI COVID: CSV → Parquet → R2

### Objetivo

Baixar microdados de vacinação COVID-19 do OpenDATASUS (CSVs por UF no S3),
converter para Parquet particionado (ano/mes/uf), e armazenar no Cloudflare R2.

### Arquitetura

```
S3 do Ministério (CSVs por UF, descompactados)
        ↓ download direto
VPS Hetzner (processamento temporário)
        ↓ polars (Rust) + Python orquestrador
        ↓ upload via rclone
Cloudflare R2 (armazenamento permanente)
        ↓ leitura via Arrow
Pesquisadores (pacote R sipni)
```

### Números finais

| Métrica | Valor |
|---------|-------|
| Unidades | 27 UFs × 5 partes = 135 arquivos CSV |
| Total de registros | **608.311.394** |
| Dados fonte | **291,8 GB** (CSV bruto, descompactado) |
| Tempo de bootstrap | **7,8 horas** (467,2 minutos) |
| Taxa | ~78,0M registros/hora |
| Estrutura no R2 | `sipni/covid/microdados/ano=YYYY/mes=MM/uf=XX/*.parquet` (+ `ano=_invalid/` para datas fora de 2021–presente) |
| Script | `scripts/pipeline/sipni-covid-pipeline.py` |
| Controle | `data/controle_versao_covid.csv` |

### Diferenças em relação ao pipeline de rotina

| Aspecto | Rotina (SI-PNI) | COVID |
|---------|-----------------|-------|
| Formato fonte | JSON array em ZIP | CSV direto (sem compactação) |
| Organização fonte | Por mês (1 ZIP = todos os estados) | Por UF (5 CSVs = todos os meses) |
| Ferramenta de parsing | jq (C) → JSONL → polars | polars direto (`read_csv`) |
| Colunas | 56 | 32 |
| Dependência de jq | Sim | Não |
| Etapa de descompactação | Sim (ZIP) | Não |

### Por que o COVID foi 2,3x mais rápido (registros/hora)

A diferença de performance não é qualidade de código — ambos os pipelines
são bem estruturados. Os fatores, em ordem de impacto:

1. **CSV vs JSON.** polars lê CSV direto em Rust puro, multi-threaded, sem
   intermediários. O JSON exige jq (processo externo em C) para converter
   JSON array → JSONL antes do polars conseguir ler.

2. **Sem descompactação.** Os CSVs COVID estão soltos no S3. O pipeline de
   rotina precisa baixar ZIP, descompactar (~800MB por parte), e só então
   processar.

3. **Menos colunas.** 32 vs 56 campos por registro — menos I/O e parsing.

4. **Sem overhead de paralelismo.** O pipeline de rotina usa
   ProcessPoolExecutor com 3 workers (serialização entre processos,
   contenção de I/O no ZIP). O COVID processa sequencialmente, mas cada
   operação individual é tão rápida que a simplicidade ganha.

### Rodar e monitorar

```bash
# Rodar
nohup python3 -u /root/pipeline_covid.py > /root/pipeline_covid.log 2>&1 &

# Monitorar
tail -f /root/pipeline_covid.log
cat /root/data/controle_versao_covid.csv
```

---

## 5. PIPELINE SI-PNI AGREGADOS DOSES: DBF → Parquet → R2

### Objetivo

Baixar dados agregados de doses aplicadas do antigo SI-PNI (1994–2019)
do FTP do DATASUS (arquivos .dbf), converter para Parquet particionado
(ano/uf), e armazenar no Cloudflare R2 para redistribuição.

### Arquitetura

```
FTP do DATASUS (arquivos .dbf por UF e ano)
        ↓ download via curl
VPS Hetzner (processamento temporário)
        ↓ R: foreign::read.dbf + arrow::write_parquet
        ↓ upload via rclone
Cloudflare R2 (armazenamento permanente)
        ↓ leitura via Arrow
Pesquisadores (pacote R sipni)
```

### Números finais

| Métrica | Valor |
|---------|-------|
| Série | 1994–2019 (26 anos) |
| Arquivos processados | **674** (de 702 possíveis: 27 UFs × 26 anos) |
| Arquivos indisponíveis | 12 (UFs ausentes em 1994–1996) |
| Arquivos vazios | 16 (.dbf esqueleto retornado pelo FTP) |
| Total de registros | **84.022.233** |
| Tempo de bootstrap | **4h40 (279,9 minutos)** |
| Taxa | ~300K registros/hora |
| Dados fonte | ~1,5 GB (.dbf via FTP) |
| Estrutura no R2 | `sipni/agregados/doses/ano=YYYY/uf=XX/part-0.parquet` |
| Script | `scripts/pipeline/sipni-agregados-doses-pipeline-r.R` |
| Controle | `data/controle_versao_sipni_agregados_doses.csv` |

### Diferenças em relação aos pipelines de microdados

| Aspecto | Microdados (rotina/COVID) | Agregados doses |
|---------|--------------------------|------------------|
| Linguagem do pipeline | Python (jq + polars) | **R puro** (foreign + arrow) |
| Formato fonte | JSON/CSV (centenas de MB por arquivo) | .dbf (KB a poucos MB por arquivo) |
| Protocolo de download | HTTPS (S3) | **FTP** |
| Número de colunas | 56 (rotina) / 32 (COVID) | 7 ou 12 (conforme era) |
| Schemas | Único | **Múltiplos** (7 cols na Era 1, 12 cols na Era 2–3) |
| Particionamento | ano/mes/uf | **ano/uf** (sem mês: Era 1 não tem) |
| Gargalo de performance | Parsing (JSON) / I/O (CSV) | **Download FTP** |

### Por que R e não Python

Os arquivos .dbf dos agregados são pequenos individualmente (KB a poucos
MB). O gargalo é o download sequencial do FTP do DATASUS, não o parsing
ou conversão. Nesse contexto, a simplicidade de um pipeline R puro
(`foreign::read.dbf` + `arrow::write_parquet`) supera a vantagem de
performance do Python+polars. A decisão é reversível se necessário.

### Schemas por era

Os dados são publicados com o schema original de cada era, sem fabricar
colunas inexistentes:

- **Era 1 (1994–2003):** 7 colunas — ANO, UF, MUNIC, FX_ETARIA, IMUNO, DOSE, QT_DOSE
- **Era 2–3 (2004–2019):** 12 colunas — + ANOMES, MES, DOSE1, DOSEN, DIFER

`open_dataset(unify_schemas = TRUE)` do Arrow preenche automaticamente
com `null` as colunas ausentes da Era 1. A harmonização fica no pacote R.

### Consolidados excluídos

Os arquivos consolidados (DPNIUF, DPNIBR, DPNIIG) foram excluídos do
pipeline após validação:

- **DPNIIG:** não existe no FTP (status 550)
- **DPNIBR:** redundante — validado com diferença zero contra soma dos
  27 estaduais (DPNIBR98: 976.481 linhas = soma dos estaduais de 1998)
- **DPNIUF:** schema diferente (6 cols, sem MUNIC) e redundante
  (agregação trivial dos dados municipais)

Racional completo em `docs/sipni-agregados/exploration-pt.md`, decisão 9.9.

### Comportamento do FTP do DATASUS

Duas descobertas operacionais:

1. **UFs ausentes não retornam erro.** O FTP entrega um .dbf válido mas
   vazio (0 linhas, ~257 bytes de header). Pipeline detecta por
   `nrow(df) == 0`.

2. **`ftp_response_timeout` não existe no libcurl 8.5 do Ubuntu 24.**
   A opção causava erro silencioso (é engolido pelo tryCatch), fazendo
   todos os downloads falharem. Removida do handle.

### Lógica de sincronização

1. Para cada combinação ano × UF, verifica controle CSV
2. Se já processado → pula
3. Se não → baixa .dbf, lê, converte para character, grava Parquet
4. Upload por lote anual (27 UFs de cada vez)
5. Checkpoint no controle CSV após cada ano → retomável

### Controle de versão (CSV)

Colunas: `arquivo, ano, uf, n_registros, n_colunas, hash_md5,
tamanho_bytes, data_processamento`

### Rodar e monitorar

```bash
# Rodar
nohup Rscript /root/sipni-agregados-doses-pipeline-r.R > /root/pipeline_agregados.log 2>&1 &

# Monitorar
tail -f /root/pipeline_agregados.log
grep "^ANO " /root/pipeline_agregados.log
grep -i "erro" /root/pipeline_agregados.log
cat /root/data/controle_versao_sipni_agregados_doses.csv
```

---

## 6. PIPELINE SI-PNI AGREGADOS COBERTURA: DBF → Parquet → R2

### Objetivo

Baixar dados agregados de cobertura vacinal do antigo SI-PNI (1994–2019)
do FTP do DATASUS (arquivos .dbf), converter para Parquet particionado
(ano/uf), e armazenar no Cloudflare R2 para redistribuição. Adaptado
diretamente do pipeline de doses (seção 5).

### Arquitetura

```
FTP do DATASUS (arquivos .dbf por UF e ano)
        ↓ download via curl
VPS Hetzner (processamento temporário)
        ↓ R: foreign::read.dbf + arrow::write_parquet
        ↓ upload via rclone
Cloudflare R2 (armazenamento permanente)
        ↓ leitura via Arrow
Pesquisadores (pacote R sipni)
```

### Números finais

| Métrica | Valor |
|---------|-------|
| Série | 1994–2019 (26 anos) |
| Arquivos processados | **686** (de 702 possíveis: 27 UFs × 26 anos) |
| Arquivos vazios | 16 (UFs ausentes em 1994–1996) |
| Total de registros | **2.762.327** |
| Tempo de bootstrap | **44 minutos** |
| Taxa | ~3,8M registros/hora |
| Dados fonte | ~50 MB (.dbf via FTP) |
| Estrutura no R2 | `sipni/agregados/cobertura/ano=YYYY/uf=XX/part-0.parquet` |
| Script | `scripts/pipeline/sipni-agregados-cobertura-pipeline-r.R` |
| Controle | `data/controle_versao_sipni_agregados_cobertura.csv` |

### Diferenças em relação ao pipeline de doses (seção 5)

Este pipeline é uma adaptação direta do pipeline de doses. As diferenças
são apenas nos dados, não na lógica:

| Aspecto | Doses (DPNI) | Cobertura (CPNI) |
|---------|:------------:|:----------------:|
| Prefixo arquivo | DPNI | CPNI |
| Eras (schemas) | 3 (7→12→12 cols) | **2** (9→7 cols) |
| Campos exclusivos | ANOMES, MES, DOSE1, DOSEN, DIFER | **POP, COBERT** |
| Dicionário IMUNO | IMUNO.CNV (vacinas individuais) | IMUNOCOB.DBF (indicadores compostos) |
| Registros | 84 milhões | **2,8 milhões** (~30x menor) |
| Tempo de bootstrap | 4h40 | **44 min** (~6x mais rápido) |
| Destino R2 | `sipni/agregados/doses/` | `sipni/agregados/cobertura/` |

### Schemas por era

- **Era 1–2 (1994–2012):** 9 colunas — ANO, UF, MUNIC, FX_ETARIA, IMUNO,
  DOSE, QT_DOSE, POP, COBERT
- **Era 3 (2013–2019):** 7 colunas — ANO, UF, MUNIC, IMUNO, QT_DOSE, POP,
  COBERT (FX_ETARIA e DOSE desaparecem)

`open_dataset(unify_schemas = TRUE)` do Arrow preenche automaticamente
com `null` as colunas ausentes da Era 3.

### Campo COBERT: formato preservado

O campo COBERT (cobertura pré-calculada pelo MS) muda de formato na
transição de 2012 para 2013:

| Período | Tipo no .dbf | Valor no Parquet | Exemplo |
|:-------:|:------------:|:----------------:|:-------:|
| 1994–2012 | numeric (ponto) | `"39.87"` | `as.character(39.87)` |
| 2013–2019 | character (vírgula) | `"64,86"` | preservado como está |

Ambos ficam como string no Parquet, mas com separadores decimais
diferentes. Esta inconsistência é da fonte, documentada para que
pesquisadores saibam. Normalização ficará no pacote R.

### Consolidados excluídos

Mesmo racional do pipeline de doses:

- **CPNIIG:** não existe no FTP ou é vazio (0 linhas)
- **CPNIBR:** redundante — validado com diferença zero contra soma dos
  27 estaduais (CPNIBR98: 49.561 linhas = soma dos estaduais de 1998)
- **CPNIUF:** schema diferente (8 cols, sem MUNIC) e redundante
- **CPNIBR contém dados divergentes:** valores de DOSE extras (D1, D3,
  SD) não presentes nos estaduais, sugerindo processamento adicional

Racional completo em `docs/sipni-agregados/exploration-cobertura-pt.md`,
decisão 9.8.

### Rodar e monitorar

```bash
# Rodar
nohup Rscript /root/sipni-agregados-cobertura-pipeline-r.R > /root/pipeline_cobertura.log 2>&1 &

# Monitorar
tail -f /root/pipeline_cobertura.log
grep "^ANO " /root/pipeline_cobertura.log
grep -i "erro" /root/pipeline_cobertura.log
cat /root/data/controle_versao_sipni_agregados_cobertura.csv
```

---

## 7. COMPARAÇÃO DOS PIPELINES

| Métrica | SI-PNI (rotina) | SI-PNI COVID | Agregados Doses | Agregados Cobertura |
|---------|-----------------|--------------|-----------------|---------------------|
| Tempo total | 21,7 horas | 7,8 horas | 4,7 horas | **44 min** |
| Registros | 736 milhões | 608 milhões | 84 milhões | **2,8 milhões** |
| Dados brutos | ~130 GB (ZIP) | 292 GB (CSV) | ~1,5 GB (.dbf) | **~50 MB (.dbf)** |
| Taxa | ~33,9M reg/hora | ~78,0M reg/hora | ~300K reg/hora | **~3,8M reg/hora** |
| Formato fonte | JSON em ZIP | CSV direto | .dbf (FTP) | .dbf (FTP) |
| Dependências | Python + jq + polars + rclone | Python + polars + rclone | R + foreign + arrow + rclone | R + foreign + arrow + rclone |

O COVID processou 2,3x mais registros por hora apesar de lidar com 2,2x
mais dados brutos em volume. **Lição: o formato da fonte é o fator
dominante na performance do pipeline**, mais do que volume de dados, número
de colunas, ou estratégia de paralelismo.

Os agregados têm taxa inferior aos microdados porque o gargalo é o
protocolo FTP: conexão sequencial, sem paralelismo, servidores do DATASUS
no Brasil com latência alta desde a Alemanha. O pipeline de cobertura
foi ~10x mais rápido que o de doses apesar de usar a mesma lógica porque
os arquivos CPNI são muito menores (~50 MB total vs ~1,5 GB) e o FTP
responde mais rápido para arquivos pequenos.

---

## 8. VALOR DO PARTICIONAMENTO NO R2

Os dados no R2 estão particionados por `ano/mes/uf`, o que permite queries
filtradas que baixam apenas o necessário. Comparação para obter todos os
dados de uma UF (exemplo: Acre):

| Via | SI-PNI rotina | SI-PNI COVID |
|-----|---------------|--------------|
| **Ministério** | ~131 GB (todos os 73 ZIPs mensais) → **~6h** | ~920 MB (5 CSVs do AC) → **~5-10 min** |
| **R2** | ~200-400 MB Parquet → **~1-2 min** | ~30-60 MB Parquet → **~15 seg** |

Para recortes mais finos (um mês + uma UF), a diferença é ainda mais brutal:
o Ministério não permite filtro server-side, enquanto o R2 com Arrow lê
apenas a partição exata.

---

## 9. DECISÕES ESTRATÉGICAS DE PIPELINE

Decisões que se aplicam a todos os pipelines:

1. **Bucket único `healthbr-data`:** Prefixos para cada sistema (sipni/,
   sipni/covid/, sim/, sinasc/, sih/). Um token, uma config rclone, Arrow
   navega transparentemente.

2. **Publicar dados exatamente como o governo fornece:** Sem decodificar
   campos — dicionários separados. Pesquisadores podem rastrear até a
   fonte original.

3. **Servidor temporário:** Bootstrap pesado em servidor potente, depois
   destroi. Manutenção mensal em servidor mínimo ou sob demanda.

4. **Linguagem do pipeline conforme o gargalo:** Microdados grandes usam
   Python+jq+polars (velocidade de parsing). Agregados pequenos usam R
   puro (simplicidade, gargalo é download FTP). Pacote de consumo será
   em R (público-alvo).

Decisões específicas por pipeline:

5. **JSON em vez de CSV (rotina):** CSVs de 2020-2024 têm artefatos de
   exportação (floats com `.0`, zeros à esquerda perdidos). JSON preserva
   dados originais. *Em retrospecto, CSV com correção dos 5 campos afetados
   teria sido mais eficiente — ver `strategy-expansion-pt.md`, seção sobre
   checklist de trade-offs.*

6. **CSV direto (COVID):** CSVs COVID não têm artefatos de float (tudo entre
   aspas, zeros preservados). Sem alternativa JSON disponível.

---

## 10. TEMPLATE PARA NOVOS PIPELINES

Ao documentar um novo pipeline neste arquivo, usar esta estrutura:

```markdown
## N. PIPELINE [SISTEMA]: [formato] → Parquet → R2

### Objetivo
[Uma frase]

### Arquitetura
[Diagrama ASCII]

### Números finais
[Tabela com série, registros, tempo, taxa, dados fonte, estrutura R2]

### Particularidades
[O que é diferente dos pipelines anteriores]

### Rodar e monitorar
[Comandos bash]
```

---

*Última atualização: 27/fev/2026.*
