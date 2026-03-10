# Exploração: SIH — Sistema de Informações Hospitalares

> Documento de exploração da Fase 2 — SIH.
> Criado em 08/mar/2026.
>
> **Artefato obrigatório da Fase 2** conforme `strategy-expansion-pt.md`, seção 3.
> Inclui: visão geral, vias de acesso, estrutura dos dados, artefatos encontrados,
> volume, comparação de formatos e decisões estruturantes (Fase 3).
>
> **Script de exploração:** `scripts/exploration/sih-01-explore.R`

---

## 1. VISÃO GERAL

| Propriedade              | Valor                                                              |
|--------------------------|--------------------------------------------------------------------|
| Nome oficial             | Sistema de Informações Hospitalares do SUS (SIH/SUS)               |
| Órgão responsável        | DATASUS / Ministério da Saúde                                      |
| Documento base           | Autorização de Internação Hospitalar (AIH)                         |
| Granularidade            | 1 linha = 1 internação (RD) ou 1 procedimento (SP)                 |
| Período coberto          | 1992–presente (FTP DATASUS)                                        |
| Frequência               | Mensal (1 arquivo por tipo × UF × mês de competência)              |
| Volume estimado          | ~11 milhões de AIH/ano (anos recentes)                             |
| Prefixo R2 definido      | `sih/`                                                             |
| Fase atual               | **2 — Exploração**                                                 |

**Por que este módulo:**
SIH é o maior sistema de informações hospitalares do SUS. Com ~11M de
internações/ano e até 113 variáveis por registro, é insumo básico para
estudos de morbidade hospitalar, avaliação de serviços, custos e indicadores
como taxa de mortalidade hospitalar e ICSAP. As alternativas existentes
(microdatasus, pysus) não persistem dados; PCDaS tem acesso restrito.
Um dataset Parquet pré-processado no R2 preenche uma lacuna real.

---

## 2. VIAS DE ACESSO AOS DADOS

### 2.1 FTP DATASUS (via principal — única viável para microdados)

```
Base: ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/
```

**Estrutura do diretório raiz SIHSUS (confirmada 08/mar/2026):**

| Diretório             | Conteúdo                                              |
|-----------------------|-------------------------------------------------------|
| `199201_200712/`      | Era antiga — Dados/ (9.132 arquivos .dbc)             |
| `200801_/`            | Era moderna — Dados/ (22.255 arquivos .dbc)           |
| `CSV/`                | Formato alternativo CSV (apenas 2008+, ~2.078 arquivos)|
| `DBF/`                | Formato alternativo DBF (apenas 2008+, ~2.078 arquivos)|
| `XML/`                | Formato alternativo XML (apenas 2008+, ~2.076 arquivos)|
| `Arquivos_MTBR/`      | 29 arquivos MTBR (movimentação?)                      |
| `2008`–`2014`         | Diretórios anuais avulsos                             |
| `MHJ_14_16/`          | Arquivos MHJ (2014-2016)                              |

**Diretórios auxiliares:**

| Caminho                                    | Conteúdo                                       |
|--------------------------------------------|-------------------------------------------------|
| `200801_/Auxiliar/`                        | TAB_SIH.zip (5,4 MB, 887 arquivos de dicionários) + 3 ZIPs históricos |
| `200801_/Doc/`                             | IT_SIHSUS_1603.pdf (instrução técnica)          |
| `199201_200712/Auxiliar/`                  | TAB_SIH_199201-199712.zip (dicionários da era antiga) |

### 2.2 OpenDATASUS (S3) — NÃO DISPONÍVEL

**Confirmado na Fase 1 (Recon):** o portal OpenDATASUS não disponibiliza
microdados do SIH convencional. O único dataset SIH-relacionado no portal
é sobre ocupação hospitalar COVID-19 (sistema e-SUS, separado do SIH/SUS).

### 2.3 Formatos alternativos no FTP

Além do `.dbc` (padrão), existem CSV, DBF e XML na raiz do SIHSUS, mas
apenas para a era moderna (2008+) e com ~2.078 arquivos (vs 22.255 em .dbc).
Provavelmente contêm apenas o tipo RD. A via `.dbc` é a mais completa e a
única que cobre 1992–presente.

---

## 3. TIPOS DE ARQUIVO

O SIH publica **6 tipos** de arquivo .dbc, cada um com série própria por
UF × mês:

