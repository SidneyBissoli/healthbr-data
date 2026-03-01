# Setup: Repositório GitHub Público — healthbr-data

> Registro da criação do repositório GitHub público do projeto healthbr-data.
> Executado em 2026-03-01.
>
> **Documentos relacionados:**
> - `strategy-dissemination-pt.md` — Checklist de lançamento (seção 8),
>   FUNDING.yml e GitHub Sponsors (seção 5.2).
> - `strategy-languages-pt.md` — Regras de idioma dos READMEs.
> - `project-pt.md` — Fonte de verdade sobre arquitetura e decisões.

---

## 1. Contexto

O projeto healthbr-data redistribui dados de vacinação do SUS (SI-PNI) em
formato Parquet via Cloudflare R2. Já existem 4 datasets publicados no R2
e no Hugging Face, READMEs bilíngues, guias, scripts de pipeline e
documentação estratégica completa — tudo numa pasta local sem controle de
versão. O próximo passo do checklist de pré-lançamento
(`strategy-dissemination-pt.md`, seção 8) é criar o repositório GitHub
público.

---

## 2. Decisões

| Decisão | Escolha | Alternativa rejeitada | Motivo |
|---------|---------|:---------------------:|--------|
| Owner do repo | Perfil pessoal `SidneyBissoli` | Organização `healthbr-data` | Consistência com perfil HF existente (`SidneyBissoli/`) |
| Estratégia de criação | `git init` local + push via `gh` | Criar repo vazio + clone | Aproveita toda a estrutura local já existente |
| Pasta `archive/` | Incluir no repo | Excluir via `.gitignore` | Preservar histórico de trabalho |
| Licença | CC-BY 4.0 (texto completo) | CC0, ODC-BY | Já decidida e aplicada nos 4 repos HF (28/fev/2026) |

---

## 3. Arquivos criados

| Arquivo | Descrição |
|---------|-----------|
| `LICENSE` | Texto completo da CC-BY 4.0 |
| `.github/FUNDING.yml` | GitHub Sponsors (`SidneyBissoli`) + Pix |

---

## 4. Alterações em arquivos existentes

| Arquivo | Alteração |
|---------|-----------|
| `.gitignore` | Adicionadas regras para `.claude/`, `.vscode/`, `.idea/`, `.env`, `credentials*` |

---

## 5. Estrutura do repositório publicada

```
healthbr-data/
├── .github/
│   └── FUNDING.yml
├── archive/                    ← Material histórico preservado
├── data/                       ← CSVs de controle de versão dos pipelines
├── docs/                       ← Documentação completa do projeto
│   ├── project-pt.md
│   ├── project-en.md
│   ├── harmonization-pt.md
│   ├── reference-pipelines-pt.md
│   ├── strategy-expansion-pt.md
│   ├── strategy-dissemination-pt.md
│   ├── strategy-synchronization.md
│   ├── strategy-languages-pt.md
│   ├── setup-github-repo.md    ← Este documento
│   ├── covid/
│   ├── sipni/
│   └── sipni-agregados/
├── guides/                     ← Guias e templates
│   ├── quick-guide-pt.R
│   ├── quick-guide-en.R
│   ├── dataset-card-template.md
│   └── dataset-cards/
├── scripts/                    ← Pipelines e scripts de exploração
│   ├── pipeline/
│   ├── exploration/
│   └── utils/
├── .gitignore
├── LICENSE
├── README.md                   ← Inglês (renderizado por padrão no GitHub)
├── README.pt.md                ← Português
└── healthbr-data.Rproj
```

---

## 6. Comandos executados

```bash
# 1. Inicializar git
git init

# 2. Adicionar todos os arquivos
git add .

# 3. Commit inicial
git commit -m "Initial commit: healthbr-data project structure"

# 4. Criar repo público e fazer push
gh repo create SidneyBissoli/healthbr-data \
  --public --source=. --push \
  --description "Free redistribution of Brazilian public health data (SUS) in Apache Parquet format"

# 5. Configurar tópicos
gh repo edit SidneyBissoli/healthbr-data \
  --add-topic "brazil,public-health,vaccination,parquet,open-data,datasus,sus,healthcare,epidemiology"
```

---

## 7. Verificação

- [ ] Repo público acessível em `github.com/SidneyBissoli/healthbr-data`
- [ ] Botão "Sponsor" visível no repo (FUNDING.yml funcionando)
- [ ] README.md renderiza corretamente (badge de idioma, tabelas, código)
- [ ] Links cruzados README.md ↔ README.pt.md funcionam
- [ ] `.gitignore` exclui `.claude/`, `.Rhistory`, `.Rproj.user/`
- [ ] Licença CC-BY 4.0 aparece no sidebar do repo

---

## 8. Itens do checklist de lançamento atualizados

Referência: `strategy-dissemination-pt.md`, seção 8.

| Item | Status |
|------|:------:|
| Criar repositório GitHub público com README do pipeline | ✅ |
| Configurar FUNDING.yml no GitHub | ✅ |
