# Estratégia de Expansão Modular — healthbr-data

> Guia prospectivo para implantação de novos módulos de dados no projeto
> healthbr-data. Define fases, critérios de avanço, artefatos obrigatórios,
> método de exploração, lições aprendidas e inventário de módulos candidatos.
> **Deve ser consultado antes de iniciar qualquer novo dataset.**
>
> Criado em 26/fev/2026.
>
> **Documentos relacionados:**  
> - `reference-pipelines-pt.md` — Manual de operação dos pipelines de
>   produção (arquitetura, números, comandos). Consultado na Fase 4
>   e para operar pipelines existentes.  
> - `strategy-dissemination-pt.md` — Estratégia de divulgação e documentação
>   pública. Acionado na Fase 5 (publicação).  
> - `strategy-synchronization.md` — Arquitetura do sistema de
>   sincronização e integridade (comparison engine, dashboard HF,
>   manifesto no R2). Acionado nas Fases 4, 5 e 6.  
> - `strategy-languages-pt.md` — Regras de idioma para cada artefato.
>   Acionado na criação de qualquer documento.  
> - `project-pt.md` — Fonte de verdade sobre arquitetura e decisões.
>   Atualizado ao final de cada módulo.  

---

## 1. POR QUE ESTE DOCUMENTO EXISTE

Quando alguém senta para começar o SIH, o SIM, ou os agregados 1994-2019,
a primeira pergunta não é "como funciona o jq" — é "qual é o processo
completo, do zero à publicação, e como sei que estou pronto para avançar?"

Este documento responde essa pergunta. Ele define:

- **Fases** do ciclo de vida de um módulo (da ideia à publicação)
- **Critérios de prontidão** para avançar entre fases
- **Artefatos obrigatórios** que cada fase deve produzir
- **Método de exploração** testado e refinado nos dois primeiros módulos
- **Lições aprendidas** que se aplicam a todo módulo futuro
- **Inventário** de módulos candidatos com suas particularidades conhecidas
- **Priorização** — em que ordem atacar e por quê

---

## 2. DEFINIÇÕES

**Módulo:** Um dataset independente publicado no R2 sob um prefixo próprio,
com pipeline, documentação e dataset card. Exemplos: `sipni/microdados/`,
`sipni/covid/microdados/`, `sim/`, `sinasc/`.

**Submódulo:** Uma subdivisão de um módulo que compartilha o mesmo sistema
de origem mas tem pipeline ou estrutura distintos. Exemplos:
`sipni/agregados/doses/`, `sipni/agregados/cobertura/`.

**Módulo completo:** Um módulo que passou por todas as 6 fases e está
publicado no R2 com documentação, dataset card e entrada no roadmap público.

---

## 3. CICLO DE VIDA DE UM MÓDULO

Cada módulo passa por 6 fases sequenciais. Não se avança para a fase
seguinte sem que os critérios de prontidão estejam cumpridos.

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  1. RECON   │───▶│ 2. EXPLORA  │───▶│ 3. DECISÃO  │
│  (1-2 dias) │    │  (3-7 dias) │    │  (1 dia)    │
└─────────────┘    └─────────────┘    └─────────────┘
                                            │
