# Exploração: Microdados de Vacinação COVID-19 (OpenDATASUS)

> Documento gerado em 2026-02-24, consolidando a sessão de exploração
> do dataset "Campanha Nacional de Vacinação contra Covid-19" do
> OpenDATASUS. Serve como base para o pipeline `sipni/covid`.

---

## 1. VISÃO GERAL

| Propriedade              | Valor                                          |
|--------------------------|-------------------------------------------------|
| Nome oficial             | Campanha Nacional de Vacinação contra Covid-19  |
| Registros totais         | **606.434.779** (API, em 2026-02-24)            |
| Volume CSV bruto         | **271.79 GB** (27 UFs × 5 partes = 135 arquivos)|
| Volume Parquet estimado  | **35-55 GB** (compressão ~5-8x)                 |
| Período                  | jan/2021 – presente (atualização contínua)      |
| Campos úteis             | 32 (CSV) / 33 (API, com extras de controle)    |
| Fonte primária           | CSV por UF no S3 (27 UFs × 5 partes = 135 arquivos) |
| Fonte complementar       | API Elasticsearch (atualizada diariamente)  |
| Sistemas de origem       | Novo PNI, IDS Saúde, VACIVIDA, e-SUS APS, outros |
| Granularidade            | 1 linha = 1 dose aplicada (anonimizada)         |
| Destino no R2            | `s3://healthbr-data/sipni/covid/`               |

**Comparação com vacinação de rotina:**

| Aspecto           | Rotina (SI-PNI)           | COVID-19                     |
|-------------------|---------------------------|------------------------------|
| Registros         | ~500M+ (2020-2026)        | ~606M (2021-presente)        |
| Volume fonte      | ~130 GB (JSON zips)       | ~272 GB (CSV bruto)          |
| Campos            | 56                        | 32 (CSV) / 33 (API)          |
| Formato fonte     | JSON (array, S3 do MS)    | CSV por UF (S3) + API ES     |
| Naming convention | snake_case                | camelCase misto              |
| Tipos             | Tudo string               | CSV: tudo string / API: misto |
| Typo oficial      | `estalecimento` (sem "b") | **Mesmo typo!**              |

---

## 2. VIAS DE ACESSO AOS DADOS

### 2.1 API Elasticsearch (CONFIRMADA ATIVA)

```
URL:     https://imunizacao-es.saude.gov.br/desc-imunizacao/_search
Índice:  desc-imunizacao (alias para desc-imunizacao-v5)
Shards:  30
Usuário: imunizacao_public
Senha:   qlto5t&7r_@+#Tlstigi
```

**Permissões do usuário público:**
- `_search` → permitido (busca com filtros, paginação)
- `_count` → permitido
- `_mapping` → **bloqueado** (403, requer `view_index_metadata`)

**Exemplo de uso (PowerShell):**
```powershell
curl -u "imunizacao_public:qlto5t`&7r_@+#Tlstigi" "https://imunizacao-es.saude.gov.br/desc-imunizacao/_count?pretty=true"
```

**Para queries com body JSON no PowerShell:**
```powershell
# 1. Criar arquivo de query (evita problemas de escape)
'{"size":3,"query":{"bool":{"must_not":[{"term":{"status":"entered-in-error"}}]}}}' | Out-File -Encoding utf8 query.json

