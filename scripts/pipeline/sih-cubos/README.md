# Pipeline `sih-cubos` — cubos anuais do SIH/SUS (`sih/cubos/`)

Receita do dataset derivado `sih/cubos/` (card: `guides/dataset-cards/sih-cubos-README.md`;
referência operacional: `docs/reference-pipelines-pt.md` §16). O produtor dos cubos é
**este repositório** desde 2026-09-08; até então era o `sih-br-mcp` (workflow
`rebuild-cubes.yml`, commit `a3284c0`), que agora é **consumidor** do canal, como o
`healthbR`. A decisão de desenho ("healthbr-data é produtor; MCP é consumidor") é de
2026-09-07 e está registrada no CONTEXT.md do sih-br-mcp (decisão 27).

## O que sai

Por ano de internação (`DT_INTER`), três cubos Parquet e um sidecar de proveniência:

| Arquivo | Conteúdo |
|---|---|
| `sih_causas_<ano>.parquet` | internações por mês, UF, capítulo/grupo CID, revisão da CID, sexo, idade, raça, CSAP |
| `sih_series_<ano>.parquet` | séries mensais por UF, capítulo e revisão da CID |
| `sih_icsap_<ano>.parquet` | ICSAP por município de residência, grupo CSAP e estrato demográfico (com `n_total` do estrato) |
| `sih_provenance_<ano>.json` | safra do cubo: partições de `sih/rd/` lidas (URL, MD5, tamanho, data de download de cada `.dbc`), totais, versão e commit do builder, eras, moedas, notas |

Mais o `manifest.json` do canal (tamanho e SHA-256 de cada arquivo, resumo do sidecar por
ano, o bloco `tables` com o SHA-256 das tabelas de classificação e o bloco `population`
com o dos denominadores), as próprias tabelas em `sih/cubos/tables/*.json` e os
denominadores populacionais abaixo. Base pública: `https://data.sidneybissoli.com/sih/cubos/`.

### Denominadores populacionais (`build-population.R`, desde 2026-09-08)

Os arquivos de população que o consumidor usa nas taxas por 100 mil vivem no MESMO
prefixo, ao lado dos cubos, assinados no bloco `population` do manifesto:

| Arquivo | Conteúdo | Fonte |
|---|---|---|
| `pop_uf.parquet` | UF × sexo (M/F) × idade simples (0–90, 90 = 90+) × ano, 2000..último cubo FECHADO (127.764 linhas até 2025) | IBGE, Projeção da População **Revisão 2024** (planilha oficial `projecoes_2024_tab1_idade_simples.xlsx` do FTP do IBGE; a SIDRA 7358 só tem a revisão 2018) |
| `pop_municipios.parquet` | município × sexo (M/F/total) × faixa etária quinquenal × ano, 1991–2024 (6.326.761 linhas); `source` = censo/contagem/estimativa | DATASUS FTP `IBGE/POP/POPBR{aa}.zip` (1991–2012) e `IBGE/POPSVS/POPSBR{aa}.zip` (2013–2024), lidos por `csapAIH::ler_popbr` |
| `pop_uf_agregado.parquet` | UF × sexo × faixa etária × ano, 1991–1999 (8.484 linhas) | soma de `pop_municipios` (única operação permitida) |
| `pop_provenance.json` | safra: `built_at`, `last_year`, fontes (URLs), linhas/anos/UFs/Brasil de cada arquivo, versões dos pacotes | — |

Regras (CONTEXT.md do sih-br-mcp): **nada interpolado**; **nunca além do último cubo
FECHADO do SIH** — `POP_UF_ULTIMO_ANO` é uma constante explícita no script (2025), e o
workflow reprova se ela passar do maior ano com `window_complete` no canal; município → UF
só por soma. Linhas com idade ignorada (`I000`, 1993–1999) ficam com `age_group` nulo.
Workflow **`build-sih-population.yml`** (só `workflow_dispatch`; ~4 min; 35 downloads do
FTP do DATASUS com 3 tentativas por ano — um ano faltando ABORTA): R + `fulvionedel/csapAIH`
(GitHub; não está no CRAN) → gate da regra do cubo fechado + contagens → smoke do consumidor
com a população nova → `publish-cubes.sh none "" "" <pasta>` (`cubes-manifest.mjs
--population --verify` confere cada arquivo com DuckDB contra o sidecar). Quando rodar de
novo: cubo do ano seguinte fechou (subir `POP_UF_ULTIMO_ANO`), nova revisão do IBGE, POPBR
reeditado. Localmente: `Rscript scripts/pipeline/sih-cubos/build-population.R --out <dir>`
(Windows serve; precisa de csapAIH, readxl, tidyr, arrow, dplyr, cli, jsonlite). Provado
em 2026-09-08: build local = parquets do sih-br-mcp linha a linha nos três arquivos
(`EXCEPT ALL` = 0; `pop_uf` byte a byte, sha `49e6e6f7…`).

