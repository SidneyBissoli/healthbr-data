# Plano de Divulgação e Sustentabilidade — healthbr-data

> Documento de planejamento para a camada de descobribilidade, documentação
> pública e sustentabilidade financeira do projeto healthbr-data.
> Criado em 26/fev/2026. Atualizado em 02/mar/2026.

---

## 1. CONTEXTO

O projeto healthbr-data redistribui dados do SUS (começando pelo SI-PNI) em
formato Parquet via Cloudflare R2, com egress gratuito e acesso via protocolo
S3 padrão. A infraestrutura técnica está operacional para 4 datasets de
vacinação: microdados de rotina (2020–presente), microdados COVID
(2021–presente), agregados históricos de doses (1994–2019) e agregados
históricos de cobertura (1994–2019). Todos estão publicados no R2, com
dataset cards no Hugging Face, manifesto de integridade e sincronização
automatizada via GitHub Actions.

O próximo desafio é **descobribilidade**: sem divulgação, o trabalho técnico
não gera impacto. Este documento planeja essa camada.

---

## 2. ESTRATÉGIA DE DOCUMENTAÇÃO (READMEs)

### 2.1 Princípio: um README por dataset

Cada sistema de informação publicado no R2 é um "dataset" independente, com
suas próprias fontes, cobertura temporal, variáveis e limitações. Cada um
precisa de documentação própria.

Datasets planejados (em ordem de prioridade):

| Dataset | Prefixo no R2 | Status |
|---------|---------------|--------|
| SI-PNI Microdados (rotina) | `sipni/microdados/` | ✅ Dados no R2 |
| SI-PNI Agregados (doses) | `sipni/agregados/doses/` | ✅ Dados no R2 |
| SI-PNI Agregados (cobertura) | `sipni/agregados/cobertura/` | ✅ Dados no R2 |
| SI-PNI COVID | `sipni/covid/` | ✅ Dados no R2 |
| SI-PNI Dicionários | `sipni/dicionarios/` | ✅ Dados no R2 |
| SINASC (Nascidos vivos) | `sinasc/` | ✅ Dados no R2 |
| SIM (Mortalidade) | `sim/` | 📋 Futuro |
| SIH (Internações) | `sih/` | 📋 Futuro |

### 2.2 Onde publicar os READMEs

O README existe em **três lugares**, cada um com um propósito:

| Local | Propósito | Formato | Idioma |
|-------|-----------|---------|--------|
| **R2** (junto dos dados) | Autodocumentação — acompanha os dados aonde quer que migrem | `README.md` no prefixo do dataset | EN (único) — R2 não renderiza Markdown nem resolve links relativos; um arquivo basta |
| **Hugging Face** (dataset card) | Descobribilidade — indexado por busca, tags, comunidade HF | YAML frontmatter + Markdown | EN + seção resumida em PT |
| **GitHub** (repositório) | Documentação do pipeline/código, não dos dados | `README.md` do repo | EN + espelho PT (`README.pt.md`) — GitHub renderiza Markdown e resolve links |

**R2:** O R2 não renderiza Markdown nem resolve links relativos entre
objetos. Por isso, cada dataset tem um único `README.md` em inglês —
sem badge de idioma, sem link para versão PT. Ter o README junto dos dados
segue a convenção de datasets autocontidos: qualquer pessoa que liste o
bucket (`rclone ls r2:healthbr-data/sipni/`) encontra o arquivo. Se os
dados migrarem para outro storage, a documentação vai junto. A versão em
português existe no GitHub e no HF, onde links relativos funcionam.

**Hugging Face:** Este é o canal principal de descoberta. Cada dataset é
um repositório HF separado sob o perfil `SidneyBissoli/`:
- `SidneyBissoli/sipni-microdados`
- `SidneyBissoli/sipni-covid`
- `SidneyBissoli/sipni-agregados-doses`
- `SidneyBissoli/sipni-agregados-cobertura`

O README do HF é um superset do README do R2 — inclui o YAML frontmatter
com metadados estruturados (license, language, tags, size_categories) que
alimentam o sistema de busca e filtros do Hub. O HF não hospeda os dados;
o README aponta para o R2 com instruções de acesso e credenciais read-only.