┌─────────────┐    ┌─────────────┐    ┌─────▼───────┐
│ 6. INTEGRA  │◀───│ 5. PUBLICA  │◀───│ 4. PIPELINE │
│  (1-2 dias) │    │  (2-3 dias) │    │  (3-10 dias)│
└─────────────┘    └─────────────┘    └─────────────┘
```

As estimativas de tempo são baseadas na experiência com SI-PNI rotina e
COVID. Módulos com fontes desconhecidas (SIH, SIM) podem levar mais tempo
na fase de exploração.

---

### Fase 1: RECONHECIMENTO (Recon)

**Objetivo:** Saber se vale a pena investir tempo neste módulo. Responder
três perguntas: os dados existem? São acessíveis? Há demanda?

**Atividades:**  
- Localizar a fonte oficial dos dados (FTP, S3, portal, API)  
- Testar acesso básico (HEAD request, curl de amostra, listar diretório)  
- Identificar formato(s) disponível(is) (.dbc, .dbf, .csv, .json, API)  
- Estimar volume bruto (número de arquivos × tamanho médio)  
- Verificar se existe dicionário oficial  
- Verificar cobertura temporal (de quando a quando)  
- Consultar alternativas existentes (Base dos Dados, PCDaS, microdatasus)  

**Critério de prontidão para avançar:**

| # | Critério | Verificação |
|:-:|----------|-------------|
| 1 | Fonte identificada e acessível | HEAD request retorna 200 ou diretório FTP listável |
| 2 | Volume estimado | Ordem de grandeza conhecida (GB, número de arquivos) |
| 3 | Formato(s) identificado(s) | Sabe-se o que vai ser baixado |
| 4 | Justificativa documentada | Por que este módulo e não outro (ver Seção 7) |

**Artefato obrigatório:**  
- Nenhum arquivo formal. Um parágrafo no log da sessão ou uma nota neste
  documento (Seção 8) é suficiente. O recon é leve por design.

**Critério de abandono:** Se a fonte não é acessível, os dados estão atrás
de paywall, ou uma alternativa existente já resolve bem o problema — não
avançar. Registrar a razão na Seção 8.

---

### Fase 2: EXPLORAÇÃO

**Objetivo:** Compreender a estrutura dos dados a fundo. Todas as decisões
estruturantes do pipeline nascem aqui.

**Atividades:**
Seguir a sequência de exploração da Seção 4 deste documento:  
1. Mapear vias de acesso  
2. Baixar amostra mínima  
3. Comparar formatos disponíveis  
4. Inventariar o volume  
5. Identificar artefatos e problemas  
6. Avaliar trade-offs antes de decidir  

**Critério de prontidão para avançar:**

| # | Critério | Verificação |
|:-:|----------|-------------|
| 1 | Estrutura dos dados documentada | Colunas, tipos, encoding, delimitador |
| 2 | Artefatos identificados | Lista de problemas com campo, valor esperado, valor encontrado |
| 3 | Formatos comparados (se >1) | Tabela campo a campo |
| 4 | Volume preciso mapeado | Número exato de arquivos, tamanho total |
| 5 | Dicionário(s) localizado(s) | Mesmo que incompleto — documentar lacunas |
| 6 | Documento de exploração escrito | `docs/<sistema>/exploration-pt.md` |

**Artefato obrigatório:**  
- `docs/<sistema>/exploration-pt.md` — Documento de exploração seguindo o
  padrão de `docs/covid/exploration-pt.md`. Inclui: visão geral,
  vias de acesso, estrutura dos dados, artefatos encontrados, volume,
  comparação de formatos.

**Scripts de exploração (opcionais mas recomendados):**  
- `scripts/exploration/<sistema>-*.R` — Scripts usados na investigação.
  Não precisam ser polidos; servem como registro do processo.

---

### Fase 3: DECISÃO

**Objetivo:** Tomar e documentar todas as decisões estruturantes antes de
escrever o pipeline. Esta fase existe para evitar o anti-padrão de
"decidir enquanto coda".

**Atividades:**  
- Para cada decisão estruturante, aplicar o checklist de trade-offs da
  Seção 5 deste documento (6 perguntas: problema exato, qual formato
  preserva melhor os dados, custo de cada alternativa, existência de
  dicionário para correção, reversibilidade)  
- Documentar decisões em tabela  

**Decisões típicas que todo módulo enfrenta:**

| Decisão | Opções comuns |
|---------|---------------|
| Formato fonte | CSV vs JSON vs DBC vs API |
| Tipos no Parquet | Tudo string vs tipagem seletiva |
| Particionamento | ano/mes/uf vs ano/uf vs outro |
| Ferramenta de parsing | polars direto vs jq+polars vs R |
| Estratégia de download | Bulk vs incremental vs on-demand |
| Tratamento de artefatos | Evitar via formato vs corrigir no pipeline |

**Critério de prontidão para avançar:**

| # | Critério | Verificação |
|:-:|----------|-------------|
| 1 | Todas as decisões estruturantes documentadas | Tabela com decisão, alternativa rejeitada, motivo |
| 2 | Tempo de bootstrap estimado | Com base no volume e ferramenta escolhida |
| 3 | Infraestrutura definida | Servidor, disco necessário, dependências |
| 4 | Estrutura de destino no R2 definida | Prefixo, particionamento, nomes de arquivo |

**Artefato obrigatório:**  
- Seção "Decisões" adicionada ao `docs/<sistema>/exploration-pt.md`, ou
  documento separado se necessário. O importante é que fique registrado
  *antes* de começar a codar.  

---

### Fase 4: PIPELINE

**Objetivo:** Construir, testar e executar o pipeline de produção.

**Atividades:**  
- Desenvolver script de pipeline em `scripts/pipeline/`  
- Testar com amostra pequena (1 UF, 1 mês, 1 ano)  
- Validar saída: conferir contagem de registros, tipos, partições  
- Executar bootstrap completo no Hetzner  
- Registrar métricas (tempo, registros, taxa, erros)  
- Criar/atualizar arquivo de controle de versão (`data/controle_versao_*.csv`)  
- **Gerar/atualizar `manifest.json` no R2** — ao final do processamento
  de cada partição, registrar: URL de origem, ETag, tamanho da fonte,
  timestamp de processamento, SHA-256 dos Parquets de saída, contagem
  de registros. O manifesto é um subproduto natural do pipeline — todas
  as informações já estão disponíveis no momento do upload. Ver
  `strategy-synchronization.md`, seção 5, para o schema completo.  

**Critério de prontidão para avançar:**

| # | Critério | Verificação |
|:-:|----------|-------------|
| 1 | Pipeline executado sem erros | Bootstrap completo ou manutenção mensal |
| 2 | Dados no R2 | `rclone ls r2:healthbr-data/<prefixo>/` retorna arquivos |
| 3 | Contagem validada | Registros no Parquet batem com fonte (margem de 0.1%) |
| 4 | Controle de versão criado | CSV com hash, tamanho, data de processamento |
| 5 | Pipeline documentado | Seção no `reference-pipelines-pt.md` |
| 6 | Manifesto gerado | `<prefixo>/manifest.json` no R2 com metadados de todas as partições processadas |

**Artefatos obrigatórios:**  
- `scripts/pipeline/<sistema>-pipeline-python.py` (ou `-r.R` se aplicável)  
- `data/controle_versao_<sistema>.csv`  
- `<prefixo>/manifest.json` no R2 (schema em `strategy-synchronization.md`,
  seção 5)  
- Seção no `reference-pipelines-pt.md` documentando o pipeline (usar
  template da seção 8 daquele documento)  

---

### Fase 5: PUBLICAÇÃO

**Objetivo:** Tornar os dados descobríveis e usáveis por pesquisadores.

**Atividades:**  
- Criar README do dataset (seguindo template do `strategy-dissemination-pt.md`,
  seção 2.3)  
- Upload do README para o R2 (`<prefixo>/README.md`)  
- Criar dataset card no Hugging Face (usando `guides/dataset-card-template.md`)  
- Verificar acesso anônimo de leitura ao bucket  
- Testar exemplos de código R e Python de ponta a ponta  
- Atualizar roadmap público (GitHub)  
- **Registrar o módulo no dashboard de sincronização** — adicionar a
  lógica de comparação do novo módulo ao comparison engine e verificar
  que o dashboard exibe corretamente o status do módulo. Na primeira
  vez (primeiro módulo a passar por esta etapa), isso inclui criar o
  próprio HF Space e o cron no Hetzner. Nos módulos seguintes, basta
  adicionar o módulo ao registro de datasets do engine. Ver
  `strategy-synchronization.md`, seções 3 e 4.  

**Critério de prontidão para avançar:**

| # | Critério | Verificação |
|:-:|----------|-------------|
| 1 | README no R2 | Arquivo acessível via S3 |
| 2 | Dataset card no HF | Publicado e indexado |
| 3 | Exemplos testados | R e Python funcionam contra os dados no R2 |
| 4 | Roadmap atualizado | Módulo movido de "Planejado" para "Disponível" |
| 5 | Dashboard de sincronização | Módulo aparece no dashboard com status correto |

**Artefatos obrigatórios:**  
- README.md no R2 (junto dos dados)  
- Dataset card no Hugging Face  
- Atualização do `strategy-dissemination-pt.md` (roadmap, seção 6)  
- Módulo registrado no comparison engine (`strategy-synchronization.md`,
  seção 10)  

**Conexão com outros documentos:**  
- Consultar `strategy-languages-pt.md` para decidir idioma(s) do README
  e dataset card  
- Seguir o template de `strategy-dissemination-pt.md` (seção 2.3)  
- Seguir `guides/dataset-card-template.md` para o dataset card no HF  

**Decisão sobre idioma dos READMEs no R2 (27/fev/2026):**  
Apenas inglês. O R2 não renderiza Markdown nem resolve links relativos
entre objetos, o que torna inútil publicar dois arquivos com referência
cruzada. Um único `README.md` em inglês é suficiente para
autodocumentação no R2. A versão em português existirá no HF (seção
resumida) e no GitHub (espelho completo), onde links funcionam.  

---

### Fase 6: INTEGRAÇÃO

**Objetivo:** Conectar o módulo ao ecossistema do projeto (pacote R,
documentação central, divulgação).

**Atividades:**  
- Atualizar `project-pt.md` e `project-en.md` com o novo módulo  
- Adicionar suporte no pacote R `healthbR` (ver decisão de arquitetura de 07/mar/2026 na Seção 8.1)  
- Atualizar guias rápidos (`guides/quick-guide-*.R`)  
- Divulgar nos canais definidos no `strategy-dissemination-pt.md`  
- Atualizar transparência financeira (novo custo de armazenamento no R2)  
- **Integrar ao pacote R** (se aplicável) — implementar funções de
  validação de integridade (`check_sync()`, `validate_local()`) que
  consomem o `manifest.json` do R2. Ver `strategy-synchronization.md`,
  seção 5.4.  

**Critério de conclusão:**

| # | Critério | Verificação |
|:-:|----------|-------------|
| 1 | `project-*.md` atualizado | Novo módulo aparece na arquitetura |
| 2 | Pacote R atualizado (se aplicável) | Funções de acesso ao novo dataset |
| 3 | Divulgação feita | Pelo menos 1 canal (HF + 1 rede social) |
| 4 | Dashboard atualizado | Novo módulo visível no dashboard de sincronização |

**Artefatos obrigatórios:**  
- Atualizações nos documentos existentes (não é arquivo novo)  
- Post de divulgação (formato livre)  

---

## 4. MÉTODO DE EXPLORAÇÃO

> Método testado nos dois primeiros módulos (SI-PNI rotina e COVID) e
> destilado em uma sequência reutilizável.

### Por que documentar o método

Na exploração do SI-PNI, as decisões técnicas mais importantes foram tomadas
durante a fase exploratória — antes de existir qualquer pipeline. Algumas
dessas decisões tiveram consequências grandes na fase de implementação.
A escolha do JSON como fonte primária, por exemplo, foi correta do ponto de
vista de fidelidade dos dados: o JSON preserva zeros à esquerda, tipos
originais e a estrutura exata dos campos como registrados pelo Ministério
da Saúde. O CSV, em contraste, introduz artefatos de serialização — campos
numéricos com sufixo `.0`, perda de zeros à esquerda em códigos — que nem
sempre podem ser corrigidos com segurança, especialmente quando não existe
dicionário de dados acessível.

O custo dessa decisão foi um pipeline mais complexo e mais lento (~22h vs
~8h de bootstrap). Esse custo é real, mas aceitável: tempo de processamento
é um investimento pontual, enquanto erros de precisão nos dados publicados
seriam permanentes e potencialmente invisíveis para os pesquisadores que
os consumissem.

O objetivo desta seção é codificar um método reutilizável para que, nos
próximos datasets, as decisões estruturantes sejam tomadas com visão
completa dos trade-offs — priorizando sempre a fidelidade dos dados.

### Sequência de exploração

A ordem que funcionou no SI-PNI e no SI-PNI COVID, destilada:

1. **Mapear as vias de acesso aos dados.** Antes de baixar qualquer coisa,
   identificar todas as formas de obter os dados: FTP, S3, API, portal.
   Para cada via, testar acesso (HEAD request, curl de amostra) e registrar
   formato, tamanho, particionamento, e restrições de acesso.

2. **Baixar amostra mínima.** Não baixar o dataset inteiro. Baixar um
   arquivo pequeno (uma UF, um mês, primeiros bytes) e inspecionar: encoding,
   delimitador, header, tipos, campos, artefatos. Comparar com o dicionário
   oficial se existir.

3. **Comparar formatos disponíveis.** Se houver mais de um formato (CSV,
   JSON, API), baixar amostra de cada um e comparar campo a campo. Documentar
   diferenças em tabela. Não assumir que são equivalentes — a experiência
   mostrou que formatos diferentes do mesmo dataset podem divergir em
   conteúdo, não apenas em estrutura.

4. **Inventariar o volume.** HEAD requests em todos os arquivos para mapear
   tamanho total, número de partes, padrões de URL. Isso informa decisões
   de infraestrutura (servidor, disco, RAM).

5. **Identificar artefatos e problemas.** Zeros à esquerda perdidos, floats
   espúrios, colunas extras, registros deletados, typos oficiais. Cada
   problema identificado deve ser registrado com: campo afetado, valor
   esperado, valor encontrado, em quais anos/formatos ocorre, e se a
   correção é determinística (ou seja, se existe dicionário ou padrão
   externo que garanta a reconstrução sem ambiguidade).

6. **Avaliar trade-offs antes de decidir.** Para cada decisão estruturante
   (formato fonte, particionamento, tipos no Parquet, etc.), aplicar o
   checklist da Seção 5. A regra geral é: precisão prevalece sobre
   velocidade.

---

## 5. CHECKLIST DE TRADE-OFFS PARA DECISÕES ESTRUTURANTES

Antes de comprometer qualquer decisão que afeta a arquitetura do pipeline,
responder estas 6 perguntas:

1. **Qual o problema exato?**
   Descrever com precisão. "CSV tem artefatos" é vago. "5 campos específicos
   têm sufixo .0 nos CSVs de 2020-2024, e co_raca_cor_paciente perde o zero
   à esquerda" é preciso.

2. **Qual formato preserva melhor os dados originais?**
   Comparar campo a campo. Se um formato preserva a representação original
   do Ministério da Saúde sem transformações, ele é a escolha padrão.
   O ônus da prova recai sobre a alternativa mais rápida: ela precisa
   demonstrar que não perde informação, não o contrário.

3. **Se o formato mais preciso não estiver disponível, a correção é
   determinística?**
   Uma correção é determinística quando existe dicionário de dados
   acessível, padrão externo documentado (código IBGE = 7 dígitos,
   CNES = 7 dígitos, CEP = 8 dígitos), ou domínio fechado conhecido
   (raça/cor = 01-05, 99). Se a correção depende de suposições sobre
   comprimentos de campos sem documentação, ela não é determinística
   e o formato mais preciso deve ser preferido, mesmo que mais lento.

4. **Qual o custo de cada alternativa em tempo de processamento?**
   Estimar para o bootstrap completo. Diferenças de 2-3x no tempo de
   processamento são significativas, mas são custos pontuais: o bootstrap
   roda uma vez (ou poucas vezes), enquanto erros de precisão nos dados
   publicados são permanentes. Tempo de processamento é um custo
   aceitável em troca de fidelidade.

5. **Qual o custo de cada alternativa em complexidade de código?**
   Contar as dependências extras, as etapas intermediárias, os pontos de
   falha. Complexidade adicional é aceitável quando necessária para
   preservar a precisão, mas deve ser documentada e testada.

6. **A decisão é reversível?**
   Se os dados fonte não mudam (o S3 do Ministério mantém os arquivos), a
   decisão é reversível — podemos reprocessar. Isso significa que, em caso
   de dúvida, a escolha mais segura (maior precisão) é também a menos
   arriscada: se depois descobrirmos que a correção era determinística,
   podemos migrar para o formato mais rápido. O inverso — descobrir que
   dados publicados tinham erros de precisão — é muito mais custoso.

### Princípio geral

**Precisão prevalece sobre velocidade.** Tempo de processamento é um custo
pontual e previsível. Erros de precisão nos dados publicados são custos
distribuídos, potencialmente invisíveis e de difícil correção depois que
pesquisadores já consumiram os dados. Na dúvida, escolher o formato que
preserva melhor os dados originais do Ministério da Saúde.

A única exceção legítima é quando o formato mais preciso **não existe** —
por exemplo, quando só há CSV disponível (caso do SI-PNI COVID). Nessa
situação, usar o CSV com correções determinísticas documentadas é a
abordagem correta, não por preferência, mas por necessidade.

### Exemplo: decisão JSON vs CSV no SI-PNI (rotina)

| Critério | CSV + correção | JSON (escolhido) |
|----------|----------------|-------------------|
| Problema | 5 campos com artefatos em 2020-2024 | Nenhum |
| Solução | 5 linhas de `str.replace` + `str.zfill` | Usar JSON diretamente |
| Tempo de bootstrap | ~8h (leitura direta com polars) | ~22h (ZIP + jq + JSONL + polars) |
| Complexidade | Baixa (polars lê CSV nativo) | Alta (jq, streaming, múltiplos formatos) |
| Fidelidade | Alta, com transformações documentadas | Máxima, sem transformações |
| Correção determinística? | Parcialmente — 3 dos 5 campos têm padrão externo; 2 dependem de dicionário interno do SI-PNI indisponível | N/A |
| Reversível? | Sim | Sim |

A escolha do JSON foi correta. Dos 5 campos com artefatos no CSV, apenas
3 tinham correção determinística garantida por padrões externos (código
IBGE, CNES, CEP). Os outros 2 campos (`vacina_grupoatendimento_codigo`,
`vacina_categoria_codigo`) dependem de dicionários internos do SI-PNI que
não estão disponíveis publicamente. Sem esses dicionários, a correção via
`str.zfill` exigiria assumir um comprimento fixo sem documentação que o
respalde — uma suposição que poderia introduzir erros silenciosos nos
dados publicados.

O custo adicional de ~14h de processamento é um investimento pontual que
se paga na confiança de que todos os campos estão exatamente como
registrados na fonte.

### Exemplo: decisão no SI-PNI COVID

| Critério | CSV (único formato disponível) |
|----------|-------------------------------|
| Problema | Mesmos tipos de artefatos do CSV de rotina |
| JSON disponível? | Não — só existe CSV |
| Correção determinística? | Parcial — campos com padrão externo (IBGE, CNES, CEP, raça/cor) são corrigíveis; campos internos do SI-PNI precisam de investigação |
| Decisão | Usar CSV com correções documentadas nos campos de padrão externo; campos internos pendentes de dicionário |

Quando o formato mais preciso não existe, a alternativa não é assumir que
o CSV está correto — é documentar exatamente quais campos foram corrigidos,
com qual regra, e quais campos permanecem potencialmente imprecisos até
que o dicionário seja localizado.

---

## 6. LIÇÕES APRENDIDAS E ARMADILHAS A EVITAR

> Extraídas da experiência com SI-PNI rotina e COVID. Aplicam-se a todo
> módulo futuro.

### Anti-padrões metodológicos

1. **Priorizar velocidade sobre precisão.** Ao escolher formato fonte, a
   tentação é privilegiar o formato mais rápido de processar. Mas tempo de
   processamento é custo pontual, enquanto erros nos dados publicados são
   permanentes. A regra é: se existe um formato que preserva melhor os
   dados originais e é acessível, usá-lo — mesmo que seja mais lento.

2. **Assumir que correções no CSV são triviais sem verificar.** "5 linhas
   de `str.zfill`" parece simples, mas pressupõe que sabemos o comprimento
   correto de cada campo. Para campos com padrão externo (IBGE, CNES, CEP),
   isso é verdade. Para campos internos do sistema (códigos de grupo de
   atendimento, categoria de vacinação), pode não ser — e o dicionário
   oficial pode estar indisponível, como ocorreu com o SI-PNI COVID.

3. **Não parar para replanejar ao mudar de fase.** O pipeline foi
   desenvolvido no PC local e depois migrado ao Hetzner. O momento certo
   para migrar era quando o script funcionou, mas não paramos para avaliar
   isso — continuamos rodando localmente por inércia.

4. **Otimizar prematuramente a infraestrutura sem testar o código.**
   Escolhemos ARM no Hetzner por custo antes de verificar se Arrow tinha
   binários. Custou horas de compilação fracassada.

### Armadilhas técnicas

1. **Nunca pegar só o primeiro arquivo do zip** — sempre listar tudo.
   Os ZIPs do Ministério contêm múltiplos JSONs paginados; o primeiro
   pipeline pegava apenas o primeiro arquivo, perdendo milhões de registros.

2. **Não usar ARM no Hetzner** — x86 tem binários pré-compilados para
   Arrow, polars, etc. Economia de horas de compilação frustrada.

3. **DIR_TEMP fora do OneDrive** se testar localmente no Windows — OneDrive
   trava deleção de arquivos temporários (EPERM).

4. **`jq --stream`** em vez de `jq -c '.[]'` para arquivos grandes — o
   segundo carrega o JSON inteiro em memória (~4GB por arquivo de 800MB).

5. **Forçar schema Utf8 no polars** — polars infere tipo NULL para colunas
   vazias no início do arquivo. A função `read_ndjson_safe()` resolve.

6. **`python3 -u`** para output unbuffered no nohup — sem isso, logs não
   aparecem em tempo real.

7. **Testar HEAD requests com redirect e retry** — S3 do governo redireciona
   e retorna 403 (não 404) para URLs inexistentes.

8. **SSH key:** se recriar servidor com mesmo IP, rodar `ssh-keygen -R IP`
   antes de reconectar.

9. **Testar opções de curl no servidor de produção** — `ftp_response_timeout`
   existe no curl do Windows/macOS mas não no libcurl 8.5 do Ubuntu 24.
   O pipeline de agregados doses falhou silenciosamente (download retornava
   erro, tryCatch engolia, todos os arquivos apareciam como "indisponíveis")
   porque a opção desconhecida causava erro antes mesmo de tentar o FTP.
   Regra: testar qualquer handle option com um download simples no servidor
   antes de rodar o pipeline completo.

10. **Validar intervalo de anos no particionamento** — o pipeline COVID
   original validava apenas formato (4 dígitos) mas não intervalo,
   permitindo que datas inválidas nos dados do Ministério (1899, 1900,
   anos de nascimento etc.) criassem 89 pastas espúrias no R2. A correção
   foi redirecionar registros com anos fora do intervalo esperado para
   `ano=_invalid`, preservando os dados sem poluir a estrutura de
   partições. Regra: todo pipeline deve validar que o ano extraído está
   dentro do intervalo plausível do dataset, e registros fora do intervalo
   devem ir para `ano=_invalid` em vez de serem descartados ou criarem
   partições inválidas.

11. **Incluir flags de paralelismo em todos os comandos rclone** — o padrão
   do rclone é `--transfers 4 --checkers 8`, que é lento para volumes
   grandes. O projeto adota `--transfers 16 --checkers 32` como padrão
   em todos os scripts e comandos manuais. Regra: nunca rodar rclone
   sem flags de paralelismo explícitos.

### Regras metodológicas

12. **Preferir o formato que preserva os dados originais** — quando mais de
   um formato está disponível, escolher aquele que não introduz artefatos
   de serialização (zeros à esquerda perdidos, floats espúrios, tipos
   alterados). Na prática, isso significa preferir JSON sobre CSV quando
   ambos existem e o JSON preserva a representação original. Usar CSV
   apenas quando é o único formato disponível ou quando todos os artefatos
   têm correção determinística documentada.

13. **Documentar artefatos e correções explicitamente** — quando forçado a
    usar um formato com artefatos (ex.: CSV sem alternativa JSON), registrar
    para cada campo afetado: o artefato, a regra de correção aplicada, e a
    fonte que garante a correção (padrão IBGE, CNES, etc.). Campos sem
    correção determinística devem ser sinalizados como potencialmente
    imprecisos na documentação do dataset.

14. **Avaliar ao menos duas alternativas** para cada decisão estruturante —
    nunca adotar a primeira solução que resolve o problema sem considerar
    alternativas. Mas a variável decisiva é precisão, não velocidade.

15. **Migrar para VPS assim que o código funcionar** — não continuar rodando
    localmente por inércia.

16. **Testar binários e dependências antes de escolher arquitetura** —
    verificar se Arrow, polars, etc. têm binários para a plataforma escolhida.

---

## 7. CRITÉRIOS DE PRIORIZAÇÃO

Ao escolher o próximo módulo a implantar, considerar estes 5 critérios
em ordem de peso:

### 7.1 Sinergia com o que já existe

Módulos que reutilizam infraestrutura, código ou conhecimento existente
têm custo marginal menor. Priorizar módulos que:
- Usam a mesma fonte (DATASUS FTP, OpenDATASUS S3)
- Têm formato similar a algo já processado (.dbf, JSON, CSV por UF)
- São dependência de algo já em andamento (ex.: SINASC é denominador
  do SI-PNI)

### 7.2 Demanda e impacto

Módulos com mais usuários potenciais geram mais impacto para o mesmo
esforço. Indicadores de demanda:
- Frequência de aparição em papers de saúde pública
- Existência (ou não) de alternativas acessíveis
- Complementaridade com dados já publicados (ex.: SIM + SINASC juntos
  permitem análises de mortalidade infantil)

### 7.3 Complexidade estimada

Módulos mais simples entregam valor mais rápido e constroem momentum.
Fatores de complexidade:
- Número de formatos/fontes a integrar
- Existência de transições estruturais ao longo do tempo
- Necessidade de harmonização com outros módulos
- Volume total de dados

### 7.4 Completude do ecossistema SI-PNI

Enquanto o SI-PNI não estiver completo (microdados + agregados +
dicionários + COVID + pacote R), submódulos do SI-PNI
têm prioridade sobre novos sistemas. A proposta de valor central
do projeto é a série histórica completa de vacinação; ela precisa
funcionar primeiro.

### 7.5 Independência

Módulos que podem ser publicados de forma independente, sem esperar
outros módulos, são preferíveis. Isso permite publicação incremental
e feedback mais rápido.

---

## 8. INVENTÁRIO DE MÓDULOS

### 8.1 Módulos SI-PNI (completar o core)

Estes módulos completam a proposta de valor central do projeto. São
prioridade máxima.

#### SI-PNI Microdados (rotina) — ✅ COMPLETO


<table>
<table style="width: 100%; border-collapse: collapse;" class="table">
  <colgroup>
    <col style="width: 50%">
    <col style="width: 50%">
  </colgroup>
  <thead>
    <tr>
      <th>Propriedade</th>
      <th>Valor</th>
    </tr>
  </thead>
  <tbody>
    <tr><td> Prefixo R2    </td><td><code> sipni/microdados/                             </code></td></tr>
    <tr><td> Fase atual    </td><td>       6 (integrado)                                 </td></tr>
    <tr><td> Registros     </td><td>       736M+                                         </td></tr>
    <tr><td> Período       </td><td>       2020–presente                                 </td></tr>
    <tr><td> Pipeline      </td><td><code> sipni-pipeline-python.py                      </code></td></tr>
    <tr><td> Formato fonte </td><td>       JSON (preserva dados originais sem artefatos) </td></tr>
    <tr><td> Documentação  </td><td><code> reference-pipelines-pt.md                     </code>, <code> project-pt.md </code></td></tr>
  </tbody>
</table>

#### SI-PNI COVID — ✅ COMPLETO

| Propriedade | Valor |
|-------------|-------|
| Prefixo R2 | `sipni/covid/microdados/` |
| Fase atual | 6 (integrado) |
| Registros | 608M+ |
| Período | 2021–presente |
| Particionamento | `ano=YYYY/mes=MM/uf=XX/` (+ `ano=_invalid/` para registros com datas fora de 2021–presente) |
| Pipeline | `sipni-covid-pipeline.py` |
| Formato fonte | CSV (único formato disponível; JSON não existe para COVID) |
| Correções aplicadas | Campos com padrão externo (IBGE, CNES, CEP, raça/cor) corrigidos via `str_pad`; campos internos do SI-PNI pendentes de dicionário |
| Reorganização R2 | Prefixo original `sipni-covid/` movido para `sipni/covid/` (fev/2026); anos inválidos no particionamento (1899–2020) realocados para `ano=_invalid/` (~39 MB, 2.756 objetos) |
| Exploração | `docs/covid/exploration-pt.md` |
| Conclusão | README no R2, dataset card HF, exemplos testados, manifesto, sincronização via GitHub Actions |

#### SI-PNI Agregados — Doses (1994-2019) — ✅ COMPLETO

| Propriedade | Valor |
|-------------|-------|
| Prefixo R2 | `sipni/agregados/doses/` |
| Fase atual | 6 (integrado) |
| Fonte | FTP DATASUS, 702 .dbf (27 UFs × 26 anos; consolidados excluídos) |
| Estrutura | 3 eras: 7 cols (94-03), 12 cols (04-12), 12 cols (13-19) |
| Pipeline | `sipni-agregados-doses-pipeline-r.R` (R puro: foreign + arrow + rclone) |
| Registros | **84.022.233** |
| Arquivos processados | 674 (+ 12 indisponíveis + 16 vazios = 702) |
| Tempo de bootstrap | **4h40 (279,9 min)** |
| Taxa | ~300K registros/hora (gargalo: download FTP) |
| Validação DPNIBR | ✔ Diferença zero (DPNIBR98 = soma dos 27 estaduais) |
| Particularidades | Código município preservado como na fonte (7d até 2012, 6d a partir de 2013); 65 vacinas ao longo de 26 anos; dicionário IMUNO.CNV com 85 entradas; consolidados UF/BR/IG excluídos (ver exploration-pt.md, decisão 9.9) |
| Exploração | `docs/sipni-agregados/exploration-pt.md` |
| Documentação pipeline | `reference-pipelines-pt.md`, seção 3 |
| Controle | `data/controle_versao_sipni_agregados_doses.csv` |
| Conclusão | README no R2, dataset card HF, exemplos testados, manifesto, sincronização via GitHub Actions |

#### SI-PNI Agregados — Cobertura (1994-2019) — ✅ COMPLETO

| Propriedade | Valor |
|-------------|-------|
| Prefixo R2 | `sipni/agregados/cobertura/` |
| Fase atual | 6 (integrado) |
| Fonte | FTP DATASUS, 702 .dbf (27 UFs × 26 anos; consolidados excluídos) |
| Estrutura | 2 schemas: 9 cols (94-12), 7 cols (13-19) |
| Registros estimados | ~3 milhões |
| Particularidades conhecidas | Dicionário IMUNOCOB.DBF (26 indicadores compostos) diferente do IMUNO.CNV; cobertura pré-calculada pelo MS; colunas FX_ETARIA e DOSE desaparecem em 2013; COBERT muda de numeric (ponto) para character (vírgula) em 2013; 64 códigos IMUNO únicos; mesmas 12 UFs ausentes em 1994 que DPNI |
| Exploração | `docs/sipni-agregados/exploration-cobertura-pt.md` |
| Bootstrap | 44 min, 686 arquivos, 2.762.327 registros |
| Conclusão | README no R2, dataset card HF, exemplos testados, manifesto, sincronização via GitHub Actions |

**Nota sobre os dois submódulos de agregados:** Doses e cobertura podem
compartilhar o mesmo pipeline (mesmo formato .dbf, mesmo FTP, mesma
lógica de download), com bifurcação apenas no processamento dos campos.
Avaliar se faz sentido um pipeline unificado.

#### SI-PNI Dicionários — ✅ COMPLETO

| Propriedade | Valor |
|-------------|-------|
| Prefixo R2 | `sipni/dicionarios/` |
| Fase atual | 5 (publicado) |
| Fonte | FTP DATASUS `/PNI/AUXILIARES/` (17 .cnv + 1 .dbf; 61 .def excluídos — config de interface) |
| Pipeline | `sipni-dicionarios-pipeline-r.R` (R puro: curl + foreign + arrow) |
| Parquets | 6 (imuno, imunocob, dose, fxet, ano, mes) — 263 linhas total |
| Originais | 18 arquivos preservados em `originais/` |
| Tamanho R2 | ~84 KB |
| Particularidades | .cnv é formato proprietário TabWin (Latin-1, largura fixa); parser custom `parse_cnv()` com `readBin()`+`iconv()` para encoding correto; mapeamento muitos-para-um via `source_codes`; sem manifesto nem sync (dados estáticos de 2019) |
| Exploração | `docs/sipni-dicionarios/exploration-pt.md` |
| Documentação pipeline | `reference-pipelines-pt.md`, seção 12 |
| Conclusão | README no R2, dataset card HF, exemplos R e Python |
| Pendente Fase 6 | Atualizar `project-pt.md` e `project-en.md`; integração ao pacote R `healthbR` (módulo `sipni`) |

#### SI-PNI Populações (denominadores) — ❌ REMOVIDO COMO MÓDULO R2

| Propriedade | Valor |
|-------------|-------|
| Prefixo R2 | ~~`sipni/populacao/`~~ — não haverá dados no R2 |
| Status | Removido como módulo independente (28/fev/2026) |
| Razão | Denominadores populacionais são dados fáceis de obter via pacotes R existentes (ex.: `brpop`, `sidrar`, `microdatasus`). Não justifica pipeline, armazenamento no R2 nem documentação de dataset. |
| Destino | A lógica de construção de denominadores (regras CGPNI por período e UF) será incorporada ao pacote R `sipni`, que acessará as fontes diretamente. |
| Fontes originárias | SINASC (FTP DATASUS) + IBGE (site) — inalterado, mas o acesso será via pacote, não via R2 |

---

### 8.2 Módulos novos (expansão do ecossistema)

Estes módulos expandem o projeto para além da vacinação. Só devem ser
iniciados quando o core SI-PNI estiver completo (todos os submódulos
acima nas fases 5 ou 6).

#### SIM (Mortalidade) — 🔍 FASE 1 CONCLUÍDA

| Propriedade | Valor |
|-------------|-------|
| Prefixo R2 | `sim/` |
| Fase atual | **1 (Recon concluído — 07/mar/2026)** |
| Fontes identificadas | **Duas vias complementares** |
| — FTP DATASUS (principal) | `ftp://ftp.datasus.gov.br/dissemin/publicos/SIM/CID10/DORES/` — arquivos `.dbc` por UF × ano (DO = óbitos não fetais); padrão `DO{UF}{AAAA}.dbc`; CID-10 (1996–presente) |
| — FTP DATASUS (óbitos fetais) | `ftp://ftp.datasus.gov.br/dissemin/publicos/SIM/CID10/DOFET/` — arquivos `.dbc` anuais de óbitos fetais (`DF{UF}{AAAA}.dbc`) |
| — FTP DATASUS (CID-9 histórico) | `ftp://ftp.datasus.gov.br/dissemin/publicos/SIM/CID9/` — série 1979–1995; padrão de nome diferente (2 dígitos de ano, prefixo `DOR`); leitura exige atenção ao esquema do período |
| — OpenDATASUS (S3) | Presente no portal (`opendatasus.saude.gov.br/dataset/sim`) com microdata do SIM (DO_BDD); formato e cobertura a verificar na Fase 2 |
| Cobertura temporal confirmada | **1979–presente** (série CID-9 + CID-10); dado oficial publicado ~15 meses após o ano de ocorrência; dado preliminar disponível ~10 meses após |
| Formato | `.dbc` (formato proprietário DATASUS — compressão sobre DBF); leitura via `read.dbc` (R) ou `blast-dbf`/`pysus` (Python) |
| Volume estimado | **~1,0–1,4 milhão de óbitos/ano** (não fetais) nos anos recentes; ~27 UFs × ~30 anos CID-10 = ~810 arquivos DORES + ~810 DOFET; série histórica CID-9 adicional (~17 anos × 27 UFs). Estimativa total: **2.500–3.500 arquivos .dbc** para cobertura completa |
| Variáveis principais | ~103 variáveis na versão CID-10 (confirmado em literatura): dados do falecido (nascimento, idade, sexo, raça/cor, estado civil, escolaridade, ocupação, município de residência), dados do óbito (data, local, estabelecimento, município de ocorrência), causa básica (CID-10), causas múltiplas, circunstâncias de morte não natural; informações maternas quando óbito fetal ou infantil |
| Dicionário oficial | Documentação disponível no DATASUS (PDF); estrutura das variáveis bem documentada pelo microdatasus e PCDaS; CID-10 como sistema de codificação internacional |
| Alternativas existentes | **PCDaS/Fiocruz** (1996–presente, tratado e enriquecido com CID-10 e geocoordenadas, acesso restrito); **`microdatasus`** (R, lê .dbc do FTP diretamente, `SIM-DO`); **Base dos Dados** (parcial); **`pysus`** (Python) |
| Complexidade estimada | **Média** — formato .dbc bem mapeado pelo microdatasus; dois subsistemas (DORES + DOFET) com estruturas distintas; série histórica CID-9 (1979–1995) tem esquema diferente e pode exigir tratamento separado |
| Sinergia | Alta com SINASC (mortalidade infantil = óbitos de menores de 1 ano via SIM + nascimentos via SINASC); Alta com SIH (internações + óbitos para estudos de desfechos) |
| Integração no pacote R | Módulo `healthbR::sim_*()` — ver decisão de arquitetura de 07/mar/2026 na Seção 8.1 |
| **Justificativa do módulo** | SIM é o principal sistema de mortalidade do Brasil e insumo básico para epidemiologia, saúde pública e formulação de políticas. Complementa diretamente o SI-PNI (cobertura vacinal × mortalidade por doenças imunopreveníveis) e é exigido para indicadores como TMI e esperança de vida. A inexistência de via de acesso via Parquet pré-processado em R2 público (PCDaS tem restrição de acesso; microdatasus não persiste dados) justifica o módulo. |

