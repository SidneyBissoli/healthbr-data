# Revisão crítica — DataSenado Lake Aberto

> **Documento revisado:** `DataSenado_Lake_Aberto_Stakeholders_A4.pdf` (8 páginas,
> "Material para alinhamento de stakeholders", ago/2026).
> **Natureza desta revisão:** parecer técnico independente, em postura de revisor
> cético, avaliando a proposta **à luz dos objetivos que ela mesma declara** — não
> contra um ideal abstrato de plataforma de dados.
> **Contexto de referência:** experiência operacional do projeto `healthbr-data`
> (redistribuição de dados do SUS em Parquet/S3, em produção) e revisão do estado
> da arte em publicação de dados abertos, agosto/2026.
> **Data:** 27/ago/2026.

---

## Sumário executivo

**A aposta arquitetural central está certa.** Parquet + arquivos estáticos servidos
por HTTPS com *range requests* + DuckDB como motor de consulta é, hoje, a escolha
correta para dados abertos de escala pequena e média. Não é modismo: é a mesma
arquitetura que sustenta o `healthbr-data` em produção (1,9 bilhão de registros,
custo de infraestrutura da ordem de R$ 40 a 150 por mês) e que convergiu como
padrão em Observable Framework, Evidence.dev, Source Cooperative e nos *datasets*
do Hugging Face. Rejeitar "banco analítico central" e "orquestração grande" para o
volume provável do DataSenado é uma decisão madura, não uma economia preguiçosa.

**O problema não está no armazenamento. Está em quatro outras camadas**, e três
delas são baratas agora e caríssimas depois:

1. **Promessas que o documento ainda não pode sustentar.** WebMCP é apresentado
   como "o que já nasce pronto"; é uma proposta de *Community Group* do W3C, de
   fevereiro de 2026, cuja superfície de API já mudou uma vez e que o próprio
   repositório marca como experimental. "Time travel" é prometido sem que exista
   um formato de tabela que o entregue. "Análise no navegador" é prometida sem
   declarar os tetos duros do DuckDB-WASM (4 GB e mono-thread por padrão).
2. **Ausências que um produto de dado público do Senado não pode ter.** O
   documento não menciona, em nenhuma das oito páginas: LGPD e risco de
   reidentificação, licença de uso, catálogo interoperável (DCAT/schema.org),
   identificador persistente e forma de citação, acessibilidade digital, política
   de retenção e descontinuidade. Acessibilidade é obrigação legal (art. 63 da
   Lei 13.146/2015).
3. **Silêncio institucional.** O Senado já opera `dados.senado.leg.br` (catálogo),
   uma API pública de dados abertos e um Plano de Dados Abertos 2026–2028 com
   comitê de governança. O material propõe `data.senado.leg.br` e rejeita "API
   pública pesada" sem dizer se substitui, complementa ou duplica o que existe.
   Essa é a primeira pergunta que um stakeholder faz.
4. **Contradições internas.** O documento promete simultaneamente "sem banco
   central" e *time travel* com deltas; "leveza, menos dependências" e onze
   tecnologias de front-end; "sem login" e "cotas de uso por perfil"; "evitamos
   API pública" e "o desenvolvedor recebe APIs".

**Recomendação central:** inserir uma **Fase 0 de decisões irreversíveis** (4–6
semanas) antes da Fase 1, e entregar **um dataset real de ponta a ponta** antes de
generalizar a plataforma. Layout de partição, política de dados pessoais, formato
de tabela e contrato de consumo são decisões que, tomadas erradas, não se corrigem
depois sem quebrar quem já consome.

**Veredito:** projeto com fundamento técnico sólido e visão correta, apresentado
com maturidade maior do que a que possui. O risco dominante não é técnico — é de
**credibilidade institucional**, se a entrega não corresponder ao que o material
promete a stakeholders.

---

## 1. O que o documento propõe (leitura fiel, antes da crítica)

Registro aqui minha leitura da proposta, para que a crítica seja verificável
contra ela.

**Produto.** Plataforma pública de publicação e consumo de dados públicos em
arquivos Parquet, distribuídos pela web como *assets* estáticos, consultáveis por
DuckDB-WASM no navegador, por agentes de IA via WebMCP e, futuramente, por
clientes em R, Python e MCP local.

**Arquitetura em cinco camadas.** (1) Fontes públicas → (2) produção e curadoria
com pipeline em R + `targets` → (3) *lake* público com Parquet, manifestos,
catálogo, deltas, *current* e *time travel* → (4) portal analítico como MPA
estática com DuckDB-WASM → (5) agentes e integrações.

**Atributos vendidos.** Sem login, *assets* estáticos, atualização incremental,
*time travel* e *provenance*, simplicidade operacional, baixo custo, escalabilidade
natural, reprodutibilidade, experiência moderna.

**Personas.** Cidadão/sociedade civil, jornalista, pesquisador/analista, equipes do
Senado e comissões, desenvolvedor/integrador, agentes e assistentes de IA.

**Stack declarada.** R + `targets`, Parquet, DuckDB, DuckDB-WASM, 11ty + WebC,
is-land, Lit, uPlot + D3, Open Props + Web Awesome, Vite + pnpm, workerd /
Workers / Durable Objects.

**Explicitamente evitado.** SPA complexa, banco central obrigatório, API pública
pesada, lakehouse excessivamente complexo, orquestração desnecessariamente grande.

**Fases.** (1) Lake incremental → (2) Portal analítico → (3) Portal *agent-native*
→ (4) Publicação institucional → (5) Assistente do Senado → (6) Ecossistema
ampliado. Indicadores: datasets publicados, tempo para atualização, tempo para
primeira análise, capacidade de reuso, estabilidade operacional, satisfação.

---

## 2. O que está certo e deve ser preservado

Uma revisão que só aponta defeitos não é cética, é apenas negativa. Estes pontos
são acertos reais e devem sobreviver a qualquer reformulação:

| Acerto | Por que é acerto |
|---|---|
| **Parquet como formato de distribuição** | Colunar, comprimido, com estatísticas por *row group* no rodapé — é o que permite ler 200 MB de um arquivo de 40 GB. Padrão aberto, lido por R, Python, DuckDB, Spark, JS. |
| **Arquivos estáticos em vez de servidor de consulta** | O custo marginal por consumidor tende a zero, a superfície operacional é mínima e a disponibilidade é a da CDN. Para dado público que muda pouco, é dominante. |
| **DuckDB como motor** | Sem servidor, embutível, lê Parquet remoto com *predicate pushdown* e *column pruning*. Uma decisão que envelhece bem. |
| **Rejeitar banco analítico central e orquestração pesada** | Correto para a ordem de grandeza provável do DataSenado. A maioria dos portais públicos falha por excesso de infraestrutura, não por falta. |
| **Sem login** | É a decisão isolada que mais aumenta acesso real. Toda barreira de autenticação reduz uso de dado público em ordem de grandeza. |
| **Reprodutibilidade e proveniência no desenho, não como remendo** | Raro no setor público e é o maior diferencial competitivo do projeto. Precisa ser especificado (§4.2), mas a intenção está certa. |
| **Tratar agentes de IA como consumidor de primeira classe** | Visão correta e antecipada. Só o *mecanismo* escolhido está imaturo (§3.4). |
| **Materializar a proposta em fases com entregáveis** | O material é claro, bem diagramado e comunica bem. Isso não é trivial. |

---

## 3. Achados

Classificação: **[B]** bloqueante (resolver antes de a Fase 1 sair do papel),
**[A]** alto (resolver dentro da fase correspondente), **[M]** médio (registrar
decisão e endereçar).

---

### 3.1 [B] Dados pessoais e risco de reidentificação — ausência total no documento

**O que o documento diz.** Nada. LGPD, dados pessoais, anonimização, controle de
divulgação estatística e risco de reidentificação não aparecem em nenhuma das oito
páginas.

**Por que é bloqueante.** O DataSenado é o instituto de pesquisa de opinião do
Senado e **publica microdados de suas pesquisas**. Microdado de survey com UF,
faixa etária, sexo, escolaridade, renda e o tema pesquisado é um conjunto clássico
de quase-identificadores. Vários temas históricos do instituto — violência
doméstica, violência contra a juventude negra, segurança pública — produzem
respostas sensíveis na acepção do art. 5º, II da LGPD.

**O agravante é específico desta arquitetura, e é o ponto que quero destacar.** Os
três recursos mais vendidos no material são exatamente os três vetores de ataque
de vinculação (*linkage*):

- **"Combinar bases"** (p. 5) — cruzamento entre conjuntos é o mecanismo canônico
  de reidentificação.
- **Séries históricas completas e *time travel*** — permitem cruzar *releases* de
  épocas diferentes do mesmo conjunto, técnica reconhecida de reidentificação.
- **Consulta SQL arbitrária e irrestrita, operada por agentes de IA** — automatiza
  e barateia a busca por células raras.

E há uma assimetria estrutural que o documento não reconhece: **um arquivo estático
não pode negar uma consulta.** Uma API pode aplicar supressão de célula, tamanho
mínimo de agregado, *rate limit* ou recusa. Um Parquet numa CDN publica o conjunto
inteiro, para sempre, para qualquer um — inclusive para quem já o baixou depois de
uma eventual retirada. A escolha por *assets* estáticos, que é acertada para dado
agregado e administrativo, **elimina o único ponto onde controles de divulgação
poderiam ser aplicados**.

**Precedente relevante.** O INEP restringiu a divulgação de microdados justamente
por risco de reidentificação mediante cruzamento da série histórica (Parecer
PF/INEP nº 00018/2022). A ANPD publicou estudo técnico sobre anonimização
sustentando que a avaliação de risco deve considerar não só os meios do próprio
agente, mas os de terceiros com esforços razoáveis — critério que a disponibilidade
pública irrestrita torna maximamente exigente.

**Recomendação.**
1. Classificar os conjuntos por sensibilidade **antes** de qualquer publicação:
   (a) administrativo/legislativo sem pessoa natural; (b) agregado; (c) microdado
   de pesquisa com pessoa natural.
2. Para a classe (c): relatório de impacto (RIPD), avaliação formal de risco de
   reidentificação e decisão explícita sobre o que vai como microdado, o que vai
   como agregado com supressão de célula, e o que não vai.
3. Registrar a decisão e o método no *card* de cada dataset — transparência sobre
   o que **não** foi publicado é parte da transparência.
4. Tratar publicação como **irreversível** no planejamento. Um conjunto publicado
   e baixado não é recuperável.
5. Envolver o encarregado de dados (DPO) do Senado na Fase 0, não na Fase 4
   ("Publicação institucional").

---

### 3.2 [B] Posicionamento frente ao que o Senado já tem

**O que o documento diz.** Propõe `data.senado.leg.br` (mockup, p. 4) e lista
"API pública pesada" entre o que se evita (p. 7). Não menciona nenhuma iniciativa
existente.

**A realidade institucional.** O Senado já opera:
- **`dados.senado.leg.br`** — catálogo de dados abertos com metadados técnicos e
  administrativos (sistema produtor, frequência de atualização, setor responsável,
  fundamentação jurídica), servindo CSV, XML e JSON.
- **`legis.senado.leg.br/dadosabertos`** — serviços REST de dados abertos.
- **Plano de Dados Abertos 2026–2028**, com comitê e política de governança.

**Por que é bloqueante.** Três problemas concretos:
- O domínio proposto (`data.senado.leg.br`) está a um caractere do catálogo
  existente (`dados.senado.leg.br`). Para o cidadão, isso é confusão pura.
- Rejeitar "API pública" como princípio de arquitetura, num órgão que **opera uma
  API pública de dados abertos**, é uma afirmação que precisa ser reformulada:
  o que se evita é *construir uma nova* API de consulta analítica, não a existência
  de APIs.
- Um projeto que publica dados abertos do Senado sem se ancorar no PDA 2026–2028
  e no comitê existente entra em rota de colisão com uma área que já tem mandato.
  Isso raramente termina em vitória técnica.

**Recomendação.**
1. Acrescentar ao material **uma página de posicionamento institucional**: o Lake
   Aberto é a *camada analítica* do ecossistema de dados abertos do Senado, não um
   catálogo concorrente.
2. Mapear explicitamente os objetivos do projeto contra as metas do PDA 2026–2028
   — isso transforma o projeto de "iniciativa paralela" em "execução do plano".
3. Convergência técnica em vez de duplicação: o Lake publica **DCAT** (§3.7) e o
   catálogo institucional o indexa. Um catálogo, duas formas de consumo.
4. Reservar a decisão de domínio para depois desse alinhamento.

---

### 3.3 [B] "Time travel", "deltas" e "current" sem formato de tabela

**O que o documento diz.** A camada 3 entrega "Parquet, manifestos, catálogo,
deltas, *current*, *time travel*" (p. 2); a Fase 1 entrega "releases incrementais,
manifestos de datasets, estado atual e deltas, controles de qualidade, proveniência
e *lineage*" (p. 8). A p. 7 rejeita "lakehouse excessivamente complexo" e "banco
central obrigatório".

