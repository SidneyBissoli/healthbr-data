# Exploração: SINASC — Sistema de Informações sobre Nascidos Vivos

> Documento de exploração da Fase 2 — SINASC.
> Criado em 07/mar/2026. Atualizado conforme a exploração avança.
>
> **Artefato obrigatório da Fase 2** conforme `strategy-expansion-pt.md`, seção 3.
> Inclui: visão geral, vias de acesso, estrutura dos dados, artefatos encontrados,
> volume, comparação de formatos e decisões estruturantes (Fase 3).
>
> **Script de exploração:** `scripts/exploration/sinasc-01-explore.R`

---

## 1. VISÃO GERAL

| Propriedade              | Valor                                                              |
|--------------------------|--------------------------------------------------------------------|
| Nome oficial             | Sistema de Informações sobre Nascidos Vivos (SINASC)               |
| Órgão responsável        | Secretaria de Vigilância em Saúde (SVS) / Ministério da Saúde      |
| Documento base           | Declaração de Nascido Vivo (DNV)                                   |
| Granularidade            | 1 linha = 1 nascido vivo                                           |
| Período coberto          | 1994–presente (FTP); 1996–2025 (OpenDATASUS)                       |
| Volume estimado          | ~3 milhões de nascimentos/ano (anos recentes)                      |
| Prefixo R2 definido      | `sinasc/`                                                          |
| Fase atual               | **2 — Exploração**                                                 |

**Por que este módulo:**
SINASC é o principal sistema de registro de nascimentos no Brasil e insumo
essencial para indicadores de saúde materno-infantil (taxa de mortalidade
infantil, prematuridade, peso ao nascer, adequação do pré-natal). Complementa
diretamente o SIM (estatísticas vitais completas) e historicamente foi a base
de denominadores para cobertura vacinal no SI-PNI. A ausência de uma via de
acesso via Parquet público em R2 (PCDaS tem acesso restrito; microdatasus não
persiste dados) justifica o módulo.

---

## 2. VIAS DE ACESSO AOS DADOS

### 2.1 FTP DATASUS (via principal — histórico completo)

```
Base: ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/
```

Dois grupos de arquivos:

| Grupo | Diretório | Padrão de arquivo | Descrição |
|-------|-----------|-------------------|-----------|
| DNASC | `NOV/DNASC/` | `DN{UF}{AAAA}.dbc` | Por local de **ocorrência** |
| DNR   | `NOV/DNASC/` ou outro | `DNR{UF}{AAAA}.dbc` | Por local de **residência** |

- Formato `.dbc`: compressão proprietária DATASUS sobre DBF; leitura via
  `read.dbc::read.dbc()` (R) ou `pysus` (Python)
- UFs: 27 (26 estados + DF)
- Cobertura temporal: **1994–presente**

> **A verificar na Fase 2:**
> - Confirmar estrutura do diretório FTP (subpastas, se há separação CID9/CID10 como no SIM)
> - Verificar se DNR existe como grupo separado ou se é um alias
> - Confirmar padrão de nomes para anos antigos (2 dígitos?)

### 2.2 OpenDATASUS — S3 (via complementar — CSVs anuais)

```
Portal: https://opendatasus.saude.gov.br/dataset/sistema-de-informacao-sobre-nascidos-vivos-sinasc
```

- CSVs anuais disponíveis: **1996–2025** (inclui dado preliminar do ano corrente)
- Inclui dicionário de dados em PDF (a confirmar)
- Atualização ao longo do ano para o ano mais recente (dado preliminar vs. definitivo)

> **A verificar na Fase 2:**
> - Padrão exato da URL S3 (ex: `s3://.../SINASC/sinasc_{ANO}.csv` ou outro)
> - Tamanho e número de arquivos
> - Separador, encoding, e se há header
> - Se o CSV é equivalente ao .dbc ou se há diferenças de conteúdo

### 2.3 Resultado da verificação de acesso