#### SINASC (Nascidos Vivos) — 🔍 FASE 2 CONCLUÍDA

| Propriedade | Valor |
|-------------|-------|
| Prefixo R2 | `sinasc/` |
| Fase atual | **3 (Decisão concluída — 07/mar/2026)** |
| Fonte | **FTP DATASUS** (única via viável; OpenDATASUS S3 bloqueado — HTTP 403) |
| — FTP `NOV/DNRES/` | 734 arquivos `DN{UF}{AAAA}.dbc`, 29 UFs, 1996–2022 |
| — FTP `ANT/DNRES/` | 109 arquivos, inclui 1994–1995 com prefixo `DNR{UF}` |
| Total de arquivos | **843 arquivos .dbc** |
| Cobertura temporal | **1994–2022** (mais recente disponível no FTP em 07/mar/2026) |
| Formato | `.dbc` (DBF comprimido); leitura via `read.dbc::read.dbc()` (R) |
| Particionamento definido | `sinasc/ano=YYYY/uf=XX/` |
| Schemas históricos | **12 schemas distintos** identificados (1994–2022, DF como referência): 30 cols (94-95), 21 cols (96-98), 20 cols (99-00), 23 cols (01), 26 cols (02-05), 29 cols (06-09), 55-61 cols (10-22) |
| Estratégia de schema | **Schema unificado** — mapeamento de nomenclatura 1994–1995 → moderna via dicionários oficiais (`NASC98.HLP` + `Estrutura_SINASC_para_CD.pdf`); 20 campos mapeados; 6 campos locais mantidos como colunas extras; 4 campos de controle interno descartados |
| Dicionários localizados | `NASC98.HLP` (FTP `ANT/DOCS/`, era 1994–1998) + `Estrutura_SINASC_para_CD.pdf` (FTP `NOV/DOCS/`, era moderna) + 5 tabelas `.DBF` em `NOV/TABELAS/` |
| Sinergia | Alta com SIM (estatísticas vitais complementares); histórica com SI-PNI (denominadores para cobertura vacinal) |
| Complexidade estimada | **Média** — formato .dbc bem mapeado; 12 schemas históricos gerenciados via schema unificado |
| Exploração | `docs/sinasc/exploration-pt.md` |
| Integração no pacote R | Módulo `healthbR::sinasc_*()` — ver decisão de arquitetura de 07/mar/2026 na Seção 8.1 |

