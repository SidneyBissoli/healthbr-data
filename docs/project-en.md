# Project: *Redistribution and Harmonization of Brazilian Public Health System (SUS) Vaccination Data*

> This document was written to be read by a human or an LLM (such as
> Claude Code) that needs to understand the project without having participated
> in previous conversations. It is the source of truth on decisions,
> architecture, and current state.
>
> Last updated: 2026-02-22 (v3 — integration of coverage technical notes)
>
> **⚠️ Note:** The Portuguese version (`project-pt.md`) was updated to v4 on
> 2026-03-01 with significant changes: 4 datasets published on R2, dataset
> cards on HF, synchronization system, updated architecture and task list.
> This English version needs to be updated to match.

---

## 1. WHAT IS THIS PROJECT

Redistribution and harmonization of SUS (SI-PNI) vaccination data covering
**the entire historical series from 1994 to 2025+**, served for free in
Parquet format via S3 protocol on Cloudflare R2.

The project integrates three distinct sources into a single access point:

1. **Historical aggregated data (1994-2019)** — administered doses and
   vaccination coverage by municipality, from the legacy SI-PNI (.dbf files
   on the DATASUS FTP server).

2. **Individual-level microdata (2020-2025+)** — records of administered
   doses (1 row = 1 dose), from the new SI-PNI integrated with RNDS (JSONs
   on the OpenDATASUS S3).

3. **Population data (denominators)** — live births from SINASC and
   municipal estimates from IBGE, needed to calculate vaccination coverage
   from the microdata.

The project has three components:

1. **Data pipeline** (this repository) — runs on a VPS, downloads raw
   sources, converts to Parquet, uploads to R2.

2. **Data and dictionary repository** — Parquets on R2 + original
   Ministry of Health dictionaries published as reference.

3. **R package `sipni`** (separate repository) — allows the researcher to
   build vaccination coverage time series for any vaccine and geography
   with a few lines of code.

---

## 2. WHY THIS PROJECT EXISTS

### The problem

SUS vaccination data is fragmented across two incompatible systems,
distributed in hard-to-use formats, and without unified documentation:

**Aggregated data (1994-2019):**  
- .dbf files on the DATASUS FTP (TabWin format from the 1990s)  
- Opaque vaccine codes without an easily accessible dictionary  
- Structure that changes over time (7→12 columns in doses; 9→7 in coverage)  
- Municipality code changes size (7→6 digits in 2013)  
- Dictionaries (.cnv) in a separate directory, TabWin proprietary format  

**Microdata (2020-2025+):**  
- Published in CSV and JSON on OpenDATASUS  
- CSV has artifacts: numeric fields converted to float (`.0` suffix),
  leading zeros lost in various codes (race/color, ZIP code, etc.)  
- JSON preserves types correctly (everything as string, leading zeros intact)  
- 56 actual columns in both formats (CSV adds an empty 57th due to trailing
  `;`), with an official dictionary of 60 fields  
- Require significant cleaning before any analysis  

**To build a 1994-2025 vaccination coverage time series, a researcher
currently needs to:**  
1. Download ~1500 .dbf files from FTP + hundreds of JSONs/CSVs from OpenDATASUS  
2. Decode two different vaccine code systems  
3. Harmonize structures that changed over 30 years  
4. Obtain population denominators from a third source (SINASC/IBGE)  
5. Know which doses and age groups to use for each coverage calculation  
6. Handle changes in the IBGE municipality code  

This work is repeated by each researcher, introducing inconsistencies.

### Existing alternatives and their limitations

**Base dos Dados (basedosdados.org):**  
- Covers vaccination, but only municipal aggregated data (doses/coverage)  
- Does not have individual-level microdata  
- Recent data behind a paywall (freemium model)  

**PCDaS (Fiocruz):**  
- Covers SIM, SINASC, SIH. Does not cover routine vaccination.  

**microdatasus (R package):**  
- Focused on legacy DATASUS systems (.dbc via FTP)  
- Does not cover the new SI-PNI (2020+)  
- Does not cover aggregated vaccination data (PNI)  

**TabNet/TabWin:**  
- Web/desktop interface for tabulating aggregated data  
- Does not allow bulk downloads, not programmatic  

### Value proposition

This project offers:  
- **Complete historical series 1994-2025+** in a single format (Parquet)  
- **Individual-level microdata** (2020+) with 56 named and typed fields  
- **Harmonized aggregated data** (1994-2019) with decoded codes  
- **Population denominators** for coverage calculation  
- **Original dictionaries** from the Ministry of Health preserved  
- **Monthly updates** (automated pipeline)  
- **Free** (no paywall on recent data)  
- **Available offline** (download via S3, no intermediary)  
- **R package** that delivers vaccination coverage with a few lines of code  

---

## 3. ARCHITECTURE

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  1. VPS (Hetzner, €4/month)                                      │
│     ├── Monthly cron: git pull + Rscript                         │
│     ├── Downloads raw sources (DATASUS FTP + OpenDATASUS S3)     │
│     ├── Converts to partitioned Parquet                          │
│     └── Uploads to R2 via rclone                                 │
│                                                                  │
│  2. Cloudflare R2 (primary storage)                              │
│     └── Serves Parquets via S3 protocol                          │
│     └── Free egress (key difference vs AWS S3)                   │
│                                                                  │
│  3. Hugging Face (mirror for discoverability)                    │
│     └── README points to R2 as primary source                    │
│                                                                  │
│  4. R package "sipni" (consumption)                              │
│     └── Connects to 4 harmonized sources on R2                   │
│     └── Calculates vaccination coverage with correct denominator │
│     └── Delivers time series and ggplot-ready data               │
│                                                                  │
│  5. GitHub (source code)                                         │
│     └── Versions pipeline + package (separate repos)             │
│     └── VPS does git pull and executes                           │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### R2 Structure