| Via | Status | Observações |
|-----|--------|-------------|
| FTP — `NOV/DNRES/` | ✅ Acessível | 734 arquivos `DN{UF}{AAAA}.dbc`, 29 UFs, 1996–2022 |
| FTP — `ANT/DNRES/` | ✅ Acessível | 109 arquivos; inclui 1994–1995 com prefixo `DNR{UF}` |
| FTP — `NOV/TABELAS/` | ✅ Acessível | `CADMUN.DBF`, `CID10.DBF`, `TABOCUP.DBF`, `TABPAIS.DBF`, `TABUF.DBF` |
| FTP — `NOV/DOCS/` | ✅ Acessível | `Estrutura_SINASC_para_CD.pdf`, `Legislacao_PDF.pdf`, `Portaria.pdf` |
| FTP — `ANT/DOCS/` | ✅ Acessível | `NASC98.HLP` (dicionário de variáveis era 1994–1998) |
| OpenDATASUS S3 | ❌ Bloqueado | HTTP 403 em todos os padrões de URL testados |
| API DEMAS (`apidadosabertos.saude.gov.br`) | ❌ Fora do ar | HTTP 404 em todos os endpoints documentados |

---

## 3. ESTRUTURA DOS DADOS

> ⚠️ **A preencher após execução de `sinasc-01-explore.R`**

### 3.1 Versão atual do formulário (DNV — 8ª versão, 2021)

A estrutura conhecida a priori (literatura + microdatasus):

**52 variáveis na versão atual**, organizadas em grupos:

| Grupo | Variáveis principais |
|-------|---------------------|
| Dados do estabelecimento | `CODESTAB`, `CODMUNNASC`, `LOCNASC` |
| Dados da mãe | `IDADEMAE`, `ESCMAE`, `CODMUNRES`, `CODMUNNATU`, `GRAVIDEZ`, `GESTACAO`, `PARTO`, `CONSULTAS`, `DTULTMENST` |
| Dados do nascido vivo | `PESO`, `APGAR1`, `APGAR5`, `RACACOR`, `SEXO`, `IDANOMAL` |
| Datas | `DTNASC`, `DTNASCMAE` |
| Controle | `DTCADASTRO`, `CODANOMAL` |

### 3.2 Evolução histórica do formulário

O formulário DNV passou por múltiplas versões. Mudanças relevantes para o pipeline:

| Versão | Período | Principais mudanças |
|--------|---------|---------------------|
| 1ª–7ª  | 1994–2020 | Variações no número de variáveis (menos detalhes inicialmente) |
| 8ª     | 2021–presente | Inclui: tipo de apresentação, tipo de gravidez, número de filhos vivos/mortos |

> ⚠️ **A confirmar na exploração:** Quais variáveis existem em cada era histórica?
> O .dbc mais antigo (1994) pode ter estrutura bem diferente da versão atual.
> Isso é crítico para decidir a estratégia de particionamento e schema.

### 3.3 Estrutura observada na amostra

**Arquivo:** `DNDF2022.dbc` (Distrito Federal, 2022 — era moderna)

```
Shape: 35.928 linhas × 61 colunas
```

| Campo | Observação |
|-------|------------|
| Todas as colunas | Chegam como `factor` via `read.dbc` — pipeline deve converter tipos explicitamente |
| Datas (`DTNASC`, etc.) | Formato `DDMMYYYY` sem separador (ex: `"25012022"`) |
| `CODMUNNASC`, `CODMUNRES`, `CODESTAB`, `CODMUNNATU` | Leading zeros preservados |
| `CODPAISRES` | Valor `"1"` — codificação desconhecida (não é IBGE 6 dígitos) |

**Schemas únicos por período (DF como referência, confirmados por análise de todos os anos 1994–2022):**

| Schema | Anos | Colunas | Característica |
|--------|------|---------|----------------|
| 1 | 1994–1995 | 30 | Nomenclatura completamente distinta; era `ANT/DNRES/`, prefixo `DNR{UF}` |
| 2 | 1996–1998 | 21 | Primeira nomenclatura moderna |
| 3 | 1999–2000 | 20 | |
| 4 | 2001 | 23 | |
| 5 | 2002–2005 | 26 | |
| 6 | 2006–2009 | 29 | |
| 7 | 2010 | 55 | Expansão expressiva do formulário |
| 8 | 2011 | 56 | |
| 9 | 2012 | 56 | |
| 10 | 2013 | 59 | |
| 11 | 2014–2017 | 61 | |
| 12 | 2018–2022 | 61 | Difere do schema 11 apenas por case: `contador` → `CONTADOR` |

---

## 4. COMPARAÇÃO DE FORMATOS

