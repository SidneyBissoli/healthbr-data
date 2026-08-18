# Exploração: SIM — Sistema de Informações sobre Mortalidade

> Documento de exploração da Fase 2 — SIM.
> Criado em 18/ago/2026.
>
> **Artefato obrigatório da Fase 2** conforme `strategy-expansion-pt.md`, seção 3.
> Inclui: visão geral, vias de acesso, estrutura dos dados, artefatos encontrados,
> volume, comparação de formatos e decisões estruturantes (Fase 3).
>
> **Scripts de exploração:** `scripts/exploration/sim-01-explore.R` (versão canônica,
> `read.dbc`, roda na VPS/RStudio) e `scripts/exploration/sim-01-explore.py`
> (equivalente Python — `datasus-dbc` + `dbfread`/`polars` — com o qual os números
> deste documento foram de fato produzidos, num PC Windows sem `read.dbc`; a
> semântica de leitura do R — apara de espaços, vazio → NA — foi conferida com
> `foreign::read.dbf`, o leitor que `read.dbc` usa internamente).

---

## 1. VISÃO GERAL

| Propriedade              | Valor                                                              |
|--------------------------|--------------------------------------------------------------------|
| Nome oficial             | Sistema de Informações sobre Mortalidade (SIM)                     |
| Órgão responsável        | SVS/CGIAE — Ministério da Saúde; disseminação DATASUS               |
| Documento base           | Declaração de Óbito (DO)                                           |
| Granularidade            | 1 linha = 1 óbito (DO)                                             |
| Período coberto          | 1979–presente (CID-9 1979–1995; CID-10 1996–presente; preliminares 2025–2026) |
| Frequência               | Anual (1 arquivo por UF de **residência** × ano); preliminares atualizados ao longo do ano |
| Volume estimado          | ~1,5 milhão de óbitos/ano (2024: 1.532.015); ~50 milhões acumulados 1979–2026 |
| Prefixo R2 proposto      | `sim/` (sub-datasets `sim/dores/` e, num 2º sprint, `sim/dofet/`)  |
| Fase atual               | **2 — Exploração concluída; 3 — decisões propostas (abaixo)**       |

**Por que este módulo:** o SIM é a fonte oficial de mortalidade do país e o
denominador/numerador de indicadores básicos (TMI com o SINASC, mortalidade
por causa, esperança de vida). As alternativas (`microdatasus`, `pysus`) leem o
FTP a cada uso; o PCDaS tem acesso restrito. É a extensão natural do que já
publicamos (SINASC/SIH em `.dbc`), com o mesmo formato de fonte e a mesma
mecânica de pipeline.

---

## 2. VIAS DE ACESSO AOS DADOS

### 2.1 FTP DATASUS (via principal — única com a série completa)

```
Base: ftp://ftp.datasus.gov.br/dissemin/publicos/SIM/
```

**Raiz `SIM/` (listada em 18/ago/2026):**

| Diretório      | Conteúdo                                                                 |
|----------------|--------------------------------------------------------------------------|
| `CID10/`       | Era CID-10, 1996–2024 (finais): `DORES/`, `DOFET/`, `DOCS/`, `TAB/`, `TABELAS/` |
| `CID9/`        | Era CID-9, 1979–1995: `DORES/`, `DOFET/`, `DOIGN/`, `DOCS/`, `TAB/`, `TABELAS/` |
| `PRELIM/`      | **Dados preliminares** 2025 e 2026: `DORES/`, `DOFET/` (mesmos nomes de arquivo da era CID-10) |
| `1996_`, `1997_1995` | Vazios (resquício)                                                  |

**Subdiretórios de dados:**

| Caminho              | Arquivos | Tamanho | Padrão de nome                         | Conteúdo |
|----------------------|:--------:|:-------:|----------------------------------------|----------|
| `CID10/DORES/`       | 812      | 4,46 GiB | `DO{UF}{AAAA}.dbc` (`.DBC` em 2007, 2010–2012) | Óbitos **não fetais** por UF de residência, 1996–2024 (783 arquivos = 27 UF × 29 anos) **+ 29 `DOBR{AAAA}.dbc`** (consolidado Brasil, 2,22 GiB) |
| `CID9/DORES/`        | 466      | 722 MiB | `DOR{UF}{AA}.DBC`                      | Idem, 1979–1995 (449 UF + 17 `DORBR{AA}`); TO só a partir de 1989 |
| `PRELIM/DORES/`      | 56       | 325 MiB | `DO{UF}{AAAA}.dbc`                     | 2025 (28 arq., 252 MiB) e 2026 (28 arq., 73 MiB) — 27 UF + BR; mtime 27–28/jul/2026 |
| `CID10/DOFET/`       | 128      | 437 MiB | `DOFET{AA}`, `DOEXT{AA}`, `DOINF{AA}`, `DOMAT{AA}` (1996–2024), `DOREXT{AA}` (2013–2024) | Arquivos **nacionais** (1/ano): fetais, causas externas, infantis, maternos, residentes no exterior |
| `CID9/DOFET/`        | 51       | 123 MiB | `DOFET{AA}`, `DOEXT{AA}`, `DOINF{AA}` (1979–1995) | Idem, era CID-9 |
| `PRELIM/DOFET/`      | 10       | 25 MiB  | os 5 tipos × 2025/2026                 | Preliminares dos nacionais |
| `CID9/DOIGN/`        | 1        | 9 KiB   | `DORIG95.DBC` (143 linhas)             | Óbitos com UF de residência ignorada, 1995 |