```
s3://healthbr-data/sipni/
  microdados/                          ← New SI-PNI (2020-2025+)
    ano=2024/mes=01/uf=AC/
      part-0.parquet
  agregados/                           ← Legacy SI-PNI (1994-2019)
    doses/
      ano=1998/uf=AC/
        part-0.parquet
    cobertura/
      ano=2005/uf=SP/
        part-0.parquet
  populacao/                           ← Denominators
    sinasc/                            ← Live births by municipality
    ibge/                              ← Population estimates
  dicionarios/                         ← Reference (MoH originals)
    microdados/
      dicionario_tb_ria_rotina.json    ← 56 fields from the new SI-PNI
    agregados/
      IMUNO.CNV                        ← Vaccines (doses)
      IMUNOCOB.DBF                     ← Vaccines (coverage)
      DOSE.CNV                         ← Dose types
      FXET.CNV                         ← Age groups
```

### Why not GitHub Actions?

Data volume is too large. ~1.8 GB/month of JSON microdata, plus the aggregated
data. A VPS at €4/month has no time limits, has persistent disk (cache), and cron.

### Why R2 and not S3 or HF directly?

- AWS S3: expensive egress (~$0.09/GB).
- Hugging Face: free, but an AI company that may change its rules.
- Cloudflare R2: S3-compatible, zero egress. If it dies, migrate in hours.

---

## 4. DATA SOURCES

### 4.1 Microdata — New SI-PNI (2020-2025+)

**Origin:** OpenDATASUS (Ministry of Health S3)

**Primary source: JSON**
```
2020-2024: https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{month}_{year}.json.zip
2025+:     https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{month}_{year}_json.zip
```
Where `{month}` = jan, fev, mar, ... (Portuguese) and `{year}` = 4 digits.
**WARNING:** The URL pattern changed in 2025 (`.json.zip` → `_json.zip`). The
pipeline must test both patterns.

**Alternative source: CSV** (kept for reference/fallback)
```
https://arquivosdadosabertos.saude.gov.br/dados/dbbni/vacinacao_{month}_{year}_csv.zip
```

**Why JSON and not CSV?**
Detailed investigation (verificar_json_disponivel.R) revealed that 2020-2024
CSVs contain export artifacts: numeric fields serialized as float (e.g.,
`420750.0` instead of `420750`), with loss of leading zeros in codes such as
race/color (`3` instead of `03`), ZIP code (`89087.0` instead of `89087`).
JSON preserves all values as strings, with leading zeros intact. The 2025 CSV
does not have these artifacts (Ministry fixed the export), but JSON is
preferred for consistency across the entire series. JSON is ~1.3x larger than
CSV (28 GB extra total for 72 months), an acceptable trade-off to eliminate
all zero-reconstruction logic.

**JSON format:** Single-line JSON array (file can exceed 2GB uncompressed).
Requires partial binary reading — R's `readLines()` fails with a string limit
error. Solution: read N bytes with `readBin()`, locate `},{` delimiters
between records, and parse the fragment with `jsonlite`.

**CSV format:** Header present, Latin-1 encoding, `;` delimiter, 56 actual
columns (+ 1 empty artifact from the trailing `;` when parsing).

**Temporal coverage:** 2020 onwards (72 months available as of Feb/2026).
JSON confirmed available for all months from 2020 to 2025.

**Dictionary:** `Dicionario_tb_ria_rotina.pdf` (60 fields, of which 56
exist in the JSONs/CSVs). Validated by cross-referencing CSV × JSON × dictionary.

### 4.2 Aggregated Data — Legacy SI-PNI (1994-2019)

**Origin:** DATASUS FTP  
**Data URL:** `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/`  
**Dictionary URL:** `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/`  

**Format:** .dbf files (dBase III), direct reading with `foreign::read.dbf()`.

**Volume:** 1504 .dbf files (752 coverage CPNI* + 752 doses DPNI*).

**File naming convention:**  
- `CPNIAC05.DBF` → Coverage, Acre, 2005  
- `DPNIRJ16.DBF` → Doses, Rio de Janeiro, 2016  
- `CPNIUF99.DBF` → Coverage consolidated by state, 1999  
- `CPNIBR07.DBF` → Coverage consolidated nationally, 2007  
- `CPNIIG04.DBF` → Coverage of records without a defined state, 2004  

**Temporal coverage:** 1994 to 2019.

**Row-level granularity:**  
- Doses: `year × state × municipality × age_group × vaccine × dose_type → administered_doses`  
- Coverage: `year × state × municipality × (age_group) × vaccine → doses, population, coverage%`  

### 4.3 Population Data (Denominators)

**SINASC** (live births by municipality): DATASUS FTP.
Used as the denominator for coverage in children under 1 year and 1 year old.
For the 1-year-old population, live births from the **previous year** are used (lag).

**IBGE** (municipal population estimates): IBGE website.
Used for other age groups (Census, counts, intercensal projections).

The combination of population sources for the denominator calculation changed
over time and, between 2000-2005, varied by group of states (see section 7).

**Reference technical notes on denominators (project files):**  
- `notatecnica.pdf` and `notatecnicaCobertura.pdf` — detailed rules by
  period, including a table with SINASC and IBGE reference years by state.  
- `Nota_Tecnica_Imunizacoes_Cobertura_desde_1994.pdf` — expanded version with
  target population and vaccine tables.  
- `Imun_cobertura_desde_1994.pdf` — same information in a different format.  

---

## 5. STRUCTURE AND TRANSITIONS OF AGGREGATED DATA

### 5.1 COVERAGE Files (CPNI)

**Three structural eras:**

| Period    | Columns    | Fields                                                         | YEAR      | MUNICIPALITY      |
|:---------:|:----------:|----------------------------------------------------------------|:---------:|:-----------------:|
| 1994-2003 | 9          | ANO, UF, MUNIC, FX_ETARIA, IMUNO, DOSE, QT_DOSE, POP, COBERT   | integer   | 7 digits          |
| 2004-2012 | 9          | (same)                                                         | character | 7 digits (w/ NAs) |
| 2013-2019 | 7          | ANO, UF, MUNIC, IMUNO, QT_DOSE, POP, COB                       | character | 6 digits          |