# 2. Executar com -d @arquivo
curl -u "imunizacao_public:qlto5t`&7r_@+#Tlstigi" -X POST "https://imunizacao-es.saude.gov.br/desc-imunizacao/_search?pretty=true" -H "Content-Type: application/json" -d "@query.json"
```

### 2.2 CSVs por UF no S3 (ACESSÍVEIS!)

```
Padrão:  https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SIPNI/COVID/uf/uf%3D{UF}/part-{NNNNN}-f58e39ef-bcdd-4fc4-bae5-f3c5a2858afe.c000.csv
UFs:     AC, AL, AM, AP, BA, CE, DF, ES, GO, MA, MG, MS, MT, PA, PB, PE, PI, PR, RJ, RN, RO, RR, RS, SC, SE, SP, TO
Partes:  00000 a 00004 (5 partes por UF)
Total:   27 UFs × 5 partes = 135 arquivos CSV
Hash:    f58e39ef-bcdd-4fc4-bae5-f3c5a2858afe (global, toda a publicação)
```

**Volume total mapeado (HEAD em 135 arquivos, 2026-02-24):**

| UF | GB    | UF | GB    | UF | GB    |
|----|------:|----|------:|----|------:|
| SP | 66.68 | PE | 12.10 | PB |  5.39 |
| MG | 28.51 | GO |  8.18 | PI |  4.82 |
| RJ | 22.72 | SC |  8.76 | AM |  4.70 |
| BA | 18.54 | PA |  8.26 | RN |  4.43 |
| PR | 15.60 | MA |  7.02 | DF |  3.87 |
| RS | 15.09 | ES |  5.32 | MT |  3.76 |
| CE | 12.49 | AL |  3.59 | MS |  3.36 |
|    |       | SE |  3.12 | RO |  1.70 |
|    |       | TO |  1.47 | AC |  0.92 |
|    |       | AP |  0.84 | RR |  0.56 |

**Total: 271.79 GB** (CSV bruto, 27 UFs × 5 partes = 135 arquivos)

Após conversão para Parquet (compressão ~5-8x), estimativa: **35-55 GB no R2.**

**NOTA:** Os "Dados Completos" (sem partição por UF) estão **bloqueados** (403).
Apenas os CSVs particionados por UF estão acessíveis.

### 2.3 CSVs "Dados Completos" no S3 (INACESSÍVEIS — AccessDenied)

```
Bucket:     s3://ckan.saude.gov.br/SIPNI/COVID/completo/
Padrão:     part-{NNNNN}-123d350b-30a4-4082-a0b9-2cf87192d64d-c000.csv
```

- 20 partes listadas no portal
- **Todas retornam 403 AccessDenied** (hash antigo e atual)

### 2.3 Portal

```
Portal novo:   dadosabertos.saude.gov.br/dataset/covid-19-vacinacao  → ATIVO
Portal antigo: opendatasus.saude.gov.br  → redirecionando, instável, 500s
```

**Recursos listados no portal (confirmado 2026-02-24):**
1. API — Registros de Vacinação COVID19 (criado 13/02/2026)
2. CSV — Dados Completos, 20 partes (criado 21/12/2025) — **links quebrados (403)**
3. CSV — AC até ES (21/12/2025) — **links funcionam (200 OK)**
4. CSV — GO até MT (21/12/2025) — **links funcionam (200 OK)**
5. CSV — PA até RO (21/12/2025) — **links funcionam (200 OK)**
6. CSV — RS até TO (21/12/2025) — **links funcionam (200 OK)**

**Dicionário de dados PDF:** inacessível em todas as URLs conhecidas (404/500).
O mapeamento de campos neste documento foi obtido empiricamente via API.

---

## 3. MAPEAMENTO COMPLETO DE CAMPOS (33 + 2)

### 3.1 Paciente (13 campos)

| # | Campo                                      | Tipo    | Exemplo                          | Nota                        |
|---|---------------------------------------------|---------|----------------------------------|-----------------------------|
| 1 | `paciente_id`                               | string  | `7c506f7c0a87...` (64 chars)    | SHA-256, anonimizado        |
| 2 | `paciente_idade`                            | integer | `29`                             | **Não é string!**           |
| 3 | `paciente_dataNascimento`                   | date    | `1992-07-13`                     | Formato ISO                 |
| 4 | `paciente_enumSexoBiologico`                | string  | `F`, `M`                         |                             |
| 5 | `paciente_racaCor_codigo`                   | string  | `01`, `02`, `03`, `04`, `99`    | Zeros à esquerda preservados |
| 6 | `paciente_racaCor_valor`                    | string  | `BRANCA`, `PRETA`, `PARDA`, `AMARELA`, `SEM INFORMACAO` | |
| 7 | `paciente_nacionalidade_enumNacionalidade`  | string  | `B`                              | B = Brasileiro              |
| 8 | `paciente_endereco_uf`                      | string  | `SE`, `SP`, `PA`, `BA`, `PI`    |                             |
| 9 | `paciente_endereco_coIbgeMunicipio`         | string  | `280670`                         | 6 dígitos IBGE              |
| 10| `paciente_endereco_nmMunicipio`             | string  | `SAO CRISTOVAO`                  |                             |
| 11| `paciente_endereco_coPais`                  | string  | `10`                             |                             |
| 12| `paciente_endereco_nmPais`                  | string  | `BRASIL`                         |                             |
| 13| `paciente_endereco_cep`                     | string  | `49100`                          | **5 dígitos** (truncado, anonimização) |

### 3.2 Estabelecimento (6 campos)

| # | Campo                            | Tipo   | Exemplo                                | Nota                     |
|---|-----------------------------------|--------|----------------------------------------|--------------------------|
| 14| `estabelecimento_valor`           | string | `0002844`, `6269567`                   | CNES, zeros preservados  |
| 15| `estabelecimento_razaoSocial`     | string | `SECRETARIA MUNICIPAL DE SAUDE DE ARACAJU` |                      |
| 16| `estalecimento_noFantasia`        | string | `US ONESIMO PINTO FILHO...`            | **Typo oficial** (sem "b") |
| 17| `estabelecimento_municipio_codigo`| string | `280030`                               | 6 dígitos IBGE           |
| 18| `estabelecimento_municipio_nome`  | string | `ARACAJU`                              |                          |
| 19| `estabelecimento_uf`              | string | `SE`                                   |                          |

### 3.3 Vacina (12 campos)

| # | Campo                           | Tipo   | Exemplo                                   | Nota                          |
|---|---------------------------------|--------|--------------------------------------------|-------------------------------|
| 20| `vacina_codigo`                 | string | `86`, `87`, `97`, `99`                    | Sem zero à esquerda           |
| 21| `vacina_nome`                   | string | `COVID-19 PFIZER - COMIRNATY`             | Inconsistências conhecidas    |
| 22| `vacina_fabricante_nome`        | string | `PFIZER`, `SINOVAC/BUTANTAN`, `Pendente Identificação` | Problema documentado |
| 23| `vacina_fabricante_referencia`  | string | `35978` ou `null`                         |                               |
| 24| `vacina_lote`                   | string | `FM2948`, `210398`                        |                               |
| 25| `vacina_dataAplicacao`          | date   | `2022-03-10T00:00:00.000Z`               | ISO datetime                  |
| 26| `vacina_descricao_dose`         | string | `1ª Dose`, `2ª Dose`, `Dose`, `Única`    | Texto livre, variável         |
| 27| `vacina_numDose`                | string | `1`, `2`, `8`, `9`                       | Vai muito além de D1-D2       |
| 28| `vacina_categoria_codigo`       | string | `1`, `2`, `114`                           |                               |
| 29| `vacina_categoria_nome`         | string | `Faixa Etária`, `Comorbidades`, `Outros` |                               |
| 30| `vacina_grupoAtendimento_codigo`| string | `000201`, `000210`, `000107`, `999999`   |                               |
| 31| `vacina_grupoAtendimento_nome`  | string | `Pessoas de 18 a 64 anos`, `Hipertensão de difícil controle...` | Granular |

### 3.4 Condição maternal (2 campos)

| # | Campo                  | Tipo         | Exemplo              | Nota                  |
|---|------------------------|--------------|----------------------|-----------------------|
| 32| `co_condicao_maternal` | integer/null | `1` ou `null`        | **Integer, não string** |
| 33| `ds_condicao_maternal` | string/null  | `Nenhuma` ou `null`  |                       |

### 3.5 Sistema e controle (7 campos)

| # | Campo                    | Tipo   | Exemplo                                  | Nota                         |
|---|--------------------------|--------|------------------------------------------|------------------------------|
| 34| `document_id`            | string | `b94aae8b-0d89-46e2-952c-938fc7ca799b-i0b0` | UUID, chave primária     |
| 35| `sistema_origem`         | string | `IDS Saúde`, `Novo PNI`, `VACIVIDA`     | Múltiplos sistemas           |
| 36| `id_sistema_origem`      | string | `17852`, `16341`, `18262`, `24190`       |                              |
| 37| `data_importacao_rnds`   | date   | `2022-03-29T14:58:02.000Z`              | Quando entrou na RNDS        |
| 38| `data_importacao_datalake`| date  | `2026-02-24T14:15:38.000Z`              | Quando reimportado ao ES     |
| 39| `status`                 | string | `final`, `entered-in-error`              | `final` = válido             |
| 40| `dt_deleted`             | date   | `0001-01-01T00:00:00.000Z` ou data real | Sentinela `0001-01-01` = não deletado |

### 3.6 Metadados Elasticsearch (2 campos — ignorar no pipeline)

| Campo        | Nota                              |
|--------------|-----------------------------------|
| `@version`   | Sempre `"1"`                      |
| `@timestamp` | Timestamp de indexação no ES      |

---

## 4. ESTRUTURA DO CSV

### 4.1 Propriedades

| Propriedade  | Valor                                |
|--------------|--------------------------------------|
| Header       | **SIM** (primeira linha)             |
| Delimitador  | **`;`** (ponto-e-vírgula)            |
| Encoding     | **UTF-8** (acentos OK)               |
| Quoting      | Todos os campos entre aspas duplas   |
| Colunas      | **32**                               |

### 4.2 Campos no CSV (32) — ordem no header

```
 1  document_id                          17  estalecimento_noFantasia (typo!)
 2  paciente_id                          18  estabelecimento_municipio_codigo
 3  paciente_idade                       19  estabelecimento_municipio_nome
 4  paciente_dataNascimento              20  estabelecimento_uf
 5  paciente_enumSexoBiologico           21  vacina_grupoAtendimento_codigo
 6  paciente_racaCor_codigo              22  vacina_grupoAtendimento_nome
 7  paciente_racaCor_valor               23  vacina_categoria_codigo
 8  paciente_endereco_coIbgeMunicipio    24  vacina_categoria_nome
 9  paciente_endereco_coPais             25  vacina_lote