**Por que é bloqueante.** O conjunto de entregáveis da Fase 1 é, funcionalmente,
**a definição de um formato de tabela**: estado atual, histórico de snapshots,
deltas entre versões, metadados de arquivos e linhagem. A escolha real não é
"com ou sem lakehouse" — é **"formato padronizado ou formato proprietário
caseiro"**.

Um formato caseiro tem custo que não aparece no diagrama: leitor próprio em cada
linguagem (R, Python, JS, DuckDB), especificação escrita, testes de compatibilidade
entre versões do próprio formato, e **nenhuma ferramenta de terceiros funciona sem
adaptação**. É a maior dívida técnica escondida da proposta, e ela cresce com o
tempo, não diminui.

Há também uma tensão de coerência: *time travel* real exige reter *snapshots*
antigos. O documento não diz por quanto tempo, nem quanto isso custa em
armazenamento, nem o que acontece quando um *release* precisa ser retirado por
erro ou por decisão de privacidade (§3.1).

**As três saídas honestas, em ordem de custo:**

| Opção | O que entrega | Custo real |
|---|---|---|
| **Não ter *time travel*** — manifesto JSON simples, o *bucket* reflete a última versão publicada, histórico do *que* foi publicado *quando* fica no git | Reprodutibilidade da *publicação*, não do *dado* | Mais barato. É a decisão do `healthbr-data`, tomada explicitamente e documentada com seus custos. Exige coragem de cortar a promessa. |
| **Apache Iceberg com metadados como arquivos estáticos** | *Snapshots* nativos, *time travel* padronizado, lido pela extensão `iceberg` do DuckDB e por todo o ecossistema | Médio. Compatível com "sem servidor" se os metadados forem servidos como arquivos. Custa aprendizado e disciplina de escrita. |
| **DuckLake** | *Time travel* com metadados em catálogo SQL; muito eficiente para muitos *snapshots* | Contraria "sem banco central" — embora o catálogo possa ser um arquivo DuckDB servido em leitura. Formato jovem, adoção concentrada em cenários embarcados. |

**Recomendação.** Decidir **antes** da Fase 1 e escrever a decisão com seus custos
assumidos. Se *time travel* não for requisito real de um caso de uso nomeado — e
para dados de opinião pública, reter os *releases* publicados provavelmente basta —
**cortar a promessa é a jogada mais barata e mais honesta**. Prometer *time travel*
em material de stakeholder e entregar "histórico de releases" é onde a credibilidade
se perde.

---

### 3.4 [A] WebMCP está sendo apresentado como pronto, e não está

**O que o documento diz.** "WebMCP hoje" (p. 2). E, na p. 6, sob o título
**"O QUE JÁ NASCE PRONTO"**: "WebMCP — ponte segura entre o agente de IA e o
portal. Permite ações padronizadas e auditáveis."

**Os fatos, verificados em agosto de 2026.**
- WebMCP é uma proposta do **W3C Web Machine Learning Community Group** —
  *Community Group*, não Working Group. Não é padrão do W3C nem *Working Draft*.
  Foi publicada como *Draft Community Group Report* em fevereiro de 2026.
- A superfície da API **já mudou**: a interface de registro de ferramentas migrou
  de `navigator.modelContext` para `document.modelContext`.
- O repositório oficial da especificação marca o estado como experimental e mantém
  seções de *open questions* com decisões de projeto em aberto.
- A implementação existe em navegadores de base Chromium (Edge e Chrome, este em
  *origin trial*); Firefox e Safari acompanham sem compromisso público de
  implementação.

**Por que importa.** Não é uma objeção à visão *agent-native* — essa visão está
certa. É uma objeção à **calibragem da promessa** num documento cujo propósito
declarado é alinhar stakeholders. *Origin trials* expiram. APIs de CG mudam de
nome. Se a Fase 3 depender de WebMCP e a API mudar de novo, o time gasta o
orçamento consertando uma dependência instável — e a explicação será difícil,
porque o material dizia "já nasce pronto".

**Recomendação.**
1. Rebaixar WebMCP de "o que já nasce pronto" para **"aposta exploratória"**, atrás
   de uma camada fina de adaptação, e dizer isso no material.
2. Entregar "agent-native" **agora** pelo caminho estável, que é mais simples:
   **catálogo legível por máquina + Parquet + um servidor MCP convencional**. Isso
   funciona hoje em qualquer cliente de IA, sem depender de navegador nem de
   *origin trial*, e é substancialmente menos trabalho.