### Pré-agregados da ICSAP (`derive-icsap-summary.mjs`, desde 2026-09-09)

Derivados dos cubos JÁ PUBLICADOS (função pura — nada dos microdados), no mesmo
prefixo, assinados no bloco `icsap_summary` do manifesto (1.3.0; PLAN-005 do
sih-br-mcp, item `sih:serie-pre-agregada`):

| Arquivo | Conteúdo | Para quê |
|---|---|---|
| `sih_icsap_resumo.parquet` | universe (csapaih/all) × year × uf × cid_revision × csap_group, com n_icsap, total_days, total_value, deaths e o n_total do denominador; TODOS os anos num arquivo (~276 KB, 35.887 linhas em 1992–2025) | a série de 34 anos do sih-br-mcp cai de 310 s (DISTINCT refeito a cada consulta em 1/4 vCPU) para ~1 s, inclusive a frio |
| `sih_icsap_estratos_YYYY.parquet` | um registro por estrato (chaves cruas do cubo + n_total) — o DISTINCT gravado uma vez (~2,5 MB/ano recente) | denominador de filtros finos (município, sexo, idade, raça) sem refazer o DISTINCT |
| `icsap_summary_provenance.json` | `built_at`, versão do derivador, `derived_from` (sha256 do cubo-fonte POR ANO), contagens | contrato de frescor |

### Pré-agregados do cubo de causas (`derive-causas-summary.mjs`, desde 2026-09-10)

Mesma receita, agora sobre o cubo mais pesado do canal (1.253 MB nos 34 anos).
Assinados no bloco `causas_summary` do manifesto (1.4.0; PLAN-006 do sih-br-mcp,
item `sih:causas-pre-agregada`):

| Arquivo | Conteúdo | Para quê |
|---|---|---|
| `sih_causas_resumo.parquet` | **grão A**: year × uf × cid_chapter × cid_revision × is_csap × exclusion, com n, days, value (DECIMAL 18,2) e deaths; TODOS os anos num arquivo (569 KB, 47.790 linhas em 1992–2025) | internações, óbitos, dias e gasto por UF e capítulo na série longa, sem baixar 1,25 GB |
| `sih_causas_estratos_YYYY.parquet` | **grão B**: o grão A mais sexo, faixa etária quinquenal e raça (18,8 MB nos 34 anos; 0,25 MB em 1995 contra 22,8 MB do cubo) | recortes demográficos sem o cubo pesado |
| `causas_summary_provenance.json` | `built_at`, versão do derivador, `derived_from` (sha256 do cubo-fonte POR ANO), grão declarado e totais por ano | contrato de frescor e moeda da conferência |

A **faixa etária é a mesma de `pop_uf_agregado.parquet`** (`0-4` … `75-79`,
`80 e +`; idade ausente ou negativa = faixa nula, que entra no total e fica fora
de qualquer recorte etário): é o que deixa o consumidor reusar a regra que já
existe para a taxa antes de 2000 — recorte só nos limites das faixas. **Fora do
grão de propósito** (medido e rejeitado): mês, categoria CID de 3 dígitos
(`cid_group`) e grupo CSAP; o grão com a categoria de 3 dígitos custaria 333 MB e
694 s de derivação. Quem pede isso segue no cubo de causas, com o número certo.

O grão A é uma **rolagem do grão B**, não uma segunda leitura dos cubos: cada ano
do B é conferido contra o cubo nas quatro medidas durante a derivação, e o A
contra os mesmos totais — nada sai do derivador sem reproduzir o cubo de onde
veio. Medido em 2026-09-10, com uma thread (como no container `basic`):
"internações, dias, gasto e óbitos por ano, 34 anos" custa **0,01 s pelo grão A
contra 5,50 s pelos cubos**, com resposta idêntica.