10  paciente_endereco_nmMunicipio        26  vacina_fabricante_nome
11  paciente_endereco_nmPais             27  vacina_fabricante_referencia
12  paciente_endereco_uf                 28  vacina_dataAplicacao
13  paciente_endereco_cep                29  vacina_descricao_dose
14  paciente_nacionalidade_enumNacion.   30  vacina_codigo
15  estabelecimento_valor                31  vacina_nome
16  estabelecimento_razaoSocial          32  sistema_origem
```

### 4.3 Campos presentes na API mas ausentes no CSV (7)

| Campo API                  | Nota                                          |
|----------------------------|-----------------------------------------------|
| `vacina_numDose`           | CSV só tem `vacina_descricao_dose` (texto)    |
| `id_sistema_origem`        | Apenas `sistema_origem` (nome) está no CSV    |
| `status`                   | CSV já vem filtrado (sem entered-in-error)    |
| `dt_deleted`               | Idem                                          |
| `data_importacao_rnds`     | Metadado de importação                        |
| `data_importacao_datalake` | Metadado de importação                        |
| `co_condicao_maternal` / `ds_condicao_maternal` | Condição maternal ausente  |

### 4.4 Vacinas identificadas no CSV (amostra AC)

| Código | Nome                                        | Fabricante                |
|--------|---------------------------------------------|---------------------------|
| `33`   | INF3                                        | BUTANTAN                  |
| `85`   | COVID-19 ASTRAZENECA/FIOCRUZ - COVISHIELD   | ASTRAZENECA/FIOCRUZ       |
| `86`   | COVID-19 SINOVAC/BUTANTAN - CORONAVAC        | SINOVAC/BUTANTAN          |
| `87`   | COVID-19 PFIZER - COMIRNATY                  | PFIZER                    |
| `88`   | COVID-19 JANSSEN - Ad26.COV2.S               | JANSSEN                   |

**DESCOBERTA: Código `33` / `INF3` = Vacina Influenza trivalente (gripe),
NÃO é vacina COVID.** O dataset COVID contém registros de vacinas não-COVID
registradas erroneamente. O registro na amostra era criança de 4 anos,
dose "Única", fabricante "BUTANTAN", data 2024-01-29 — influenza de rotina.

### 4.5 Formato de `vacina_fabricante_referencia`

Valores mistos observados na amostra:
- Numérico: `29501`, `30587`, `152`
- CNPJ: `Organization/00394544000851`, `Organization/61189445000156`, `Organization/33781055000135`

### 4.6 Tipos observados no CSV

Diferente da API (onde `paciente_idade` é integer), no CSV **tudo é string**
(entre aspas duplas). Zeros à esquerda preservados nos códigos:
`"04"` (raça), `"000207"` (grupo atendimento), `"120038"` (município).

**Excelente — sem artefatos de float como no CSV de rotina 2020-2024.**

| Código | Nome                                        | Fabricante          |
|--------|---------------------------------------------|---------------------|
| `86`   | COVID-19 SINOVAC/BUTANTAN - CORONAVAC       | SINOVAC/BUTANTAN    |
| `87`   | COVID-19 PFIZER - COMIRNATY                 | PFIZER              |
| `97`   | COVID-19 MODERNA - SPIKEVAX                 | Pendente Identificação (!) |
| `99`   | COVID-19 PEDIÁTRICA - PFIZER COMIRNATY      | Pendente Identificação (!) |

**Nota:** AstraZeneca e Janssen também estão presentes no dataset completo
mas não apareceram na amostra de 8 registros. A inconsistência entre
`vacina_nome`, `vacina_fabricante_nome` e `vacina_fabricante_referencia`
é um problema documentado pela comunidade (199 combinações distintas
quando deveriam ser ~10).

---

## 5. DESCOBERTAS E OBSERVAÇÕES

### 5.1 Registros deletados (`entered-in-error`)

A busca sem filtro retorna **preferencialmente registros deletados**,
provavelmente porque são os mais recentemente reimportados ao datalake.
Os 5 primeiros registros retornados tinham:
- `status: "entered-in-error"`
- `dt_deleted` com datas de 2026-02-22 a 2026-02-24

Para obter registros válidos, é obrigatório filtrar:
```json
{"query": {"bool": {"must_not": [{"term": {"status": "entered-in-error"}}]}}}
```

Registros válidos usam `status: "final"` e `dt_deleted: "0001-01-01T00:00:00.000Z"`.

### 5.2 Tipos de dados mistos

Diferente da vacinação de rotina (tudo string), o dataset COVID tem tipos
mistos na API:
- `paciente_idade` → **integer** (não string)
- `co_condicao_maternal` → **integer ou null** (não string)
- Demais campos → string ou null

**Decisão necessária para o pipeline:** manter como está ou normalizar tudo
para string (como na rotina)?

### 5.3 CEP truncado a 5 dígitos

O CEP do paciente tem apenas 5 dígitos (ex: `49100`, `08141`), enquanto
na vacinação de rotina o CEP tem 5 ou 8 dígitos. Isso parece ser
anonimização intencional para a campanha COVID (nível de setor censitário
removido).

### 5.4 Doses além de D1/D2

O campo `vacina_numDose` vai pelo menos até 9, refletindo a evolução do
esquema vacinal COVID:
- `1` = 1ª Dose
- `2` = 2ª Dose
- `3`+ = Reforços, doses bivalentes, atualizações anuais
- `8`, `9` = Doses mais recentes (2024+)

O campo `vacina_descricao_dose` é texto livre e variável: `1ª Dose`,
`2ª Dose`, `Dose`, `Única`.

### 5.5 Paciente e estabelecimento em UFs diferentes

O registro de Coronavac/Praia Grande-SP mostra paciente residente no PI
(`paciente_endereco_uf: "PI"`) vacinado em SP (`estabelecimento_uf: "SP"`).
Isso é esperado mas relevante para o particionamento — por qual UF
particionar?

### 5.6 Múltiplos sistemas de origem

Pelo menos 3 sistemas identificados na amostra:
- `Novo PNI` — o novo SI-PNI integrado à RNDS
- `IDS Saúde` — sistema de integração
- `VACIVIDA` — sistema do estado de São Paulo

Potencialmente há outros (e-SUS APS, sistemas proprietários de estados).

### 5.7 Inconsistências conhecidas no dataset

Documentadas pela comunidade (Brasil.IO, ICMC-USP, UFV):
- **Vacina/fabricante:** 199 combinações distintas entre `vacina_codigo`,
  `vacina_nome`, `vacina_fabricante_nome` e `vacina_fabricante_referencia`
- **Duplicatas:** registros com mesmos dados em todas as colunas exceto
  `document_id`, `sistema_origem`, `data_importacao_rnds`, `id_sistema_origem`
- **Pacientes com 3+ registros:** em 2021, já havia ~468K `paciente_id`
  com 3+ doses quando o esquema era de no máximo 2
- **`vacina_fabricante_nome: "Pendente Identificação"`** aparece em
  registros mais recentes, especialmente Moderna e Pfizer pediátrica

### 5.8 Dataset contém vacinas não-COVID

O código `33` / `INF3` na amostra do AC é Vacina Influenza trivalente
(vacina da gripe, fabricante Butantan). Não é vacina COVID. Registrado
em criança de 4 anos, dose "Única", data 2024-01-29. Isso indica que o
dataset "Vacinação COVID-19" contém registros de outras vacinas,
possivelmente por erro de registro no sistema de origem.

### 5.9 Portal em migração

O OpenDATASUS migrou de `opendatasus.saude.gov.br` (CKAN) para
`dadosabertos.saude.gov.br`. O portal antigo retorna erros 500 e
redireciona. O dicionário PDF oficial não está acessível em nenhuma
das URLs conhecidas (2026-02-24). O novo portal responde 200 OK.

---

## 6. ESTRATÉGIA PARA O PIPELINE

### 6.1 Fonte dos dados

**CSV por UF é a fonte primária.** Download bulk via S3, 27 UFs × 5 partes.

- URLs determinísticas com hash global: `f58e39ef-bcdd-4fc4-bae5-f3c5a2858afe`
- HEAD request para sincronização (ETag + Content-Length + Last-Modified)
- Snapshot de 22/12/2025 — dados não são atualizados continuamente
- Sem artefatos de float (tudo string entre aspas, zeros preservados)
- Volume total: **272 GB** de CSV bruto
- Maior UF: SP com 66.7 GB (5 partes de ~13.3 GB cada)
- Menor UF: RR com 0.56 GB
- **Requer CPX42 (16 GB RAM) ou maior** para processar SP
- Estimativa de tempo: ~4-8 horas para download completo (depende da banda)
- Estimativa de Parquet no R2: 35-55 GB

**API Elasticsearch como complemento:**
- Dados atualizados diariamente (vs snapshot do CSV)
- Campos extras: `vacina_numDose`, `status`, `co_condicao_maternal`
- Pode servir para delta updates entre publicações do CSV
- Extração completa via `search_after` possível mas lenta (~60K requests)

**Estratégia híbrida recomendada:**
1. Bootstrap: download bulk dos CSVs por UF (135 arquivos)
2. Atualização: quando o Ministério republicar CSVs (hash muda), re-download
3. Se CSVs ficarem muito defasados: complementar com API para registros recentes

### 6.2 Estrutura no R2

```
s3://healthbr-data/sipni/covid/
  microdados/
    ano=2021/mes=01/uf=XX/
      part-00001.parquet
    ...
    ano=_invalid/mes=MM/uf=XX/     ← registros com datas fora de 2021–presente
      part-NNNNN.parquet
  dicionarios/
    campos.json               ← mapeamento documentado neste arquivo