#### SIH (Internações Hospitalares) — 📋 FUTURO

| Propriedade | Valor |
|-------------|-------|
| Prefixo R2 | `sih/` |
| Fase atual | 0 (não iniciado) |
| Fonte provável | FTP DATASUS (`.dbc`) — AIH (Autorização de Internação Hospitalar) |
| Cobertura temporal provável | 1992–presente |
| Alternativas existentes | PCDaS (Fiocruz); microdatasus; Base dos Dados (parcial) |
| Sinergia | Baixa com SI-PNI; alta com SIM (internações + óbitos) |
| Complexidade estimada | Alta (múltiplos tipos de arquivo: RD, RJ, SP, ER; estrutura complexa; volume muito grande — dezenas de milhões de AIH/ano) |
| Reconhecimento necessário | Tipos de arquivo, volume, estrutura, se há microdados no OpenDATASUS |

#### SINAN (Agravos de Notificação) — 🔮 HORIZONTE

| Propriedade | Valor |
|-------------|-------|
| Prefixo R2 | `sinan/` |
| Fase atual | 0 (não investigado) |
| Sinergia | Média com SI-PNI (doenças imunopreveníveis notificáveis) |
| Nota | Incluído no horizonte por complementaridade temática com vacinação. Prioridade baixa sem demanda explícita. |

