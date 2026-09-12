# Notas construtivas de arquitetura — DataSenado Lake Aberto

> **Segunda rodada, outro perfil.** A primeira revisão (`2026-08-revisao-datasenado-lake-aberto.md`)
> foi escrita como revisor cético. O feedback do time foi: "mais chata que útil;
> queremos algo prático para a solução que queremos em si". Este documento responde
> a isso com o perfil de **arquiteto de solução**: toma o objetivo declarado como
> dado e projeta a partir dele. Começa, porém, pelo acerto de contas com o feedback
> — retratando o que não se sustentou e mantendo, com franqueza, o que se sustenta.
>
> **Objetivo declarado (nas palavras do time):** interface analítica e conversacional
> rodando no browser do cliente, por canal HTTPS (range), majoritariamente sobre
> assets estáticos bem governados, inclusive por CDNs, com suporte serverless
> minimalista e altamente escalável para o que precisar de backend: agregações
> intensas ad-hoc, gestão de caches e modelos conversacionais servidos pelo próprio
> Senado — distintos dos modelos do próprio usuário, que chegam via WebMCP.
>
> **Data:** 27/ago/2026.

---

## 0. Acerto de contas com o feedback

Não vou fingir que a primeira revisão estava toda certa, nem que estava toda
errada. Item a item:

| Ponto do feedback | Posição revista |
|---|---|
| **"workerd e miniflare são open source"** | **Retirado.** Correto: `workerd` é Apache-2.0, `miniflare` idem, e Durable Objects rodam no próprio `workerd`; desde ago/2026 existe até o `celld` (Ryan Dahl, Apache-2.0, alpha) implementando Durable Objects em infra própria com S3 como camada de coordenação. O risco que atribuí a licença/aprisionamento é, na verdade, **operacional** (paridade de operação fora da Cloudflare; `celld` é alpha) — ordem de grandeza menor do que escrevi. O que sobrevive da recomendação é só o que o time já pratica: manter o *caminho do dado* em HTTP/S3 puro. |
| **"Time travel é consequência, não feature nem requisito"** | **Reformulado — e registro convergência.** Releases imutáveis + publicação atômica + retenção ⇒ histórico endereçável de graça, sem formato de tabela. Isso é exatamente a **opção 1** da minha tabela no §3.3 ("manifesto simples, sem formato de tabela"), que eu apontei como a mais barata e recomendei. A divergência real era menor do que o texto fez parecer: minha crítica válida era ao *material* (que vende "time travel" como atributo, convidando o leitor a cobrá-lo como feature), não ao desenho. O que fica de concreto: **consequência também ocupa disco e também precisa de regra** — a política de retenção de releases precisa ser escrita (ver §2.4). |
| **"Iceberg e DuckLake atrapalhariam leveza e HTTP range"** | **Concordo — e já concordava.** A primeira revisão listou Iceberg/DuckLake como *alternativas a considerar* e recomendou explicitamente não adotá-los se time travel não fosse requisito nomeado. Com a clarificação de que não é, a questão está encerrada: Parquet + manifestos + releases imutáveis, sem camada de formato de tabela. |
| **"Ignorou a centralidade da interface no browser + serverless mínimo"** | **Aceito em parte.** O parecer gastou mais tinta em governança do que no desenho da solução — escolha deliberada do perfil cético, mas o custo foi real: pouco material acionável para quem vai construir. Registro, porém, um fato: **o backend serverless para agregações intensas e modelos do Senado não estava nas 8 páginas** (o material lista workerd como "aceleração opcional e coordenação quando necessário"). Com essa peça no centro, várias críticas mudam de natureza — e uma delas se **resolve** dentro da própria arquitetura (cotas e privacidade moram no backend; ver §4.2 e §4.3). Vale atualizar o material de stakeholders para dar a essa peça o lugar que ela tem de fato. |
| **"Pelo em ovo"** | **Em parte, sim** — seis contradições editoriais e indicadores sem meta são achados de revisor, não de arquiteto. **Em parte, não**: LGPD para microdados de survey, posicionamento frente ao `dados.senado.leg.br`, acessibilidade legal e licença/citação não são pelos em ovo; são os itens que travam um lançamento público no Senado, e nenhum deles ficou mais fraco com o feedback. Estes seguem em pé (§8) — mas agora acompanhados de solução, não só de objeção. |