**Documentação e tabelas:**

| Caminho | Conteúdo |
|---------|----------|
| `CID10/DOCS/Estrutura_do_SIM_2025.pdf` (07/2025) | **Dicionário oficial vigente** (campos, tipos, tamanhos, valores válidos) |
| `CID10/DOCS/Estrutura_SIM_para_CD.pdf`, `Estrutura_SIM_Anterior.pdf` | Estruturas 2006 e anteriores (inclui `NUMERODO`, que **não** vem nos arquivos públicos) |
| `CID10/DOCS/Docs_Tabs_CID10.zip`, `Legislacao_PDF.pdf`, `Portaria.pdf` | Documentação complementar |
| `CID10/TAB/OBITOS_CID10_TAB.zip` (10 MB), `CNVS_CID10_v2019.rar` | Definições TabWin (.def/.cnv) |
| `CID10/TABELAS/` | `CADMUN.DBF`, `CID10.DBF`, `CIDCAP10.DBF`, `TABOCUP.DBF`, `TABPAIS.DBF`, `TABUF.DBF` |
| `CID9/DOCS/MORT98.HLP`, `MTAB16M.pdf`, `Docs-Tabs-CID9.zip` | Documentação da era CID-9 |
| `CID9/TABELAS/` | `CID9.DBF`, `CIDBR.DBF`, `TABMUN.DBF`, `TABOCUP.DBF`, `TABETNIA.DBF`, … |

O servidor FTP é IIS (listagem estilo Windows): o **download é case-insensitive**
(`DOFET24.DBC` e `DOFET24.dbc` devolvem o mesmo arquivo), mas a caixa da
extensão varia entre anos na listagem — o pipeline deve resolver nomes a partir
da listagem, não de um padrão fixo.

### 2.2 OpenDATASUS — não usado

O portal lista o SIM (`DO_BDD`), mas a Fase 1 e o precedente do SINASC (S3
com HTTP 403) tornam o FTP a única via confiável e com série completa
(1979–presente + preliminares). Não explorado além disso.

### 2.3 Calendário de publicação (observado nos mtimes)

- Ano final `N` aparece em `CID10/DORES/` em **dezembro de N+1** (2022 → 22/dez/2023;
  2023 → 19/dez/2024; 2024 → 23/dez/2025).
- Preliminares de N+1 e N+2 ficam em `PRELIM/DORES/`, **regravados periodicamente**
  (2025 e 2026 com mtime 27–28/jul/2026); quando o ano fecha, o arquivo com o
  **mesmo nome** migra para `CID10/DORES/` e some do `PRELIM/`.
- Republicações em massa acontecem (567 arquivos com mtime 31/jan/2020; todos os
  `DOBR` regravados em jan–fev/2025) — o sync-check por tamanho/MD5 cobre isso.

---

## 3. FAMÍLIA DE ARQUIVOS E O QUE CADA UM CONTÉM

Verificado com os arquivos de 2024 (nacional `DOBR2024`, 1.532.015 linhas) e
1994/1996 (todas as UFs + BR):