**GitHub:** O README do repositório GitHub documenta o pipeline (como rodar,
como contribuir), não os dados em si. Links cruzados com os dataset cards
no HF.

### 2.3 Template de README para datasets

O template reutilizável está em `guides/dataset-card-template.md`.
Os 4 dataset cards publicados estão em `guides/dataset-cards/`.

**Lições aprendidas na implementação (28/fev/2026):**

1. **Sem acesso S3 anônimo.** O Cloudflare R2 não suporta acesso S3
   anônimo (ListObjects requer autenticação). Solução: token read-only
   público (Account API token com Object Read only no bucket
   `healthbr-data`). Credenciais publicadas nos dataset cards e
   serão embutidas no pacote R `healthbR`.

2. **Public Development URL.** Habilitada para acesso HTTP direto
   (`https://pub-99d9e1a3f5c542178d04efbddf1bba97.r2.dev`), mas
   rate-limited e sem S3 API. Útil para downloads pontuais, não para
   Arrow/PyArrow.

3. **Nomes de arquivo.** Parquets usam `part-NNNNN.parquet` (5 dígitos),
   não `part-0.parquet`.

4. **README no R2 causa erro no Arrow.** O `open_dataset()` tenta
   ler `README.md` como Parquet e falha. Solução: apontar para
   subpastas específicas nas partições, não para a raiz do dataset.
   O template reflete isso nos exemplos.

5. **Todas as colunas como string.** Confirmado nos 4 datasets.
   Nomes reais de colunas documentados nos dataset cards.

6. **Citação.** Chave BibTeX: `healthbrdata` (sem ano). Autor:
   `Sidney da Silva Bissoli`. Licença: CC-BY 4.0.

7. **Idioma.** Cards em inglês com seção "Resumo em português".
   Funciona bem para discoverability no HF.

### 2.4 Adaptações por dataset

O template acima é para os microdados. Para outros datasets, as seções de
esquema, fonte e limitações mudam, mas a estrutura geral permanece. Diferenças
principais:

**Agregados (doses e cobertura):** Mencionar as 3 eras estruturais dos .dbf,
o sistema de códigos IMUNO diferente entre doses e cobertura, e a transição
APIDOS→APIWEB em 2013.

**~~Populações~~** *(removido como módulo R2)*: Denominadores populacionais
serão acessados diretamente via pacotes R existentes (ex.: `brpop`,
`sidrar`), sem necessidade de pipeline ou dados no R2. A lógica de
construção de denominadores será incorporada ao pacote `sipni`.

**Dicionários:** Explicar que são os arquivos originais do MS (.cnv, .dbf)
publicados como referência, sem modificação.

---

## 3. CANAIS DE DIVULGAÇÃO

### 3.1 Fase 1 — Fundação (antes do lançamento público)

Antes de divulgar, esses itens precisam estar prontos:

- [x] README de pelo menos um dataset completo e publicado no HF (4 datasets publicados, 28/fev/2026)
- [x] Repositório GitHub público com README do pipeline (`SidneyBissoli/healthbr-data`, 02/mar/2026)
- [x] Bucket R2 com acesso de leitura confirmado e testado (via token read-only público, 28/fev/2026)
- [x] Pelo menos um exemplo reproduzível de acesso via R e Python (4 datasets testados, 28/fev/2026)
- [ ] Página de sustentabilidade (ver Seção 5)

### 3.2 Fase 2 — Lançamento suave (comunidade técnica)

| Canal | Ação | Público |
|-------|------|---------|
| **Hugging Face** | Publicar dataset cards, usar tags relevantes | Data scientists, ML community |
| **GitHub** | Repo público com FUNDING.yml configurado | Desenvolvedores |
| **Twitter/X** | Thread explicando o projeto, com exemplo de código | Pesquisadores, jornalistas de dados |
| **Bluesky** | Mesma thread adaptada | Comunidade acadêmica BR |
| **R-bloggers** | Post tutorial "Como acessar 500M+ registros de vacinação do Brasil" | Comunidade R |
| **rOpenSci** | Submeter para revisão quando o pacote `sipni` estiver pronto | Comunidade R científica |
| **Curso-R / Blog** | Post convidado ou divulgação mútua | Comunidade R Brasil |
| **LinkedIn** | Post profissional sobre o projeto | Rede profissional / saúde pública |