---

### 8.3 Visão consolidada

| Módulo | Fase | Prioridade | Justificativa |
|--------|:----:|:----------:|---------------|
| SI-PNI Microdados (rotina) | ✅ 6 | — | Concluído |
| SI-PNI COVID | ✅ 6 | — | Concluído |
| SI-PNI Agregados (doses) | ✅ 6 | — | Concluído |
| SI-PNI Agregados (cobertura) | ✅ 6 | — | Concluído |
| SI-PNI Dicionários | ✅ 5 | **1** | Publicado (R2 + HF); pendente Fase 6 (integração ao `healthbR`) |
| Pacote R `healthbR` | — | **2** | Meta-pacote unificado (módulos `sipni`, `sim`, `sinasc`…); inclui lógica de denominadores sem módulo R2 próprio — ver decisão de 07/mar/2026 |
| SIM | 1 | **3** | Recon concluído 07/mar/2026; primeiro módulo fora do SI-PNI (prefixo `sim/`) |
| SINASC | 4 | **5** | Fases 2–4 concluídas em 07/mar/2026; bootstrap: 783 arquivos, 85M registros, 0 erros; pronto para Fase 5 (publicação) |
| SIH | 0 | **5** | Complexo, muitas alternativas existentes (prefixo `sih/`) |
| SINAN | 0 | **6** | Horizonte, sem demanda explícita (prefixo `sinan/`) |
| ~~SI-PNI Populações~~ | ❌ | — | Removido: denominadores via pacotes R existentes, sem R2 |