```

### 6.3 Questões em aberto

1. ~~**Qual fonte usar?**~~ → **CSV por UF** (bulk) + API (complemento)
2. **Registros deletados:** CSV já filtra `entered-in-error` — publicar como está?
3. **Particionamento R2:** dados já vêm por UF; subdividir por ano também?
4. **Tipos no Parquet:** CSV traz tudo string (como rotina) — manter
5. ~~**Formato JSON existe?**~~ → **Não** (confirmado no portal)
6. **Deduplicação:** o pipeline deve lidar com duplicatas ou publicar como está?
7. **Hash do S3 muda quando?** Monitorar HEAD requests periódicos
8. **Código `33` / `INF3`:** identificar que vacina é essa
9. **Campos extras da API:** vale enriquecer CSV com `vacina_numDose`?

---

## 7. COMANDOS UTILIZADOS NA EXPLORAÇÃO

```powershell
# Testar acesso à API
curl -u "imunizacao_public:qlto5t`&7r_@+#Tlstigi" "https://imunizacao-es.saude.gov.br/desc-imunizacao/_search?size=1`&pretty=true"

# Contagem total
curl -u "imunizacao_public:qlto5t`&7r_@+#Tlstigi" "https://imunizacao-es.saude.gov.br/desc-imunizacao/_count?pretty=true"