### 3.3 Fase 3 — Divulgação institucional

| Canal | Ação | Público |
|-------|------|---------|
| **Listas de saúde pública** | E-mail para listas de epidemiologia (Abrasco, EpiSUS) | Epidemiologistas, gestores de saúde |
| **Conferências** | Submeter trabalho/pôster para congressos (Abrasco, useR!, LatinR, CSV,conf) | Academia, comunidade de dados |
| **IEPS / Vital Strategies** | Contato direto — organizações que trabalham com dados de saúde BR | Potenciais parceiros/financiadores |
| **Fiocruz / ICICT** | Contato com grupos que mantêm PCDaS e MonitoraCovid | Academia, infraestrutura de dados |

### 3.4 Mensagem central (elevator pitch)

> **healthbr-data** redistribui dados públicos de saúde do Brasil em formato
> moderno (Apache Parquet), com acesso gratuito via protocolo S3, atualizações
> mensais automatizadas, e documentação completa. Comece a analisar 500 milhões
> de registros de vacinação em 3 linhas de código R ou Python.

---

## 4. LICENCIAMENTO

### 4.1 O problema

Os dados originais são produzidos pelo governo brasileiro e disponibilizados
via DATASUS/OpenDATASUS. A Lei de Acesso à Informação (LAI, Lei 12.527/2011)
estabelece que dados públicos devem ser acessíveis, mas não define
explicitamente uma licença de redistribuição no sentido de open data.

O OpenDATASUS publica dados sob a "Licença Aberta" do governo brasileiro, que
na prática é compatível com CC-BY 4.0 (atribuição obrigatória, uso livre).

### 4.2 Opções

| Licença | Prós | Contras |
|---------|------|---------|
| **CC-BY 4.0** | Padrão internacional, reconhecida no HF, permite uso comercial | Exige verificar compatibilidade com termos do OpenDATASUS |
| **CC0 (domínio público)** | Máxima abertura, sem restrição | Pode conflitar com atribuição exigida pelo governo |
| **ODC-BY** | Específica para dados (não conteúdo criativo) | Menos conhecida |
| **Sem licença (atribuição à fonte)** | Sem risco jurídico para nós | Ambiguidade para usuários |

### 4.3 Decisão

✅ **CC-BY 4.0** adotada (28/fev/2026), com atribuição dupla: ao projeto
healthbr-data (como redistribuidor) e ao Ministério da Saúde (como fonte
original). Aplicada nos 4 repositórios HF e nos dataset cards.

---

## 5. SUSTENTABILIDADE FINANCEIRA

### 5.1 Custos reais do projeto

| Item | Custo mensal | Notas |
|------|:-----------:|-------|
| **Cloudflare R2** (armazenamento) | ~$1.50 | ~100 GB × $0.015/GB. Pode crescer com novos datasets. |
| **Cloudflare R2** (operações) | ~$0.50 | Class A ($4.50/M ops) e Class B ($0.36/M ops). Uso baixo. |
| **Hetzner VPS** (manutenção mensal) | €3.99 (~$4.30) | CX22 mínimo, rodando 1-2 dias/mês. Alternativa: criar/destruir sob demanda (~$0.50). |
| **Domínio** (futuro) | ~$1.00 | Se registrar domínio próprio (ex: healthbr-data.org) |
| **Claude Pro** (desenvolvimento) | ~$20.00 | Ferramenta de desenvolvimento usada no projeto |
| | | |
| **Total estimado** | **~$7–27/mês** | ~R$40–150/mês na cotação atual |

> **Nota sobre o crescimento:** À medida que novos datasets forem adicionados
> (SIM, SINASC, SIH — cada um com prefixo próprio na raiz do R2), o
> armazenamento pode chegar a 500 GB–1 TB, elevando o custo de storage para
> $7.50–$15/mês. Mesmo no cenário máximo, o custo total ficaria abaixo de
> $50/mês (~R$275).

### 5.2 Modelo de financiamento

O modelo proposto combina **transparência radical** com **múltiplos canais
de contribuição**, sem promessa de devolução de excedentes.

#### Princípios

1. **Transparência total.** Publicar mensalmente: custo real de infraestrutura,
   contribuições recebidas, e saldo. Qualquer pessoa pode auditar.

