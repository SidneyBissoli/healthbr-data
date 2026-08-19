# Contrato de consumo dos dados healthbr-data

> O que um consumidor (o pacote R `healthbR`, DuckDB, Python/Arrow, um auditor)
> pode assumir sobre o que está no bucket R2 `healthbr-data` — e o que **não**
> pode. É a fonte da verdade para quem lê; quem publica (pipelines) é obrigado
> a manter estas garantias (ver `policy-reproducibility-pt.md` §4).
>
> Criado em 18/ago/2026 a partir das decisões do SIM (`sim/exploration-pt.md` §9)
> e da política de reprodutibilidade. Consumidor de referência:
> `healthbR` (`inst/healthbr-data-integration.md` naquele repositório).

---

## 1. Acesso

- Endpoint S3: `https://5c499208eebced4e34bd98ffa204f2fb.r2.cloudflarestorage.com`,
  bucket `healthbr-data`, região `auto`; credenciais **públicas somente-leitura**
  no `README.md`. Egress gratuito.
- Leitura recomendada: `arrow::open_dataset("s3://healthbr-data/<prefixo>/",
  unify_schemas = TRUE)` ou DuckDB `read_parquet('s3://…/**/*.parquet',
  hive_partitioning = true, union_by_name = true)`.
- Download individual sem S3: `https://pub-99d9e1a3f5c542178d04efbddf1bba97.r2.dev/<chave>`.

## 2. Layout — estável, é API pública

| Dataset (id plano) | Prefixo | Partição | Chave no manifesto |
|---|---|---|---|
| `sipni-microdados` | `sipni/microdados/` | `ano=YYYY/mes=MM/uf=XX/` | `YYYY-MM` |
| `sipni-covid` | `sipni/covid/microdados/` | `ano=YYYY/mes=MM/uf=XX/` | `XX` (UF) |
| `sipni-agregados-doses` / `-cobertura` | `sipni/agregados/{doses,cobertura}/` | `ano=YYYY/uf=XX/` | `YYYY-XX` |
| `sipni-dicionarios` | `sipni/dicionarios/` | arquivos planos | — |
| `sinasc` | `sinasc/` | `ano=YYYY/uf=XX/` | `YYYY-XX` |
| `sih-rd` / `sih-sp` | `sih/rd/`, `sih/sp/` | `ano=YYYY/mes=MM/uf=XX/` | `YYYY-MM-XX` |
| `sim-dores` (planejado) | `sim/dores/` | `ano=YYYY/uf=XX/` | `YYYY-XX` |
| `sim-dofet` (planejado) | `sim/dofet/` | `ano=YYYY/` | `YYYY` |

Regras: um sub-dataset nunca fica aninhado sob um prefixo que já contém `ano=`
(Arrow recursaria); cada partição tem `part-0.parquet` (ou `part-NNNNN.parquet`
nos Python); `manifest.json` e `README.md` na raiz do prefixo — **exceção legada**: o
manifesto dos microdados SI-PNI está em `sipni/manifest.json` (não em `sipni/microdados/`).

## 3. Conteúdo dos Parquets — o que é garantido

1. **Todas as colunas são string** (`Utf8`). Tipagem é responsabilidade do
   consumidor (`healthbR::…(parse = TRUE)` faz isso).
2. **Nenhuma transformação de valor**: sem recodificação, sem normalização de
   datas, sem remapeamento de CID, sem apara além da que o leitor da fonte faz
   (`read.dbc`/`foreign` apara espaços e devolve NA para vazio; polars idem).
3. **Nenhuma unificação de schema entre eras** — cada Parquet tem o schema do
   arquivo-fonte de que veio. Exceções documentadas: SINASC 1994–95 (rename
   para a nomenclatura moderna) e, **provisoriamente**, SINASC
   `contador`→`CONTADOR` (pendente de reversão — ver §5.2). Consequência: ao
   abrir vários anos, use `unify_schemas`/`union_by_name`; colunas ausentes num
   ano vêm NA.
4. **Metadado embutido** em cada Parquet: chave `healthbr` do schema metadata,
   JSON com `dataset`, `source_url`, `source_file`, `source_hash_md5`,
   `source_size_bytes`, `download_date`, `pipeline_script`, `pipeline_version`,
   `git_commit` e, nos datasets com preliminares (SIM), `source_status`
   (`final` | `preliminar`). Arquivos do bootstrap 1.0.0 do SIH RD/SINASC têm o
   metadado por backfill (`git_commit_inferred: true`).
   ```r
   pq <- arrow::read_parquet(f, as_data_frame = FALSE)
   jsonlite::fromJSON(pq$metadata$healthbr)
   ```

## 4. `manifest.json` — o índice que o consumidor deve ler