# Mapeamento (bloqueado para usuário público)
curl -u "imunizacao_public:qlto5t`&7r_@+#Tlstigi" "https://imunizacao-es.saude.gov.br/desc-imunizacao/_mapping?pretty=true"

# Amostra de 5 registros
curl -u "imunizacao_public:qlto5t`&7r_@+#Tlstigi" "https://imunizacao-es.saude.gov.br/desc-imunizacao/_search?size=5`&pretty=true" -o covid_amostra.json

# Registros válidos (excluindo entered-in-error)
'{"size":3,"query":{"bool":{"must_not":[{"term":{"status":"entered-in-error"}}]}}}' | Out-File -Encoding utf8 query.json
curl -u "imunizacao_public:qlto5t`&7r_@+#Tlstigi" -X POST "https://imunizacao-es.saude.gov.br/desc-imunizacao/_search?pretty=true" -H "Content-Type: application/json" -d "@query.json" -o covid_amostra_validos.json

# Testar listing do bucket S3 (AccessDenied)
curl "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br?prefix=SIPNI/COVID/&delimiter=/&max-keys=10"

# Testar CSV por UF — AC parte 1 (200 OK! 188 MB)
curl -sI "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SIPNI/COVID/uf/uf%3DAC/part-00000-f58e39ef-bcdd-4fc4-bae5-f3c5a2858afe.c000.csv"