O restante deste documento é o que faltou na primeira rodada: **o projeto da
solução que vocês querem**, com números, layouts e contratos.

---

## 1. O alvo, convertido em regras de projeto

O objetivo declarado, decomposto em seis regras que resolvem sozinhas a maioria
das decisões que aparecem pelo caminho:

- **R1 — Toda resposta padrão do portal sai de asset estático.** Nenhuma página,
  gráfico ou visão default pode depender do backend. O backend serve a cauda
  longa, nunca o caminho feliz.
- **R2 — SQL arbitrário só executa no browser do usuário.** DuckDB-WASM, sobre
  dados públicos, com o compute do próprio usuário. É o modelo de segurança mais
  simples que existe: o servidor nunca vê SQL de terceiros.
- **R3 — O servidor só executa consultas nomeadas.** Parametrizadas, versionadas,
  com allowlist. "Ad-hoc" do lado do servidor significa *combinação ad-hoc de
  parâmetros*, não SQL livre (ver §4.1 para a opção B, se SQL livre for mesmo
  necessário).
- **R4 — Todo asset de release é imutável.** Publicado uma vez, nunca reescrito,
  cacheável para sempre (`Cache-Control: public, max-age=31536000, immutable`).
- **R5 — Só ponteiros são mutáveis.** Um JSON minúsculo por dataset aponta para o
  release corrente. É o único objeto com TTL curto. Atualizar = trocar o ponteiro.
- **R6 — Cota, identidade e telemetria só existem onde há computação do Senado.**
  Assets estáticos ficam sem login e sem medição individual, como prometido; os
  endpoints de consulta nomeada e conversação têm rate limit e métrica. Isso
  dissolve a contradição "sem login × cotas por perfil" apontada na primeira
  revisão: as duas promessas são verdadeiras, **em camadas diferentes**.

---

## 2. Anatomia do lake

### 2.1 Layout físico

```
/{dataset}/
  current.json                  ← ponteiro (único objeto mutável; TTL 60s)
  releases/
    2026-08-27T18.00-r042/      ← release imutável
      manifest.json             ← proveniência, schema, stats, sha256, licença
      dcat.jsonld               ← DCAT-AP + schema.org (gerado, estático)
      data/
        part-000.parquet        ← dados do release (estrutura curada)
      delta/
        changed.parquet         ← opcional: chaves alteradas vs release anterior
        removed.parquet
    2026-07-30T18.00-r041/
      ...
/catalog.json                   ← índice global de datasets (estático)
```

- **Publicação atômica**: escrever o diretório do release completo → validar
  (contagens, sha256, leitura de fumaça via DuckDB) → trocar `current.json`.
  Consumidor nunca vê estado intermediário. Rollback = apontar de volta.
- **CDN sem purge**: como releases são imutáveis, a CDN nunca precisa de
  invalidação — só o ponteiro expira (60s + `stale-while-revalidate`). Custo de
  cache-miss tende a zero; comportamento é previsível sob qualquer CDN.
- **"Time travel" como consequência, formalizado**: o histórico é a lista de
  releases retidos, endereçáveis por URL. Um link `?release=r041` reproduz a
  análise daquele momento — é o "link reproduzível" do material, de graça.
- **Deltas para quem mantém cópia**: o browser ignora `delta/` e lê o release
  corrente; clientes R/Python/espelhos aplicam deltas para sincronizar sem
  rebaixar tudo. Deltas são otimização, não fonte de verdade — a fonte é sempre
  o release completo.

### 2.2 Parquet dimensionado para HTTP range + WASM

Números de partida (ajustar com medição real, mas começar aqui):