| Arquivo | Linhas 2024 | Relação com `DO{UF}` (DORES) | Conclusão |
|---------|:-----------:|------------------------------|-----------|
| `DOBR{AAAA}` | 1.532.015 | **= união exata das 27 UFs** (1994: 887.594 = 887.594; 1996: 908.883 = 908.883; mesmo schema) | Redundante — **não publicar** |
| `DOEXT{AA}` (causas externas) | 159.534 | 100 % dos `CONTADOR` estão no DOBR; = linhas com `CAUSABAS` V–Y (159.534) | Subconjunto — **não publicar** (usuário filtra) |
| `DOINF{AA}` (infantis) | 30.020 | 100 % no DOBR; = linhas com `IDADE` < 1 ano (30.020) | Subconjunto — **não publicar** |
| `DOMAT{AA}` (maternos) | 1.326 | 100 % no DOBR; `CAUSABAS` capítulo O | Subconjunto — **não publicar** |
| `DOFET{AA}` (fetais) | 24.364 | **0 %** no DOBR — o DORES só tem `TIPOBITO = 2`; fetais (`TIPOBITO = 1`) só existem aqui | **Complementar** — candidato a `sim/dofet/` |
| `DOREXT{AA}` (residentes no exterior, 2013+) | 562 | 0 % no DOBR — `CODMUNRES` = `900{país}`, coluna extra `CODPAISRES`; óbitos ocorridos no Brasil de residentes no exterior | Complementar, minúsculo (12 arquivos, 0,5 MiB) — opcional/futuro |
| `DORIG95` | 143 | UF de residência ignorada (só 1995) | Curiosidade histórica — não publicar |

Os arquivos por UF são **por residência** (`DOSP2024`: 100 % `CODMUNRES` = 35…;
`CODMUNOCOR` inclui 26 outras UFs), e todas as linhas têm `DTOBITO` no ano do
arquivo. `CONTADOR` é sequencial **por arquivo** (1…n) até 2017 e um
identificador **nacional-anual** (não sequencial, comum a DORES/DOEXT/DOINF/DOMAT)
de 2018 em diante — serve de chave só dentro do mesmo ano.

---

## 4. COBERTURA DO DORES

| Era | Diretório | Arquivos UF | Anos | Nota |
|-----|-----------|:-----------:|------|------|
| CID-9 | `CID9/DORES/` | 449 | 1979–1995 | 26 UF até 1988 (TO nasce em 1989): 27×17 − 10 = 449 |
| CID-10 | `CID10/DORES/` | 783 | 1996–2024 | 27 UF × 29 anos, sem lacunas |
| Preliminar | `PRELIM/DORES/` | 54 | 2025–2026 | 27 UF × 2; muda a cada republicação |
| **Total** | | **1.286** | **1979–2026** | + 48 `DOBR`/`DORBR` ignorados |

---

## 5. ESTRUTURA DOS DADOS (DORES)

### 5.1 Evolução do schema — 13 schemas em 48 anos (AC, todos os anos)