**Main transition (2013):** FX_ETARIA and DOSE disappear. From 2013 onwards,
each IMUNO code already embeds the correct dose and age group (pre-calculated
composite indicator). Before 2013, granularity was greater.

### 5.2 DOSES Files (DPNI)

**Three structural eras:**

| Period    | Columns    | Additional fields vs 1994-2003                        | YEAR      | MUNICIPALITY |
|:---------:|:----------:|-------------------------------------------------------|:---------:|:------------:|
| 1994-2003 | 7          | ANO, UF, MUNIC, FX_ETARIA, IMUNO, DOSE, QT_DOSE       | integer   | 7 digits     |
| 2004-2012 | 12         | + ANOMES, MES, DOSE1, DOSEN, DIFER                    | character | 7 digits     |
| 2013-2019 | 12         | (same as 2004-2012)                                   | character | 6 digits     |

**Main transition (2004):** ANOMES, MES (monthly granularity) and DOSE1,
DOSEN, DIFER (fields for dropout rate calculation) appear.

### 5.3 Common milestone: municipality code (2013)

In both (CPNI and DPNI), the municipality code changes from 7 to 6 digits in
2013. The 7th digit is the IBGE check digit. The pipeline must truncate to 6
digits for prior years (6 digits without check digit is the IBGE standard).

### 5.4 APIDOS → APIWEB Transition (Jul/2013)

The vaccination registration system changed in July 2013:  
- **APIDOS** (until Jun/2013): DOS-based PNI evaluation system  
- **APIWEB** (from Jul/2013): web system that absorbed APIDOS + SIPNI  

This means that 2013 data may have records from both systems for the same
municipality. From 2013 onwards, SIPNI data (individual-level) is grouped
with SIAPI data and made available in the same aggregated reports. For
exclusive individual-level SIPNI data, the reference was
`http://sipni.datasus.gov.br`.

### 5.5 IMUNO Code Systems

**CRITICAL DISCOVERY:** Coverage and doses use different code systems.

**Doses (DPNI)** → dictionary `IMUNO.CNV` (85 individual vaccines).
Each code identifies a specific vaccine. Examples:  
- `02` = BCG  
- `06` = Yellow Fever  
- `08` = Hepatitis B  
- `52` = Pentavalent (DTP+HB+Hib)  
- `60` = Hexavalent  
- `61` = Rotavirus  

**Coverage (CPNI)** → dictionary `IMUNOCOB.DBF` (26 composite indicators).
Each code represents a coverage metric that may sum multiple vaccines:  
- `072` = Total BCG (routine + leprosy contacts)  
- `073` = Total Hepatitis B (HB + Penta + Hexa combined)  
- `074` = Total Poliomyelitis (OPV + IPV + Hexa + sequential schedule)  
- `080` = Total Penta (Penta + Hexa)  

### 5.6 Vaccine Code Evolution

The IMUNO × year matrix (1994-2019) reveals 65 codes over 26 years, with
three generations of vaccines reflecting schedule replacements:

- **1st generation (1994-2003):** standalone DTP, monovalent Measles, standalone Hib
- **2nd generation (2004-2012):** Tetravalent (DTP/Hib), Rotavirus, Pneumo 10V, Meningo C
- **3rd generation (2013+):** Pentavalent, IPV/OPV sequential, Tetraviral, Hepatitis A

Some codes appear for only 1-3 years (ad hoc campaigns, H1N1, etc.).

---

## 6. MICRODATA STRUCTURE (2020+)

### Technical characteristics

| Property             | JSON (primary source)                       | CSV (alternative)                        |
|----------------------|---------------------------------------------|------------------------------------------|
| Encoding             | **UTF-8**                                   | **Latin-1**                              |
| Structure            | JSON array (single giant line)              | Header + data, **;** delimiter           |
| Columns              | **56** actual columns                       | **56** actual + 1 artifact from trailing ;|
| Types                | All **string** (character)                  | Mixed (some fields as float in 2020-2024)|
| Leading zeros        | **Preserved**                               | **Lost in 2020-2024** (fixed in 2025)    |
| Size (zip)           | ~1.8 GB per month                           | ~1.4 GB per month                        |

### CSV Artifacts (2020-2024) — reason for choosing JSON

| CSV Field               | CSV Value       | JSON Value      | Problem                     |
|-------------------------|-----------------|-----------------|-----------------------------|
| co_municipio_paciente   | `420750.0`      | `420750`        | `.0` suffix                 |
| co_pais_paciente        | `10.0`          | `10`            | `.0` suffix                 |
| nu_cep_paciente         | `89087.0`       | `89087`         | `.0` suffix                 |
| co_estrategia_vacinacao | `1.0`           | `1`             | `.0` suffix                 |
| co_raca_cor_paciente    | `3`             | `03`            | Leading zero lost           |

These artifacts do not exist in 2025 CSVs — the Ministry fixed the export.
But since the pipeline needs to cover 2020-2024, JSON is the safest source
for the entire series.

### Column 57 (artifact — CSV only)

In the CSV, each line ends with `;`, causing the parser to create an empty
57th column. In JSON, this artifact does not exist — there are 56 actual
columns.

### Data types

**Decision: everything as character in Parquet.** JSON already delivers all
fields as strings, preserving leading zeros in codes such as IBGE, CNES, ZIP
code, and race/color. The pipeline converts JSON → Parquet keeping the
character type.

Planned exceptions (future typing in the R package):  
- `dt_*` fields → `Date` type (YYYY-MM-DD format confirmed)  
- Pure numeric fields without leading zeros → `integer` (e.g., `nu_idade_paciente`)  