| Tipo | Nome                      | Padrão          | Cols (modern) | Rows/mês (DF) | Descrição                                |
|:----:|---------------------------|-----------------|:------------:|:--------------:|------------------------------------------|
| RD   | AIH Reduzida              | `RD{UF}{AAMM}`  | 113          | ~18K           | **Dataset principal** — internações processadas e validadas |
| SP   | Serviços Profissionais    | `SP{UF}{AAMM}`  | 36           | ~320K          | Atos médicos detalhados por procedimento (granularidade maior) |
| RJ   | AIH Rejeitada             | `RJ{UF}{AAMM}`  | 90           | ~0,5K          | Internações rejeitadas no processamento   |
| ER   | Erros de Rejeição         | `ER{UF}{AAMM}`  | 13           | ~0,8K          | Motivos de erro das AIHs rejeitadas       |
| CH   | Cadastro Hospitalar       | `CH{BR}{AAMM}`  | 7            | ~4,5K          | Cadastro de estabelecimentos (apenas BR, 38 arquivos) |
| CM   | (a confirmar)             | `CM{BR}{AAMM}`  | ?            | ?              | 38 arquivos, apenas BR                    |

**Contagem de arquivos por tipo e era:**

| Tipo | Era moderna (2008–2026) | Era antiga (1992–2007) | Total  |
|:----:|:-----------------------:|:----------------------:|:------:|
| RD   | 5.858                   | 5.165                  | 11.023 |
| SP   | 5.856                   | 3.420                  | 9.276  |
| RJ   | 5.697                   | 547                    | 6.244  |
| ER   | 4.768                   | 0                      | 4.768  |
| CH   | 38                      | 0                      | 38     |
| CM   | 38                      | 0                      | 38     |
| **Total** | **22.255**          | **9.132**              | **31.387** |

**Escopo do pipeline:** Apenas **RD (AIH Reduzida)** — 11.023 arquivos,
1992–presente. Os demais tipos (SP, RJ, ER) são expansões futuras opcionais.

---

## 4. COBERTURA DO RD

### 4.1 Era moderna (200801_/Dados/)

| Propriedade | Valor |
|-------------|-------|
| Arquivos RD | 5.858 |
| UFs         | 27    |
| Período     | 2008–2026 |
| Arquivo/ano | 324 (27 UFs × 12 meses; 2026 parcial com 25 arquivos) |

### 4.2 Era antiga (199201_200712/Dados/)

| Propriedade | Valor |
|-------------|-------|
| Arquivos RD | 5.165 |
| UFs         | 27    |
| Período     | 1992–2007 |
| Arquivo/ano | ~320-324 (algumas lacunas pontuais por UF/mês) |

### 4.3 Cobertura combinada

**11.021 arquivos RD**, 27 UFs, 1992–2026 (35 anos).
Esperado teórico: 27 × 12 × 35 = 11.340. Diferença (~319 arquivos) decorre
de meses/UFs indisponíveis nos anos iniciais e de 2026 estar incompleto.

---

## 5. ESTRUTURA DOS DADOS (RD)

### 5.1 Evolução do schema

O schema do RD mudou significativamente ao longo de 35 anos. A exploração
identificou **pelo menos 10 schemas distintos** (testando DF, Jan de cada ano):

| Ano  | Cols | ANO_CMPT | Datas      | Diagnóstico | Procedimento | CNES | RACA_COR | DIAGSEC1-9 | Nota |
|:----:|:----:|:--------:|:----------:|:-----------:|:------------:|:----:|:--------:|:----------:|------|
| 1992 | 35   | 2 dig    | ? (NA)     | CID-9 (6ch) | 8 dig        | —    | —        | —          | |
| 1995 | 41   | 2 dig    | YYMMDD (6) | CID-9 (6ch) | 8 dig        | —    | —        | —          | |
| 1997 | 42   | 2 dig    | YYMMDD (6) | CID-9 (6ch) | 8 dig        | —    | —        | —          | |
| **1998** | **41** | **4 dig** | **YYYYMMDD (8)** | **CID-10 (3-4ch)** | 8 dig | — | — | — | **Transição maior** |
| 1999 | 52   | 4 dig    | YYYYMMDD   | CID-10      | 8 dig        | —    | —        | —          | +UTI, gestão |
| 2000 | 60   | 4 dig    | YYYYMMDD   | CID-10      | 8 dig        | —    | —        | —          | |
| 2004 | 69   | 4 dig    | YYYYMMDD   | CID-10      | 8 dig        | ✓    | —        | —          | **+CNES** |
| 2007 | 75   | 4 dig    | YYYYMMDD   | CID-10      | 8 dig        | ✓    | —        | —          | |
| **2008** | **86** | 4 dig | YYYYMMDD | CID-10 | **10 dig (SIGTAP)** | ✓ | **✓** | — | **Troca de era** |
| 2012 | 93   | 4 dig    | YYYYMMDD   | CID-10      | 10 dig       | ✓    | ✓        | —          | |
| **2015** | **113** | 4 dig | YYYYMMDD | CID-10 | 10 dig | ✓ | ✓ | **✓** | **Estabiliza** |
| 2020-2026 | 113 | 4 dig | YYYYMMDD | CID-10 | 10 dig | ✓ | ✓ | ✓ | Estável |