2. **Sem promessa de devolução.** Excedentes são direcionados para expansão
   do projeto (novos datasets, mais armazenamento, domínio, conferências).
   Isso evita complexidade operacional e desincentivo a contribuições.

3. **Contribuição voluntária, não obrigatória.** Os dados são e sempre serão
   gratuitos. O financiamento cobre infraestrutura, não acesso.

4. **Independência.** Nenhum contribuinte ganha acesso privilegiado ou
   influência sobre decisões técnicas.

#### Canais de contribuição

| Plataforma | Prós | Contras | Taxa |
|------------|------|---------|:----:|
| **GitHub Sponsors** | Integrado ao repo, botão nativo, visibilidade no perfil | Requer conta GitHub, payout via Stripe | 0% (GitHub absorve) |
| **Ko-fi** | Simples, aceita doação única e mensal, sem taxa de plataforma | Menos visível para comunidade dev | 0% (só PayPal/Stripe) |
| **Open Collective** | Transparência máxima (todas transações públicas), gestão fiscal | Taxa de 10%, mais burocrático | 10% |
| **Buy Me a Coffee** | Marca conhecida, interface amigável | Taxa de 5%, menos transparente | 5% |
| **Pix** (Brasil) | Sem taxa, instantâneo, acessível a brasileiros | Sem registro público, sem recorrência automática | 0% |

#### Recomendação

Começar com **duas plataformas**:

1. **GitHub Sponsors** — para a comunidade internacional e dev. Configurar
   via `FUNDING.yml` no repositório. Zero taxa. Tiers sugeridos:
   - ☕ $2/mês — "Obrigado!"
   - 💉 $5/mês — "Cobre 1 mês de R2"
   - 🏥 $10/mês — "Cobre infraestrutura completa"
   - 🏛️ $25/mês — "Apoiador institucional"

2. **Pix** — para a comunidade brasileira. Publicar chave Pix no README e
   na página do projeto. Sem burocracia, sem taxa.

Avaliar adicionar Ko-fi ou Open Collective depois, conforme a comunidade
crescer.

### 5.3 Página de transparência

Criar uma página pública (Markdown no GitHub ou seção no site) com:

```markdown
## Transparência financeira — healthbr-data

### Custos mensais (atualizado em [MÊS/ANO])

| Item | Custo |
|------|-------|
| Cloudflare R2 (armazenamento + operações) | $X.XX |
| Hetzner VPS | $X.XX |
| Domínio | $X.XX |
| **Total** | **$X.XX** |

### Contribuições recebidas

| Mês | GitHub Sponsors | Pix | Total | Saldo |
|-----|----------------|-----|-------|-------|
| Mar/2026 | $0 | R$0 | $0 | -$X.XX |
| Abr/2026 | ... | ... | ... | ... |

### Uso de excedentes

Qualquer valor que exceda os custos operacionais será direcionado para:
1. Expansão para novos sistemas de informação (SIM, SINASC, SIH)
2. Registro de domínio próprio
3. Participação em conferências para divulgação
4. Reserva para 3 meses de operação (resiliência)
```

### 5.4 Financiamento institucional (médio/longo prazo)

Após estabelecer base de usuários e demonstrar impacto (downloads, citações),
considerar:

| Fonte | Tipo | Adequação |
|-------|------|-----------|
| **Fiocruz / ICICT** | Parceria institucional | Alta — alinham-se com infraestrutura de dados de saúde |
| **IEPS** | Financiamento de projeto | Alta — trabalham com dados de saúde pública BR |
| **Vital Strategies** | Grant | Média — foco em dados para políticas de saúde |
| **GAVI** | Grant | Média — foco específico em vacinação |
| **Google.org / Data.org** | Grant para dados de impacto social | Média — competitivo mas bem alinhado |
| **NumFOCUS** | Fiscal sponsorship para projetos open source científicos | Alta — modelo comprovado (pandas, NumPy, Arrow) |
| **rOpenSci** | Parceria de revisão e incubação | Alta — se o pacote `sipni` for submetido |
| **Chan Zuckerberg Initiative (CZI)** | Grant para open source científico | Alta — financiam infraestrutura de dados |

**[TODO]** Pesquisar editais e prazos para cada opção após o lançamento.