| Critério | FTP (.dbc) | OpenDATASUS (CSV) |
|----------|------------|-------------------|
| Cobertura temporal | **1994–2022** (mais recente disponível) | 1996–2025 (inclui preliminar) |
| Formato físico | .dbc (DBF comprimido) | CSV |
| Encoding | Latin-1 (padrão DATASUS) | Desconhecido — acesso bloqueado |
| Colunas | Schema nativo por era (ver 3.3) | Desconhecido |
| Artefatos conhecidos | Todos os campos chegam como `factor`; datas sem separador | Inacessível para verificação |
| Acesso | FTP anônimo ✅ | S3 público — HTTP 403 ❌ |
| Ferramenta de leitura | `read.dbc::read.dbc()` (R) | — |

**Decisão de formato:** FTP `.dbc` como única fonte viável (OpenDATASUS inacessível). Ver seção 9.

---

## 5. INVENTÁRIO DE VOLUME

### 5.1 FTP DATASUS

| Grupo | Diretório | UFs | Período | Arquivos |
|-------|-----------|-----|---------|----------|
| DNASC era moderna | `NOV/DNRES/` | 29 | 1996–2022 | 734 |
| DNASC era antiga | `ANT/DNRES/` | variável | 1994–1995 | 109 |
| **Total** | | | **1994–2022** | **843** |

- Extensão: `.dbc` ou `.DBC` dependendo do ano
- Ano mais recente no FTP: **2022** (2023 ausente em 07/mar/2026)
- Grupo DNR (por residência): presente em `ANT/DNRES/` como prefixo `DNR{UF}` — não existe separação de grupo na era moderna

### 5.2 OpenDATASUS

Inacessível (HTTP 403). Não utilizado no pipeline.

---

## 6. ARTEFATOS E PROBLEMAS IDENTIFICADOS

| Campo | Artefato | Detalhe | Correção |
|-------|----------|---------|----------|
| Todas as colunas | Chegam como `factor` via `read.dbc` | Comportamento padrão da biblioteca | Converter tipos explicitamente no pipeline |
| `DTNASC` e datas (era moderna) | Formato `DDMMYYYY` sem separador | Ex: `"25012022"` | Padronizar para `Date` ou string ISO |
| `DATA_NASC` (era 1994–1995) | Formato `YYYYMMDD` (invertido em relação à era moderna) | Ex: `"19940810"` | Converter para `DDMMYYYY` ao fazer rename → `DTNASC` |
| `DATA_CART` (era 1994–1995) | Formato `YYYYMMDD`; 98,8% dos registros com valor `"00000000"` | Data de registro em cartório | Converter formato ao mapear → `DTCADASTRO` |
| `CODPAISRES` | Codificação desconhecida (valor `"1"` — não é IBGE 6 dígitos) | Verificar com `TABPAIS.DBF` | A investigar no pipeline |
| `CODMUNNASC`, `CODMUNRES`, `CODESTAB`, `CODMUNNATU` | Leading zeros preservados no `.dbc` | OK — não há artefato | Garantir tipo `character` no Parquet |

---

## 7. DICIONÁRIO OFICIAL

### 7.1 Fontes localizadas

| Fonte | Arquivo | Cobertura | Localização |
|-------|---------|-----------|-------------|
| Dicionário era moderna | `Estrutura_SINASC_para_CD.pdf` | Duas estruturas: atual e "até 2005" | `ftp://.../SINASC/NOV/DOCS/` |
| Dicionário era antiga | `NASC98.HLP` | 1994–1998, todas as variáveis documentadas | `ftp://.../SINASC/ANT/DOCS/` |
| Tabela de municípios | `CADMUN.DBF` | 5.652 municípios, 28 colunas (geocoordenadas, regiões de saúde) | `ftp://.../SINASC/NOV/TABELAS/` |
| Tabela de países | `TABPAIS.DBF` | 264 países | idem |
| Tabela de ocupações | `TABOCUP.DBF` | 3.564 ocupações (CBO) | idem |
| Tabela de UFs | `TABUF.DBF` | 27 UFs | idem |
| Tabela de CID-10 | `CID10.DBF` | 14.198 códigos | idem |

### 7.2 Completude

Ambos os dicionários cobrem todas as variáveis presentes nos respectivos períodos. O `NASC98.HLP` inclui descrição semântica completa de cada campo da era 1994–1998, confirmando o mapeamento para a nomenclatura moderna (ver seção 9).

---