# Testar CSV por UF — SP parte 1 (200 OK! 14.3 GB)
curl -sI "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SIPNI/COVID/uf/uf%3DSP/part-00000-f58e39ef-bcdd-4fc4-bae5-f3c5a2858afe.c000.csv"

# Baixar amostra (primeiros 5000 bytes) para inspeção de header
curl -r 0-5000 "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SIPNI/COVID/uf/uf%3DAC/part-00000-f58e39ef-bcdd-4fc4-bae5-f3c5a2858afe.c000.csv" -o covid_ac_amostra.csv

# Testar CSV Dados Completos — URL do Google (hash antigo, 403)
curl -sI "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SIPNI/COVID/completo/part-00000-10b10edc-a977-44ae-af01-b48b78d8b58f-c000.csv"

# Testar CSV Dados Completos — URL do portal (hash atual, TAMBÉM 403)
curl -sI "https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/SIPNI/COVID/completo/part-00000-123d350b-30a4-4082-a0b9-2cf87192d64d-c000.csv"

# Testar novo portal
curl -sI "https://dadosabertos.saude.gov.br/dataset?groups=vacinacao"
```

---

## 8. REFERÊNCIAS

- Portal antigo: https://opendatasus.saude.gov.br/dataset/covid-19-vacinacao
- Portal novo: https://dadosabertos.saude.gov.br/
- Portal dados.gov.br: https://dados.gov.br/dataset/covid-19-vacinacao
- Análise Brasil.IO: https://blog.brasil.io/2021/07/15/resposta-do-ministerio-da-saude-aos-problemas-nos-microdados-de-vacinacao/
- Análise turicas: https://github.com/turicas/covid19-br/blob/master/analises/microdados-vacinacao/README.md
- Dados processados UFV: https://github.com/wcota/covid19br-vac
- Dados agregados covid19br: https://github.com/covid19br/dados-vacinas
- Vacinômetro ICMC-USP: http://vacinometro.icmc.usp.br/
- Referência PAMEpi/Fiocruz (~63GB CSV): https://pamepi.rondonia.fiocruz.br/data.html
