# Plano de Internacionalização (i18n) — healthbr-data

> Documento de referência para a gestão bilíngue (português/inglês) do
> projeto healthbr-data. Deve ser consultado antes de criar ou traduzir
> qualquer documento do projeto.
>
> Criado em 26/fev/2026. Complementa o `dissemination-plan-pt.md`.

---

## 1. PRINCÍPIO GERAL

Nem todo arquivo precisa existir nos dois idiomas. O custo de manter
traduções sincronizadas é real e cresce com o projeto. A regra é:

- **Traduzir o que o público externo precisa para descobrir e usar os dados.**
- **Não traduzir o que é interno, de domínio técnico brasileiro, ou efêmero.**

---

## 2. CLASSIFICAÇÃO DOS ARQUIVOS

Cada arquivo do projeto pertence a uma de três categorias:

### 2.1 Bilíngue obrigatório

Documentos que o público externo (pesquisadores, comunidade HF, rOpenSci,
R-bloggers) precisa ler. São poucos e de alto impacto.

| Arquivo | PT | EN | Justificativa |
|---------|:--:|:--:|---------------|
| `README` (raiz do repo GitHub) | `README.pt.md` | `README.md` | Porta de entrada do projeto. GitHub renderiza `README.md` por padrão. |
| Dataset cards (Hugging Face) | Seção resumida em PT | Idioma principal | HF é indexado globalmente; público internacional domina. |
| READMEs no R2 (junto dos dados) | — | EN (único) | R2 não renderiza Markdown nem resolve links; um arquivo EN basta. PT no HF/GitHub. |
| `docs/project-*.md` | `project-pt.md` ✅ | `project-en.md` ✅ | Arquitetura e decisões do projeto — interessa a colaboradores de qualquer país. |
| `guides/quick-guide-*.R` | `quick-guide-pt.R` ✅ | `quick-guide-en.R` ✅ | Tutorial de uso dos dados — pesquisador precisa no seu idioma. |

### 2.2 Apenas português

Documentos de domínio técnico brasileiro, planejamento interno, ou registros
de processo. Traduzir não agrega valor real.

| Arquivo | Justificativa |
|---------|---------------|
| `docs/harmonization.md` | De-para entre IMUNO.CNV e co_vacina é intrinsecamente brasileiro. |
| `docs/dissemination-plan-pt.md` | Planejamento estratégico interno. |
| `docs/covid/exploration-pt.md` | Exploração técnica de dataset brasileiro. |
| `log/status-*.md` | Registros de sessão — valor apenas histórico. |
| `docs/sipni/*.pdf` | PDFs oficiais do DATASUS — não nos cabe traduzir. |
| `archive/*` | Material obsoleto preservado. |

### 2.3 Apenas inglês

Documentos direcionados exclusivamente ao público internacional ou
cuja implementação é inteiramente em código (schemas, scripts, configs).

| Arquivo | Justificativa |
|---------|---------------|
| `docs/strategy-synchronization.md` | Arquitetura técnica de sincronização (schema JSON, scripts Python, config Streamlit). Implementação em código, público-alvo são desenvolvedores. |
| `CONTRIBUTING.md` (futuro) | Convenção open source — contribuidores internacionais. |
| `CODE_OF_CONDUCT.md` (futuro) | Idem. |
| `CHANGELOG.md` (futuro) | Convenção de releases — inglês é padrão. |

---

## 3. CONVENÇÕES DE NOMENCLATURA

### 3.1 README do GitHub (raiz do repo)

Seguir a convenção mais reconhecida pela comunidade:

```
README.md       ← inglês (GitHub renderiza este por padrão)
README.pt.md    ← português (link no topo do README.md)
```

No topo de cada README, incluir badges de idioma:

```markdown
<!-- No README.md (inglês) -->
🇬🇧 English | [🇧🇷 Português](README.pt.md)

<!-- No README.pt.md (português) -->
[🇬🇧 English](README.md) | 🇧🇷 Português
```

### 3.2 Demais arquivos bilíngues

Manter o padrão já adotado no projeto — sufixo de idioma antes da extensão:

```
docs/project-pt.md
docs/project-en.md
guides/quick-guide-pt.R
guides/quick-guide-en.R
```

### 3.3 Arquivos monolíngues

