[🇬🇧 English](README.md) | 🇧🇷 Português

# healthbr-data

Redistribuição gratuita de dados públicos de saúde do Brasil (SUS) em
formato analítico moderno.

O **healthbr-data** redistribui dados públicos de saúde do Sistema Único
de Saúde (SUS) em formato Apache Parquet, com acesso gratuito via protocolo
S3, atualizações mensais automatizadas e documentação completa. Comece a
analisar mais de 500 milhões de registros de vacinação em 3 linhas de
código R ou Python.

## Datasets disponíveis

| Dataset | Prefixo no R2 | Registros | Período | Status |
|---------|---------------|-----------|---------|--------|
| SI-PNI Vacinação de rotina (microdados) | `sipni/microdados/` | ~736M | 2020–presente | ✅ Disponível |
| SI-PNI Vacinação COVID (microdados) | `sipni/covid/microdados/` | ~608M | 2021–presente | ✅ Disponível |
| SI-PNI Agregados históricos (doses) | `sipni/agregados/doses/` | ~84M | 1994–2019 | ✅ Disponível |
| SI-PNI Agregados históricos (cobertura) | `sipni/agregados/cobertura/` | ~2,8M | 1994–2019 | ✅ Disponível |

## Início rápido

### R (Arrow)

```r
library(arrow)

# Configurar endpoint Cloudflare R2 (egress gratuito, token read-only público)
Sys.setenv(
  AWS_ENDPOINT_URL      = "https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
  AWS_ACCESS_KEY_ID     = "28c72d4b3e1140fa468e367ae472b522",
  AWS_SECRET_ACCESS_KEY = "2937b2106736e2ba64e24e92f2be4e6c312bba3355586e41ce634b14c1482951",
  AWS_DEFAULT_REGION    = "auto"
)

# Conectar ao dataset
ds <- open_dataset("s3://healthbr-data/sipni/microdados/", format = "parquet")

# Exemplo: contar vacinas aplicadas no Acre em janeiro/2024
ds |>
  filter(ano == "2024", mes == "01", uf == "AC") |>
  count(ds_vacina) |>
  collect()
```

### Python (PyArrow)

```python
import pyarrow.dataset as pds
import pyarrow.fs as fs

s3 = fs.S3FileSystem(
    endpoint_override="https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com",
    access_key="28c72d4b3e1140fa468e367ae472b522",
    secret_key="2937b2106736e2ba64e24e92f2be4e6c312bba3355586e41ce634b14c1482951",
    region="auto"
)

dataset = pds.dataset(
    "healthbr-data/sipni/microdados/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

# Ler um subconjunto filtrado
table = dataset.to_table(
    filter=(pds.field("ano") == "2024") & (pds.field("uf") == "AC")
)
print(table.to_pandas().head())
```

## Por que este projeto?

Os dados públicos de saúde do Brasil (DATASUS/OpenDATASUS) são abertos,
mas distribuídos em formatos que dificultam análises em larga escala:
arrays JSON massivos, arquivos .dbf legados, e CSVs com inconsistências
de encoding e tipos. Pesquisadores gastam dias apenas baixando e preparando
dados antes de qualquer análise.

O **healthbr-data** resolve isso oferecendo os mesmos dados em formato
Apache Parquet, particionados por ano/mês/UF, servidos via S3 com custo
zero de egress. Uma consulta que exigiria baixar 130 GB de arquivos brutos
do servidor do Ministério leva segundos via partition pruning do Arrow.

Os dados são publicados exatamente como fornecidos pelo Ministério da
Saúde — sem limpeza, sem transformação, sem perda de informação.
Dicionários e documentação são publicados separadamente como referência.

## Arquitetura

```
Ministério da Saúde (JSON/CSV/DBF)
        ↓ pipeline automatizado
VPS Hetzner (processamento)
        ↓ jq + polars + rclone
Cloudflare R2 (armazenamento S3, egress gratuito)
        ↓ Arrow / DuckDB
Pesquisadores (R, Python, ou qualquer ferramenta compatível com Parquet)
```

## Roadmap

- ✅ Microdados de vacinação de rotina (SI-PNI), 2020–presente — 736M+ registros
- ✅ Microdados de vacinação COVID (SI-PNI COVID), 2021–presente — 608M+ registros
- ✅ Agregados históricos — doses aplicadas (SI-PNI), 1994–2019 — 84M+ registros
- ✅ Agregados históricos — cobertura vacinal (SI-PNI), 1994–2019 — 2,8M+ registros
- 🔧 Dicionários oficiais do Ministério da Saúde
- 📋 Pacote R `healthbR` para acesso integrado
- 📋 Série temporal harmonizada de cobertura vacinal (1994–presente)
- 🔮 Novos sistemas de informação (SIM, SINASC, SIH)

## Documentação

- [Arquitetura e decisões do projeto (PT)](docs/project-pt.md) |
  [EN](docs/project-en.md)
- [Guia de início rápido (PT)](guides/quick-guide-pt.R) |
  [EN](guides/quick-guide-en.R)
- [Harmonização: agregados ↔ microdados (PT)](docs/harmonization-pt.md)

## Apoie o projeto

Este projeto é mantido de forma independente. Os custos de infraestrutura
são modestos (~R$40–150/mês) mas contínuos. Se você acha esses dados
úteis, considere apoiar:

- **GitHub Sponsors** — [link a adicionar]
- **Pix** — `sbissoli76@gmail.com`

Veja a [página de transparência](docs/strategy-dissemination-pt.md) para
detalhamento completo de custos e contribuições.

## Licença

CC-BY 4.0. Fonte dos dados: Ministério da Saúde / OpenDATASUS.

## Citação

Se você usar esses dados em publicações, por favor cite:

```bibtex
@misc{healthbrdata,
  author = {Sidney da Silva Bissoli},
  title  = {healthbr-data: Redistribuição de Dados de Saúde Pública do Brasil},
  year   = {2026},
  url    = {https://huggingface.co/SidneyBissoli},
  note   = {Fonte original: Ministério da Saúde / OpenDATASUS}
}
```

## Contato

- **GitHub:** [https://github.com/SidneyBissoli](https://github.com/SidneyBissoli)
- **Hugging Face:** [https://huggingface.co/SidneyBissoli](https://huggingface.co/SidneyBissoli)
- **E-mail:** sbissoli76@gmail.com