### Frescor e operação dos dois resumos

Regra de frescor: `cubes-manifest.mjs --summary` / `--causas-summary` REPROVA se o
`derived_from` de qualquer ano não bater com o sha256 do cubo correspondente no
bloco `years` final; sem a flag, o bloco herdado gera AVISO quando um rebuild o
deixou velho — e o consumidor cai no caminho lento naquele ano. **Rodar
`build-sih-summary.yml` depois de todo rebuild de cubos**: ele deriva e publica os
DOIS resumos no mesmo run (só `workflow_dispatch`; selftest dos dois derivadores →
deriva com sha conferido, `.derive-cache` compartilhado → `publish-cubes.sh none
data/sih-cubos "" "" <pasta> <pasta>`). Publicar um sem o outro é o defeito a
evitar: os dois blocos vivem no mesmo manifesto e o rebuild de um ano invalida os
dois. Localmente:
`node scripts/pipeline/sih-cubos/derive-icsap-summary.mjs --out <dir>` e
`node scripts/pipeline/sih-cubos/derive-causas-summary.mjs --out <dir>`
(a máquina de baixar cubo conferindo hash é compartilhada, em `summary-lib.mjs`).

## Cadeia de reprodução (política do bucket: `docs/policy-reproducibility-pt.md`)

```
Ministério da Saúde / DATASUS (RD<UF><AAMM>.dbc, FTP)
  → sih/rd/ (Parquet 1:1, sih-pipeline-r.R; manifesto com MD5 e data de download)
  → build-aggregations.R (lê sih/rd/ pelo healthbR; tabelas de tables/)
  → sih/cubos/ (cubos + sidecar + manifesto + tables/)
```

- **Builder:** `build-aggregations.R` (`BUILDER_VERSION` 2.7.0). A 2.7.0 é a 2.6.1 do
  sih-br-mcp mudada de casa — mesma agregação, cubos byte a byte iguais (provado em
  2026-09-08: 2023/RR local = fixture do sih-br-mcp; 2025 no runner = delta zero).
  Regras de janela, eras (CID-9 1992–1997, `uf` de arquivo até 1997, raça nula antes
  de 2008, moedas), universo ICSAP do csapAIH e sidecar estão no cabeçalho do script.
- **Linha de comando:** `rebuild-cubes.R --years 2023[,2024] [--ufs RR,AC|all] [--out <dir>]`.
  As UFs de arquivo de um ano existente vêm do **sidecar anterior** (o workflow o baixa
  do canal para a pasta de saída); ano novo exige `--ufs`.
- **Tabelas de classificação (`tables/`)** — contrato versionado, assinado no manifesto:
  `cid9-codes.json`, `cid9-chapters.json` (CID-9 de 6 dígitos → categoria e capítulo
  CID-10), `csap-groups.json` (ICSAP oficial, Portaria 221/2008, CID-10),
  `csap-groups-cid9.json` (lista ICSAP DERIVADA para CID-9, não oficial),
  `csap-universe.json` (universo do % ICSAP como o csapAIH). Os três primeiros e o
  último são GERADOS por `tables/generators/` a partir de insumos públicos:

  ```bash
  cd scripts/pipeline/sih-cubos
  bash tables/generators/fetch-insumos.sh            # TAB_SIH_199201-199712.zip → insumos/tab/ (gitignored)
  python tables/generators/estudo-1992-1997-cnv.py   # insumos/cid9_codes.csv + relatório do DV
  python tables/generators/cid9-tables.py            # tables/cid9-codes.json, cid9-chapters.json
  python tables/generators/csap-universe-tables.py   # tables/csap-universe.json
  ```

  O zip vem do FTP do DATASUS (`SIHSUS/199201_200712/Auxiliar/`) e uma cópia está no
  canal em `sih/cubos/insumos/` (SHA-256
  `b433310785e08b5d2d0c5a438f495ac6b2af9a10d86d8741a3252bc268b1ff88`) para a cadeia não
  depender do FTP. Regenerar muda só `metadata.generated_at`. `csap-groups.json` e
  `csap-groups-cid9.json` são tabelas de autoria (Portaria; `docs/analise-003` do
  sih-br-mcp) — editadas à mão, não geradas. O sih-br-mcp embarca cópias em `src/data/`
  e o CI dele confere o SHA-256 contra `manifest.json.tables`.

## Como roda: `.github/workflows/rebuild-sih-cubes.yml`