Arquivos que existem em apenas um idioma levam o sufixo quando em português
(para explicitar o idioma) e podem omitir o sufixo quando em inglês (quando
a convenção open source já pressupõe inglês como padrão):

```
docs/dissemination-plan-pt.md      ← PT, sufixo explícito
docs/harmonization-pt.md           ← PT, sufixo explícito (ver Seção 4)
CONTRIBUTING.md                    ← EN, sem sufixo (convenção open source)
```

---

## 4. PLANO DE ALTERAÇÕES IMEDIATAS

Mudanças que podem ser feitas agora para alinhar o projeto com este método.

### 4.1 Renomear `harmonization.md` → `harmonization-pt.md`

**Por quê:** O arquivo é inteiramente em português mas não tem o sufixo `-pt`.
Isso quebra a convenção de que todo arquivo em português dentro de `docs/`
carrega o sufixo de idioma. Sem o sufixo, a expectativa natural é que esteja
em inglês.

**Ação:** Renomear.

### 4.2 Criar `README.md` e `README.pt.md` na raiz

**Por quê:** Quando o repositório for publicado no GitHub, o `README.md` é a
primeira coisa que qualquer pessoa vê. Preparar agora evita atropelo no
lançamento.

**Conteúdo do `README.md` (EN):**  
- Badge de idioma no topo  
- Elevator pitch (do `dissemination-plan-pt.md`, seção 3.4, traduzido)  
- Tabela resumo (datasets disponíveis, status)  
- Exemplo de código R e Python (3-5 linhas cada)  
- Links para: dataset cards no HF, documentação completa, guia rápido  
- Seção de contribuição e financiamento  
- Licença  

**Conteúdo do `README.pt.md` (PT):**  
- Espelho do `README.md`, em português  
- Mesma estrutura, mesmos links  

**Ação:** Criar ambos os arquivos.

### 4.3 Criar template de dataset card bilíngue

**Por quê:** O `dissemination-plan-pt.md` (seção 2.3) já contém um template
de dataset card, mas apenas em inglês. Criar uma versão bilíngue (inglês
como idioma principal, seção resumida em português) padroniza a publicação
de futuros datasets no HF.

**Ação:** Criar `guides/dataset-card-template.md`.

### Resumo das ações imediatas

| # | Ação | Tipo |
|:-:|------|------|
| 1 | Renomear `docs/harmonization.md` → `docs/harmonization-pt.md` | Renomear |
| 2 | Criar `README.md` (EN) na raiz do projeto | Novo arquivo |
| 3 | Criar `README.pt.md` (PT) na raiz do projeto | Novo arquivo |
| 4 | Criar `guides/dataset-card-template.md` | Novo arquivo |

---

## 5. MÉTODO GERAL PARA CRIAÇÃO DE DOCUMENTOS

Este é o processo a seguir sempre que um novo documento for criado no projeto.

### 5.1 Antes de escrever: decidir o idioma

Responder estas três perguntas:

1. **Quem é o público primário?**
   - Se pesquisadores brasileiros que vão usar os dados → PT
   - Se comunidade open source internacional → EN
   - Se ambos → bilíngue

2. **O conteúdo é intrinsecamente brasileiro?**
   - Se sim (ex: de-para entre sistemas do DATASUS, exploração de .dbf,
     notas técnicas do MS) → apenas PT
   - Se não (ex: como acessar Parquets via Arrow, como contribuir) → bilíngue ou EN

3. **O documento é público-facing ou interno?**
   - Se público-facing (README, dataset card, guia de uso) → bilíngue
   - Se interno (log de sessão, plano estratégico, exploração) → idioma natural do autor

### 5.2 Ao escrever: seguir as convenções

- Nome do arquivo com sufixo `-pt` ou `-en` (exceto `README.md` na raiz)
- Colocar na pasta correta conforme a função (ver estrutura do projeto)
- Se bilíngue: escrever no idioma que o autor domina melhor primeiro,
  depois traduzir para o outro

### 5.3 Ao traduzir: regras de sincronização

- **Não traduzir linha a linha.** Adaptar para que o texto soe natural no
  idioma-alvo. Exemplos de código podem ser idênticos.
- **Marcar a versão no cabeçalho.** Ambas as versões devem indicar a data
  da última atualização. Se uma ficar defasada, fica explícito.