## 8. CRITÉRIOS DE PRONTIDÃO — FASE 2

Conforme `strategy-expansion-pt.md`, seção 3, para avançar à Fase 3 (Decisão):

| # | Critério | Status |
|:-:|----------|--------|
| 1 | Estrutura dos dados documentada (colunas, tipos, encoding) | ✅ Concluído (seção 3.3) |
| 2 | Artefatos identificados (lista com campo, valor esperado, valor encontrado) | ✅ Concluído (seção 6) |
| 3 | Formatos comparados campo a campo (.dbc vs CSV) | ⚠️ Parcial — OpenDATASUS S3 bloqueado; FTP documentado |
| 4 | Volume preciso mapeado (número de arquivos, tamanho total) | ✅ Concluído (seção 5.1) |
| 5 | Dicionário localizado (mesmo que incompleto — lacunas documentadas) | ✅ Concluído (seção 7) |
| 6 | Este documento escrito (`docs/sinasc/exploration-pt.md`) | ✅ Concluído |

---

## 9. DECISÕES ESTRUTURANTES

### 9.1 Formato fonte

**Decisão:** FTP DATASUS (`.dbc`)

**Alternativa rejeitada:** OpenDATASUS S3 (CSV)

**Motivo:** OpenDATASUS retornou HTTP 403 em todos os padrões de URL testados (07/mar/2026). A API DEMAS (`apidadosabertos.saude.gov.br`) está fora do ar (HTTP 404). FTP DATASUS é a única via acessível e cobre o período histórico completo (1994–2022), incluindo os anos ausentes no OpenDATASUS.

---

### 9.2 Cobertura temporal

**Decisão:** 1994–2022 (cobertura máxima disponível no FTP)

**Alternativa rejeitada:** 1996–presente

**Motivo:** Os arquivos de 1994–1995 estão acessíveis em `ANT/DNRES/` com prefixo `DNR{UF}`. Excluí-los implicaria perda de dois anos do único registro nacional de nascimentos. A diferença de schema (era 1994–1995) é gerenciável via mapeamento de nomenclatura (ver 9.5).

---

### 9.3 Particionamento

**Decisão:** `sinasc/ano=YYYY/uf=XX/`

**Motivo:** Consistente com os demais módulos do projeto. Permite queries eficientes por corte temporal ou geográfico sem varrer o dataset completo. Granularidade UF é o menor denominador comum disponível nos arquivos fonte.

---

### 9.4 Grupos a incluir

**Decisão:** Apenas `DNASC` (nascimentos por local de ocorrência)

**Alternativa rejeitada:** incluir `DNR` (por residência)

**Motivo:** Na era moderna (`NOV/DNRES/`), não há separação de grupos — todos os arquivos são DNASC. O prefixo `DNR` existe apenas em `ANT/DNRES/` para 1994–1995 e coexiste com os arquivos DNASC do mesmo período. Incluir DNR criaria duplicidade de registros. O grupo de residência pode ser derivado via `CODMUNRES` a partir dos microdados de ocorrência.

---

### 9.5 Estratégia de schema

**Decisão:** Schema unificado com mapeamento de nomenclatura para 1994–1995

**Alternativas rejeitadas:** multi-schema por era; exclusão de 1994–1995

**Motivo:** Os dois dicionários oficiais (`NASC98.HLP` e `Estrutura_SINASC_para_CD.pdf`) permitem mapeamento completo e fundamentado entre as nomenclaturas. O pipeline aplica `rename()` nos 20 campos mapeados e converte `DATA_NASC` de `YYYYMMDD` para `DDMMYYYY` ao unificar com `DTNASC`. Campos sem equivalente nacional são mantidos ou descartados conforme tabela abaixo.

**Mapeamento de nomenclatura: era 1994–1995 → era moderna**