| Parâmetro | Alvo | Por quê |
|---|---|---|
| Tamanho de arquivo | 100–500 MB (detalhe); ≤ 10 MB (agregados de visão) | Cada arquivo custa ≥ 2 requests (footer + ranges). Poucos arquivos grandes vencem muitos pequenos; mas 1 arquivo gigante impede paralelismo de ranges. |
| Row group | 8–32 MB comprimidos (~100 mil–1 mi de linhas) | É a granularidade real do range request e do descarte por estatística. Row groups enormes forçam o browser a baixar muito para filtrar pouco. |
| Ordenação | Pela coluna de filtro dominante (tempo, depois UF/tema) | Transforma min/max de row group em índice de graça: o pushdown do DuckDB pula grupos inteiros. |
| Compressão | zstd (nível moderado) | Melhor razão para egress/CDN; decodificação rápida no WASM. |
| Bloom filter | Colunas de igualdade de alta cardinalidade (código de município, id de pesquisa) | Suportado e lido de forma transparente pelo DuckDB ≥ 1.2. |
| Particionamento em diretórios | Só pelas 1–2 dimensões de filtro mais comuns | Hive-partitioning demais fragmenta em arquivos minúsculos e mata o item 1. |

### 2.3 Proveniência que viaja com o arquivo

