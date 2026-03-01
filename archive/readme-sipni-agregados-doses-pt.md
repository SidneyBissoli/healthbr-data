[🇬🇧 English](README.md) | 🇧🇷 Português

# SI-PNI — Dados Agregados de Doses Aplicadas (1994–2019)

Dados agregados de doses aplicadas do Programa Nacional de Imunizações
(SI-PNI), cobrindo o período histórico de 1994 a 2019. Cada linha
representa o total de doses para uma combinação de município × vacina ×
tipo de dose × faixa etária. Redistribuído em formato Apache Parquet
particionado a partir dos arquivos .dbf originais do FTP do DATASUS.

## Resumo

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | FTP do DATASUS / Ministério da Saúde |
| **Cobertura temporal** | 1994–2019 (26 anos) |
| **Cobertura geográfica** | Todos os municípios brasileiros |
| **Granularidade** | Município × vacina × dose × faixa etária (uma linha por combinação) |
| **Registros** | **84.022.233** |
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
  "s3://healthbr-data/sipni/agregados/doses/",
  format = "parquet",
  unify_schemas = TRUE
)

# Exemplo: total de doses por vacina em São Paulo, 2018
ds |>
  filter(ano == "2018", uf == "SP") |>
  count(IMUNO, wt = as.numeric(QT_DOSE)) |>
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
    "healthbr-data/sipni/agregados/doses/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

table = dataset.to_table(
    filter=(pds.field("ano") == "2018") & (pds.field("uf") == "SP")
)
print(table.to_pandas().head())
```

> **Nota:** O bucket permite leitura anônima. Não é necessário credencial.
>
> **Importante:** Use `unify_schemas = TRUE` no R (ou equivalente) porque
> o esquema muda entre as eras (veja abaixo).

## Estrutura dos arquivos

```
s3://healthbr-data/sipni/agregados/doses/
  README.md
  README.pt.md
  ano=1994/
    uf=AC/
      part-0.parquet
    uf=AL/
      part-0.parquet
    ...
  ano=2019/
    ...
