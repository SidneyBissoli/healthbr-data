[🇬🇧 English](README.md) | 🇧🇷 Português

# SI-PNI — Dados Agregados de Cobertura Vacinal (1994–2019)

Dados agregados de cobertura vacinal pré-calculada do Programa Nacional de
Imunizações (SI-PNI), cobrindo o período histórico de 1994 a 2019. Cada
linha contém o total de doses, a população-alvo e a cobertura percentual
para uma combinação de município × indicador de cobertura. Redistribuído em
formato Apache Parquet particionado a partir dos arquivos .dbf originais do
FTP do DATASUS.

## Resumo

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | FTP do DATASUS / Ministério da Saúde |
| **Cobertura temporal** | 1994–2019 (26 anos) |
| **Cobertura geográfica** | Todos os municípios brasileiros |
| **Granularidade** | Município × vacina (× dose × faixa etária até 2012) |
| **Registros** | **2.762.327** |
| **Formato** | Apache Parquet, particionado por `ano/uf` |
| **Tipos de dados** | Todos os campos como `string` (preserva formatação original) |
| **Atualização** | Estático (dados históricos, sem atualizações previstas) |
| **Licença** | CC-BY 4.0 |

## Acesso aos dados

### R (Arrow)

```r
library(arrow)

# Configuração do endpoint S3 (leitura anônima)
Sys.setenv(
  AWS_ENDPOINT_URL = "https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
  AWS_ACCESS_KEY_ID = "",
  AWS_SECRET_ACCESS_KEY = "",
  AWS_DEFAULT_REGION = "auto"
)

# Conectar ao dataset
ds <- open_dataset(
  "s3://healthbr-data/sipni/agregados/cobertura/",
  format = "parquet",
  unify_schemas = TRUE
)

# Exemplo: cobertura por vacina em Minas Gerais, 2015
ds |>
  filter(ano == "2015", uf == "MG") |>
  group_by(IMUNO) |>
  summarise(
    media_cobertura = mean(as.numeric(COBERT), na.rm = TRUE)
  ) |>
  collect()
```

### Python (PyArrow)

```python
import pyarrow.dataset as pds
import pyarrow.fs as fs

s3 = fs.S3FileSystem(
    endpoint_override="https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
    region="auto",
    anonymous=True
)

dataset = pds.dataset(
    "healthbr-data/sipni/agregados/cobertura/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

table = dataset.to_table(
    filter=(pds.field("ano") == "2015") & (pds.field("uf") == "MG")
)
print(table.to_pandas().head())
```

> **Nota:** O bucket permite leitura anônima. Não é necessário credencial.
>
> **Importante:** Use `unify_schemas = TRUE` no R (ou equivalente) porque
> o esquema muda entre as eras (veja abaixo).

## Estrutura dos arquivos

```
s3://healthbr-data/sipni/agregados/cobertura/
  README.md
  README.pt.md
  ano=1994/
    uf=AC/
      part-0.parquet
    ...
  ano=2019/
    ...
```

Cada arquivo Parquet contém todos os registros de cobertura de uma UF em
um ano. Particionado por `ano/uf`.

## Esquema das variáveis

O dataset tem duas eras estruturais com conjuntos de colunas diferentes:

### Era 1–2: 1994–2012 (9 colunas)

| Variável | Descrição |
|----------|-----------|
| `ANO` | Ano |
| `UF` | Código da UF |
| `MUNIC` | Código do município (**7 dígitos** até 2012, inclui dígito verificador IBGE) |
| `FX_ETARIA` | Código da faixa etária |
| `IMUNO` | Código do indicador de cobertura (ver dicionário IMUNOCOB.DBF) |
| `DOSE` | Tipo de dose |
| `QT_DOSE` | Número de doses aplicadas |
| `POP` | População-alvo (denominador) |
| `COBERT` | Taxa de cobertura (%) — **separador decimal: ponto** |

### Era 3: 2013–2019 (7 colunas)

| Variável | Descrição |
|----------|-----------|
| `ANO` | Ano |
| `UF` | Código da UF |
| `MUNIC` | Código do município (**6 dígitos**, dígito verificador IBGE removido) |
| `IMUNO` | Código do indicador de cobertura (composto, embute dose e faixa etária) |
| `QT_DOSE` | Número de doses aplicadas |
| `POP` | População-alvo (denominador) |
| `COBERT` | Taxa de cobertura (%) — **separador decimal: vírgula** |

**Mudança principal em 2013:** As colunas `FX_ETARIA` e `DOSE` desaparecem.
A partir de 2013, cada código IMUNO é um indicador composto que já embute a
dose e faixa etária corretas para o cálculo de cobertura.

**Usar `open_dataset(unify_schemas = TRUE)`** no Arrow preenche
automaticamente com `null` as colunas ausentes ao ler entre eras.

## Relação com o dataset de doses

Este dataset é complementar ao dataset de doses agregadas
(`s3://healthbr-data/sipni/agregados/doses/`). Diferenças principais:

| Aspecto | Doses (DPNI) | Cobertura (CPNI) |
|---------|:------------:|:----------------:|
| Dicionário de vacinas | IMUNO.CNV (85 vacinas individuais) | **IMUNOCOB.DBF** (26 indicadores compostos) |
| Campos exclusivos | ANOMES, MES, DOSE1, DOSEN, DIFER | **POP, COBERT** |
| Finalidade | Contagem de doses aplicadas | Taxas de cobertura pré-calculadas |
| Eras de schema | 3 (7→12→12 colunas) | **2** (9→7 colunas) |
| Registros | 84 milhões | **2,8 milhões** |

**Os códigos IMUNO são diferentes entre doses e cobertura.** No dataset de
doses, cada código identifica uma vacina individual (ex.: `02` = BCG). No
dataset de cobertura, cada código representa um indicador composto que pode
somar múltiplas vacinas (ex.: `073` = Hepatite B total = HB + Penta + Hexa
combinados).

## Campo COBERT: inconsistência no separador decimal

O campo `COBERT` (cobertura pré-calculada) muda de formato de separador
decimal na transição de 2013:

| Período | Tipo na fonte | Valor no Parquet | Exemplo |
|:-------:|:------------:|:----------------:|:-------:|
| 1994–2012 | numérico (ponto) | `"39.87"` | `as.character(39.87)` |
| 2013–2019 | caractere (vírgula) | `"64,86"` | preservado como está |

Ambos ficam como string no Parquet. Usuários precisam tratar o separador
decimal inconsistente ao converter para numérico.

## Fonte e processamento

**Fonte original:** 702 arquivos .dbf no FTP do DATASUS
(`ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/`), seguindo o
padrão `CPNI{UF}{AA}.DBF` (27 UFs × 26 anos).

**Arquivos processados:** 686 de 702. 16 estão vazios (headers .dbf válidos
com 0 linhas, retornados pelo FTP para UFs sem dados nos primeiros anos).

**Pipeline de processamento:** .dbf → R (`foreign::read.dbf`) → Parquet
(`arrow::write_parquet`) → upload para R2 (via `rclone`). Todos os campos
são armazenados como `string` para preservar a formatação original.

**Arquivos consolidados excluídos:** Mesmo racional do dataset de doses —
consolidados nacionais (CPNIBR) e por UF (CPNIUF) são redundantes com os
arquivos estaduais e foram excluídos.

**Dicionário de cobertura:** `IMUNOCOB.DBF` (26 indicadores compostos de
cobertura), disponível no diretório de arquivos auxiliares do FTP do
DATASUS. Este é um dicionário diferente do `IMUNO.CNV` usado para doses.

## Limitações conhecidas

1. **Dados do governo, não nossos.** Valores são publicados exatamente como
   encontrados nos arquivos .dbf originais — incluindo as taxas de
   cobertura pré-calculadas.

2. **Cobertura é pré-calculada pelo Ministério.** O campo `COBERT` equivale
   a `QT_DOSE / POP * 100`. Esses valores podem diferir de coberturas
   calculadas diretamente a partir do dataset de doses, devido a diferenças
   em denominadores e regras de agregação de doses usadas pelo Ministério.

3. **Códigos IMUNO são indicadores compostos.** Requerem o dicionário
   `IMUNOCOB.DBF` (não `IMUNO.CNV`) para interpretação. Esse dicionário
   será publicado em `s3://healthbr-data/sipni/dicionarios/`.

4. **Separador decimal inconsistente.** O campo `COBERT` usa ponto (`.`)
   em 1994–2012 e vírgula (`,`) em 2013–2019.

5. **Todos os campos são strings.** Campos numéricos (`QT_DOSE`, `POP`,
   `COBERT`) devem ser convertidos pelo usuário.

6. **Códigos de município inconsistentes.** 7 dígitos (1994–2012) vs 6
   dígitos (2013–2019).

7. **FX_ETARIA e DOSE desaparecem em 2013.** Essas colunas estão ausentes
   a partir de 2013 — estão embutidas nos códigos IMUNO compostos.

8. **UFs ausentes nos primeiros anos.** Algumas combinações UF-ano em
   1994–1996 têm arquivos vazios (headers .dbf válidos com 0 linhas).

## Citação sugerida

```bibtex
@misc{healthbrdata_sipni_agregados_cobertura,
  author = {Sidney Silva},
  title = {{SI-PNI} Aggregated Vaccination Coverage (1994--2019) — healthbr-data},
  year = {2026},
  url = {https://huggingface.co/datasets/sidneyjunior/sipni-agregados-cobertura},
  note = {Fonte original: DATASUS / Ministério da Saúde}
}
```

## Contato

- **GitHub:** [healthbr-data](https://github.com/sidneyjunior/healthbr-data)
- **Projeto:** [healthbr-data](https://huggingface.co/healthbr-data)

---

*Última atualização: 27/fev/2026*
