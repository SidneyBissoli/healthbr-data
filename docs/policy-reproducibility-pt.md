# Política de reprodutibilidade, rastreabilidade e auditabilidade

> Vale para todos os datasets publicados pelo healthbr-data. Consultada
> por quem publica (pipelines) e por quem audita (pesquisadores, revisores).
> Definida em 18/ago/2026; aplicada aos pipelines dinâmicos a partir de
> `pipeline_version` 1.2.0.

## 1. Princípios

| Princípio | Compromisso | O que **não** é compromisso |
|---|---|---|
| **Reprodutibilidade** | Qualquer arquivo publicado pode ser regenerado byte a byte* a partir do arquivo-fonte do Ministério + o commit exato do código que o gerou. | Guardar cópia dos arquivos brutos do Ministério — a fonte é responsabilidade do Ministério da Saúde. |
| **Rastreabilidade** | Todo arquivo publicado declara de onde veio (URL), qual era a fonte (MD5, tamanho), quando foi baixada, com qual script/versão/commit foi processada. | — |
| **Auditabilidade** | Um terceiro consegue verificar, sem nos consultar, que o dado publicado corresponde à fonte declarada e ao código declarado, e detectar qualquer divergência. | — |
| **Sem versionamento de dados** | O R2 reflete a **última** versão publicada pelo Ministério. Quando a fonte é revisada, o Parquet é substituído. | Manter versões anteriores dos dados no R2. O histórico do *que* foi publicado e *quando* fica no git (CSVs de controle) e nos manifestos. |

\* "Byte a byte" para o conteúdo lógico (linhas, colunas, valores) e o
metadado embutido; o arquivo Parquet físico pode diferir se a versão do
Arrow mudar (codificação/compressão), o que não altera o dado. A
verificação de igualdade deve ser feita sobre o conteúdo lido, não sobre o
hash do arquivo Parquet — o SHA-256 no manifesto serve para verificar
integridade da cópia, não reprodutibilidade.

## 2. Onde cada garantia mora

| Artefato | Local | Conteúdo | Serve para |
|---|---|---|---|
| **Metadado embutido** (`healthbr`) | schema metadata de cada Parquet | `dataset`, `source_url`, `source_file`, `source_hash_md5`, `source_size_bytes`, `download_date`, `pipeline_script`, `pipeline_version`, `git_commit` | Rastreabilidade do arquivo isolado — viaja com o dado, mesmo copiado para fora do R2 |
| **Manifesto** (`<prefixo>/manifest.json`) | R2 | por partição: fonte (URL, tamanho, MD5, ETag quando há), `processing_timestamp`, `pipeline_script`/`pipeline_version`/`git_commit`, arquivos de saída com SHA-256, tamanho e contagem | Auditoria do dataset inteiro; integridade das cópias; base do sync-check |
| **Controle de versão** (`data/controle_versao_*.csv`) | git | uma linha por arquivo-fonte processado: nome, MD5, tamanho, linhas, colunas, timestamp, `pipeline_version`, `git_commit` | Estado "já processado" dos pipelines; **histórico** (via `git log`) do que foi publicado quando |
| **Código** | git (`SidneyBissoli/healthbr-data`) | pipelines, orquestração, docs | O `git_commit` gravado nos três artefatos acima aponta para cá |
| **Sync-status** | R2 `sync-status.json` + dashboard HF | comparação semanal fonte × redistribuição por partição | Detecção de deriva; não é histórico (é sobrescrito) |

Regra: **os três primeiros artefatos concordam entre si** para uma mesma
partição (mesmo MD5 da fonte, mesmo `git_commit`, mesma contagem). Uma
discordância é um defeito a corrigir, nunca a normalizar.

## 3. Como um terceiro audita (receita)

Exemplo para uma partição do SIH RD (`sih/rd/ano=2024/mes=01/uf=AC/`):

```r
library(arrow); library(jsonlite)
pq  <- read_parquet("s3://healthbr-data/sih/rd/ano=2024/mes=01/uf=AC/part-0.parquet",
                    as_data_frame = FALSE)
meta <- fromJSON(pq$metadata$healthbr)
meta$source_url; meta$source_hash_md5; meta$git_commit; meta$pipeline_version
```

1. **Fonte**: baixe `meta$source_url` do FTP do DATASUS; confira
   `tools::md5sum()` = `meta$source_hash_md5`. Se diferir, o Ministério
   revisou o arquivo depois da nossa publicação — o sync-check semanal deve
   sinalizar `outdated` e a manutenção reprocessa.
2. **Código**: `git checkout <meta$git_commit>` no repositório; leia o
   script `meta$pipeline_script`.