---

## 6. ROADMAP PÚBLICO

O roadmap será publicado no GitHub (arquivo `ROADMAP.md` ou GitHub Projects)
e referenciado nos dataset cards:

### Já disponível ✅

- Microdados de vacinação de rotina (SI-PNI), 2020–presente
  - 736M+ registros em Parquet particionado (ano/mes/uf)
  - Atualização mensal
  - HF: `SidneyBissoli/sipni-microdados`
- Microdados de vacinação COVID-19 (SI-PNI), 2021–presente
  - 608M+ registros em Parquet particionado (ano/mes/uf)
  - HF: `SidneyBissoli/sipni-covid`
- Dados agregados históricos — doses aplicadas (SI-PNI), 1994–2019
  - 84M+ registros (674 arquivos .dbf → Parquet, particionado por ano/uf)
  - HF: `SidneyBissoli/sipni-agregados-doses`
- Dados agregados históricos — cobertura vacinal (SI-PNI), 1994–2019
  - 2,8M+ registros (686 arquivos .dbf → Parquet, particionado por ano/uf)
  - HF: `SidneyBissoli/sipni-agregados-cobertura`
- Dicionários de dados do SI-PNI (IMUNO, DOSE, FXET, ANO, MES, IMUNOCOB)
  - 6 Parquets + 18 arquivos originais (.cnv/.dbf)
  - HF: `SidneyBissoli/sipni-dicionarios`
- Microdados de nascidos vivos (SINASC), 1994–2022
  - 85M+ registros em Parquet particionado (ano/uf)
  - 783 arquivos .dbc (FTP DATASUS), 12 schemas históricos
  - HF: `SidneyBissoli/sinasc`

### Em finalização 🔧

- Documentação de harmonização entre sistemas agregado ↔ microdados

### Planejado 📋

- Pacote R `healthbR` (meta-pacote unificado) para acesso integrado a SI-PNI, SIM, SINASC e outros sistemas via mesma interface — inclui acesso a denominadores populacionais via pacotes R existentes. Decisão de arquitetura formalizada em 07/mar/2026.
- Série temporal harmonizada de cobertura vacinal (1994–presente)
- Página de transparência financeira

### Futuro 🔮

- Novos sistemas de informação: SIM (mortalidade), SIH (internações) — cada um como dataset independente no R2
- API REST para consultas leves (se houver demanda)

---

## 7. IDENTIDADE DO PROJETO

### 7.1 Nome

**healthbr-data** — nome do bucket e identidade do projeto guarda-chuva.
Cada dataset específico tem seu próprio nome descritivo nos canais de
divulgação (ex: "SI-PNI Microdados de Vacinação").

### 7.2 Presença online necessária

| Recurso | URL | Status |
|---------|-----|:------:|
| Hugging Face (perfil) | `huggingface.co/SidneyBissoli` | ✅ Ativo (4 dataset repos + 1 HF Space) |
| GitHub repo | `github.com/SidneyBissoli/healthbr-data` | ✅ Ativo (README EN/PT, FUNDING.yml, GitHub Actions) |
| Site/landing page | `healthbr-data.org` (ou GitHub Pages) | Futuro |
| Twitter/X | `@healthbrdata` | Futuro |
| Bluesky | `@healthbrdata.bsky.social` | Futuro |

**[TODO]** Verificar disponibilidade de nomes e registrar.

### 7.3 Materiais visuais

- [ ] Logo simples (pode ser texto estilizado + ícone de saúde)
- [ ] Banner para GitHub e HF
- [ ] Card para compartilhamento em redes sociais (Open Graph)

---

## 8. CHECKLIST DE LANÇAMENTO

### Pré-lançamento