### 5.2 Transições críticas

1. **1998 — Transição CID-9 → CID-10:** Mudança simultânea de ANO_CMPT
   (2→4 dígitos), formato de datas (YYMMDD→YYYYMMDD), e sistema de
   codificação diagnóstica (CID-9→CID-10). Os dados de 1992–1997 usam CID-9
   (códigos de 6 caracteres); a partir de 1998, CID-10 (3-4 caracteres).

2. **2004 — Aparecimento do CNES:** O campo CNES (Cadastro Nacional de
   Estabelecimentos de Saúde) aparece a partir de 2004. Antes disso,
   estabelecimentos eram identificados por CGC_HOSP.

3. **2008 — Troca de era FTP e SIGTAP:** Coincide com a mudança de diretório
   no FTP (199201_200712/ → 200801_/). Procedimentos mudam de 8 dígitos
   para 10 dígitos (código SIGTAP). RACA_COR aparece.

4. **2015 — Schema estabiliza em 113 colunas:** Adição de DIAGSEC1-DIAGSEC9
   (até 9 diagnósticos secundários individuais, além do DIAG_SECUN compactado).
   A partir de 2015, o schema permanece em 113 colunas.

### 5.3 Colunas do schema moderno (113 cols, 2015–presente)

**Identificação da AIH (6):** UF_ZI, ANO_CMPT, MES_CMPT, ESPEC, CGC_HOSP, N_AIH

**Paciente (9):** IDENT, CEP, MUNIC_RES, NASC, SEXO, COD_IDADE, IDADE,
RACA_COR, ETNIA

**Internação (14):** DT_INTER, DT_SAIDA, DIAS_PERM, MORTE, MUNIC_MOV,
COBRANCA, NATUREZA, NAT_JUR, CAR_INT, GESTAO, NACIONAL, CNES, CNPJ_MANT,
COMPLEX

**Diagnósticos (12):** DIAG_PRINC, DIAG_SECUN, CID_ASSO, CID_MORTE,
CID_NOTIF, DIAGSEC1–DIAGSEC9

**Procedimentos e tipos (13):** PROC_REA, PROC_SOLIC, NUM_PROC, QT_DIARIAS,
DIAR_ACOM, CBOR, CNAER, TPDISEC1–TPDISEC9

**Valores financeiros (17):** VAL_SH, VAL_SP, VAL_SADT, VAL_RN, VAL_ACOMP,
VAL_ORTP, VAL_SANGUE, VAL_SADTSR, VAL_TRANSP, VAL_OBSANG, VAL_PED1AC,
VAL_TOT, VAL_UTI, US_TOT, VAL_SH_FED, VAL_SP_FED, VAL_SH_GES, VAL_SP_GES

**UTI (10):** UTI_MES_IN, UTI_MES_AN, UTI_MES_AL, UTI_MES_TO, MARCA_UTI,
UTI_INT_IN, UTI_INT_AN, UTI_INT_AL, UTI_INT_TO, MARCA_UCI, VAL_UCI

**Gestão e controle (12+):** FINANC, FAEC_TP, REGCT, GESTOR_TP, GESTOR_COD,
GESTOR_CPF, GESTOR_DT, TOT_PT_SP, CPF_AUT, SEQUENCIA, REMESSA, IND_VDRL,
RUBRICA, VINCPREV, INFEHOSP, AUD_JUST, SIS_JUST

**Maternidade (7):** HOMONIMO, NUM_FILHOS, INSTRU, CONTRACEP1, CONTRACEP2,
GESTRISCO, INSC_PN, SEQ_AIH5

### 5.4 Colunas comuns a TODAS as eras (31 cols)