3. **Reprocessamento**: rode o script sobre o arquivo-fonte (o pipeline lê
   com `read.dbc`/`polars`, converte tudo para string, particiona). Compare
   o conteúdo com o Parquet publicado (`nrow`, `names`, `all.equal` sobre o
   data frame).
4. **Integridade da cópia**: `sha256` do arquivo baixado = `output_files[].sha256`
   da partição em `manifest.json`; `record_count` = `nrow`.
5. **Consistência interna**: a linha do arquivo em `data/controle_versao_*.csv`
   (no commit indicado) traz o mesmo MD5, contagem e `git_commit`.

## 4. Obrigações de quem publica (checklist por pipeline)

- [ ] Grava o metadado `healthbr` completo (seção 2) em **todo** Parquet.
- [ ] Atualiza o manifesto **na mesma operação** que sobe os dados (nunca
      dados sem manifesto).
- [ ] Registra no CSV de controle `pipeline_version` e `git_commit`.
- [ ] Bumpa `PIPELINE_VERSION` sempre que a saída (dados ou metadado) mudar.
- [ ] Roda a partir de um clone do repositório (a manutenção e o
      `launch-bootstrap-vps.sh` garantem isso); fora de um clone, define
      `HEALTHBR_GIT_COMMIT` explicitamente — `"unknown"` no metadado é um
      defeito de operação, não um valor aceitável em produção.
- [ ] Não transforma valores (política de fidelidade à fonte,
      `project-pt.md` §9): a reprodutibilidade depende de o pipeline ser
      uma função determinística e simples da fonte.
- [ ] Documenta no card do dataset a seção "Reproducibility & provenance"
      apontando para esta política.

## 5. Limitações conhecidas (declaradas, não escondidas)

- **Arquivos do bootstrap com `pipeline_version` 1.0.0** (mar/2026) não
  nasceram com metadado embutido. **Resolvido para os módulos `.dbc`
  (18/ago/2026)**: `scripts/maintenance/backfill-metadata.py` regrava só o
  schema metadata dos Parquets do SIH RD e do SINASC (conteúdo verificado
  igual via `pyarrow` `equals()` antes de subir), montando o registro
  `healthbr` a partir do CSV de controle + manifesto: `pipeline_version`
  **original** (1.0.0; ou 1.1.0 nos que já tinham registro sem commit),
  `download_date` = timestamp de processamento do CSV, `git_commit`
  **inferido** (último commit do script ≤ timestamp de processamento; se o
  bootstrap precedeu o 1º commit do script — caso do SIH RD `020ee5c` e do
  SINASC `ac2ff96`, scripts idênticos até a 1.1.0 —, esse 1º commit) e
  marcado com `git_commit_inferred: true` + bloco `metadata_backfill`
  (quando, por qual script/commit, com que base). Manifesto (SHA-256 novo,
  `git_commit_inferred`, `metadata_backfilled_at`) e CSV (`pipeline_version`,
  `git_commit`) recebem os mesmos valores — a regra dos três artefatos vale
  também para o backfill. O SHA-256 dos arquivos muda (rodapé regravado);
  o conteúdo lógico não. Um auditor deve tratar `git_commit_inferred` como
  "melhor evidência", não como registro contemporâneo.
  **Ainda em aberto**: SI-PNI microdados/COVID 1.0.0 — os microdados são
  regravados nas revisões da fonte (backfill oportunista) e o COVID não tem
  metadado de fonte utilizável no manifesto; ficam para depois.
- **Sem versão anterior dos dados**: se o Ministério revisar um arquivo,
  a versão anterior deixa de existir no R2 (e no FTP). O que resta dela é o
  registro (MD5, contagem, data) no histórico git do CSV e no manifesto
  antigo — se alguém precisar do dado anterior, precisa tê-lo baixado.
- **Fontes que o Ministério republica com hash novo sem mudar conteúdo**
  (SI-PNI COVID, Spark) aparecem como `outdated` e são reprocessadas mesmo
  sem mudança de dado; isso é ruído aceito em favor da regra simples.
- **Módulos estáticos** (agregados 1994–2019, dicionários) foram publicados
  uma vez com `pipeline_version` 1.0.0 e não têm automação; a rastreabilidade
  deles é a do manifesto + CSV + código no git.

## 6. Relação com outros documentos

- `project-pt.md` §9 — princípio de publicar sem transformar (pré-condição
  da reprodutibilidade).
- `reference-pipelines-pt.md` §11 — mecânica dos manifestos; §15 —
  metadado de proveniência e manutenção.
- `strategy-synchronization.md` — comparação fonte × redistribuição.
- `CLAUDE.md` — resumo operacional para quem altera pipelines.