---

## 9. ORDEM RECOMENDADA DE EXECUÇÃO

### Bloco 1 — Completar o SI-PNI (prioridade máxima)

```
✅ SI-PNI Microdados (rotina) ─ Fase 6 (concluído)
✅ SI-PNI COVID ──────────── Fase 6 (concluído)
✅ Agregados doses ───────── Fase 6 (concluído)
✅ Agregados cobertura ───── Fase 6 (concluído)
       │
✅ Dicionários ────────── Fase 5 (publicado) ──── pendente Fase 6
       │
2. Pacote R healthbR ──── Desenvolvimento ───── ~3-4 semanas
                          (meta-pacote; módulo sipni como ponto
                           de entrada; denominadores via pacotes
                           R existentes, sem módulo R2 próprio)
```

**Situação atual (02/mar/2026):**
4 dos 6 submódulos SI-PNI estão concluídos (microdados rotina, COVID,
agregados doses, agregados cobertura), todos com dados no R2, dataset cards
no HF, manifesto de integridade e sincronização via GitHub Actions.

**Próximos passos:**  
- Dicionários são rápidos e desbloqueiam a decodificação dos agregados.  
- O pacote R `healthbR` é o produto final que integra tudo, incluindo acesso a
  denominadores populacionais via pacotes R existentes (sem módulo R2).  