| Anos | Cols | Mudança em relação ao anterior |
|------|:----:|--------------------------------|
| 1979–1994 | 48 | Schema CID-9: `contador`, `CARTORIO`, `REGISTRO`, `DATAREG`, `TIPOBITO`, `DATAOBITO`, `ESTCIVIL`, `SEXO`, `DATANASC`, `IDADE`, `LOCOCOR`, `CODIGO`, `MUNIOCOR`, `MUNIRES`, `BAIRES`, `AREARES`, `OCUPACAO`, `NATURAL`, `INSTRUCAO`, `OCUPPAI`, `INSTRPAI`, `OCUPMAE`, `IDADEMAE`, `INSTRMAE`, `FILHVIVOS`, `FILHMORT`, `SEMANGEST`, `TIPOGRAV`, `TIPOPARTO`, `PESONASC`, `ASSISTMED`, `ATESTANTE`, `EXAME`, `CIRURGIA`, `NECROPSIA`, `OBITOFE1`, `OBITOFE2`, `CAUSABAS`, `TIPOVIOL`, `TIPOACID`, `FONTINFO`, `ACIDTRAB`, `LOCACID`, `CRITICA`, `NUMEXPORT`, `CRSOCOR`, `CRSRES`, `UFINFORM` |
| 1995 | 50 | + `RACACOR`, `ETNIA` (100 % vazios) |
| **1996–2000** | **40** | **Troca de era (CID-10, DO nova):** 25 colunas novas (`DTOBITO`, `DTNASC`, `ESTCIV`, `ESC`, `OCUP`, `CODBAIRES`, `CODMUNRES`, `CODMUNOCOR`, `ESCMAE`, `QTDFILVIVO`, `QTDFILMORT`, `GRAVIDEZ`, `GESTACAO`, `PARTO`, `OBITOPARTO`, `PESO`, `OBITOGRAV`, `OBITOPUERP`, `LINHAA–D`, `LINHAII`, `CIRCOBITO`, `FONTE`), 35 removidas |
| 2001 | 41 | + `CODESTAB`, `ATESTANTE`; − `CODBAIRES` |
| 2002–2005 | 43 | + `CODBAIRES`, `UFINFORM` |
| 2006–2008 | 54 | + `CONTADOR` (maiúsculo), `HORAOBITO`, `CODBAIOCOR`, `TPASSINA`, `DTATESTADO`, `TPPOS`, `DTINVESTIG`, `CAUSABAS_O`, `DTCADASTRO`, `FONTEINV`, `DTRECEBIM`, `CB_PRE`; − `contador` |
| 2009–2010 | 59 | + `contador` (minúsculo de novo), `ORIGEM`, `NUMERODN`, `MORTEPARTO`, `DTCADINF`, `TPOBITOCOR`, `DTCADINV`; − `CONTADOR`, `TPASSINA` |
| 2011 | 62 | + `CONTADOR`, `COMUNSVOIM`, `DTRECORIG`, `DTRECORIGA`, `CAUSAMAT`, `ESC2010`, `ESCMAE2010`, `STDOEPIDEM`, `STDONOVA`; − `contador`, `CODBAIRES`, `CODBAIOCOR`, `NUMERODN`, `UFINFORM`, `CB_PRE` |
| 2012 | 77 | + `CODMUNCART`, `CODCART`, `NUMREGCART`, `DTREGCART`, `SERIESCFAL`, `ESCMAEAGR1`, `ESCFALAGR1`, `SERIESCMAE`, `SEMAGESTAC`, `TPMORTEOCO`, `EXPDIFDATA`, `DIFDATA`, `DTCONINV`, `DTCONCASO`, `NUDIASOBIN` |
| 2013 | 73 | − `ESCMAEAGR1`, `ESCFALAGR1`, `DTRECORIGA`, `EXPDIFDATA` |
| 2014–2017 | 88 | + `CODMUNNATU`, `ESTABDESCR`, `CB_PRE`, `CRM`, `NUMEROLOTE`, `STCODIFICA`, `CODIFICADO`, `VERSAOSIST`, `VERSAOSCB`, `ATESTADO`, `DTRECORIGA`, `ESCMAEAGR1`, `ESCFALAGR1`, `NUDIASOBCO`, `FONTES`, `TPRESGINFO`, `TPNIVELINV`, `NUDIASINF`, `FONTESINF`, `ALTCAUSA`; − colunas de cartório e `DTRECORIG` |
| 2018 | 88 | mesma lista, ordem diferente |
| **2019–2026** | **87** | − `CRM`. **Estável** (inclui os preliminares 2025–2026) |

Colunas comuns a **todos** os anos (13): `ACIDTRAB`, `ASSISTMED`, `CAUSABAS`,
`CIRURGIA`, `EXAME`, `IDADE`, `IDADEMAE`, `LOCOCOR`, `NATURAL`, `NECROPSIA`,
`OCUPMAE`, `SEXO`, `TIPOBITO`. Comuns à era CID-10 (1996–2026): 38.

Todos os campos DBF são `C` (caractere) em todos os anos — nenhum campo
numérico/data nativo. Nas eras 1979–2005 as larguras dos campos DBF são
"artificiais" (≈ tamanho do nome da coluna; ex.: `TIPOBITO` C(8) com valor `2`),
com padding de espaços à direita: `read.dbc`/`foreign` apara e devolve `NA`
para vazio, portanto o Parquet sai limpo (conferido: 0 valores com espaço em
`DODF2024` após `read.dbf`).

### 5.2 Transições críticas de formato (valores)

| Campo | 1979–1990 | 1991 | 1992–1995 | 1996–2005 | 2006–presente |
|-------|-----------|------|-----------|-----------|---------------|
| Data do óbito | `DATAOBITO` **AAMMDD com dia 00** (`790600`) | `DATAOBITO` **AAMM** (`9108`) | `DATAOBITO` AAMMDD (parciais AA / AAMM ocorrem) | `DTOBITO` **DDMMAAAA** (parciais em 1996–98) | `DTOBITO` DDMMAAAA |
| Data de nascimento | `DATANASC` **100 % vazia** | vazia | `DATANASC` **AAAAMMDD** | `DTNASC` DDMMAAAA | `DTNASC` DDMMAAAA |
| Município de residência | `MUNIRES` **7 dígitos** (IBGE c/ dígito) | idem | idem | `CODMUNRES` **7 dígitos** | `CODMUNRES` **6 dígitos** |
| Causa básica | `CAUSABAS` **CID-9** 4 chars (`8199`, `436X`) | idem | idem | `CAUSABAS` **CID-10** 3–4 chars | idem |
| Ocupação | `OCUPACAO` 3 dígitos | idem | idem | `OCUP` **5 dígitos** (CBO-94) | `OCUP` **6 dígitos** (CBO-2002) |
| Escolaridade | `INSTRUCAO` (1 dígito) | idem | idem | `ESC` (anos de estudo) | `ESC` + `ESC2010` (nível, 2011+) |
| Estado civil | `ESTCIVIL` (0–4) | idem | idem | `ESTCIV` (1–5, 9) | idem |
| Sexo | `0/1/2` | idem | `1/2/9` (1995) | `0/1/2` | `1/2` (+ `0`/`9` raros) |
| Idade | `IDADE` 3 dígitos (unidade + quantidade) | idem | idem | idem | idem — **estável desde 1979** |
| Causas múltiplas (`LINHAA`…`LINHAII`) | — | — | — | colunas existem mas **100 % vazias em 1996–1998**; preenchidas de 1999 em diante (`*I499*I490`) | preenchidas |
| Identificador | `contador` 1…n por arquivo | idem | idem | idem (`contador` até 2005) | `CONTADOR`/`contador` (ver §5.3); nacional-anual desde 2018 |