3. Manter WebMCP como experimento paralelo com critério de saída definido ("se não
   estiver em *Working Draft* com duas implementações independentes até *data*,
   descontinuamos").

---

### 3.5 [A] DuckDB-WASM tem tetos duros que o documento não declara

**O que o documento diz.** "DuckDB-WASM permite consultas analíticas diretamente
sobre os Parquet, sem servidores para o usuário final" (p. 2); "100% no navegador"
(p. 4); "alta performance" (p. 6).

**Os limites documentados pelo próprio DuckDB.** A documentação oficial é explícita:
o cliente WASM usa **uma única thread por padrão, e o suporte a multithreading
permanece experimental**; o WebAssembly **restringe a memória disponível a no
máximo 4 GB**, e navegadores individuais podem impor limites ainda menores. Some-se
a isso que, no navegador, **não há *spilling* para disco** — quando a consulta não
cabe na memória, ela é cancelada com erro, em vez de degradar graciosamente como no
DuckDB nativo.

E há um trade-off arquitetural que costuma ser descoberto tarde: **multithreading
exige isolamento cross-origin (cabeçalhos COOP/COEP)**. Ativar isolamento
cross-origin restringe o carregamento de recursos de terceiros e complica embutir o
portal em outras páginas — exatamente o "reuso por outros sistemas" prometido na
p. 5. É uma escolha entre desempenho e integrabilidade, não um detalhe de deploy.

Acrescente o pior caso real: **dispositivos móveis**, onde memória e CPU são menores
e onde está boa parte do público de um portal do Senado.

**Por que importa.** Nada disso invalida a escolha do DuckDB-WASM — invalida a
promessa implícita de que **toda** análise roda no navegador. A promessa vai
quebrar publicamente na primeira consulta que junte duas séries históricas grandes,
e vai quebrar na frente do usuário, sem mensagem útil.

**Recomendação.**
1. **Declarar o envelope de operação** no material e na documentação: "consultas
   sobre até X GB comprimidos / Y milhões de linhas, em navegador desktop". Um
   número honesto vale mais que um advérbio.
2. Definir o **plano B agora**, não na Fase 2: publicar **pré-agregados** como
   datasets de primeira classe (barato, resolve 80% das perguntas do público geral
   e reduz drasticamente o dado trafegado) e/ou um endpoint opcional de consulta
   para o que não couber.
3. Fazer as escolhas de layout físico que dobram o desempenho e são gratuitas se
   feitas desde o início — e caras depois:
   - *row groups* dimensionados para *range requests* granulares (na ordem de
     dezenas de MB descomprimidos, não centenas);
   - **ordenar** os arquivos pela coluna mais filtrada (data, UF), o que habilita
     descarte de *row group* por estatística de mínimo/máximo;
   - particionamento Hive pelas colunas de filtro mais comuns, **sem** fragmentar
     em milhares de arquivos minúsculos (cada arquivo custa ao menos duas
     requisições HTTP);
   - *bloom filters* nas colunas de alta cardinalidade usadas em igualdade.
4. Testar em celular de gama média antes de prometer "para qualquer pessoa".

---

### 3.6 [A] A stack de front-end contradiz o discurso de leveza

**O que o documento diz.** Vende "**Leveza** — menos dependências, menor superfície
de falha" e rejeita "SPA complexa" (p. 7). Na mesma página, lista: 11ty, WebC,
is-land, Lit, uPlot, D3, Open Props, Web Awesome, Vite, pnpm, workerd/Workers/
Durable Objects.

**Por que importa.** São cerca de onze tecnologias só na camada de apresentação e
build, várias delas de nicho e de mantenedor único ou equipe pequena. Para um órgão
público, **cada dependência é um compromisso de manutenção de cinco a dez anos**. O
critério de seleção precisa ser: *se o mantenedor parar amanhã, o que fazemos?* —
e a resposta precisa estar escrita.

A comparação incômoda: **Observable Framework** e **Evidence.dev** entregam
exatamente o produto descrito — site estático + Parquet + DuckDB-WASM + gráficos
interativos + páginas de dataset — com **uma** dependência de topo, comunidade
grande e documentação madura. O documento não menciona nenhuma das duas nem explica
por que construir em vez de adotar. Essa pergunta vai aparecer, e é legítima.

**Recomendação.** Uma das duas:
- **Justificar explicitamente** a rejeição desses frameworks no material (pode
  haver boas razões: controle de acessibilidade, identidade visual do Senado,
  requisitos de hospedagem). Uma justificativa escrita é uma resposta; o silêncio,
  não.
- **Reduzir a stack.** uPlot *e* D3 *e* Lit *e* is-land *e* WebC é mais superfície
  do que o produto descrito exige.

---

### 3.7 [A] Faltam os metadados que tornam um dado público encontrável e citável

**O que o documento diz.** "Catálogo de datasets" e "páginas de dataset" como
entregáveis da Fase 2 (p. 8).

**O que falta.** Nenhuma menção a:
- **DCAT-AP / DCAT-US / schema.org `Dataset`** — os vocabulários que fazem um
  dataset ser colhido por portais nacionais e aparecer no Google Dataset Search.
  Um catálogo próprio sem vocabulário padrão é mais um silo: o **oposto** do
  objetivo declarado de "mais acesso".
- **Licença explícita por dataset.** Sem licença declarada, o usuário jurídico
  cauteloso — justamente a imprensa e as instituições de pesquisa — não usa.
- **Identificador persistente e forma de citação** (DOI ou equivalente), com versão
  citável. Sem isso, o dataset não entra em artigo revisado por pares, e a persona
  "pesquisador e analista" fica mal servida.

**Por que importa.** É a lacuna de **melhor relação custo-benefício de todas**:
DCAT-AP e JSON-LD `schema.org` são **geração estática**, encaixam perfeitamente num
pipeline que já produz manifestos, e transformam descoberta passiva em ativa. Custa
dias; o retorno é permanente.

**Recomendação.** Emitir, junto com cada *release*: DCAT-AP + JSON-LD schema.org,
licença por dataset (no manifesto e no *card*), e uma *string* de citação com
versão. Incluir na Fase 1, não na Fase 4.

---

### 3.8 [A] Acessibilidade não aparece — e é obrigação legal

**O que o documento diz.** Nada sobre acessibilidade. "Experiência moderna",
"gráficos interativos", "hidratação progressiva".

**A obrigação.** O art. 63 da Lei 13.146/2015 (Lei Brasileira de Inclusão) torna
obrigatória a observância dos padrões de acessibilidade em sítios mantidos por
órgãos de governo. O **eMAG** é o modelo brasileiro de referência, institucionalizado
pela Portaria SLTI nº 3/2007 sob o Decreto 5.296/2004, e traduz o WCAG para o
contexto do governo brasileiro.

**Por que importa aqui em particular.** Um portal cujo conteúdo é **renderizado no
cliente** — tabelas produzidas por WASM, gráficos em canvas/SVG, ilhas interativas
— é exatamente a classe de interface que falha em leitor de tela quando
acessibilidade não é requisito desde o primeiro *sprint*. "Hidratação progressiva"
resolve desempenho, não acessibilidade: são problemas diferentes.

Há aqui, porém, um **trunfo desperdiçado**: a escolha por MPA estática (11ty) é
naturalmente favorável à acessibilidade e ao funcionamento sem JavaScript. Basta
usá-la de propósito.

**Recomendação.**
1. Acessibilidade como **critério de aceite** da Fase 2, com avaliação eMAG/WCAG
   AA, não como ajuste posterior.
2. Toda visualização com **equivalente textual e tabular** — o que também serve ao
   consumo por agentes de IA, resolvendo dois requisitos com um mecanismo.
3. Garantir que o conteúdo essencial de cada página de dataset (descrição, dicionário
   de variáveis, metadados, link de download) funcione **sem JavaScript**. O DuckDB-WASM
   fica para a exploração interativa, não para renderizar o conteúdo básico.

---

### 3.9 [A] "Sem servidor" não é exato, e o *lock-in* não está declarado

**O que o documento diz.** "Sem banco central", "sem servidores para o usuário
final", e lista `workerd / Workers / Durable Objects` como "aceleração opcional e
coordenação quando necessário" (p. 7).

**Por que importa.** Workers e, sobretudo, **Durable Objects** são Cloudflare.
Durable Objects não tem equivalente portável — é a peça com maior *lock-in* de toda
a stack, apresentada como opcional. Para um órgão público isso toca três coisas
distintas: contratação, continuidade do serviço e o debate político de soberania
de dados. A Portaria SGD/MGI nº 5.950/2023 vincula os órgãos do SISP (Poder
Executivo) e **não vincula o Senado**, que é Legislativo com governança de TI
própria — mas ela define o padrão de mercado e a expectativa política, e "onde ficam
os dados do Senado" é uma pergunta que pode ser feita em plenário.

**Recomendação.**
1. Manter os **dados** em armazenamento S3-compatível puro. Esse foi exatamente o
   critério do `healthbr-data` ao escolher R2: *se o fornecedor mudar as regras, a
   migração é de horas*. Essa portabilidade só existe enquanto nada específico do
   fornecedor entra no caminho do dado.
2. Manter o **site** estático e genérico (qualquer CDN serve arquivos).
3. Isolar qualquer uso de Durable Objects atrás de uma interface, com plano de
   saída escrito.
4. Declarar no material **onde os dados ficam fisicamente** e sob que jurisdição.
   É melhor responder antes de ser perguntado.

---

### 3.10 [M] Reprodutibilidade prometida, mecanismo não especificado

**O que o documento diz.** "Snapshot coerente", "provenance", "lineage", "links
reproduzíveis", "reprodutibilidade" — em cinco das oito páginas.

**O que falta.** *Onde mora* cada garantia, e como um terceiro a verifica **sem
consultar o Senado**. Sem isso, "proveniência" é adjetivo de material de divulgação.

**Referência concreta.** O `healthbr-data` resolve isso com três artefatos que são
obrigados a concordar entre si para a mesma partição, e uma receita pública de
auditoria:

| Artefato | Onde mora | Para que serve |
|---|---|---|
| **Metadado embutido** no próprio Parquet (URL de origem, hash MD5 e tamanho da fonte, data de download, script, versão do pipeline, commit git) | Rodapé do arquivo | Viaja **com o dado**, mesmo quando alguém baixa o arquivo e o recompartilha fora do portal |
| **Manifesto** por dataset | Bucket | Auditoria do conjunto todo; integridade das cópias (SHA-256, contagem de registros); base da verificação de sincronia |
| **Controle de versão** em CSV versionado no git | Repositório | Estado "já processado" e histórico de *o que* foi publicado *quando* |

A regra operacional é simples e vale a pena copiar: **os três concordam; uma
divergência é defeito a corrigir, nunca a normalizar.**

O ponto mais transferível é o primeiro. **Gravar proveniência dentro do arquivo
Parquet**, e não apenas no catálogo, é barato e muda o jogo: o catálogo descreve o
que está no portal; o metadado embutido continua respondendo "de onde veio isso?"
quando o arquivo já está no notebook de um jornalista, três anos depois.

**Recomendação.** Escrever dois documentos curtos antes da Fase 1 — eles definem
quase todo o resto:
- **Contrato de consumo**: o que o consumidor pode e **não pode** assumir (layout
  de partição, tipagem, transformações, estabilidade, invalidação de cache).
- **Política de reprodutibilidade**: onde mora cada garantia e a receita de
  auditoria por terceiros.

---

### 3.11 [M] Falta uma política de fidelidade à fonte

**O que o documento diz.** "Produção e curadoria", "qualidade", "controles de
qualidade".

**O problema.** Não fica dito se o dado publicado é **o dado da fonte** ou um
**derivado curado pelo DataSenado**. Para um órgão do Legislativo que redistribui
dados de terceiros (IBGE, TSE, DATASUS, órgãos do Executivo), essa distinção é
institucionalmente crítica: se o Senado "melhora" um dado do IBGE e o número
divergir do oficial, **o erro passa a ser do Senado** — e a discussão vira política,
não técnica.

**Recomendação.** Separar explicitamente, com prefixos, nomes e *cards* distintos:
- **camada espelho** — fiel à fonte no conteúdo; só mudam formato e particionamento;
- **camada derivada** — indicadores, harmonizações, séries construídas, com
  metodologia documentada e assumidamente de autoria do DataSenado.

O `healthbr-data` adota o princípio "publicar exatamente o que o Ministério publica,
sem transformar" e empurra toda conveniência para o pacote cliente. Não é a única
resposta possível, mas **é uma resposta explícita** — e ter uma resposta explícita é
o requisito.

---

### 3.12 [M] Contradições internas a resolver

Listadas juntas porque a correção é editorial, mas o custo de deixá-las é de
credibilidade: um leitor técnico atento encontra todas em uma leitura.

| # | Promessa A | Promessa B | Como resolver |
|---|---|---|---|
| 1 | "Sem login para acesso público" (p. 1) | "Cotas de uso por perfil" (p. 6) | Cotas exigem identificar quem consome; CDN de arquivos estáticos não permite cota por perfil sem um gateway — que é a "API pesada" rejeitada. Decidir qual promessa cai, ou restringir cotas apenas ao assistente conversacional. |
| 2 | "Evitamos API pública pesada" (p. 7) | Persona desenvolvedor "recebe APIs e arquivos estáticos prontos" (p. 3) | Reformular: evita-se construir uma **nova API de consulta analítica**; arquivos estáticos + catálogo **são** a interface programática. |
| 3 | "Leveza, menos dependências" (p. 7) | Onze tecnologias de front-end (p. 7) | Ver §3.6. |
| 4 | "Sem banco central" (p. 7) | *Time travel*, deltas, *current*, catálogo (p. 2) | Ver §3.3. |
| 5 | "Sem servidores" | workerd / Workers / Durable Objects (p. 7) | Ver §3.9. |
| 6 | "Reduz superfície de ataque" (p. 7) | SQL arbitrário no cliente + agentes operando a UI (p. 6) | Ver §3.13. |

---

### 3.13 [M] Modelo de ameaças da camada de agentes

**O que o documento diz.** Evitar API pública "aumenta[ria] a superfície de ataque
e o custo de manutenção" — logo, evitá-la reduz risco (p. 7).

**Parcialmente verdade, e por isso perigoso.** Reduz a superfície *do servidor*.
Mas a arquitetura **cria** superfícies novas que o documento não trata:

- **Injeção de prompt via conteúdo de dado.** Um campo de resposta aberta de
  pesquisa de opinião é texto escrito por terceiros. Quando o assistente do Senado
  (Fase 5) ler esse campo para responder a um usuário, ele estará lendo entrada não
  confiável. Um texto plantado numa resposta aberta pode tentar redirecionar o
  assistente. **Isso é específico do DataSenado**, cujo dado *é* texto de terceiros.
- **Agentes operando a UI** via WebMCP ampliam o que um agente comprometido pode
  fazer em nome do usuário.
- **Custo de egresso como vetor.** *Assets* estáticos públicos sem cota podem ser
  varridos em laço; dependendo do contrato de CDN, isso é um problema de fatura,
  não de segurança — mas é um problema.

**Recomendação.** Um modelo de ameaças de uma página antes da Fase 3, com uma regra
central escrita: **conteúdo de dataset é entrada não confiável para o assistente**,
nunca instrução. Definir também política de rastreamento de abuso compatível com
"sem login".

---

### 3.14 [M] Indicadores de sucesso sem linha de base, meta ou instrumentação

**O que o documento diz.** Seis indicadores (p. 8): datasets publicados, tempo para
atualização, tempo para primeira análise, capacidade de reuso, estabilidade
operacional, satisfação de usuários.

**O problema.** Nenhum tem definição operacional, valor atual, meta ou meio de
medição. E há um agravante honesto: **"sem login" e "100% no navegador" tornam a
medição genuinamente difícil** — logs de CDN registram requisições de *range*, não
"análises realizadas". "Capacidade de reuso" e "satisfação" não são mensuráveis do
jeito como estão escritos.

**Recomendação.** Escolher **três** indicadores com definição operacional,
instrumentação decidida e meta numérica — e aceitar não medir o resto. Sugestão:
(1) nº de datasets publicados com *card* e metadado completos; (2) mediana de dias
entre atualização na origem e publicação (mensurável no pipeline, é o melhor
indicador de saúde operacional); (3) taxa de sucesso das execuções do pipeline.

---

### 3.15 [M] Não há dimensionamento: volume, custo, equipe, prazo

**O problema.** Um material de alinhamento de stakeholders com seis fases e
**nenhuma data, nenhum FTE, nenhum valor em reais e nenhum volume de dado** (GB, nº
de datasets, nº de linhas) não permite decisão. É precisamente a informação que o
público-alvo do documento precisa para dizer sim.

Também não há a contrapartida: **o custo de não fazer** — quantas horas de equipe
são gastas hoje respondendo a pedidos de dado, quantas análises não acontecem.

**Recomendação.** Acrescentar um quadro com ordem de grandeza por fase, mesmo com
incerteza de ±50%, explicitando a incerteza. Uma estimativa declarada como
estimativa é infinitamente mais útil que nenhuma.

---

### 3.16 [M] Bus factor e sustentação operacional

**O que o documento diz.** Pipeline em R + `targets`.

**Avaliação justa.** `targets` é uma excelente escolha para reprodutibilidade e
execução incremental, e é a escolha certa se a equipe é de R — o que faz sentido
num instituto de pesquisa. Não é uma crítica à ferramenta.

**A questão é institucional.** É orquestração de máquina única, e continuidade num
órgão público depende de **mais de uma pessoa** ser capaz de operar o pipeline.
Projetos assim costumam morrer não por falha técnica, mas por saída de pessoa.

**Recomendação.** *Runbook* de operação escrito; execução em ambiente conteinerizado
e reproduzível; nomear operador titular e reserva; e um mecanismo de inspeção da
última execução que qualquer pessoa da equipe consiga rodar. (O `healthbr-data`
resolve isso com pipeline executado a partir de um clone git, VPS efêmera criada
sob demanda, script de manutenção e um comando de inspeção da última rodada — vale
como referência de **forma**, não de escala.)

---

### 3.17 [M] Preservação e descontinuidade

**O problema.** Nada sobre: por quanto tempo um *release* fica disponível; o que
acontece com os dados se o projeto for descontinuado; como um pesquisador que citou
o *release* v1.2.3 em 2027 o recupera em 2032.

Para um projeto independente isso é aceitável (o `healthbr-data` declara
explicitamente que **não** versiona dados, e assume o custo). Para uma instituição
permanente que convida cidadãos, jornalistas e pesquisadores a **citar** seus dados,
a expectativa é outra — e o material reforça essa expectativa ao vender *time
travel* e reprodutibilidade.

**Recomendação.** Política de retenção escrita e publicada; compromisso de
preservação alinhado à política arquivística do Senado; e plano de saída (para onde
os dados vão se o portal for desligado).

---

## 4. Comparação estruturada com o `healthbr-data`

O `healthbr-data` não é modelo a ser copiado — é um projeto independente, com
escala e restrições diferentes das de um órgão do Legislativo. Mas é uma
implementação **em produção** da mesma aposta arquitetural, o que o torna útil como
contraprova empírica. O que transfere e o que não transfere:

| Decisão | `healthbr-data` | DataSenado Lake Aberto | Transfere? |
|---|---|---|---|
| Formato | Parquet, todas as colunas string | Parquet | **Sim** na escolha do formato. A tipagem única (tudo string) é decisão de fidelidade à fonte: preserva zeros à esquerda e evita coerção silenciosa. Vale considerar para a camada espelho. |
| Armazenamento | S3-compatível com egresso zero | Assets estáticos + CDN | **Sim**, com a ressalva de manter o caminho do dado livre de recursos proprietários (§3.9). |
| Layout de partição | `ano=/mes=/uf=` — declarado **API pública, não muda** | Não especificado | **Sim, e é urgente.** Layout de partição é contrato: mudá-lo quebra o `open_dataset()` de todo mundo. Definir na Fase 0. |
| Versionamento | **Não versiona.** O bucket reflete a última versão da fonte; o histórico do que foi publicado fica no git | Promete *time travel* | **Não transfere — e é o ponto de decisão.** Ver §3.3. |
| Proveniência | Metadado embutido no Parquet + manifesto + CSV no git, com regra de concordância entre os três | "provenance", sem mecanismo | **Sim, integralmente.** Ver §3.10. |
| Fidelidade à fonte | Princípio explícito: publica o que o Ministério publica, sem limpar, sem recodificar; conveniência vai para o pacote cliente | Não declarado | **Sim, como princípio a decidir** (não necessariamente com a mesma resposta). Ver §3.11. |
| Contrato de consumo | Documento próprio: o que o consumidor pode e não pode assumir | Ausente | **Sim.** Barato e evita quebras futuras. |
| Sincronia com a fonte | Verificação semanal automatizada que compara manifesto × fonte e dispara reprocessamento só quando há deriva | "atualização incremental" | **Sim.** É o que torna "tempo para atualização" mensurável (§3.14). |
| Dados pessoais | Não se aplica — dado administrativo agregado do SUS já publicado pelo Ministério | **Aplica-se fortemente** (microdados de survey) | **Não transfere.** O DataSenado tem um problema que o `healthbr-data` não tem, e é o mais sério (§3.1). |
| Interface de consumo | Pacote R cliente, com o portal como camada secundária | Portal no navegador como camada primária | **Não transfere.** Escolhas legítimas e diferentes, ditadas por públicos diferentes. |
| Custo/escala | ~R$ 40–150/mês, 1 mantenedor, ~1,9 bi de registros | Não dimensionado | Referência útil de ordem de grandeza: a arquitetura é genuinamente barata. Ver §3.15. |

---

## 5. Recomendação de sequenciamento

O documento começa a execução pela Fase 1 ("Lake incremental", já com *time
travel*). Proponho intercalar uma **Fase 0** e reordenar a camada de agentes. A
lógica é única: **tudo que é irreversível deve ser decidido antes de haver
consumidores**.

### Fase 0 — Decisões e contratos (4 a 6 semanas, quase sem código)

| Entregável | Por quê |
|---|---|
| Classificação LGPD dos conjuntos + RIPD para microdados de pesquisa | §3.1 — publicação é irreversível |
| Decisão sobre formato de tabela (ou decisão explícita de não ter *time travel*) | §3.3 — define toda a Fase 1 |
| **Layout de partição congelado** | É API pública; mudar depois quebra consumidores |
| Contrato de consumo + política de reprodutibilidade | §3.10 |
| Licença por dataset + forma de citação | §3.7 |
| Posicionamento frente a `dados.senado.leg.br` e ao PDA 2026–2028 | §3.2 |
| Envelope de operação declarado do DuckDB-WASM | §3.5 |

### Fase 1 — Lake mínimo, real, estreito

**Dois ou três datasets reais publicados de ponta a ponta**, sem *time travel*, com
proveniência embutida no Parquet + manifesto + DCAT + *card*. O objetivo não é a
plataforma: é **provar o caminho completo** com dado de verdade e usuário de
verdade. O `healthbr-data` validou a arquitetura publicando um dataset e só depois
generalizou — a ordem inversa é onde projetos de plataforma costumam se perder.

### Fase 2 — Portal, com acessibilidade como critério de aceite

Envelope de operação declarado, plano B de pré-agregados implementado,
conformidade eMAG/WCAG AA avaliada antes do lançamento (§3.8).

### Fase 3 — Agentes pelo caminho estável primeiro

**Servidor MCP convencional** sobre o catálogo e os Parquet — funciona hoje, em
qualquer cliente, sem *origin trial*. WebMCP como experimento paralelo com critério
de descontinuação (§3.4).

### Fases 4 a 6 — como no documento

Com a ressalva de que "Publicação institucional" (Fase 4) contém itens de
governança que, como argumentado, precisam estar resolvidos na Fase 0 — não no
final.

---

## 6. As perguntas que os stakeholders farão

Um material de alinhamento é bom na medida em que antecipa as perguntas difíceis.
Estas seis não estão respondidas no documento atual, e todas serão feitas:

1. **Isto substitui o `dados.senado.leg.br`?** Se não, qual a divisão de
   responsabilidade — e quem decide?
2. **Quanto custa, quem opera e o que acontece se essa pessoa sair?**
3. **Quais dados exatamente entram?** Os microdados de pesquisa do DataSenado
   entram? Com que tratamento de privacidade?
4. **O que acontece se o WebMCP mudar de novo?** Quanto do plano depende dele?
5. **Se a Cloudflare mudar preço ou política, quanto tempo levamos para sair?**
   Onde os dados ficam fisicamente?
6. **Quando o cidadão vê a primeira coisa funcionando?** Uma data.

---

## 7. Conclusão

A proposta acerta na aposta difícil — a arquitetura de dados — e subestima as
fáceis: governança, metadados, acessibilidade e posicionamento institucional. Isso
é comum em projetos liderados por competência técnica genuína, e é corrigível a
baixo custo **se for corrigido agora**.

O risco dominante não é o de a plataforma não funcionar. É o de **que o material
prometa, a stakeholders, uma maturidade que o projeto ainda não tem** — "já nasce
pronto", "time travel", "100% no navegador", "sem servidores" — e a diferença entre
a promessa e a entrega ser lida como falha de execução, quando na verdade é falha
de calibragem do discurso. Num órgão público, esse tipo de erro custa mais caro que
um erro de arquitetura, porque não se corrige com um *refactor*.

Três frases resumem o que eu mudaria:

1. **Corte o que ainda não é verdade.** WebMCP como aposta, não como pronto;
   *time travel* só se houver formato que o entregue; envelope de operação
   declarado em números.
2. **Decida agora o que é irreversível.** Dados pessoais, layout de partição,
   licença, contrato de consumo. São semanas hoje e anos depois.
3. **Publique um dataset real antes de construir a plataforma inteira.** É a
   forma mais barata de descobrir o que está errado nesta revisão e no próprio
   documento.

A visão está certa. Falta ajustar o relógio entre o que se promete e o que se tem.

---

## Anexo A — Evidências e fontes consultadas

**WebMCP (§3.4)**
- [Repositório oficial da especificação — W3C Web Machine Learning Community Group](https://github.com/webmachinelearning/webmcp) — proposta de *Community Group*, não padrão nem *Working Draft*; API em `document.modelContext`; estado marcado como experimental, com *open questions* em aberto.
- [The State of WebMCP: July 2026 — Spronta](https://www.spronta.com/blog/state-of-webmcp-july-2026/) e [WebMCP in 2026: browser compatibility status](https://dev.to/ai-agent-economy/webmcp-in-2026-which-browsers-support-navigatormodelcontext-complete-compatibility-status-1oe4) — cronologia (anúncio fev/2026, Draft CG Report fev/2026, revisão abr/2026), migração de `navigator.modelContext` para `document.modelContext`, e estado de implementação em navegadores. *Fontes secundárias; os números de versão de navegador não foram confirmados em fonte primária.*

**DuckDB-WASM (§3.5)**
- [DuckDB — documentação oficial, Wasm client](https://duckdb.org/docs/stable/clients/wasm/overview.html): "By default, the DuckDB-Wasm client uses a single thread, while multithreading support remains experimental. Furthermore, WebAssembly restricts available memory to a maximum of 4 GB, and individual web browsers may impose even stricter memory constraints."
- [DuckDB — instanciação multi-thread](https://github.com/duckdb/duckdb-web/blob/main/docs/current/clients/wasm/instantiation.md): o *bundle* multi-thread exige isolamento cross-origin (COOP/COEP); caso contrário há *fallback* para mono-thread.
- [DuckDB — Parquet tips](https://duckdb.org/docs/current/data/parquet/tips) e [Parquet Bloom Filters in DuckDB](https://duckdb.org/2025/03/07/parquet-bloom-filters-in-duckdb) — dimensionamento de *row group*, ordenação para descarte por estatística, *bloom filters*.
- [DuckDB-Wasm: Fast Analytical Processing for the Web (VLDB 2022)](https://www.vldb.org/pvldb/vol15/p3574-kohn.pdf) — artigo original.

**Formatos de tabela e *time travel* (§3.3)**
- [Lakehouse Table Formats in 2026: Iceberg, Delta Lake, Hudi, Paimon, and DuckLake](https://amdatalakehouse.substack.com/p/lakehouse-table-formats-in-2026-iceberg)
- [DuckLake in Perspective — endjin](https://endjin.com/blog/ducklake-perspective-advanced-features-future-implications)

**Metadados e descoberta (§3.7)**
- [DCAT-AP — Publications Office of the EU](https://op.europa.eu/en/web/eu-vocabularies/dcat-ap)
- [DCAT-US / Project Open Data Metadata Schema — resources.data.gov](https://resources.data.gov/resources/dcat-us/)
- [Mapeamento DCAT-AP → schema.org (JRC)](https://ec-jrc.github.io/dcat-ap-to-schema-org/) — conformidade com DCAT-AP implica alinhamento com schema.org, o que habilita indexação por Google Dataset Search.

**Contexto institucional do Senado (§3.2)**
- [Catálogo de Dados Abertos do Senado Federal](https://www12.senado.leg.br/dados-abertos/catalogo-de-dados-abertos) — metadados técnicos e administrativos; CSV, XML e JSON.
- [Plano de Dados Abertos do Senado Federal 2026–2028](https://www12.senado.leg.br/dados-abertos/pdf/plano-2026-2028-de-dados-abertos-do-senado-federal.pdf) — política e comitê de governança. *Não foi possível acessar o PDF integral no ambiente desta revisão; a referência baseia-se nos metadados públicos da página. Recomenda-se leitura direta antes do alinhamento institucional.*
- [Serviços de Dados Abertos do Senado Federal](https://legis.senado.leg.br/dadosabertos/docs/) — API REST existente.
- [Sobre o DataSenado](https://www12.senado.leg.br/institucional/datasenado/sobre) e [Microdados do DataSenado](https://www12.senado.leg.br/institucional/datasenado/microdados) — instituto de pesquisa vinculado à Secretaria de Transparência; publica microdados de pesquisas.

**Privacidade e microdados (§3.1)**
- [ANPD — Estudo técnico sobre a anonimização de dados na LGPD: análise jurídica](https://www.gov.br/anpd/pt-br/centrais-de-conteudo/documentos-tecnicos-orientativos/estudo_tecnico_sobre_anonimizacao_de_dados_na_lgpd___analise_juridica.pdf) — a avaliação de risco de reidentificação deve considerar meios de terceiros, não só do agente de tratamento.
- [Parecer PF/INEP nº 00018/2022](https://download.inep.gov.br/microdados/parecer_00018-2022_PFInep.pdf) — restrição de microdados por risco de reidentificação em cruzamento de série histórica.
- [Data Privacy Brasil — Workshop LGPD e microdados](https://www.dataprivacybr.org/documentos/relatorio-workshop-lgpd-e-microdados-avancando-em-metodologias-para-avaliar-riscos-e-garantir-a-transparencia/)

**Acessibilidade (§3.8)**
- [eMAG — Modelo de Acessibilidade em Governo Eletrônico](https://emag.governoeletronico.gov.br/) — institucionalizado pela Portaria SLTI nº 3/2007, sob o Decreto 5.296/2004.
- Lei nº 13.146/2015 (Lei Brasileira de Inclusão), art. 63 — obrigatoriedade de padrões de acessibilidade em sítios de órgãos de governo.

**Alternativas de implementação (§3.6)**
- [Observable Framework](https://github.com/observablehq/framework) — gerador de site estático para aplicações de dados, com DuckDB-WASM embutido.
- [Evidence.dev](https://evidence.dev) — SQL sobre DuckDB-WASM com *deploy* estático.

**Soberania de dados e nuvem no setor público (§3.9)**
- Portaria SGD/MGI nº 5.950/2023 — modelo de contratação de nuvem, obrigatória para órgãos do SISP desde 30/abr/2024. **Não vincula o Senado** (Poder Legislativo), mas define o padrão de mercado e a expectativa política.

**Referência de implementação em produção (§4)**
- [`healthbr-data`](https://github.com/SidneyBissoli/healthbr-data) — `docs/policy-reproducibility-pt.md` (política de reprodutibilidade e receita de auditoria), `docs/contract-consumers-pt.md` (contrato de consumo), `docs/project-pt.md` §9 (princípio de fidelidade à fonte).

---

## Anexo B — Limitações desta revisão

Em coerência com o que ela mesma cobra:

1. **Base documental única.** A revisão avaliou apenas o material de 8 páginas de
   alinhamento de stakeholders. Não houve acesso a especificação técnica,
   protótipo, código, orçamento ou cronograma. Vários achados classificados como
   "ausência" podem estar resolvidos em documentos que não me foram apresentados —
   nesse caso, o achado se converte em "ausente do material de stakeholders", o que
   ainda é um problema de comunicação, mas menor.
2. **Restrições de acesso à rede.** O ambiente desta revisão bloqueia parte dos
   domínios consultados. O Plano de Dados Abertos 2026–2028 do Senado e a
   documentação do DuckDB foram acessados por fontes secundárias ou por espelho do
   repositório; o conteúdo citado do DuckDB foi confirmado em seu repositório
   oficial de documentação.
3. **Versões de navegador com suporte a WebMCP** vêm de fontes secundárias. O
   estado da especificação (Community Group, experimental, API em
   `document.modelContext`) foi confirmado no repositório oficial.
4. **Não avaliei** identidade visual, adequação do material como peça de
   comunicação, nem o mérito das escolhas de design gráfico — que são, aliás, boas.
5. **Viés declarado.** O contexto de referência inclui um projeto (`healthbr-data`)
   que fez escolhas específicas nas mesmas questões. Procurei distinguir "isto é
   melhor" de "isto é o que eu conheço"; onde a decisão do `healthbr-data` é apenas
   *uma* resposta possível, está assim indicado.

---

*Revisão produzida em 27/ago/2026.*