### Bloco 2 — Expandir o ecossistema

```
6. SIM ────────────── Fase 1→6 ──── primeiro módulo novo, valida o método
       │
7. SINASC (completo) ─ Fase 1→6 ──── sinergia com SIM
       │
8. SIH ────────────── Fase 1→6 ──── maior complexidade, mais alternativas
```

**Antes de iniciar o Bloco 2:**  
- O Bloco 1 deve estar completo (todos os submódulos SI-PNI publicados)  
- O pacote `sipni` deve ter uma versão funcional no GitHub  
- A primeira rodada de divulgação (Fase 2 do `strategy-dissemination-pt.md`)
  deve ter sido feita — feedback de usuários pode reordenar prioridades  

---

## 10. MAPA DE ARTEFATOS POR FASE

Visão consolidada de tudo que cada fase produz:

| Fase | Artefato | Localização |
|:----:|----------|-------------|
| 1 | Nota de viabilidade | Seção 8 deste documento |
| 2 | Documento de exploração | `docs/<sistema>/exploration-pt.md` |
| 2 | Scripts de exploração (opcional) | `scripts/exploration/<sistema>-*.R` |
| 3 | Decisões estruturantes | Seção no documento de exploração |
| 4 | Script de pipeline | `scripts/pipeline/<sistema>-pipeline-*.py` |
| 4 | Controle de versão | `data/controle_versao_<sistema>.csv` |
| 4 | Documentação do pipeline | Seção no `reference-pipelines-pt.md` |
| 4 | Manifesto de integridade | R2: `<prefixo>/manifest.json` |
| 5 | README do dataset | R2: `<prefixo>/README.md` |
| 5 | Dataset card | Hugging Face |
| 5 | Atualização do roadmap | `strategy-dissemination-pt.md` |
| 5 | Registro no dashboard de sincronização | HF Space + comparison engine |
| 6 | Atualização do PROJECT | `docs/project-*.md` |
| 6 | Suporte no pacote R | Repositório do pacote |
| 6 | Post de divulgação | Canais externos |
| 6 | Integração de validação no pacote R | `check_sync()`, `validate_local()` |