```json
{
  "manifest_version": "1.0.0", "dataset": "sim/dores",
  "last_updated": "…Z", "pipeline_version": "1.2.0", "git_commit": "<sha>",
  "partitions": {
    "2025-AC": {
      "source_url": "ftp://…/PRELIM/DORES/DOAC2025.dbc", "source_file": "DOAC2025.dbc",
      "source_size_bytes": 358745, "source_hash_md5": "…", "source_status": "preliminar",
      "source_etag": null, "source_last_modified": null,
      "processing_timestamp": "…", "pipeline_script": "…", "pipeline_version": "1.2.0",
      "git_commit": "<sha>",
      "output_files": [{"path": "sim/dores/ano=2025/uf=AC/part-0.parquet",
                        "size_bytes": 1, "sha256": "…", "record_count": 4219}],
      "total_records": 4219, "total_size_bytes": 1
    }
  }
}
```

Garantias: uma entrada por partição publicada; `total_records` = linhas do
Parquet; `source_hash_md5` = MD5 do arquivo-fonte no momento do processamento;
`source_status` presente onde há preliminares (ausente = final). O manifesto é
atualizado **na mesma operação** que sobe os dados. Ler o manifesto (≈ KB) é a
forma barata de saber o que existe, o que é preliminar e quando foi processado —
antes de abrir o dataset.

## 5. Notas por dataset que o consumidor precisa conhecer

### 5.1 SIM (`sim/dores`, `sim/dofet`) — ver `sim/exploration-pt.md`
- Eras: CID-9 1979–1995 (`DATAOBITO` AAMMDD — dia `00` até 1990, só AAMM em 1991;
  `MUNIRES` 7 dígitos; `OCUPACAO` 3 dígitos; `INSTRUCAO`, `ESTCIVIL`) vs CID-10
  1996+ (`DTOBITO`/`DTNASC` DDMMAAAA; `CODMUNRES` 7 dígitos até 2005 e **6 a partir
  de 2006**; `OCUP` CBO 5→6 dígitos em 2006). `IDADE` (unidade+quantidade) é
  estável desde 1979. `LINHAA–LINHAII` vazias em 1996–1998.
- `contador` (1979–2005, 2009–2010) e `CONTADOR` (2006–2008, 2011+) são a mesma
  coluna com caixa diferente; o consumidor coalesce (`dplyr::coalesce`) se precisar.
  DuckDB `union_by_name` funde sozinho. Não é o número da DO — `NUMERODO` **não
  existe** nos arquivos públicos.
- `dores` = óbitos **não fetais** por UF de **residência**; fetais só em `dofet`
  (arquivo nacional, sem `uf=`).
- **Preliminares**: anos em `PRELIM/` do DATASUS entram no mesmo prefixo, marcados
  `source_status = "preliminar"` (metadado + manifesto + CSV de controle). Ano
  final N é publicado pelo Ministério em dez/N+1; até lá N e N+1 são preliminares
  e podem ser regravados a qualquer momento (o Parquet é substituído, sem
  histórico). Contrato com o `healthbR`: argumento `preliminary = FALSE` por
  padrão (exclui anos preliminares lendo o manifesto), aviso quando o retorno
  contém preliminar, coluna/atributo de status, função `*_status()` e vinheta
  com o calendário.

### 5.2 SINASC (`sinasc/`)
- 1994–95 renomeado para a nomenclatura moderna (documentado no card).
- `contador`→`CONTADOR` unificado pelo pipeline **hoje**; decisão de 18/ago/2026:
  reverter para publicar como na fonte (igual SIM/SIH) — quando isso acontecer,
  os anos 1996–2017 passam a ter `contador` minúsculo. Consumidores devem
  coalescer as duas caixas desde já para não quebrar.

### 5.3 SIH (`sih/rd`, `sih/sp`)
- Transição 1998 (CID-9→10, datas AAMMDD→AAAAMMDD, `ANO_CMPT` 2→4 dígitos), SIGTAP
  em 2008, 113 colunas desde 2015; SP com 3 schemas (16/18/36 cols). Nada
  convertido. Ver `sih/exploration-pt.md`.

### 5.4 SI-PNI
- Microdados 2020+ da origem JSON (sem artefatos `.0`); agregados 1994–2019 estáticos.

## 6. O que o consumidor NÃO pode assumir

- Que o dado de uma partição é o mesmo de ontem: revisões da fonte substituem o
  Parquet (política sem versionamento). Cache local deve ser invalidado por
  `source_hash_md5`/`processing_timestamp` do manifesto, não por nome de arquivo.
- Que existe histórico de versões ou os arquivos-fonte no R2 (`_raw/` é
  transitório de bootstrap).
- Que a lista de colunas é a mesma entre anos (ver §3.3).
- Que o `sync-status.json` é histórico — é sobrescrito a cada rodada.

## 7. Como este contrato evolui

Mudanças aqui exigem: bump de `PIPELINE_VERSION` do(s) pipeline(s) afetado(s),
nota no card do dataset, entrada neste documento com data, e aviso no
`inst/healthbr-data-integration.md` do `healthbR`. Layout de partição e
"tudo string" não mudam.

*Última atualização: 18/ago/2026.*
