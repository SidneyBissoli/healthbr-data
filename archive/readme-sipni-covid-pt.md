[🇬🇧 English](README.md) | 🇧🇷 Português

# SI-PNI — Microdados de Vacinação COVID-19

Microdados individuais de vacinação COVID-19 do Sistema de Informação do
Programa Nacional de Imunizações (SI-PNI), redistribuídos em formato Apache
Parquet particionado para acesso analítico eficiente. Cada linha representa
uma dose aplicada (dados anonimizados).

## Resumo

| Item | Detalhe |
|------|---------|
| **Fonte oficial** | OpenDATASUS / Ministério da Saúde |
| **Cobertura temporal** | Janeiro/2021 — presente |
| **Cobertura geográfica** | Todos os 27 estados brasileiros |
| **Granularidade** | Registro individual (uma linha por dose aplicada, anonimizado) |
| **Registros** | ~608 milhões |
| **Formato** | Apache Parquet, particionado por `ano/mes/uf` |
| **Tipos de dados** | Todos os campos como `string` (preserva zeros à esquerda) |
| **Atualização** | Conforme publicação do Ministério da Saúde |
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
  "s3://healthbr-data/sipni/covid/microdados/",
  format = "parquet"
)

# Exemplo: doses de Pfizer em São Paulo, março/2022
ds |>
  filter(ano == "2022", mes == "03", uf == "SP") |>
  count(vacina_nome) |>
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
    "healthbr-data/sipni/covid/microdados/",
    filesystem=s3,
    format="parquet",
    partitioning="hive"
)

# Leitura com filtro
table = dataset.to_table(
    filter=(pds.field("ano") == "2022") & (pds.field("uf") == "SP")
)
print(table.to_pandas().head())
```

> **Nota:** O bucket permite leitura anônima. Não é necessário credencial.

## Estrutura dos arquivos

```
s3://healthbr-data/sipni/covid/microdados/
  README.md
  README.pt.md
  ano=2021/
    mes=01/
      uf=AC/
        part-0.parquet
      ...
  ano=2022/
    ...
  ano=_invalid/
    mes=.../
      uf=.../
        part-0.parquet
```

Cada arquivo Parquet contém os registros de um mês e UF específicos.
O particionamento Hive (`chave=valor`) permite *partition pruning*
automático.

**A partição `ano=_invalid/`** contém registros cujas datas de vacinação
estão fora do intervalo esperado (2021–presente). São registros com datas
como 1899, 1900 ou anos de nascimento — erros de digitação na fonte
original. Eles são preservados (não descartados) mas separados das
partições válidas para não poluir a estrutura baseada em anos.

## Esquema das variáveis

O dataset contém 32 variáveis, todas armazenadas como `string`. A
convenção de nomes do Ministério da Saúde usa camelCase misto.

Variáveis principais:

| Variável | Descrição |
|----------|-----------|
| `paciente_id` | ID anonimizado do paciente (hash SHA-256) |
| `paciente_idade` | Idade do paciente na vacinação |
| `paciente_dataNascimento` | Data de nascimento do paciente |
| `paciente_enumSexoBiologico` | Sexo biológico (M/F) |
| `paciente_racaCor_codigo` | Código de raça/cor |
| `paciente_endereco_uf` | UF do paciente |
| `paciente_endereco_coIbgeMunicipio` | Código IBGE do município (6 dígitos) |
| `vacina_codigo` | Código da vacina |
| `vacina_nome` | Nome da vacina |
| `vacina_dataAplicacao` | Data da vacinação (ISO datetime) |
| `vacina_descricao_dose` | Descrição da dose (1ª, 2ª, reforço, etc.) |
| `vacina_numDose` | Número da dose |
| `estabelecimento_valor` | Código CNES do estabelecimento de saúde |
| `estabelecimento_uf` | UF do estabelecimento |
| `sistema_origem` | Sistema de origem (Novo PNI, IDS Saúde, VACIVIDA, etc.) |
| `status` | Status do registro (`final` = válido) |

> **Nota:** O campo `estalecimento_noFantasia` contém um typo oficial
> (falta o "b" de "estabelecimento") — é o nome original no banco do
> Ministério.

## Fonte e processamento

**Fonte original:** Arquivos CSV particionados por UF, publicados pelo
Ministério da Saúde no S3 via OpenDATASUS. Volume bruto total: ~292 GB
em 135 arquivos CSV (27 UFs × 5 partes cada).

**Por que CSV?** Diferentemente dos dados de vacinação de rotina, não
existe formato JSON para os dados de COVID-19. O CSV é a única opção
de download em massa.

**Pipeline de processamento:** CSV → Parquet (via `polars`) → upload
para R2 (via `rclone`). Todos os campos são convertidos para string por
consistência. Registros com datas de vacinação fora do intervalo esperado
(2021–presente) são direcionados para a partição `ano=_invalid/` em vez
de serem descartados.

**Verificação:** Cada arquivo processado tem metadados registrados em CSV
de controle de versão.

## Limitações conhecidas

1. **Dados do governo, não nossos.** Erros nos dados originais são
   preservados intencionalmente. Não aplicamos limpeza ou correção.

2. **Datas inválidas.** Alguns registros têm datas de vacinação de 1899,
   1900 ou outros anos implausíveis (erros de digitação). Esses registros
   ficam na partição `ano=_invalid/` (~39 MB, ~2.756 objetos).

3. **Todos os campos são strings.** A tipagem deve ser feita pelo
   usuário no momento da análise.

4. **Múltiplos sistemas de origem.** Registros vêm de vários sistemas de
   registro de vacinação (Novo PNI, IDS Saúde, VACIVIDA, e-SUS APS, etc.),
   o que pode introduzir duplicidades ou inconsistências.

5. **CEP truncado.** O campo `paciente_endereco_cep` contém apenas os 5
   primeiros dígitos do CEP (anonimização pelo Ministério).

6. **Sem dicionário oficial.** O dicionário em PDF deste dataset está
   inacessível no portal OpenDATASUS. O mapeamento de campos foi feito
   empiricamente a partir dos dados e da API Elasticsearch.

## Citação sugerida

```bibtex
@misc{healthbrdata_sipni_covid,
  author = {Sidney Silva},
  title = {{SI-PNI} {COVID-19} Vaccination Microdata — healthbr-data},
  year = {2026},
  url = {https://huggingface.co/datasets/sidneyjunior/sipni-covid-vacinacao},
  note = {Fonte original: Ministério da Saúde / OpenDATASUS}
}
```

## Contato

- **GitHub:** [healthbr-data](https://github.com/sidneyjunior/healthbr-data)
- **Projeto:** [healthbr-data](https://huggingface.co/healthbr-data)

---

*Última atualização: 27/fev/2026*