UF_ZI, ANO_CMPT, MES_CMPT, ESPEC, CGC_HOSP, N_AIH, IDENT, CEP, MUNIC_RES,
NASC, SEXO, PROC_REA, VAL_SH, VAL_SP, VAL_SADT, VAL_RN, VAL_ORTP,
VAL_SANGUE, VAL_TOT, US_TOT, DT_INTER, DT_SAIDA, DIAG_PRINC, COBRANCA,
NATUREZA, MUNIC_MOV, COD_IDADE, IDADE, DIAS_PERM, MORTE, NUM_PROC

Estas 31 colunas formam o "core" disponível em toda a série histórica.

### 5.5 Colunas exclusivas de eras anteriores (descontinuadas)

| Coluna     | Era       | Descrição provável                |
|------------|-----------|-----------------------------------|
| UTI_TOTAL  | 1992–1997 | Total de diárias UTI (substituído por UTI_MES_* a partir de 1999) |
| US_SH … US_SANGUE | 1992–1997 | Valores em Unidade de Serviço (descontinuados com nova tabela de valores) |
| SEMIPLEN   | 1992–1997 | Flag de gestão semiplena           |
| COD_SEG    | ~2004     | Código de segmento (aparece brevemente) |

---

## 6. ARTEFATOS E PROBLEMAS IDENTIFICADOS

### 6.1 Formato .dbc preserva dados corretamente

Diferentemente dos CSVs do OpenDATASUS, o formato `.dbc` preserva:
- Zeros à esquerda em campos de código (MUNIC_RES=6 dígitos, CEP=8, CNES=7)
- Tipos originais (campos lidos como `factor` pelo R)
- Sem artefatos de float (não há sufixos `.0` nos códigos)

**Consequência para o pipeline:** Não há necessidade de correções de artefatos
como houve no SI-PNI. A estratégia "tudo string no Parquet" funciona
diretamente com a conversão `as.character()` dos fatores.

### 6.2 Incompatibilidade de formatos entre eras

| Campo       | 1992–1997           | 1998–presente          |
|-------------|---------------------|------------------------|
| ANO_CMPT    | 2 dígitos ("95")    | 4 dígitos ("1998")     |
| DT_INTER    | YYMMDD ("940929")   | YYYYMMDD ("19980101")  |
| DT_SAIDA    | YYMMDD ("950103")   | YYYYMMDD ("19980115")  |
| NASC        | YYMMDD ("601217")   | YYYYMMDD ("19601217")  |
| DIAG_PRINC  | CID-9 (6ch, "029599") | CID-10 (3-4ch, "F250")|