---

## 11. PADRÕES REUTILIZÁVEIS ENTRE MÓDULOS

### 11.1 O que se repete em todo módulo

Independente do sistema de informação, todo módulo vai:

- Baixar dados de um servidor do governo (FTP ou S3)
- Converter para Parquet particionado
- Subir para o R2 via rclone
- Precisar de controle de versão (ETag ou hash)
- Precisar de documentação (README, dataset card)
- Precisar ser tipado como string no Parquet (para preservar códigos)

### 11.2 O que varia

| Aspecto | Varia como? |
|---------|-------------|
| Formato fonte | .dbc (SIM, SINASC, SIH), .dbf (agregados), JSON/CSV (microdados) |
| Ferramenta de leitura | polars (CSV/JSON), foreign::read.dbf (DBF), read.dbc (DBC) |
| Particionamento | ano/mes/uf (microdados), ano/uf (agregados), ano/uf (SIM, SINASC) |
| Volume | 500M–700M registros (microdados) vs milhões (agregados) vs dezenas de milhões/ano (SIH) |
| Dicionários | .cnv (SI-PNI), .dbf (SI-PNI cob), tabelas em PDF (SIM, SINASC), ? (SIH) |
| Atualização | Mensal (microdados), anual (agregados), ? (SIM, SINASC, SIH) |

### 11.3 Infraestrutura compartilhada

Todos os módulos usam a mesma infraestrutura base, documentada em detalhe
no `reference-pipelines-pt.md` (seção 1):

- Mesmo bucket R2 (`healthbr-data`)
- Mesmo servidor Hetzner (temporário, sob demanda)
- Mesmo rclone config
- Mesmo padrão de controle de versão (CSV com hash, data, contagem)
- Mesma estratégia de tipos no Parquet (tudo string)
- Mesma lógica de particionamento Hive (`chave=valor/`)
- Mesmo manifesto de integridade por módulo (`<prefixo>/manifest.json`)
- Mesmo dashboard de sincronização (HF Space compartilhado entre módulos)
- Mesmo comparison engine (GitHub Actions semanal, verifica todos os módulos)
- Mesmo módulo `manifest_utils.py` para atualização do manifesto nos pipelines Python

---

## 12. QUANDO ATUALIZAR ESTE DOCUMENTO

- **Ao concluir a Fase 1 (Recon) de qualquer módulo:** Atualizar a ficha
  do módulo na Seção 8 com informações descobertas.
- **Ao concluir qualquer módulo (Fase 6):** Mover o módulo para ✅ na
  Seção 8 e registrar números finais.
- **Ao descobrir um novo módulo candidato:** Adicionar ficha na Seção 8.
- **Ao mudar prioridades:** Atualizar Seção 9.
- **Ao aprender uma nova lição reutilizável:** Adicionar na Seção 6.

---

## 13. RELAÇÃO COM OUTROS DOCUMENTOS

| Este documento define... | Outro documento define... |
|--------------------------|--------------------------|
| Fases, critérios, método e lições | `reference-pipelines-pt.md`: como operar cada pipeline específico |
| Quando criar README e dataset card (Fase 5) | `strategy-dissemination-pt.md`: como criá-los (template, canais) |
| Quando decidir idioma de cada artefato | `strategy-languages-pt.md`: qual idioma usar |
| Quando atualizar a documentação central | `project-pt.md`: o que a documentação central contém |
| Priorização entre módulos | `project-pt.md` seção 13: lista de tarefas pendentes |
| Quando gerar manifesto e registrar no dashboard | `strategy-synchronization.md`: como gerar, schema, comparison engine |

---

---

## 14. DECISÃO DE ARQUITETURA DO PACOTE R (07/mar/2026)

**Decisão:** O projeto adotará um **pacote R unificado `healthbR`** em vez
de pacotes isolados por sistema de informação.

**Contexto:** Durante o Recon do SIM (07/mar/2026), ficou evidente que o SIM
não cabe dentro do `sipni` — são sistemas independentes. Dois modelos foram
avaliados:

| Critério | Pacotes isolados (`sipni`, `sim`, `sinasc`…) | Meta-pacote `healthbR` |
|----------|:-------------------------------------------:|:----------------------:|
| Denominadores SINASC para SI-PNI | Duplicados entre pacotes | Resolvidos internamente |
| Interface do pesquisador | Fragmentada (vários `install.packages`) | Unificada (`library(healthbR)`) |
| Consistência de convenções | Risco de divergência entre pacotes | Garantida pelo meta-pacote |
| Sinergia SIM × SINASC × SI-PNI | Exige coordenação manual | Natural dentro do mesmo pacote |
| Overhead de manutenção | Alto (N repos, N CIs, N release cycles) | Baixo (1 repo) |
| Modelo de referência | — | tidyverse, tidymodels |

**Modelo adotado:** `healthbR` como meta-pacote com módulos por sistema:
- `healthbR::sipni_*()` — acesso ao SI-PNI (microdados, agregados, dicionários)
- `healthbR::sim_*()` — acesso ao SIM (mortalidade)
- `healthbR::sinasc_*()` — acesso ao SINASC (nascidos vivos)
- `healthbR::sih_*()` — acesso ao SIH (internações) — futuro

**Consequências:**  
- O repositório do pacote será nomeado `healthbR` (não `sipni`)  
- A documentação pública já fazia referência ao `healthbR` como meta-pacote futuro — essa visão está agora formalizada como o modelo definitivo  
- Módulos individuais podem ser submetidos ao CRAN como pacotes leves se houver demanda por instalação granular, mas a interface primária é o `healthbR`  
- Denominadores populacionais (SINASC + IBGE) são acessados via funções internas do `healthbR`, sem módulo R2 próprio  

---

*Este documento será atualizado conforme módulos avancem nas fases.
Última atualização: 07/mar/2026 — SI-PNI Dicionários movido para Fase 5
(publicado: R2 + dataset card HF). SINASC avançou para Fase 3 (Fases 2 e 3 concluídas
em 07/mar/2026: FTP mapeado, 843 arquivos, 12 schemas históricos,
dicionários analisados, schema unificado confirmado, infraestrutura
e bootstrap estimados). SIM avançou para Fase 1 (Recon
concluído). Decisão sobre arquitetura do pacote R formalizada: `healthbR`
unificado (meta-pacote) adotado como modelo definitivo.*