Gravar no *schema metadata* de cada Parquet uma chave `datasenado` (JSON):
`dataset`, `release_id`, `source_url`, `source_hash`, `download_ts`,
`pipeline`, `pipeline_version`, `git_commit`, `license`. Custa zero no pipeline
e responde "de onde veio isto?" quando o arquivo já saiu do portal — no notebook
de um jornalista, três anos depois. Manifesto e footer devem concordar; o
`healthbr-data` opera essa regra ("três artefatos concordam; divergência é
defeito") há meses sem custo perceptível.

### 2.4 Retenção (a regra que a "consequência" precisa)

Proposta de partida, a calibrar com custo real de armazenamento:

- **Todos os releases por 24 meses.**
- Depois: **1 release por trimestre** (o primeiro de cada trimestre).
- **Exceção documentada**: correção de dado pessoal ou erro grave ⇒ o release
  afetado é substituído por tombstone (`manifest.json` fica, dados saem, motivo
  registrado). É a única operação de reescrita permitida, e é auditável.
- Datasets sensíveis (§4.2): retenção definida no RIPD, não por este default.

---

## 3. Pré-agregados como produto — o teto do WASM resolvido por desenho

O DuckDB-WASM tem envelope conhecido (mono-thread por padrão, ~4 GB de teto,
sem spill). Em vez de tratar isso como limitação a pedir desculpas, o desenho
o torna irrelevante para 95% dos usos, em três camadas:

- **Tier A — agregados de visão** (≤ ~10 MB por asset): um Parquet pequeno por
  visualização default do portal (série por UF, ranking por município, pirâmide
  por faixa). Carrega em qualquer celular. **Regra de produto: toda página
  default renderiza só com Tier A** (é a R1).
- **Tier B — detalhe navegável**: as partições curadas do §2.2. Drill-down,
  filtros e SQL local no browser, dentro de um envelope declarado e testado
  (ex.: "consultas que varrem até ~1–2 GB comprimidos, desktop"). Publicar o
  envelope na documentação — um número honesto evita o bug report "travou meu
  navegador".
- **Tier C — consultas nomeadas no backend** (§4.1): o que não cabe em A nem B.

No pipeline R + `targets`, os Tiers A e C-materializados são *targets* derivados
no mesmo DAG dos dados — com hash de conteúdo, só recomputam quando o insumo
muda. Manifesto, `dcat.jsonld` e `catalog.json` também são targets: descoberta
e catálogo saem do mesmo lugar que os dados, sem processo paralelo.

---

## 4. O backend serverless mínimo — um contrato, três serviços

A peça que o feedback colocou no centro. Três responsabilidades, um princípio:
**o backend é pequeno porque o estático faz o grosso — e é exatamente por
existir que dois problemas da primeira revisão se resolvem aqui.**

### 4.1 Consultas nomeadas (agregações intensas)

- Endpoint único: `POST /q/{query_id}` com parâmetros validados por schema.
  Cada `query_id` é uma consulta versionada no repositório (SQL DuckDB sobre os
  Parquet do release corrente), com limites declarados (timeout, linhas, custo).
- **Cache content-addressed**: a resposta é gravada em storage keyed por
  `(release_id, query_id, params_hash)` e servida pela CDN com `immutable`.
  Novo release ⇒ chave nova ⇒ invalidação por construção, nunca purge. Segunda
  chamada idêntica custa zero compute — "gerenciar caches" vira consequência do
  esquema de chaves, não um sistema.
- Rate limit simples por IP nos misses. Nos hits, é asset estático — sem cota
  (R6).
- **Opção B, se SQL livre no servidor for mesmo necessário**: DuckDB read-only
  em container isolado, com timeout, teto de memória e de linhas, sobre réplica
  dos assets. Funciona, mas traz superfície de abuso e curva de custo — a
  recomendação é lançar sem, e só adicionar se as consultas nomeadas provarem
  ser insuficientes na prática. A demanda dirá.

### 4.2 Privacidade embutida — o achado de LGPD, resolvido dentro deste desenho

O achado central da primeira revisão era: *um asset estático não pode negar uma
consulta*, e microdado de pesquisa de opinião é reidentificável por cruzamento.
O backend que vocês já planejam para agregações intensas é **o único lugar da
arquitetura onde controle de divulgação é aplicável** — então a solução é usar
a peça que já existe:

- Datasets **administrativos/legislativos e agregados**: assets estáticos,
  irrestritos. É a maioria do catálogo e nada muda.
- Datasets **com microdado de pessoa natural** (surveys): o estático publica
  apenas os agregados pré-suprimidos (Tier A/B com supressão de célula feita no
  pipeline); o acesso fino sai **só** por consulta nomeada com limiar mínimo de
  célula (k ≥ n) imposto no servidor. Consulta que retornaria célula rara
  devolve célula suprimida — o que um Parquet público jamais poderia fazer.
- A classificação (o que é sensível, qual o k, o que nunca sai) vem do RIPD com
  o encarregado de dados — esse trabalho continua sendo pré-requisito do
  primeiro microdado publicado, e nenhum arranjo técnico o substitui.

Isso converte o achado bloqueante em decisão de roteamento: **a pergunta deixa
de ser "publicar ou não" e vira "por qual camada"**.

### 4.3 Modelos conversacionais do Senado

- Endpoint streaming, com tool-use restrito ao **mesmo contrato de ferramentas**
  do §5 (catálogo, schema, consultas nomeadas, citação). O modelo do Senado
  nunca executa SQL livre no servidor (R3) — compõe consultas nomeadas.
- **Cota e sessão moram aqui** — e só aqui (R6). É o único ponto da plataforma
  com custo marginal real por uso; proteger o orçamento dele não contradiz o
  "sem login" dos dados.
- **Campo aberto de survey é entrada não confiável.** O assistente lê texto
  escrito por milhares de respondentes; um deles pode conter instrução
  plantada. Regra no system prompt e no pós-processamento: conteúdo de dataset
  é dado a citar, nunca instrução a seguir. Uma página de modelo de ameaças
  cobre isso; é barata e evita o incidente público.

---

## 5. Agentes: um contrato, dois transportes

A visão *agent-native* fica; o risco de maturidade do WebMCP se isola com uma
camada fina:

- **Definir as ferramentas uma vez**, como JSON Schema neutro de transporte:
  `search_datasets`, `get_dataset`, `get_schema`, `list_releases`,
  `run_named_query`, `run_local_sql` *(browser-only)*, `get_citation`.
- **Transporte 1 — WebMCP** no portal, para os modelos do próprio usuário:
  adaptador de ~100 linhas registrando as ferramentas em
  `document.modelContext`. Quando a spec mudar de novo (mudou uma vez:
  `navigator.*` → `document.*`), muda o adaptador, não o produto.
- **Transporte 2 — servidor MCP clássico**, mesmo schema, para clientes fora do
  browser (Claude Desktop, IDEs, pipelines). Custa pouco além do que o
  Transporte 1 já obriga a especificar, e entrega o caso "agentes usam o lake"
  hoje, sem depender de origin trial.
- Modelo de segurança resultante, simples de auditar: **SQL arbitrário só
  existe em `run_local_sql`**, que roda no WASM do usuário sobre dados públicos.
  Tudo que toca o servidor é tipado e nomeado.

---

## 6. Descoberta e citação — os baratos que continuam valendo

Nada aqui contradiz o feedback; é ortogonal à arquitetura e sai do pipeline:

- `catalog.json` (máquina) + `dcat.jsonld` por dataset (DCAT-AP) + JSON-LD
  schema.org embutido nas páginas ⇒ Google Dataset Search e agregadores públicos
  indexam sozinhos.
- **Licença por dataset** no manifesto e na página (sem licença declarada, o
  usuário institucional cauteloso não usa).
- **Citação com `release_id`**: "DataSenado Lake Aberto, dataset X, release
  r042, URL" — dá ao pesquisador o que citar e a vocês a rastreabilidade de
  qual versão embasou o quê.

---

## 7. Medir sem login

Três indicadores mensuráveis com esta arquitetura, sem identificar ninguém:

1. **Frescor**: dias entre atualização na origem e flip do `current.json` —
   medido no próprio pipeline, por dataset.
2. **Confiabilidade**: taxa de sucesso das execuções do pipeline + latência p95
   dos assets na CDN.
3. **Uso do backend**: volume e latência de consultas nomeadas e do endpoint
   conversacional (os únicos pontos com compute do Senado).

Volumetria de assets via logs de CDN complementa. E aceitar — dizendo isso no
material — que análise 100% no browser é, por construção, invisível ao servidor:
é o preço da privacidade que a própria arquitetura oferece, e vale como argumento,
não como lacuna.

---

## 8. O que continua precisando de dono (independente de arquitetura)

Mantidos da primeira revisão, agora em uma linha cada, porque a natureza deles
não mudou com o feedback:

- **RIPD/classificação LGPD antes do primeiro microdado de survey** — §4.2 dá o
  mecanismo, não a decisão.
- **Posicionamento frente a `dados.senado.leg.br`, à API existente e ao PDA
  2026–2028** — uma página; evita a colisão institucional que nenhuma stack
  resolve.
- **Acessibilidade eMAG/WCAG como critério de aceite do portal** — obrigação
  legal (art. 63, Lei 13.146/2015); a MPA estática de vocês é o melhor ponto de
  partida possível para isso.
- **Runbook + segunda pessoa capaz de operar o pipeline** — continuidade
  institucional.
- **Política de retenção publicada** (§2.4) — a consequência vira compromisso.

---

## 9. Blueprint em uma página

```
Fontes públicas
   │  R + targets (dados, agregados, manifestos, DCAT — um DAG)
   ▼
Lake estático (S3/R2 + CDN)
   ├── releases imutáveis + current.json (ponteiro)      [R4, R5]
   ├── Tier A: agregados de visão (≤10 MB)               [R1]
   ├── Tier B: detalhe curado p/ range+WASM (§2.2)       [R2]
   └── catalog.json / dcat.jsonld / páginas estáticas
   │
   ├────────────► Browser do usuário
   │                ├── portal MPA (11ty) — default = só Tier A
   │                ├── DuckDB-WASM — SQL local sobre A+B
   │                └── WebMCP (adaptador fino) — modelos do usuário
   │
   └────────────► Backend serverless mínimo (workerd/Workers)
                    ├── /q/{id}: consultas nomeadas       [R3]
                    │     cache (release_id, id, params) → CDN immutable
                    │     limiar k p/ datasets sensíveis   [§4.2]
                    ├── assistente do Senado (streaming, tool-use nomeado,
                    │     cotas aqui e só aqui)            [R6]
                    └── servidor MCP clássico (mesmo contrato do WebMCP)
```

| Componente | Faz | **Nunca** faz |
|---|---|---|
| Lake estático | Servir releases imutáveis e ponteiros | Ser reescrito in-place; exigir login |
| Browser (WASM) | SQL arbitrário do usuário, sobre dado público | Ser pré-requisito do conteúdo default da página |
| Consultas nomeadas | Agregações intensas, supressão k, cache endereçado | SQL livre de terceiros; servir o caminho feliz |
| Assistente do Senado | Conversa com tool-use nomeado, com cota | Executar SQL livre; tratar dado como instrução |
| WebMCP / MCP | Expor o mesmo contrato em dois transportes | Divergir de schema entre transportes |

---

*Estas notas assumem o objetivo declarado como dado e projetam a partir dele.
As decisões de governança listadas no §8 não são substituídas por nenhum item
técnico deste documento — são os pré-requisitos institucionais do lançamento.*
