[🇬🇧 English](README.md) | 🇧🇷 Português

# SI-PNI — Microdados de Vacinação de Rotina

Microdados individuais de vacinação de rotina do Sistema de Informação do
Programa Nacional de Imunizações (SI-PNI), redistribuídos em formato Apache
Parquet particionado para acesso analítico eficiente. Cada linha representa
uma dose aplicada.

## Resumo

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | OpenDATASUS / Ministério da Saúde |
| **Cobertura temporal** | Janeiro/2020 — presente (atualização mensal) |
| **Cobertura geográfica** | Todos os 5.570 municípios brasileiros |
| **Granularidade** | Registro individual (uma linha por dose aplicada) |
| **Registros** | ~736 milhões+ |
| **Formato** | Apache Parquet, particionado por `ano/mes/uf` |
| **Tipos de dados** | Todos os campos como `string` (preserva zeros à esquerda) |
| **Atualização** | Mensal, automatizada via pipeline |
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
  "s3://healthbr-data/sipni/microdados/",
  format = "parquet"
)

# Exemplo: doses de BCG no Acre em janeiro/2024
ds |>
  filter(ano == "2024", mes == "01", sg_uf == "AC") |>
  count(ds_vacina) |>
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
    "healthbr-data/sipni/microdados/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

# Leitura com filtro
table = dataset.to_table(
    filter=(pds.field("ano") == "2024") & (pds.field("sg_uf") == "AC")
)
print(table.to_pandas().head())
```

> **Nota:** O bucket permite leitura anônima. Não é necessário credencial.

## Estrutura dos arquivos

```
s3://healthbr-data/sipni/microdados/
  README.md
  README.pt.md
  ano=2020/
    mes=01/
      uf=AC/
        part-0.parquet
      uf=AL/
        part-0.parquet
      ...
    mes=02/
      ...
  ano=2021/
    ...
```

Cada arquivo Parquet contém os registros de um mês e UF específicos.
O particionamento Hive (`chave=valor`) permite que Arrow, DuckDB e Spark
façam *partition pruning* automaticamente — queries filtradas por ano,
mês ou UF leem apenas os arquivos relevantes.

## Esquema das variáveis

O dataset contém 56 variáveis, todas armazenadas como `string` para
preservar zeros à esquerda em códigos (IBGE, CNES, CEP, raça/cor).

Variáveis principais:

| Variável | Descrição |
|----------|-----------|
| `dt_vacina` | Data da vacinação (YYYY-MM-DD) |
| `co_vacina` | Código do imunobiológico |
| `ds_vacina` | Descrição do imunobiológico |
| `co_dose_vacina` | Código da dose (1ª, 2ª, 3ª, reforço, etc.) |
| `sg_uf` | UF de vacinação |
| `co_municipio_ibge` | Código IBGE do município (6 dígitos) |
| `co_cnes` | Código CNES do estabelecimento de saúde |
| `dt_nascimento` | Data de nascimento do vacinado |
| `co_sexo` | Sexo (M/F) |
| `co_raca_cor` | Raça/cor autodeclarada |

> Para o dicionário completo das 56 variáveis, consulte o arquivo
> `Dicionario_tb_ria_rotina.pdf` do Ministério da Saúde.

## Fonte e processamento

**Fonte original:** Arquivos JSON comprimidos disponibilizados pelo
Ministério da Saúde via OpenDATASUS (S3).

**Por que JSON e não CSV?** Os arquivos CSV de 2020–2024 contêm artefatos
de exportação (campos numéricos com sufixo `.0`, perda de zeros à
esquerda). O JSON preserva todos os valores como strings com integridade
total. Os CSVs de 2025 em diante não apresentam esses artefatos, mas o
JSON é usado por consistência em toda a série.

**Pipeline de processamento:** JSON → NDJSON (via `jq`) → Parquet (via
`polars`) → upload para R2 (via `rclone`). Nenhuma transformação é
aplicada aos dados — os valores são publicados exatamente como fornecidos
pelo Ministério da Saúde.

**Verificação:** Cada arquivo processado tem hash MD5 registrado em
arquivo de controle de versão. O pipeline compara ETags do servidor
contra registros locais para detectar atualizações.

## Limitações conhecidas

1. **Dados do governo, não nossos.** Erros nos dados originais são
   preservados intencionalmente. Não aplicamos limpeza ou correção.

2. **Completude variável.** Muitos campos têm preenchimento facultativo
   e apresentam alta proporção de valores vazios ou "SEM INFORMACAO".

3. **Todos os campos são string.** A tipagem (Date, integer) deve ser
   feita pelo usuário no momento da análise. O pacote R `sipni`
   (em desenvolvimento) fará isso automaticamente.

4. **Cobertura temporal.** Microdados individuais estão disponíveis
   apenas a partir de janeiro/2020. Para a série histórica anterior
   (1994–2019), consulte os dados agregados em
   `s3://healthbr-data/sipni/agregados/`.

5. **Defasagem.** O Ministério pode levar semanas para publicar os
   dados de um mês. Nosso pipeline roda mensalmente e reflete o
   que está disponível na fonte.

6. **Typo oficial.** A coluna 17 chama-se `no_fantasia_estalecimento`
   (sem o "b" de "estabelecimento"). É o nome oficial no banco do
   Ministério — não é erro nosso.

## Citação sugerida

```bibtex
@misc{healthbrdata_sipni_microdados,
  author = {Sidney Silva},
  title = {{SI-PNI} Routine Vaccination Microdata — healthbr-data},
  year = {2026},
  url = {https://huggingface.co/datasets/sidneyjunior/sipni-microdados-vacinacao},
  note = {Fonte original: Ministério da Saúde / OpenDATASUS}
}
```

## Contato

- **GitHub:** [healthbr-data](https://github.com/sidneyjunior/healthbr-data)
- **Projeto:** [healthbr-data](https://huggingface.co/healthbr-data)

---

*Última atualização: 27/fev/2026*