### Code/description pairs

The Ministry publishes microdata with column pairs (e.g., `co_vacina` +
`ds_vacina`, `co_dose_vacina` + `ds_dose_vacina`). Data is published
exactly as the Ministry provides — without transformations.

### Official typo

Column 17 is named `no_fantasia_estalecimento` (missing the "b" from
"estabelecimento"). This is the official name in the database and in the
JSON. It is not our error.

### Fields missing from CSV/JSON vs dictionary

| Dict | Field                    | Observation                         |
|:----:|-------------------------:|------------------------------------:|
| 13   | st_vida_paciente         | Absent from CSV and JSON            |
| 34   | dt_entrada_datalake      | Ghost field (absent from everything)|
| 38   | co_identificador_sistema | Absent from CSV and JSON            |
| 59   | ds_identificador_sistema | Absent from CSV and JSON            |

**Note:** `dt_deletado_rnds` (dict #58) is present in both formats
(confirmed in the JSON×CSV comparison for Jan/2020), usually empty.
Previously reported as absent from CSV — the inclusion may have occurred
with the addition of the header, or it was read incorrectly in the original
positional mapping. Total columns in the files: **56** in both formats
(same names, confirmed by direct comparison).

### Complete mapping (position → official name, 56 columns)

```
 1  co_documento                        22  co_vacina
 2  co_paciente                         23  sg_vacina
 3  tp_sexo_paciente                    24  dt_vacina
 4  co_raca_cor_paciente                25  co_dose_vacina
 5  no_raca_cor_paciente                26  ds_dose_vacina
 6  co_municipio_paciente               27  co_local_aplicacao
 7  co_pais_paciente                    28  ds_local_aplicacao
 8  no_municipio_paciente               29  co_via_administracao
 9  no_pais_paciente                    30  ds_via_administracao
10  sg_uf_paciente                      31  co_lote_vacina
11  nu_cep_paciente                     32  ds_vacina_fabricante
12  ds_nacionalidade_paciente           33  dt_entrada_rnds (CORRECTED)
13  no_etnia_indigena_paciente          34  co_sistema_origem
14  co_etnia_indigena_paciente          35  ds_sistema_origem
15  co_cnes_estabelecimento             36  st_documento
16  no_razao_social_estabelecimento     37  co_estrategia_vacinacao
17  no_fantasia_estalecimento (typo)    38  ds_estrategia_vacinacao
18  co_municipio_estabelecimento        39  co_origem_registro
19  no_municipio_estabelecimento        40  ds_origem_registro
20  sg_uf_estabelecimento               41  co_vacina_grupo_atendimento
21  co_troca_documento                  42  ds_vacina_grupo_atendimento
                                        43  co_vacina_categoria_atendimento
                                        44  ds_vacina_categoria_atendimento
                                        45  co_vacina_fabricante
                                        46  ds_vacina
                                        47  ds_condicao_maternal
                                        48  co_tipo_estabelecimento
                                        49  ds_tipo_estabelecimento
                                        50  co_natureza_estabelecimento
                                        51  ds_natureza_estabelecimento
                                        52  nu_idade_paciente
                                        53  co_condicao_maternal
                                        54  no_uf_paciente
                                        55  no_uf_estabelecimento
                                        56  dt_deletado_rnds (*)
```

(*) Column 56 identified in the JSON×CSV comparison for Jan/2020. Absent
from the original positional mapping (which assumed 55 columns without a
header). Usually empty.

---

## 7. VACCINATION COVERAGE CALCULATION

### Formula

```
Coverage (%) = (Administered doses of vaccine X, at the indicated dose, in the location and period)
               ÷ (Target population in the same location and period) × 100
```

### Aggregated data (1994-2019)

Coverage is already calculated in the `COBERT` (1994-2012) or `COB`
(2013-2019) fields of CPNI files. The `POP` and `QT_DOSE` fields are also
available for recalculation.

### Microdata (2020-2025+)

Coverage must be calculated from microdata + external denominator. The
numerator is the count of doses of the indicated vaccine/dose, aggregated by
municipality and period. The denominator comes from SINASC (live births) or
IBGE (estimates), depending on the age group.

### Which dose counts for coverage? (complete table)

Each vaccine has a coverage indicator dose, target population, and target
defined by PNI. The rules changed over time as vaccines were replaced in the
schedule.

**Current childhood schedule vaccines (routine):**

| Vaccine               | Target pop. | Coverage dose               | Target | Period        | Numerator: sum of vaccines with the same component  |
|-----------------------|:-----------:|:---------------------------:|:------:|:-------------:|-----------------------------------------------------|
| BCG                   | < 1 year    | SD                          | 90%    | 1994+         | SD routine + SD leprosy contacts                    |
| Hepatitis B           | < 1 year    | D3                          | 95%    | 1994+         | D3 HB + D3 Penta + D3 Hexa                         |
| Hepatitis B (newborn) | < 1 month   | D                           | —      | 2014+         | Dose "D" HB (denominator = LB of the year)          |
| Rotavirus (VORH)      | < 1 year    | D2                          | 90%    | 2006+         | D2 Total Rotavirus                                  |
| Pneumo 10V/13V        | < 1 year    | D3                          | 95%    | 2010+         | D3 Pneumo 10V + D3 Pneumo 13V                      |
| Meningo C             | < 1 year    | D2                          | 95%    | 2010+         | D2 Meningo C                                        |
| Penta (DTP/Hib/HB)    | < 1 year    | D3                          | 95%    | 2nd half 2012+| D3 Penta + D3 Hexa                                  |
| Seq. Sch. IPV/OPV     | < 1 year    | D3                          | 95%    | 2nd half 2012+| D3 OPV when registered as sequential schedule       |
| Poliomyelitis         | < 1 year    | D3                          | 95%    | 1994+         | D3 OPV + D3 IPV + D3 Hexa + D3 Penta inactiv. + D3 Seq.Sch. |
| MMR D1                | 1 year      | D1                          | 95%    | 2000+         | D1 MMR                                              |
| MMR D2                | 1 year      | D2                          | 95%    | 2013+         | D2 MMR + SD MMRV                                    |
| MMRV                  | 1 year      | SD                          | —      | 2013+         | SD MMRV                                             |
| Hepatitis A           | 1 year      | SD                          | —      | 2014+         | SD Hepatitis A                                      |
| Yellow Fever          | < 1 year    | SD/D1                       | 100%   | 1994+         | SD/D1 YF (all municipalities)                       |
| DTP BOOST1            | 1 year      | BOOST1                      | 95%    | 1994+         | BOOST1 DTP                                          |

**Historical vaccines (replaced or discontinued):**

| Vaccine               | Target pop. | Coverage dose  | Target | Period        | Replaced by                            |
|-----------------------|-------------|:--------------:|:------:|:-------------:|----------------------------------------|
| DTP (whole-cell)      | < 1 year    | D3             | 95%    | 1994-2002     | Tetravalent (2003)                     |
| Measles (monovalent)  | < 1 year    | SD             | 95%    | 1994-2002     | MMR at 1 year (2003)                   |
| Haemophilus b (Hib)   | < 1 year    | D3             | 95%    | 1999-2002     | Tetravalent (2003)                     |
| Tetra (DTP/Hib)       | < 1 year    | D3             | 95%    | 2003-2012     | Pentavalent (2012)                     |

**Campaigns (separate records in aggregated data):**

| Vaccine                        | Target pop.        | Dose    | Target | Period        |
|--------------------------------|--------------------|:-------:|:------:|:-------------:|
| Polio campaign (1st round)     | <1 yr (94-99), 0-4 yrs (00-10) | D | 95%  | 1994-2010     |
| Polio campaign (2nd round)     | <1 yr (94-99), 0-4 yrs (00-10) | D | 95%  | 1994-2010     |
| Influenza campaign             | ≥65 (1999), ≥60 (2000-2010)    | D | 80%  | 1999-2010     |
| MMR campaign                   | 1 to 4 years       | D1      | 95%    | 2004          |

**Pregnant women:**

| Vaccine               | Target pop.     | Coverage dose  | Period    |
|-----------------------|:---------------:|:--------------:|:---------:|
| Pregnant (dT + dTpa)  | 12 to 49 years  | D2 + BOOST     | 1994+     |
| Pregnant (dTpa)       | 12 to 49 years  | SD + BOOST     | Jul/2013+ |

**Note on campaigns:** From 2011 onwards, polio and influenza campaign data
began to be recorded only on the PNI website, no longer in the aggregated
FTP files.

### Composite coverage indicators

To calculate coverage by disease (not by product), it is necessary to sum
doses of vaccines with the same component. The official composite indicators
are:

| Composite indicator               | Sum of vaccines                                        |
|-----------------------------------|--------------------------------------------------------|
| Total against tuberculosis        | BCG + BCG-Leprosy (− contacts)                         |
| Total against hepatitis B         | HB + Pentavalent + Hexavalent                          |
| Total against poliomyelitis       | OPV + IPV + Hexavalent                                 |
| Total against pertussis/diph./tet.| Tetravalent + Pentavalent + Hexavalent                 |
| Total against measles and rubella | MMR + MR                                               |
| Total against diphtheria and tetanus | DTP + DTaP + Tetravalent + Penta + Hexa + pediatric DT|
| Total against haemophilus b       | Hib + Tetravalent + Pentavalent + Hexavalent           |

These sums are necessary during vaccine transition years (e.g., 2002
DTP→Tetra, 2012 Tetra→Penta), when the numerator must include both
formulations.

### Dropout rates

The dropout rate measures the proportion of vaccinated individuals who
started the schedule but did not complete it:

```
Dropout rate (%) = (D1 − Dlast) ÷ D1 × 100
```

Calculated for multi-dose vaccines in the childhood schedule:

| Vaccine          | Calculation                    | Period     |
|------------------|-------------------------------|------------|
| Hepatitis B      | (D1 HB+Penta+Hexa − D3) / D1 | in < 1 year|
| Rotavirus        | (D1 − D2) / D1               | in < 1 year, from 2006 |
| Pneumo 10V/13V   | (D1 10V+13V − D3) / D1       | in < 1 year, from 2010 |
| Meningo C        | (D1 − D2) / D1               | in < 1 year, from 2010 |
| Seq. Sch. IPV/OPV| (D1 − D3) / D1               | in < 1 year, from 2nd half 2012 |
| Penta            | (D1 Penta+Hexa − D3) / D1    | in < 1 year, from 2nd half 2012 |
| MMR              | (D1 − D2 MMR+MMRV) / D1      | at 1 year, from 2013 |
| Poliomyelitis    | (D1 OPV+IPV+... − D3) / D1   | in < 1 year|
| Tetra (DTP/Hib)  | (D1 Tetra+Penta+Hexa − D3) / D1 | in < 1 year, 2003-2012 |

For Hepatitis B, the "D" doses (newborn < 1 month) are NOT included in the
dropout calculation because they are part of the schedule completed by Penta.

### Denominator: sources and rules over time

The population denominator source changed multiple times, including
differently across groups of states:

**Period 1994-1999 (all states):**  
Preliminary IBGE population estimates for all age groups. Data from the 1996
Population Count or later revisions were not used (per CGPNI guidance).
Therefore, the target population is NOT the same available on the DATASUS
Resident Population pages.

**Period 2000-2005 (split rule by state):**  
Two groups of states with different rules:

- Group A (AL, AM, BA, CE, MA, MG, MT, PA, PB, PI, RO, TO):
  all age groups use Census 2000 and IBGE estimates (no SINASC).
- Group B (AC, AP, ES, GO, MS, PR, PE, RJ, RN, RS, RR, SC, SP, SE, DF):
  < 1 year and 1 year use SINASC; other age groups use Census 2000/estimates.

Detail: for the 1-year-old population, SINASC uses live births from the
**previous year** (e.g., 1-year-old pop in 2003 = LB from 2002).

**Period 2006+ (all states):**  
- < 1 year: SINASC (live births from the same year)  
- 1 year: SINASC (live births from the previous year)  
- Other age groups: Census, counts, intercensal projections, or IBGE estimates  

**Important notes on the denominator:**  
- SINASC data may be revised later without updating the target population
  used by PNI (data frozen at the time).  
- When the current year's SINASC is not available, the previous year's is used.  
- For the current year (preliminary data), a cumulative monthly target is used:
  annual_pop ÷ 12 × number of months. Data is finalized in March of the
  following year.  

### Missing data by state in early years

| Year | States without data |
|:----:|:-------------------:|
| 1994 | AL, AP, DF, MS, MG, PB, PR, RJ, RS, SP, SE, TO (12 states) |
| 1995 | MS, MG, TO (3 states) |
| 1996 | MG (1 state) |
| 1997+| All states available |

### Notes on private clinic records

The Hexavalent vaccine (DTaP/Hib/HB/IPV) is administered in private clinics
and registered in the APIWEB system. The 13-valent Pneumococcal vaccine is
also administered in private clinics, in addition to some municipalities that
purchase the vaccine separately. Both are included in the coverage sums of
the corresponding composite indicators. Before Penta entered the routine
schedule (2nd half 2012), Penta/Hexa records in the data refer to indigenous
vaccination and Special Immunobiological Reference Centers (CRIE).

### Reference table: SINASC year used as denominator

SINASC for 1-year-olds uses LB from the previous year. When data is not
available, the last available year is repeated. Table extracted from
technical notes:

| Data year | <1 year (SINASC) | 1 year (SINASC) | States with SINASC for <1 and 1 year |
|-----------|------------------|------------------|--------------------------------------|
| 1994-1999 | — (IBGE)         | — (IBGE)         | None (all use IBGE)                  |
| 2000      | 2000             | 2000             | Group B (AC,AP,ES,GO,MS,PR,PE,RJ,RN,RS,RR,SC,SP,SE,DF) |
| 2001      | 2001             | 2000             | Group B                              |
| 2002      | 2002             | 2001             | Group B                              |
| 2003      | 2003             | 2002             | Group B                              |
| 2004      | 2004             | 2003             | Group B                              |
| 2005      | 2005             | 2004             | Group B                              |
| 2006      | 2006             | 2005             | All states                           |
| 2007      | 2007             | 2006             | All states                           |
| 2008      | 2008             | 2007             | All states                           |
| 2009      | 2009*            | 2008             | All states                           |
| 2010      | 2009*            | 2009             | All states                           |
| 2011      | 2009*            | 2009             | All states                           |
| 2012      | 2009*            | 2009             | All states                           |

(*) SINASC 2009 repeated in subsequent years (most recent data available at
the time of publication). This freeze is a known source of distortion in
coverage calculated for ~2010-2012.

---

## 8. COMPATIBILITY BETWEEN AGGREGATED AND MICRODATA

### What matches directly

- **Municipality:** both have IBGE code (normalize to 6 digits)
- **Period:** both allow aggregation by year (and by month in microdata and
  DPNI from 2004 onwards)
- **Administered doses:** counts extractable from both (QT_DOSE in
  aggregated, record count in microdata)

### What requires harmonization

- **Vaccines:** names and codes changed. DTP → Tetravalent → Pentavalent.
  Monovalent Measles → MMR. To build a continuous poliomyelitis coverage
  series, for example, one needs to sum OPV + IPV + Pentavalent depending
  on the period.
- **Age group:** aggregated data has pre-defined groups; microdata has exact
  age (`nu_idade_paciente`), which needs to be recategorized.
- **Dose type:** aggregated data uses numeric codes (01=D1, 02=D2...);
  microdata has `co_dose_vacina` and `ds_dose_vacina` with different values.

### What does not exist in aggregated data

Sex, race/color, facility (CNES), lot, manufacturer, vaccination strategy
— these are exclusive to microdata (2020+).

### Unavoidable methodological discontinuity

The 1994-2019 series uses coverage pre-calculated by the Ministry (with
official denominators from that year). The 2020+ series will have coverage
calculated by us from microdata + SINASC/IBGE denominators. Values should
be comparable but not identical, due to differences in the moment of data
extraction and possible revisions to the denominators.

---

## 9. DATA PUBLICATION DECISION

### Principle: publish what the Ministry publishes, without transforming

**Microdata (2020+):** published exactly as the Ministry provides. The
Ministry already includes code/description pairs (e.g., `co_vacina` /
`ds_vacina`). Only changes: format (JSON → Parquet), partitioning by
year/month/state.

**Aggregated (1994-2019):** published with raw codes from the .dbf files.
The original dictionaries (.cnv and IMUNOCOB.DBF) are published as separate
reference files in the repository. The researcher does the join if desired.

**Dictionaries:** published in full, in the Ministry's original formats.

**Populations:** published as separate Parquets, with source identified
(SINASC or IBGE).

### Why not decode aggregated data inline?

Decoding would create a derivative of ours, no longer the Ministry's
original document. The project prioritizes fidelity to the source. The R
package `sipni` will do the join automatically for the researcher —
convenience lives in the software, not in the data.

---

## 10. R PACKAGE `sipni`

### Name

`sipni` — validated with `pak::pkg_name_check()`. Available on CRAN and
Bioconductor. Short, descriptive, no `r` prefix (modern rOpenSci convention).

### Package value

The package is justified by integrating 4 harmonized sources and solving
complexity that no researcher should have to repeat individually:

- Connects to aggregated data, microdata, dictionaries, and population data on R2
- Automatically joins code→name for aggregated data
- Calculates coverage from microdata + SINASC/IBGE denominator
- Harmonizes vaccine nomenclature across 30 years
- Builds continuous time series for any vaccine × geography

### Conceptual interface

```r
library(sipni)

# Coverage time series
sipni::cobertura("triplice_viral", uf = "DF", anos = 1994:2025)
# → tibble with year, coverage_pct, source (aggregated/microdata), denominator

# Raw administered doses
sipni::doses(vacina = "pentavalente", municipio = "530010", anos = 2015:2025)

# Raw microdata
sipni::microdados(uf = "AC", ano = 2024, mes = 1)
# → arrow::open_dataset() with filters applied
```

### Relationship with healthbR

`sipni` will be an independent CRAN package. `healthbR` may become a
meta-package (tidyverse-style) in the future, bundling sipni, sim, sinasc, etc.

---

## 11. DESIGN DECISIONS (AND WHY)

| Decision | Rejected alternative | Reason |
|----------|:--------------------:|--------|
| JSON as microdata source | CSV | 2020-2024 CSV has artifacts (.0, lost zeros). JSON ~1.3x larger, but eliminates all reconstruction logic. |
| Everything as character in Parquet | Automatic typing | JSON already delivers everything as string. Leading zeros preserved natively. |
| R2 as storage | HF direct / AWS S3 | Zero egress + S3 standard. |
| Hetzner VPS for execution | GitHub Actions | Volume exceeds free tier limits. |
| Raw data + separate dictionaries | Inline decoded data | Fidelity to original source. Convenience via package. |
| Pipeline separate from package | Monorepo | Infrastructure ≠ researcher interface. |
| Municipality in 6 digits | Keep 7 digits from legacy data | 6 digits (without check digit) is the IBGE standard. |
| Name `sipni` | `rsipni`, `vacinabr` | rOpenSci convention: short, descriptive, no `r` prefix. |

---

## 12. WHAT HAS BEEN DONE (EXPLORATORY PHASE)

### Microdata (2020+)
- [x] Format discovery: CSV with header (Latin-1) and JSON (UTF-8), 56 columns
- [x] Located official dictionary (60 fields)
- [x] Complete mapping of 56 columns (position → official name)
- [x] Cross-validation CSV × JSON × dictionary (55/56 matched; 1 corrected)
- [x] Identification of 4 missing fields and 1 official typo
- [x] **Discovery: CSV has a header** (contrary to initial assumption)
- [x] **Discovery: 2020-2024 CSV has artifacts** (float .0, lost zeros)
- [x] **Discovery: JSON preserves types correctly** (all string, zeros intact)
- [x] **Decision: JSON as primary source** (available 2020-2025, both URL patterns mapped)
- [x] Size comparison: JSON ~1.3x larger than CSV (~28 GB extra for 72 months)
- [x] Confirmation: same 56 columns in both formats, zero exclusives
- [x] Technical note: JSON is a single-line array (>2GB), requires binary reading
- [x] Type decision (all character, preserving leading zeros from JSON)
- [x] Partitioning definition (year/month/state)
- [x] Pipeline scripts drafted (4 scripts in /outputs)

### Aggregated data (1994-2019)
- [x] Discovery of .dbf files on DATASUS FTP (1504 files)
- [x] File naming convention mapping (CPNI/DPNI + state + year)
- [x] Identification of 3 structural eras (CPNI and DPNI)
- [x] Located dictionaries in /AUXILIARES/ (17 .cnv + 62 .def + 1 .dbf)
- [x] Decoding of IMUNO.CNV and IMUNOCOB.DBF dictionaries
- [x] Confirmation that coverage and doses use different IMUNO code systems
- [x] Analysis of the evolution of 65 vaccine codes over 26 years
- [x] Complete IMUNO × year matrix (exported as CSV)
- [x] Transition mapping: municipality code (7→6), columns, types

### Reference documentation consulted
- `Regrascobertura2013.pdf` — Detailed numerators by vaccine (2012-2013),
  including APIDOS vs APIWEB rules, multi-vaccination and MRC campaign
- `notatecnicaTx.pdf` — Dropout rates: formulas by vaccine, components to sum
- `notatecnicaCobertura.pdf` — Vaccination coverage: complete rules by vaccine,
  doses that complete the schedule, notes on Hexa (private clinics) and Pneumo 13V
- `notatecnica.pdf` — General technical notes: data origin, coverage and vaccines,
  target population table by period and state, age groups by immunobiological
- `Nota_Tecnica_Imunizacoes_Cobertura_desde_1994.pdf` — Coverage since 1994:
  immunobiologicals × period × target population × coverage dose table,
  composite indicators ("vaccine totals against..."), denominator rules
  by state and period, observations on vaccine transitions
- `Imun_cobertura_desde_1994.pdf` — Same information in different layout
- `Nota_Tecnica_Imunizacoes_Doses_aplicadas_desde_1994.pdf` — Complete table
  of immunobiologicals with periods, doses, age groups, and conditions (sex,
  pregnancy), including sera and immunoglobulins
- `Imun_doses_aplic_desde_1994.pdf` — Same information in different layout

---

## 13. WHAT REMAINS TO BE DONE

### Phase 1: Documentation (CURRENT)
- [x] Rewrite PROJECT.md with updated scope
- [ ] Organize exploratory scripts without redundancy
- [ ] Create missing scripts from the microdata exploration phase
- [ ] Store dictionaries (both phases)
- [ ] Create harmonization document for aggregated ↔ microdata
- [ ] Create code translation document across the entire time series

### Phase 2: Production pipeline
- [ ] Final script: JSON download + microdata conversion (2020+)
- [ ] Final script: download + conversion of aggregated data (1994-2019)
- [ ] Final script: denominator download (SINASC + IBGE)
- [ ] Upload script to R2
- [ ] Complete pipeline testing and validation

### Phase 3: R package `sipni`
- [ ] Create package repository
- [ ] Implement data access functions
- [ ] Implement vaccine harmonization
- [ ] Implement coverage calculation (microdata + denominator)
- [ ] Implement time series construction
- [ ] Documentation and vignettes
- [ ] Publish on GitHub (with pkgdown)
- [ ] Submit to CRAN

### Phase 4: Expansion (future)
- [ ] Expand pipeline to other systems (SIM, SINASC, SIH)
- [ ] Refactor healthbR as a meta-package
- [ ] API for non-R consumers

---

## 14. PROJECT RESOURCES

### FTP and URLs

| Resource | URL |
|----------|-----|
| Microdata JSON (2020-2024) | `https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{month}_{year}.json.zip` |
| Microdata JSON (2025+) | `https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{month}_{year}_json.zip` |
| Microdata CSV (fallback) | `https://arquivosdadosabertos.saude.gov.br/dados/dbbni/vacinacao_{month}_{year}_csv.zip` |
| Aggregated .dbf | `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/` |
| Dictionaries .cnv/.def | `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/` |
| TabNet coverage | `http://tabnet.datasus.gov.br/cgi/dhdat.exe?bd_pni/cpnibr.def` |
| TabNet doses | `http://tabnet.datasus.gov.br/cgi/dhdat.exe?bd_pni/dpnibr.def` |
| SINASC (FTP) | `ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/` |

### Exploration artifacts

| Artifact | Description |
|----------|-------------|
| `inventario_imuno_por_ano.csv` | 65 vaccines × 26 years matrix |
| `verificar_json_disponivel.R` | JSON/CSV availability mapping and field-by-field comparison |
| `diagnostico_tipagem.R` | Type diagnosis per variable in microdata and aggregated data |
| `comparar_formatos_csv_api.R` | Plain text CSV vs Elasticsearch API (COVID) comparison |
| `explorar_*.R` scripts | Exploratory scripts documenting discoveries |
| Transcripts in `/mnt/transcripts/` | Complete record of all conversations |

### Technical reference documents (project files)

| Document | Content |
|----------|---------|
| `Regrascobertura2013.pdf` | Numerators by vaccine (APIDOS/APIWEB), 2012-2013 rules |
| `notatecnicaTx.pdf` | Dropout rate formulas by multi-dose vaccine |
| `notatecnicaCobertura.pdf` | Complete coverage rules by vaccine, doses, and notes |
| `notatecnica.pdf` | Data origin, coverage, target population by period/state |
| `Nota_Tecnica_Imunizacoes_Cobertura_desde_1994.pdf` | Coverage × vaccine × dose × target pop table, composite indicators |
| `Imun_cobertura_desde_1994.pdf` | Same information (different layout), immunobiologicals table |
| `Nota_Tecnica_Imunizacoes_Doses_aplicadas_desde_1994.pdf` | Complete table: immunobiologicals × doses × age groups × sex |
| `Imun_doses_aplic_desde_1994.pdf` | Same information (different layout) |

---

## 15. GLOSSARY

| Term | Meaning |
|------|---------|
| SI-PNI | National Immunization Program Information System (Sistema de Informação do Programa Nacional de Imunizações) |
| RNDS | National Health Data Network (Rede Nacional de Dados em Saúde) |
| DATASUS | SUS Information Technology Department (Departamento de Informática do SUS) |
| OpenDATASUS | Ministry of Health Open Data Portal |
| SINASC | Live Birth Information System (Sistema de Informações sobre Nascidos Vivos) |
| IBGE | Brazilian Institute of Geography and Statistics (Instituto Brasileiro de Geografia e Estatística) |
| API (system) | PNI Evaluation System (legacy, not to be confused with web API) |
| APIDOS | DOS-based PNI evaluation system (until Jun/2013) |
| APIWEB | Web system that replaced APIDOS (from Jul/2013) |
| SIPNI | New SI-PNI (records by individual, not aggregated) |
| TabWin/TabNet | DATASUS tabulation software/interface |
| CRIE | Special Immunobiological Reference Centers (Centros de Referência de Imunobiológicos Especiais) |
| .dbf | dBase III format (used by legacy aggregated data) |
| .cnv | TabWin conversion format (code→name dictionary) |
| .def | TabWin tabulation definition format |
| CNES | National Health Facility Registry (Cadastro Nacional de Estabelecimentos de Saúde) |
| R2 | Cloudflare R2 (S3-compatible storage, zero egress) |
| Arrow | Apache Arrow (library for efficient Parquet reading) |
| Parquet | Compressed columnar format, standard for big data |
| CPNI | Prefix for PNI Coverage files |
| DPNI | Prefix for PNI Doses files |
| IMUNOCOB | Composite coverage indicator dictionary |
| IMUNO.CNV | Individual vaccine dictionary (doses) |
| LB | Live births (Nascidos vivos) |
| SD | Single dose (Dose única) |
| D1, D2, D3 | First, second, third dose of the vaccination schedule |
| BOOST1, BOOST2 | First and second booster (Primeiro e segundo reforço) |
| Seq. Sch. | Sequential schedule IPV/OPV (Esquema sequencial VIP/VOP) |
| Penta | Pentavalent (DTP+HB+Hib) |
| Hexa | Hexavalent (DTaP+Hib+HB+IPV) — private clinics |
| VORH | Human Rotavirus Oral Vaccine (Vacina Oral de Rotavírus Humano) |
| MMR | Measles, Mumps, Rubella (Tríplice Viral) |
| MMRV | Measles, Mumps, Rubella, Varicella (Tetraviral) |
| OPV | Oral Polio Vaccine (VOP - Vacina Oral contra Poliomielite) |
| IPV | Inactivated Polio Vaccine (VIP - Vacina Inativada contra Poliomielite) |
| MR | Measles-Rubella (Dupla Viral) |
| SUS | Unified Health System (Sistema Único de Saúde) |