- **Sincronização não precisa ser imediata.** Se uma alteração for feita na
  versão PT, a versão EN pode ser atualizada no próximo ciclo de trabalho.
  O importante é que não fiquem permanentemente dessincronizadas.
- **Usar este checklist em cada atualização:**

```
[ ] O arquivo existe na(s) versão(ões) de idioma necessária(s)?
[ ] O sufixo de idioma está no nome do arquivo?
[ ] A data de última atualização está no cabeçalho?
[ ] Se bilíngue: a outra versão precisa ser atualizada?
```

### 5.4 Onde cada tipo de documento vai

| Tipo de documento | Pasta | Idioma | Exemplos |
|-------------------|-------|--------|----------|
| Arquitetura e decisões do projeto | `docs/` | Bilíngue | `project-pt.md`, `project-en.md` |
| Especificações técnicas de domínio | `docs/` | PT | `harmonization-pt.md` |
| Estratégia e planejamento | `docs/` | PT | `dissemination-plan-pt.md` |
| Arquitetura técnica (schemas, scripts) | `docs/` | EN | `strategy-synchronization.md` |
| Exploração de datasets | `docs/<sistema>/` | PT | `exploration-pt.md` |
| Guias de uso para pesquisadores | `guides/` | Bilíngue | `quick-guide-pt.R`, `quick-guide-en.R` |
| Templates | `guides/` | EN (com seção PT) | `dataset-card-template.md` |
| READMEs de dataset (R2) | `data/` (fonte) → R2 (destino) | EN (único) | `readme-sipni-*.md` → `README.md` no R2 (sem sufixo `-en`, pois são monolíngues EN) |
| README do GitHub | raiz `/` | Bilíngue | `README.md` (EN), `README.pt.md` |
| Dataset cards (HF) | externo (HF) | EN (com seção PT) | — |
| Convenções open source | raiz `/` | EN | `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` |
| Logs e registros de sessão | `log/` | PT | `status-*.md` |
| PDFs de referência oficial | `docs/<sistema>/` | Original (PT) | Notas técnicas do DATASUS |
| Scripts | `scripts/` | Comentários em EN | Pipeline, exploração, utils |

### 5.5 Sobre comentários em scripts

Os scripts atualmente têm comentários em português e inglês misturados.
A convenção recomendada para projetos open source é:

- **Comentários de código:** inglês (facilita contribuições internacionais)
- **Nomes de variáveis:** inglês
- **Strings de output/log:** podem ser português se o público de execução é brasileiro

Essa padronização não é urgente e pode ser feita gradualmente conforme os
scripts forem revisados.

---

## 6. DIAGRAMA RESUMO

```
                     ┌─────────────────────────┐
                     │   Novo documento        │
                     └──────────┬──────────────┘
                                │
                     ┌──────────▼──────────────┐
                     │ Público externo precisa │
                     │ ler para usar os dados? │
                     └──────────┬──────────────┘
                          │           │
                         SIM         NÃO
                          │           │
                  ┌───────▼───┐  ┌───▼──────────────┐
                  │ BILÍNGUE  │  │ Domínio técnico  │
                  │ -pt + -en │  │ brasileiro?      │
                  └───────────┘  └───┬─────────┬────┘
                                     │         │
                                    SIM       NÃO
                                     │         │
                              ┌──────▼──┐   ┌──▼────────┐
                              │ Só PT   │   │ Só EN     │
                              │ com -pt │   │ (padrão   │
                              └─────────┘   │ open src) │
                                            └───────────┘
```

---

## 7. RELAÇÃO COM O PLANO DE DIVULGAÇÃO

Este documento é complementar ao `dissemination-plan-pt.md`. A conexão
entre os dois:

| `dissemination-plan-pt.md` define... | Este documento define... |
|--------------------------------------|-------------------------|
| Quais canais de divulgação usar (HF, GitHub, redes) | Em qual idioma cada artefato nesses canais deve estar |
| O template de dataset card (seção 2.3) | Como adaptar o template para ser bilíngue |
| O checklist de lançamento (seção 8) | Quais itens do checklist precisam de versão PT e EN |
| O elevator pitch (seção 3.4) | Que o pitch existe em ambos os idiomas |

Na conversa "01 - Geral: estratégia de divulgação e financiamento", este
documento pode ser referenciado como o guia operacional de idiomas.