- [x] ~~Confirmar acesso anônimo de leitura ao bucket R2~~ → R2 não suporta acesso S3 anônimo. Solução: token read-only público (Account API token `healthbr-data-readonly`, Object Read only). Public Development URL habilitado para HTTP direto.
- [x] Criar README completo para SI-PNI microdados (usando template §2.3)
- [x] Upload do README para o R2 (4 datasets: `sipni/microdados/`, `sipni/covid/microdados/`, `sipni/agregados/doses/`, `sipni/agregados/cobertura/`)
- [x] Criar repositórios HF e publicar dataset cards (4 repos sob `SidneyBissoli/`)
- [x] Criar repositório GitHub público com README do pipeline (`SidneyBissoli/healthbr-data`, README bilingue EN/PT, 02/mar/2026)
- [x] Configurar FUNDING.yml no GitHub (GitHub Sponsors + Pix, 02/mar/2026)
- [x] Criar conta GitHub Sponsors (configurada em `SidneyBissoli`, 02/mar/2026)
- [x] Definir chave Pix para contribuições (`sbissoli76@gmail.com`, 02/mar/2026)
- [x] Gerar `manifest.json` retroativamente para os 4 módulos já no R2
  (02/mar/2026). Ver `strategy-synchronization.md`, seção 5.
- [x] Implementar comparison engine (`sync_check.py`) e configurar GitHub
  Actions semanal (02/mar/2026). Ver `strategy-synchronization.md`, seção 3.
- [x] Criar HF Space (dashboard Streamlit) consumindo `sync-status.json`
  (`SidneyBissoli/healthbr-sync-status`, 02/mar/2026).
  Ver `strategy-synchronization.md`, seção 4.
- [x] Testar exemplos de código R e Python de ponta a ponta (4 datasets testados com token read-only, 28/fev/2026)
- [x] Definir licença → CC-BY 4.0 (aplicada nos 4 repos HF)
- [ ] Publicar página de transparência financeira

### Lançamento

- [ ] Publicar thread no Twitter/X
- [ ] Publicar no Bluesky
- [ ] Publicar post no LinkedIn
- [ ] Submeter post para R-bloggers
- [ ] Contactar Curso-R para divulgação
- [ ] Postar no r/datascience e r/rstats

### Pós-lançamento

- [ ] Monitorar issues e feedback
- [ ] Atualizar transparência financeira mensalmente
- [ ] Planejar submissão a conferências
- [ ] Avaliar necessidade de Open Collective ou Ko-fi
- [ ] Iniciar contatos com instituições para financiamento

---

## 9. DECISÕES PENDENTES

| Decisão | Opções | Impacto | Prazo |
|---------|--------|---------|-------|
| ~~Licença dos dados~~ | ~~CC-BY 4.0~~, CC0, ODC-BY | ~~Alto~~ | ✅ Decidido: CC-BY 4.0 (28/fev/2026) |
| GitHub org vs. perfil pessoal | Criar org `healthbr-data` vs. publicar sob perfil pessoal | Médio — afeta identidade | Antes do lançamento |
| ~~Hugging Face: org ou perfil~~ | ~~Publicar sob perfil pessoal~~ | ~~Médio~~ | ✅ Decidido: perfil pessoal `SidneyBissoli` (28/fev/2026) |
| Domínio próprio | Registrar healthbr-data.org (ou .dev, .io) | Baixo — pode esperar | Pós-lançamento |
| Landing page | GitHub Pages vs. site simples vs. apenas README | Baixo — pode esperar | Pós-lançamento |

---

## 10. REFERÊNCIAS E INSPIRAÇÕES

Projetos de redistribuição de dados públicos que servem de referência:

- **Base dos Dados** (basedosdados.org) — repositório brasileiro de dados
  públicos tratados, com pacotes R e Python. Modelo de organização sem fins
  lucrativos com financiamento institucional.

- **Our World in Data** (ourworldindata.org) — datasets de saúde global,
  GitHub + catalogo próprio. Financiamento por grants.

- **openelections** (openelections.net) — redistribuição padronizada de
  dados eleitorais dos EUA. GitHub + voluntários.

- **nflverse** (nflverse.nflverse.com) — dados esportivos em Parquet no
  GitHub Releases. Pacotes R, comunidade ativa, modelo voluntário.

- **dados.gov.br** — portal oficial do governo brasileiro. Referência para
  termos de uso e licenciamento.

---

*Este documento será atualizado conforme decisões forem tomadas. Cada seção
com [TODO] indica um item que precisa de investigação ou decisão antes do
lançamento.
Última atualização: 08/mar/2026 — SINASC adicionado ao roadmap
(6 datasets concluídos: 5 SI-PNI + SINASC). HF: `SidneyBissoli/sinasc`.
85M+ registros, 1994–2022, 783 arquivos .dbc.*