- **Gatilhos:** cron terça 06:00 UTC; `workflow_dispatch` (`years`, `ufs`, `force`); e o
  `sync-check.yml` dispara ao fim da rodada pós-manutenção (`gh workflow run`).
- **`decide`:** baixa o estado do canal (`canal-state.mjs`: manifesto + 34 sidecars),
  compila o consumidor de referência (checkout de `SidneyBissoli/sih-br-mcp`) e mede o
  frescor de cada cubo com `scripts/freshness-check.mjs` dele contra
  `sih/rd/manifest-summary.json`; roda o autoteste do gate de delta; escolhe os anos
  (manual > force > atrás > nada; máximo 2 por rodada automática).
- **`build`:** R + healthbR (GitHub main; o CRAN limita o SIH a 2008+) + arrow pelo
  RSPM; sidecar publicado → `before/` e pasta de saída; `Rscript rebuild-cubes.R`;
  **gate 1** (contagem por partição = manifesto de `sih/rd/`, dentro do builder);
  **gate 2** `cube-delta.mjs` (partição perdida sem retirada, queda > 1 %, janela
  regredida, escopo mudado sem `ufs`); **gate 3** smoke stdio do consumidor sobre os
  cubos novos; `publish-cubes.sh` (`cubes-manifest.mjs --verify` com DuckDB → cubos →
  tabelas → manifesto por último → conferência de `Content-Length` pelo domínio);
  linha em `data/controle_versao_sih_cubos.csv` (commit do bot; único commit por run).
- **Estado = o canal.** Nenhum sidecar é versionado aqui. Para saber o que está
  publicado: `node canal-state.mjs --out state`.
- **Limites:** 2 anos por run (memória do runner); fila de 1 rodando + 1 pendente;
  ~20–35 min por par de anos.

### Rodar e monitorar

```bash
gh workflow run rebuild-sih-cubes.yml -f years=2025            # rebuild de um ano
gh workflow run rebuild-sih-cubes.yml -f years=2026 -f ufs=all # cubo NOVO
gh run list --workflow rebuild-sih-cubes.yml --limit 5
gh run watch <id>
# conferir o canal contra os sidecars (o ?v= fura o cache de 300 s)
curl -s "https://data.sidneybissoli.com/sih/cubos/manifest.json?v=$(date +%s)" | node -e '
  const m=JSON.parse(require("fs").readFileSync(0));const y=Object.values(m.years);
  console.log(y.length,"anos",y.reduce((s,a)=>s+a.records_in_cube,0).toLocaleString("pt-BR"),"internações",
  Object.keys(m.tables||{}).length,"tabelas")'
```

Localmente (Windows serve; precisa do healthbR dev instalado e de `npm ci` nesta pasta):

```bash
"/c/Program Files/R/R-4.6.1/bin/Rscript.exe" scripts/pipeline/sih-cubos/rebuild-cubes.R --years 2023 --ufs RR --out /tmp/prova
node scripts/pipeline/sih-cubos/cube-delta.mjs --selftest --fixtures scripts/pipeline/sih-cubos/state/sidecars
```

## Arquivos

| Arquivo | Papel |
|---|---|
| `build-aggregations.R` | builder (agregação, sidecar, gate 1) |
| `rebuild-cubes.R` | CLI do builder para o workflow e para a mão |
| `build-population.R` | denominadores populacionais (pop_uf, pop_municipios, pop_uf_agregado + pop_provenance.json); `build-sih-population.yml` |
| `canal-state.mjs` | baixa manifesto + sidecars do canal (estado) |
| `cube-delta.mjs` | gate 2 (+ `--selftest`) |
| `cubes-manifest.mjs` | manifesto assinado (`--verify` com DuckDB; `--tables`) |
| `publish-cubes.sh` | publicação ordenada no R2 + conferência pelo domínio |
| `controle.mjs` | linha por build em `data/controle_versao_sih_cubos.csv` (`seed` fez a carga inicial dos 34 anos em 2026-09-08) |
| `tables/`, `tables/generators/` | contrato de classificação e sua regeneração |
| `package.json` | `@duckdb/node-api` para o `--verify` |

Insumos e saídas locais são gitignored: `data/sih-cubos/`, `state/`, `node_modules/`,
`tables/generators/insumos/`, `cubes-manifest.json`, `previous-manifest.json`.