Outros marcos: `RACACOR` só de 1996 (100 % vazia em 1995–1997 no AC);
`CODESTAB` (CNES 7 dígitos) de 2001; `HORAOBITO`, `DTCADASTRO`, `DTATESTADO`
de 2006; `CODMUNOCOR` 7→6 dígitos junto com `CODMUNRES` em 2006. `NUMERODO`
**não existe** em nenhum arquivo público (é do banco interno/CD; a "Estrutura do
SIM" a lista, mas o FTP a omite).

### 5.3 A coluna `contador`/`CONTADOR`

| Anos | Nome |
|------|------|
| 1979–2005 | `contador` |
| 2006–2008 | `CONTADOR` |
| 2009–2010 | `contador` |
| 2011–2026 | `CONTADOR` |

Num dataset unificado (`open_dataset(..., unify_schemas = TRUE)`) isso rende
**duas colunas**, cada uma NA nos anos da outra. Arrow trata como colunas
distintas; DuckDB (`union_by_name`) as funde silenciosamente (nomes
case-insensitive). O SINASC padronizou para `CONTADOR` (`padronizar_contador()`),
o SIH não renomeia nada. Ver decisão em §9.6.

### 5.4 Colunas efetivamente vazias na era atual (AC 2024)

100 % NA: `ESTABDESCR`, `EXAME`, `CIRURGIA`, `CB_PRE`, `CAUSAMAT`, `NUDIASOBIN`,
`TPRESGINFO`, `NUDIASINF`, `FONTESINF`. > 90 % NA (só óbitos infantis/fetais/
maternos as preenchem): bloco materno (`IDADEMAE`, `ESCMAE*`, `OCUPMAE`,
`QTDFIL*`, `GRAVIDEZ`, `SEMAGESTAC`, `GESTACAO`, `PARTO`, `OBITOPARTO`, `PESO`,
`TPMORTEOCO`, `OBITOGRAV`, `OBITOPUERP`), investigação (`DTCADINV`, `TPOBITOCOR`,
`DTCONINV`, `FONTES`, `TPNIVELINV`, `DTCADINF`, `MORTEPARTO`, `DTCONCASO`,
`ALTCAUSA`, `NUDIASOBCO`), `ACIDTRAB`. Publicam-se mesmo assim (fidelidade à fonte;
Parquet comprime NA a custo zero).

---

## 6. ARTEFATOS E PROBLEMAS IDENTIFICADOS

1. **Nenhum artefato de tipagem**: tudo é caractere no DBF; zeros à esquerda
   preservados (`CODESTAB` `0010472`, `IDADE` `002`, `PESO` `0630`, `HORAOBITO`
   `0040`). Estratégia "tudo string" funciona sem correções.
2. **Datas parciais e sentinelas** na era CID-9 (dia `00`, só AAMM em 1991,
   `DATANASC` ausente até 1991) e parciais em 1996–1998 — preservar; documentar
   no card.
3. **Descontinuidades de era** (§5.2) — mesmo caso do SIH 1998: preservar como
   publicado, avisar em seção "notas sobre a série histórica".
4. **Caixa da extensão** e **nome igual entre PRELIM e final** — resolvidos por
   listagem no pipeline (§9.8).
5. **`DOBR` e derivados** — redundantes; ignorar (§3).
6. **Padding/vazios** — resolvidos pelo leitor (§5.1).

---

## 7. VOLUME

### 7.1 Arquivos e bytes (fonte `.dbc`, só UF)

| Conjunto | Arquivos | `.dbc` | Parquet estimado (razão ~0,5) |
|----------|:--------:|:------:|:-----------------------------:|
| DORES CID-9 1979–1995 | 449 | 361 MiB | ~180 MiB |
| DORES CID-10 1996–2024 | 783 | 2.289 MiB | ~1,1 GiB |
| DORES PRELIM 2025–2026 | 54 | 159 MiB | ~80 MiB |
| **DORES total** | **1.286** | **2,75 GiB** | **~1,4 GiB** |
| DOFET 1979–2026 (nacional) | 48 | 86 MiB + prelim 3 MiB | ~45 MiB |

Teste Parquet (todas Utf8, zstd): `DODF2024` 1.326 KiB → 764 KiB (0,58);
`DOSP2024` 28,6 MiB → 14,0 MiB (0,49); `DOBR2024` 134 MiB → 64 MiB (0,48);
`DORDF95` 0,53; `DODF1996` 0,52. Maior partição: SP (352 mil linhas/ano, ~14 MiB).

### 7.2 Registros

| Ano | Brasil (linhas) | Fonte |
|-----|:---------------:|-------|
| 1994 | 887.594 | 27 UF + `DORBR94` |
| 1996 | 908.883 | 27 UF + `DOBR1996` |
| 2024 | 1.532.015 | `DOBR2024` |
| DF | 5.244 (1979) → 8.116 (1995) → 8.224 (1996) → 10.851 (2010) → 16.218 (2020) → 15.878 (2024) → 15.103 (2025 prelim) | |
| AC | 1.319 (1979) → 2.263 (1996) → 4.267 (2024) → 1.510 (2026 parcial, mar) | |

Estimativa acumulada 1979–2026: **~50 milhões de óbitos** (14 M na era CID-9,
~34 M em 1996–2024, ~2 M preliminares); fetais ~1,5 M (DOFET: 41,8 mil em 1995,
40,4 mil em 1996, 24,4 mil em 2024).

### 7.3 Tempo de bootstrap estimado

1.286 arquivos de tamanho médio 2,2 MiB — perfil idêntico ao SINASC (783
arquivos → 117 min na VPS). Estimativa **3–4 h** de FTP → Parquet → R2 numa
cpx42, sem paralelismo; leitura `read.dbc` do maior arquivo (SP 2024, 28 MiB)
é de segundos. Não justifica espelho `_raw/` nem `SIM_WORKERS`.

---

## 8. DICIONÁRIOS

- `Estrutura_do_SIM_2025.pdf` (CID10/DOCS) — dicionário vigente: 87 campos com
  tipo/tamanho/valores. Confirma `IDADE` (1º dígito unidade: 0 ign., 1 min/h,
  2 dias, 3 meses, 4 anos, 5 = 100+), `SEXO` (`1/2`, `0/9` ign.), `ESC2010`,
  `LOCOCOR` (1–6, 9), `ORIGEM` (1 Oracle, 2 banco estadual, 3 …), `STDOEPIDEM`,
  `STDONOVA`, `TPPOS` (investigado), `OPOR_DO` (não presente nos arquivos).
- `Estrutura_SIM_Anterior.pdf` / `Estrutura_SIM_para_CD.pdf` — 2006 e anteriores.
- `CID9/DOCS/MORT98.HLP` + `MTAB16M.pdf` — era CID-9 (nomes `MUNIRES`,
  `INSTRUCAO`, `TIPOVIOL`, …).
- `TABELAS/*.DBF` (municípios, CID, ocupações, países) — candidatos a um futuro
  `sim/dicionarios/`, análogo ao `sipni/dicionarios/`.

---

## 9. DECISÕES ESTRUTURANTES (Fase 3 — propostas)

### 9.1 Formato fonte

| Decisão | Alternativa rejeitada | Motivo |
|---------|-----------------------|--------|
| **`.dbc` do FTP** (`CID9/DORES`, `CID10/DORES`, `PRELIM/DORES`) | OpenDATASUS | Série completa 1979–presente + preliminares só no FTP; mesmo formato e leitor dos módulos SINASC/SIH |

### 9.2 Escopo

| Decisão | Alternativa rejeitada | Motivo |
|---------|-----------------------|--------|
| **Sprint 1: DORES (`DO{UF}`), 1979–presente + preliminares** | Incluir `DOBR`, `DOEXT`, `DOINF`, `DOMAT` | São união/subconjuntos exatos do DORES (§3): duplicariam 2,2 GiB sem informação nova |
| **Sprint 2: DOFET (fetais, nacional/ano)** como `sim/dofet/` | Ignorar fetais | Não estão no DORES; TMI/mortalidade perinatal precisa deles; 48 arquivos, 90 MiB |
| DOREXT: **fora do escopo por ora** (documentado) | Publicar já | 12 arquivos, 0,5 MiB, 2013+; ganho marginal < custo de mais um sub-dataset no sync/manutenção. Reavaliar sob demanda |

### 9.3 Namespace e particionamento

| Decisão | Alternativa rejeitada | Motivo |
|---------|-----------------------|--------|
| **`sim/dores/ano=YYYY/uf=XX/part-0.parquet`** e **`sim/dofet/ano=YYYY/part-0.parquet`**; ids planos `sim-dores`, `sim-dofet` | `sim/ano=…` (sem sub-prefixo) | Regra de namespace do projeto: sistema com vários sub-datasets ganha prefixo pai + sub-prefixos curtos, e nunca se aninha um sub-dataset sob um prefixo com `ano=` (Arrow recursaria). "DORES"/"DOFET" são os nomes com que DATASUS, `microdatasus` e `pysus` designam esses arquivos |
| Partição anual por UF (como SINASC) | `ano/mes/uf` (como SIH) | Fonte é anual; maior partição tem 352 mil linhas / 14 MiB — manejável |
| DOFET sem `uf=` | Derivar UF de `CODMUNRES` | O Ministério publica um arquivo nacional; fatiar por UF seria transformação nossa. Fica `ano=` |

### 9.4 Tipos no Parquet

**Tudo string** (padrão do projeto). Fonte já é 100 % caractere; nenhuma
conversão.

### 9.5 Schema

**Um Parquet por arquivo-fonte com o schema daquele arquivo** (13 schemas ao
longo da série); unificação por `unify_schemas` na leitura, como SINASC/SIH.
Sem superset forçado, sem renomear colunas de era (`DATAOBITO`≠`DTOBITO`,
`MUNIRES`≠`CODMUNRES` ficam como estão — mesmo tratamento do SIH 1998).

### 9.6 `contador`/`CONTADOR` — **decisão a confirmar pelo mantenedor**

| Opção | Efeito | Precedente |
|-------|--------|-----------|
| **A (recomendada): manter a caixa como publicada** | Duas colunas no dataset unificado; coalescer no `healthbR` | SIH (não renomeia nada); política de fidelidade à fonte + reprodutibilidade 1.2.0 |
| B: renomear `contador` → `CONTADOR` | Uma coluna; renomeação só de caixa, valores intactos | SINASC (`padronizar_contador()`), listado no CLAUDE.md como exceção só para o rename 1994–95 |

O rascunho do pipeline implementa **A**; B seria uma linha (`padronizar_contador`)
mais uma frase no card e no CLAUDE.md.

### 9.7 Dados preliminares — publicar, com marcação

| Decisão | Alternativa rejeitada | Motivo |
|---------|-----------------------|--------|
| **Publicar `PRELIM/DORES` no mesmo prefixo**, com `source_status = "preliminar"` no metadado `healthbr`, no manifesto e no CSV de controle, e tabela "anos preliminares" no card | Só anos finais | Mortalidade recente é o uso mais demandado (a lacuna de ~15 meses do dado final foi o problema da pandemia); é o que o Ministério publica, marcado como tal. Alternativa `sim/dores-prelim/` rejeitada: o usuário teria de unir dois datasets e o ano migra de prefixo ao fechar |

Mecânica: o final tem precedência (se `DO{UF}{AAAA}` existe em `CID10/DORES/`,
o `PRELIM/` é ignorado); a migração PRELIM→final ou uma republicação do PRELIM
muda tamanho/MD5 → sync-check marca `outdated` → manutenção apaga a linha do CSV
→ pipeline regrava a partição (política "sem versionamento": o preliminar
deixa de existir, como no FTP).

### 9.8 Resolução de arquivos por listagem

O pipeline lista os três diretórios de DORES (ou DOFET) no início e monta um
mapa `nome_upper → (url, tamanho, status final|preliminar)`; a grade
`ano × UF` é gerada a partir do mapa (cobre a caixa da extensão, TO < 1989,
`DOIGN`, PRELIM e novos anos sem mexer em constante — `SIM_ANO_FIM` só como
override). O `sync_check.py` fará a mesma resolução (final > prelim) para
comparar tamanhos.

### 9.9 Cobertura-alvo e sprints

- **Sprint 1 — DORES completo 1979–presente + PRELIM** (1.286 arquivos, ~2,75 GiB, ~3–4 h).
- **Sprint 2 — DOFET** (48 arquivos + 2 prelim; mesmo script com `SIM_TIPO=DOFET`).
- Manutenção semanal: entra em `AUTOMATED_DATASETS` do sync-check/maintenance
  como `sim-dores` (e `sim-dofet`), depois de `sinasc`.

### 9.10 Reprodutibilidade (política 1.2.0)

Cada Parquet leva o metadado `healthbr` (`dataset`, `source_url`, `source_file`,
`source_hash_md5`, `source_size_bytes`, `source_status`, `download_date`,
`pipeline_script`, `pipeline_version` = 1.2.0, `git_commit`); manifesto por
partição com os mesmos campos + `sha256`/`record_count`; CSV de controle
`data/controle_versao_sim_dores.csv` (e `_sim_dofet.csv`) com MD5, contagens,
`pipeline_version`, `git_commit`, `source_status`. Sem `_raw/`, sem histórico.

### 9.11 Estrutura de destino no R2

```
healthbr-data/
  sim/
    dores/
      manifest.json
      README.md
      ano=1979/uf=AC/part-0.parquet … ano=1995/uf=TO/part-0.parquet   (CID-9)
      ano=1996/uf=AC/part-0.parquet … ano=2024/uf=TO/part-0.parquet   (CID-10)
      ano=2025/uf=AC/part-0.parquet … ano=2026/uf=TO/part-0.parquet   (preliminar)
    dofet/
      manifest.json
      README.md
      ano=1979/part-0.parquet … ano=2026/part-0.parquet
```

---

## 10. QUESTÕES EM ABERTO

1. **§9.6** — caixa de `contador` (A vs B): decisão do mantenedor antes do bootstrap.
2. **Schemas dos anos não amostrados por UF**: a evolução foi levantada com o AC
   (todos os anos) e conferida com DF em 11 anos; assume-se schema uniforme entre
   UFs num mesmo ano (verdadeiro nas 27 UFs de 1994 e 1996). O pipeline não
   depende disso (schema por arquivo).
3. **DOFET**: só 3 anos amostrados (1995: 50 cols; 1996: 56 cols — híbrido com
   nomes CID-9 e CID-10; 2024: 98 cols = DORES + cartório + `LINHAx_O` + `MEDICO`
   + `DTRECORIG`). Levantar a evolução completa antes do Sprint 2.
4. **`sim/dicionarios/`** (TABELAS + Estrutura PDFs): fora deste ciclo.
5. **Frequência de republicação do PRELIM**: os dois anos foram regravados no
   mesmo dia (27–28/jul/2026); a cadência não é conhecida — o sync-check semanal
   dirá.

---

## 11. SCRIPTS EXPLORATÓRIOS DE REFERÊNCIA

| Script | O que faz |
|--------|-----------|
| `scripts/exploration/sim-01-explore.R` | Listagem FTP (curl), download das amostras, `read.dbc`, evolução de schema (AC 1979–2026), formatos de valores, DOBR × UFs, subconjuntos (DOEXT/DOINF/DOMAT/DOFET/DOREXT), teste Parquet |
| `scripts/exploration/sim-01-explore.py` | Mesma exploração em Python (`datasus-dbc` + `dbfread` + `polars`), usada para produzir os números deste documento em ambiente sem `read.dbc` |

---

## 12. PRÓXIMOS PASSOS

1. Confirmar §9.6 (contador) e §9.7 (preliminares).
2. Revisar/parse-checkar o rascunho `scripts/pipeline/sim-pipeline-r.R`
   (`SIM_TIPO=DORES|DOFET`, resolução por listagem, política 1.2.0) e testar
   com uma amostra pequena na VPS (`SIM_UFS=AC,DF SIM_ANOS=1979,1996,2024,2026`).
3. Sprint 1 (bootstrap DORES) via `launch-bootstrap-vps.sh`; validar contagens
   contra `DOBR{AAAA}` (soma das UFs = BR) e TABNET.
4. `sync_check.py`: `check_sim()` (3 diretórios, final > prelim), ids `sim-dores`/
   `sim-dofet`; `prepare_maintenance.py`/`run-maintenance.sh`: ordem
   `sinasc → sim-dores → …`; `SIM_ANO_FIM` opcional.
5. Card bilíngue `guides/dataset-cards/sim-dores.md` com seções "notas sobre a série
   histórica" (§5.2), "anos preliminares" (§9.7) e "Reproducibility & provenance";
   README, `reference-pipelines-pt.md` (nova seção), CLAUDE.md (tabela de datasets).
6. Sprint 2 (DOFET) após levantar a evolução de schema (§10.3).

---

*Última atualização: 18/ago/2026 — **Fase 2 concluída; Fase 3 proposta (aguarda §9.6/§9.7).***