```

Cada arquivo Parquet contém todos os registros de doses de uma UF em um
ano. Particionado por `ano/uf` (não por `ano/mes/uf`, pois a granularidade
mensal não está disponível antes de 2004).

## Esquema das variáveis

O dataset tem três eras estruturais com conjuntos de colunas diferentes:

### Era 1: 1994–2003 (7 colunas)

| Variável | Descrição |
|----------|-----------|
| `ANO` | Ano (inteiro armazenado como string) |
| `UF` | Código da UF |
| `MUNIC` | Código do município (**7 dígitos**, inclui dígito verificador IBGE) |
| `FX_ETARIA` | Código da faixa etária |
| `IMUNO` | Código da vacina (ver dicionário IMUNO.CNV) |
| `DOSE` | Tipo de dose |
| `QT_DOSE` | Número de doses aplicadas |

### Era 2: 2004–2012 (12 colunas)

Todas as 7 colunas da Era 1, mais:

| Variável | Descrição |
|----------|-----------|
| `ANOMES` | Ano-mês (AAAAMM) |
| `MES` | Mês |
| `DOSE1` | 1ªs doses aplicadas |
| `DOSEN` | Últimas (enésimas) doses aplicadas |
| `DIFER` | Diferença (DOSE1 − DOSEN, para cálculo de taxa de abandono) |

### Era 3: 2013–2019 (12 colunas)

Mesmas 12 colunas da Era 2, mas:
- `MUNIC` muda de **7 dígitos para 6 dígitos** (dígito verificador IBGE removido)

**Usar `open_dataset(unify_schemas = TRUE)`** no Arrow preenche
automaticamente com `null` as colunas ausentes ao ler entre eras.

## Transições importantes

1. **Código de município (2013):** Muda de 7 dígitos (com dígito
   verificador IBGE) para 6 dígitos. O código é preservado exatamente como
   na fonte. A normalização para formato consistente fica a cargo do
   usuário ou do pacote R `sipni` (em desenvolvimento).

2. **Granularidade mensal (2004):** As colunas `ANOMES`, `MES`, `DOSE1`,
   `DOSEN` e `DIFER` surgem a partir de 2004. Antes disso, só existem
   totais anuais.

3. **Transição APIDOS → APIWEB (julho/2013):** O sistema de registro de
   vacinação mudou em meados de 2013. Dados de 2013 podem conter registros
   de ambos os sistemas (APIDOS e APIWEB/SIPNI).

4. **Evolução dos códigos de vacina:** 65 códigos IMUNO únicos aparecem ao
   longo de 26 anos, refletindo três gerações de vacinas no calendário
   nacional (ex.: DTP → Tetravalente → Pentavalente).

## Fonte e processamento

**Fonte original:** 702 arquivos .dbf no FTP do DATASUS
(`ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/`), seguindo o
padrão `DPNI{UF}{AA}.DBF` (27 UFs × 26 anos).

**Arquivos processados:** 674 de 702. 12 arquivos estão indisponíveis
(UFs ausentes no FTP em 1994–1996) e 16 estão vazios (headers .dbf
válidos com 0 linhas, retornados pelo FTP para UFs sem dados nos
primeiros anos).

**Pipeline de processamento:** .dbf → R (`foreign::read.dbf`) → Parquet
(`arrow::write_parquet`) → upload para R2 (via `rclone`). Todos os campos
são armazenados como `string` para preservar a formatação original.

**Arquivos consolidados excluídos:** Consolidados nacionais (DPNIBR) e por
UF (DPNIUF) foram excluídos. DPNIBR foi validado com diferença zero contra
a soma dos 27 arquivos estaduais. DPNIUF tem esquema diferente (sem coluna
de município) e é trivialmente reproduzível. DPNIIG (UF ignorada) não
existe no FTP.

**Dicionário de vacinas:** `IMUNO.CNV` (85 vacinas individuais), disponível
no diretório de arquivos auxiliares do FTP do DATASUS.

## Limitações conhecidas

1. **Dados do governo, não nossos.** Valores são publicados exatamente como
   encontrados nos arquivos .dbf originais.

2. **Códigos IMUNO são opacos.** Os códigos de vacina requerem o dicionário
   `IMUNO.CNV` para interpretação. Esse dicionário será publicado
   separadamente em `s3://healthbr-data/sipni/dicionarios/`.

3. **Todos os campos são strings.** Campos numéricos como `QT_DOSE` devem
   ser convertidos pelo usuário.

4. **Códigos de município inconsistentes.** 7 dígitos (1994–2012) vs 6
   dígitos (2013–2019). Usuários precisam tratar isso ao combinar dados
   entre eras.

5. **Sem cálculo de cobertura.** Este dataset contém apenas contagens de
   doses, não taxas de cobertura. Para cobertura pré-calculada, consulte
   `s3://healthbr-data/sipni/agregados/cobertura/`.

6. **UFs ausentes nos primeiros anos.** 12 combinações UF-ano (1994–1996)
   não estão disponíveis no FTP. Não são arquivos vazios — simplesmente
   não existem.

## Citação sugerida

```bibtex
@misc{healthbrdata_sipni_agregados_doses,
  author = {Sidney Silva},
  title = {{SI-PNI} Aggregated Doses Applied (1994--2019) — healthbr-data},
  year = {2026},
  url = {https://huggingface.co/datasets/sidneyjunior/sipni-agregados-doses},
  note = {Fonte original: DATASUS / Ministério da Saúde}
}
```

## Contato

- **GitHub:** [healthbr-data](https://github.com/sidneyjunior/healthbr-data)
- **Projeto:** [healthbr-data](https://huggingface.co/healthbr-data)

---

*Última atualização: 27/fev/2026*