| Campo 1994–1995 | Campo moderno | Observação |
|----------------|---------------|------------|
| `CODIGO` | `NUMERODN` | ID sequencial da DN |
| `LOCAL_OCOR` | `LOCNASC` | |
| `MUNI_OCOR` | `CODMUNNASC` | Codificação IBGE idêntica |
| `ESTAB_OCOR` | `CODESTAB` | Campo local em 1994–95; nacional a partir de 2001 |
| `DATA_NASC` | `DTNASC` | Formato invertido: `YYYYMMDD` → `DDMMYYYY` |
| `SEXO` | `SEXO` | |
| `PESO` | `PESO` | |
| `RACACOR` | `RACACOR` | |
| `APGAR1` | `APGAR1` | |
| `APGAR5` | `APGAR5` | |
| `GESTACAO` | `GESTACAO` | |
| `TIPO_GRAV` | `GRAVIDEZ` | |
| `TIPO_PARTO` | `PARTO` | |
| `PRE_NATAL` | `CONSULTAS` | |
| `IDADE_MAE` | `IDADEMAE` | |
| `INSTR_MAE` | `ESCMAE` | |
| `MUNI_MAE` | `CODMUNRES` | |
| `FIL_VIVOS` | `QTDFILVIVO` | |
| `FIL_MORTOS` | `QTDFILMORT` | |
| `UFINFORM` | `UFINFORM` | |

**Campos de 1994–1995 sem equivalente nacional (fonte: `NASC98.HLP`):**

| Campo | Decisão | Justificativa |
|-------|---------|---------------|
| `CARTORIO` | Manter como coluna extra | Código do cartório de registro civil; sem equivalente na era moderna |
| `DATA_CART` | Manter como coluna extra | Data de registro em cartório; semanticamente próximo de `DTCADASTRO`, mas com cobertura de ~1,2% dos registros |
| `AREA` | Manter como coluna extra | Área administrativa estadual; **explicitamente não faz parte da base nacional** segundo o dicionário |
| `BAIRRO_MAE` | Manter como coluna extra | Bairro de residência; **explicitamente não faz parte da base nacional** |
| `CRS_MAE` | Manter como coluna extra | Coordenadoria Regional de Saúde; **explicitamente não faz parte da base nacional** |
| `CRS_OCOR` | Manter como coluna extra | Idem |
| `ETNIA` | Descartar | Campo vestigial: 1 valor único (`100`), 99,99% NA; substituído por `RACACOR=5` (indígena) na era moderna |
| `FIL_ABORT` | Descartar | 100% NA no arquivo de 1994 |
| `NUMEXPORT` | Descartar | **Dado para controle interno** (textual no dicionário); 100% NA |
| `CRITICA` | Descartar | **Dado para controle interno** (textual no dicionário); 100% NA |

---

### 9.6 Estrutura de destino no R2

**Prefixo:** `sinasc/`

**Particionamento:** `sinasc/ano=YYYY/uf=XX/`

**Nomes de arquivo:** `part-0.parquet` (arquivo único por partição, padrão Arrow)

**Exemplo de caminho completo:** `sinasc/ano=2022/uf=DF/part-0.parquet`

**Arquivos auxiliares:** `sinasc/manifest.json` (metadados de integridade, gerado ao final do pipeline)

---

### 9.7 Infraestrutura e tempo de bootstrap

**Servidor:** Hetzner CX21 (2 vCPU, 4 GB RAM, 40 GB SSD) — suficiente com folga
- Volume fonte estimado: ~5,4 GB (843 arquivos `.dbc`, média ~7 MB/arquivo)
- Volume Parquet estimado: ~2,2 GB (~40% do fonte)
- Espaço total necessário (fonte + saída + buffer): ~14 GB → CX21 adequado

**Dependências R no servidor:**
- `read.dbc` — leitura de arquivos `.dbc`
- `arrow` — escrita em Parquet
- `curl` — download FTP
- `dplyr` — manipulação (renomear colunas, schema unificado)
- `rclone` — upload para R2

**Tempo de bootstrap estimado:** ~1,5–2,5 horas
- Estimativa baseada em taxa FTP DATASUS de 1–2 MB/s + 30% de overhead de processamento
- Referência: SI-PNI Agregados (702 arquivos `.dbf`, ~45 MB total) → 4h40; SINASC tem arquivos maiores mas download é gargalo único (sem etapa jq/JSONL)
- Estimativa conservadora: **2 horas** no Hetzner CX21

---

*Última atualização: 07/mar/2026 — **Fases 2, 3 e 4 concluídas.** FTP mapeado (843 arquivos, 1994–2022), 12 schemas históricos identificados, mapeamento de nomenclatura 1994–1995 concluído. Bootstrap executado com sucesso: 783 arquivos, 85.033.402 registros, 0 erros, 117 min. Pipeline: `scripts/pipeline/sinasc-pipeline-r.R`. Controle: `data/controle_versao_sinasc.csv`.*