**Decisão necessária (Fase 3):** O pipeline preserva os dados como estão
(sem conversão), ou padroniza formatos? O princípio do projeto ("dados como
publicados pelo MS") sugere preservar como estão.

### 6.3 Nascimento com zeros

Na era antiga (1995), o campo NASC pode conter "000000" (data de nascimento
desconhecida). Na era moderna, o equivalente é a ausência de informação.

### 6.4 SEXO com valor 0

Na era antiga, SEXO pode ter valor "0" (não informado), além de "1" (masculino)
e "3" (feminino). A era moderna tem apenas "1" e "3".

---

## 7. VOLUME

### 7.1 Contagem de arquivos RD

| Era     | Arquivos | Período      | Média/ano |
|---------|:--------:|:------------:|:---------:|
| Antiga  | 5.165    | 1992–2007    | ~323      |
| Moderna | 5.858    | 2008–2026    | ~325      |
| **Total** | **11.023** | **1992–2026** | ~324  |

### 7.2 Volume estimado de registros

Amostra DF (Distrito Federal) × Jan:
- 1992: 11.022 registros
- 1995: 11.492
- 2005: 14.486
- 2023: 18.394
- 2024: 19.950

DF é ~1,5% do Brasil. Extrapolando grosseiramente:
~18.000 × 12 meses × (1/0,015) ≈ **14 milhões de AIH/ano** nos anos recentes.
Estimativa acumulada 1992–2025: **300–400 milhões de registros**.

### 7.3 Tamanho estimado em disco

Amostra RD DF Jan/2023: 1.375 KB (.dbc) → 1.046 KB (Parquet string)
Extrapolando: 11.023 arquivos × ~1,5 MB médio ≈ **~16 GB em .dbc** (comprimido).
Em Parquet (string): estimativa **~20-30 GB** para RD completo.

---

## 8. DICIONÁRIOS

### 8.1 TAB_SIH.zip (5,4 MB, 887 arquivos)

Conteúdo principal:

| Tipo | Qtd | Exemplos                                     |
|------|:---:|----------------------------------------------|
| .cnv | 793 | Municípios (BRUFMUNIC, MUNICBR), regiões de saúde, microrregiões IBGE |
| .dbf | 81  | CID-10 (cid10.dbf, S_CID.DBF), SIGTAP (TB_SIGTAP.dbf), CBO (CBO.dbf), CNES (TCNESBR.dbf), fornecedores |
| .def | 4   | Definições TabWin para tabulação              |
| .pdf | 2   | LEIAME.pdf (documentação), IT_SIHSUS_1603.pdf |
| .xlsx| 1   | (a inspecionar)                               |

### 8.2 Dicionários legados

TAB_SIH_199201-199712.zip: dicionários específicos da era antiga (1992–1997),
incluindo tabela de procedimentos anterior ao SIGTAP.

---

## 9. DECISÕES ESTRUTURANTES (Fase 3)

> **Critério de prontidão (Fase 3):** Todas as decisões documentadas com
> alternativa rejeitada e motivo.

### 9.1 Formato fonte

| Decisão        | Alternativa rejeitada | Motivo                                |
|----------------|-----------------------|---------------------------------------|
| **.dbc do FTP** | CSV/DBF/XML do FTP   | .dbc cobre 1992–presente (34 anos completos); CSV/DBF/XML cobrem apenas 2008+. O .dbc preserva dados originais sem artefatos. |

### 9.2 Escopo do pipeline

| Decisão | Alternativa rejeitada | Motivo |
|---------|----------------------|--------|
| **Apenas RD** (11.023 arquivos) | RD + SP + RJ + ER (31.387 arquivos) | RD é o dataset de pesquisa por excelência. SP tem volume 18× maior que RD (320K vs 18K/mês para DF). Incluir SP triplicaria o tempo e armazenamento sem demanda demonstrada. SP, RJ, ER ficam como expansões futuras opcionais. |

### 9.3 Estratégia de schema

| Decisão | Alternativa rejeitada | Motivo |
|---------|----------------------|--------|
| **Schema unificado por superset** | Schemas separados por era | O pipeline do SINASC (12 schemas → 1 unificado) demonstrou que `unify_schemas=TRUE` do Arrow funciona bem. Colunas ausentes em eras anteriores ficam como NULL. A alternativa (schemas separados) fragmentaria o dataset e dificultaria consultas longitudinais. |

### 9.4 Tipos no Parquet

| Decisão | Alternativa rejeitada | Motivo |
|---------|----------------------|--------|
| **Tudo string** | Tipagem seletiva (numeric para valores, integer para contagens) | Padrão do projeto. Preserva códigos com zeros à esquerda e evita ambiguidade. Pesquisadores fazem a conversão de tipos no momento da análise. |

### 9.5 Particionamento

| Decisão | Alternativa rejeitada | Motivo |
|---------|----------------------|--------|
| **`sih/ano=YYYY/mes=MM/uf=XX/`** | `sih/ano=YYYY/uf=XX/` (sem mês) | O SIH é mensal por natureza. Agregar todos os meses de um ano em um único Parquet criaria arquivos de ~130K+ linhas por UF (vs ~18K). O particionamento por mês mantém arquivos manejáveis e permite consultas por período específico. |

### 9.6 Tratamento de formatos legados (1992–1997)

| Decisão | Alternativa rejeitada | Motivo |
|---------|----------------------|--------|
| **Preservar dados como publicados pelo MS** | Converter datas YYMMDD→YYYYMMDD, CID-9→CID-10 | Princípio do projeto: dados são publicados exatamente como o Ministério da Saúde os disponibiliza. Conversões seriam feitas no pacote R `healthbR`, não no pipeline de dados. ANO_CMPT de 2 dígitos ("95") é preservado como string. |

### 9.7 Cobertura-alvo

| Decisão | Alternativa rejeitada | Motivo |
|---------|----------------------|--------|
| **RD completo 1992–presente** (em 2 sprints) | Apenas era moderna 2008+ | O SIH tem cobertura desde 1992 e a era antiga (1992–2007) é relevante para estudos longitudinais de morbidade hospitalar. O custo marginal de incluir a era antiga é aceitável (5.165 arquivos adicionais). |

**Sprint 1 — Era moderna (2008–presente):** 5.858 arquivos RD. Schema mais
estável (86–113 cols). Pipeline nasce aqui.

**Sprint 2 — Era antiga (1992–2007):** 5.165 arquivos RD. Schemas variáveis
(35–75 cols), formatos de data e diagnóstico diferentes. Incorpora ao mesmo
prefixo `sih/` no R2.

### 9.8 Estrutura de destino no R2

```
healthbr-data/
  sih/
    manifest.json
    README.md
    ano=1992/
      mes=01/
        uf=AC/
          part-0.parquet
        uf=AL/
          part-0.parquet
        ...
      mes=02/
        ...
    ...
    ano=2026/
      mes=01/
        uf=AC/
          part-0.parquet
        ...
```

### 9.9 Infraestrutura e tempo de bootstrap

**Servidor:** Hetzner CX21 (2 vCPU, 4 GB RAM, 40 GB disco) — ou maior se
necessário. Estimativa de espaço: ~30 GB para Parquet final + ~16 GB para
fontes .dbc intermediárias = ~46 GB. Pode ser necessário CPX31 (80 GB disco)
ou processamento em lotes com limpeza intermediária.

**Dependências R:** read.dbc, arrow, curl, dplyr, fs, glue, stringr

**Tempo de bootstrap estimado:**
- Sprint 1 (5.858 arquivos, era moderna): ~4–8 horas
  - Gargalo: download FTP (~1–2 MB/s) + leitura .dbc
  - Referência: SINASC (783 arquivos) → 117 min; SIH Sprint 1 tem ~7,5× mais arquivos
- Sprint 2 (5.165 arquivos, era antiga): ~3–6 horas
  - Arquivos menores (era mais simples)
- **Total estimado: 8–14 horas**

---

## 10. QUESTÕES EM ABERTO

1. **Schema exato por ano:** A exploração testou 13 anos-amostra. Os anos
   intermediários não testados (1993, 1994, 1996, 2001-2003, 2005-2006,
   2009-2011, 2013-2014) podem ter schemas ligeiramente diferentes.
   O pipeline deve detectar colunas dinamicamente (padrão SINASC).

2. **Formatos alternativos (CSV/DBF/XML):** Cobrem apenas 2008+. Não foram
   inspecionados em detalhe. Se o .dbc apresentar problemas, podem servir
   de fallback para a era moderna.

3. **Tipos CH e CM:** Não são parte do escopo RD, mas merecem documentação
   futura.

4. **Tamanho real dos arquivos .dbc:** A extrapolação baseada em DF é
   grosseira. UFs grandes (SP, MG, BA) terão arquivos muito maiores.
   Impacta a estimativa de disco necessário.

5. **Anos com lacunas:** Alguns anos têm <324 arquivos (ex: 1994 tem 318).
   Identificar quais UFs/meses estão ausentes.

---

## 11. SCRIPTS EXPLORATÓRIOS DE REFERÊNCIA

| Script                         | O que explora                                      |
|--------------------------------|----------------------------------------------------|
| `sih-01-explore.R`             | Mapeamento FTP, download de amostras RD de 3 eras, comparação de schemas, artefatos, Parquet test, tipos SP/RJ/ER/CH, dicionários TAB_SIH.zip |

---

## 12. PRÓXIMOS PASSOS

Com a exploração documentada (Fase 2) e as decisões formalizadas (Fase 3),
o módulo está pronto para avançar para a **Fase 4 (Pipeline):**

1. Desenvolver script de pipeline em `scripts/pipeline/sih-pipeline-r.R`
2. Testar com amostra pequena (DF, 1 mês de cada era)
3. Sprint 1: bootstrap completo RD 2008–presente no Hetzner
4. Validar contagens contra PCDaS/literatura
5. Sprint 2: bootstrap RD 1992–2007
6. Criar controle de versão (`data/controle_versao_sih.csv`)
7. Gerar manifesto (`sih/manifest.json`)
8. Documentar pipeline no `reference-pipelines-pt.md`

**Nota para a Fase 5 (Publicação):** O README do R2 e o dataset card no
Hugging Face devem comunicar de forma explícita a descontinuidade estrutural
em 1998: mudança de CID-9 para CID-10, de datas YYMMDD para YYYYMMDD, e de
ANO_CMPT de 2 para 4 dígitos. O dataset preserva os dados como publicados
pelo Ministério da Saúde (sem conversões), portanto o pesquisador precisa
tratar essa transição na análise. Essa informação deve constar em seção
dedicada da documentação (ex: "Known limitations" ou "Notas sobre a série
histórica").

---

*Última atualização: 08/mar/2026 — **Fases 2 e 3 concluídas.***
