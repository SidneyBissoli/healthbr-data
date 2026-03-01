# Resumo da conversa — Projeto SI-PNI

> Este documento resume ~16 sessões de conversa (21-22/fev/2026) sobre o
> projeto de redistribuição e harmonização de dados de vacinação do SUS.
> O objetivo é servir como input para o próximo prompt, permitindo continuidade
> sem perda de contexto.

---

## 1. DECISÕES TOMADAS

### 1.1 Escopo do projeto

**Decisão:** Expandir de "redistribuição de microdados 2020+" para
"harmonização de série histórica completa 1994-2025+".

**Racional:** O valor real para o pesquisador não é apenas ter os microdados
em Parquet — é poder construir séries temporais de cobertura vacinal
contínuas de 1994 a 2025. Isso exige integrar três fontes: dados agregados
históricos (1994-2019), microdados individuais (2020+), e denominadores
populacionais (SINASC/IBGE). Nenhuma alternativa existente (Base dos Dados,
PCDaS, microdatasus, TabNet) oferece essa integração.

### 1.2 JSON como fonte primária dos microdados

**Decisão:** Usar JSON (não CSV) como fonte dos microdados 2020-2025+.

**Racional:** Investigação empírica revelou que os CSVs de 2020-2024 contêm
artefatos de exportação: campos numéricos serializados como float (sufixo
`.0`), com perda de zeros à esquerda em códigos como raça/cor (`3` em vez de
`03`), CEP e CNES. O JSON preserva todos os valores como strings com zeros
intactos. O CSV de 2025 foi corrigido pelo Ministério, mas o JSON é
consistente em toda a série. Trade-off: JSON ~1.3x maior (~28 GB extra para
72 meses), aceitável para eliminar toda lógica de reconstrução de zeros.

**Detalhes técnicos:**
- Dois padrões de URL: 2020-2024 (`vacinacao_{mes}_{ano}.json.zip`) e
  2025+ (`vacinacao_{mes}_{ano}_json.zip`)
- JSON é array em linha única (>2GB descomprimido) — `readLines()` falha,
  requer `readBin()` + busca de delimitadores `},{`
- Ambos os formatos (JSON e CSV) têm exatamente 56 colunas, zero exclusivas

### 1.3 Infraestrutura

**Decisão:** VPS Hetzner (€4/mês) + Cloudflare R2 + Hugging Face (espelho).

**Racional:**
- GitHub Actions descartado: volume grande demais (~1.8 GB/mês de JSON),
  sem disco persistente para cache
- AWS S3 descartado: egress caro ($0.09/GB)
- HF como primário descartado: empresa de IA pode mudar regras; usado
  apenas como espelho para descobribilidade
- R2: S3-compatível, egress zero, migrável em horas se necessário

### 1.4 Tipos de dados no Parquet

**Decisão:** Tudo character no Parquet publicado.

**Racional:** O JSON já traz tudo como string. Manter character preserva
zeros à esquerda em códigos IBGE, CNES, CEP, raça/cor nativamente.
Tipagem forte (Date, integer) será feita no pacote R `sipni`, não nos
dados publicados. Isso mantém fidelidade à fonte e evita decisões de
tipagem irreversíveis no pipeline.

### 1.5 Publicação: dados brutos + dicionários separados

**Decisão:** Publicar dados exatamente como o Ministério fornece, sem
decodificação inline. Dicionários originais publicados como referência.

**Racional:** Decodificar criaria um derivado nosso, não mais o documento
original. Fidelidade à fonte é prioritária. A conveniência (join
código→nome) fica no pacote R, não nos dados.

### 1.6 Particionamento

**Decisão:** `ano/mes/uf` para microdados; `ano/uf` para agregados.

**Racional:** Permite queries filtradas eficientes via Apache Arrow sem
carregar tudo na memória. UF como partição final porque é o filtro
geográfico mais comum.

### 1.7 Nome do pacote

**Decisão:** `sipni` (sem prefixo `r`).

**Racional:** Convenção rOpenSci moderna. Validado com `pak::pkg_name_check()`:
disponível no CRAN e Bioconductor.

### 1.8 Código de município: 6 dígitos

**Decisão:** Normalizar para 6 dígitos (sem verificador).

**Racional:** 6 dígitos é o padrão IBGE moderno. Os agregados pré-2013 usam
7 dígitos — o pipeline trunca o verificador para uniformizar.

### 1.9 Sincronização com o servidor via HEAD requests

**Decisão:** A atualização mensal não usa janelas arbitrárias (ex: "rebaixa
os últimos 6 meses"). Em vez disso, faz HEAD request no S3 do Ministério
para todos os meses da série (2020 até o mês corrente) e compara ETag e
Content-Length com o controle local.

**Racional:** O Ministério pode republicar qualquer mês a qualquer momento
(dados são "preliminares" até o fechamento). HEAD requests são praticamente
gratuitos (~72 requests em poucos segundos, sem transferir dados). O script
classifica cada mês como "novo", "atualizado", "inalterado" ou
"indisponível", e só baixa/reprocessa o necessário. Isso é mais robusto e
mais simples do que manter regras arbitrárias sobre quais meses reverificar.

### 1.10 Integridade e rastreabilidade dos dados

**Decisão:** Construir uma cadeia de confiança em três camadas: (1) controle
operacional do pipeline com metadados do servidor (ETag, Content-Length,
hash MD5 do zip), (2) manifesto público no R2 com hashes SHA-256 dos JSONs
fonte e dos Parquets gerados, (3) função `sipni::validar_integridade()` no
pacote R para o pesquisador verificar seus dados locais contra o manifesto.

**Racional:** O pesquisador precisa confiar que o Parquet que ele tem
corresponde exatamente ao JSON publicado pelo Ministério. A camada 1 (já
implementada) serve ao pipeline. A camada 2 (Fase 2, junto com upload R2)
serve a qualquer pessoa que queira auditar. A camada 3 (Fase 3, pacote R)
oferece verificação automatizada com uma linha de código.

---

## 2. PASSOS DADOS ATÉ AQUI (cronologia)

### Sessão 1 (21/fev, madrugada): Arquitetura e RNDS
- Discussão sobre RNDS, FHIR, Data Lake do MS
- Entendimento de como o SI-PNI se conecta ao OpenDATASUS
- Primeira proposta de pipeline: CSV → Parquet → S3

### Sessão 2: PCDaS e alternativas
- Análise de PCDaS (Fiocruz), Base dos Dados, Brasil.IO, microdatasus
- Conclusão: nenhuma alternativa cobre vacinação em Parquet com microdados

### Sessão 3 (21/fev, tarde): Arquitetura detalhada
- Decisões de infraestrutura (VPS, R2, HF)
- Mapeamento inicial das 56 colunas do CSV (sem header — suposição errada)
- Debugging de encoding Latin-1
- Análise de valores únicos por coluna
- Planejamento do meta-pacote healthbR

### Sessão 4: Dicionário oficial e mapeamento de colunas
- Descoberta do `Dicionario_tb_ria_rotina.pdf` (60 campos)
- Validação dos 56 campos do CSV contra dicionário
- Correção de 12 erros no mapeamento posicional original
- Identificação de X34 como `co_sistema_origem`
- 4 campos do dicionário ausentes nos dados, 1 typo oficial (`estalecimento`)

### Sessão 5: Validação JSON e primeira decisão CSV
- Validação cruzada CSV × JSON × dicionário
- Confirmação dos tipos VARCHAR
- **Decisão temporária:** manter CSV como fonte (1.32 GB vs 1.81 GB JSON)
- Identificação de 4 scripts em /outputs precisando atualização

### Sessão 6 (21/fev, noite): Viabilidade e comparação com Base dos Dados
- Análise crítica de viabilidade do projeto
- Comparação detalhada com Base dos Dados (BigQuery)
- Análise do modelo freemium
- Validação da proposta de valor
- Decisão final: VPS Hetzner + R2 + pacote R direto

### Sessão 7: Expansão de escopo para dados agregados
- Decisão de incluir dados agregados históricos (1994-2019)
- Discussão sipni vs rsipni → sipni
- Discussão: precisa de pacote ou só documentação? → precisa de pacote
- Investigação de compatibilidade agregados ↔ microdados

### Sessão 8 (22/fev, madrugada): Exploração dos agregados
- Descoberta dos .dbf no FTP (1504 arquivos)
- Mapeamento de nomenclatura (CPNI/DPNI + UF + ano)
- Identificação das 3 eras estruturais em CPNI e DPNI
- Script R para mapear evolução de códigos IMUNO ao longo de 26 anos
- Matriz 65 vacinas × 26 anos exportada

### Sessão 9: Busca de dicionários
- Localização de dicionários .cnv no FTP (/AUXILIARES/)
- 17 .cnv + 62 .def + 1 .dbf encontrados
- Decodificação de IMUNO.CNV (85 vacinas individuais para doses)
- Decodificação de IMUNOCOB.DBF (26 indicadores compostos para cobertura)
- **Descoberta crítica:** cobertura e doses usam sistemas de códigos diferentes

### Sessão 10 (continuação): Dicionários e mudanças estruturais
- Análise detalhada da estrutura .cnv
- Confirmação de transições: município 7→6 dígitos, colunas 7→9→12→7

### Sessão 11 (22/fev, manhã): Reescrita do PROJECT.md
- Reescrita completa do PROJECT.md (de ~200 para ~675 linhas)
- Escopo atualizado: 1994-2025
- 15 seções cobrindo todas as decisões e descobertas

### Sessão 12: Tipagem e diagnóstico
- Mudança de estratégia sobre tipos no Parquet
- Script `diagnostico_tipagem.R` criado
- **Descoberta:** CSV tem header (contrário à suposição inicial `col_names = FALSE`)
- **Descoberta:** campos numéricos como float no CSV

### Sessão 13: Diagnóstico CSV float
- Comparação byte-a-byte do CSV
- Queries à API Elasticsearch (JSON nativo)
- Tabela comparativa de campos afetados
- Confirmação: conversão float na exportação CSV causa `.0` e perda de zeros

### Sessão 14 (22/fev, tarde): Investigação JSON vs CSV
- Descoberta de que JSON existe para todos os meses 2020-2025
- Dois padrões de URL mapeados
- Comparação campo a campo: JSON preserva tudo, CSV de 2020-2024 não
- CSV de 2025 corrigido (mas JSON preferido por consistência)
- JSON é array em linha única (requer leitura binária)
- **Reversão da decisão:** JSON como fonte primária (antes era CSV)

### Sessão 15: Atualização do PROJECT.md para refletir decisão JSON
- 15+ seções editadas sistematicamente
- URLs, tabelas comparativas, decisões de design, artefatos — tudo atualizado
- PROJECT.md passou de ~675 para ~746 linhas

### Sessão 16 (atual): Integração das notas técnicas
- Seção 7 (Cobertura Vacinal) expandida massivamente:
  - Tabela completa de vacinas (15 atuais + 4 históricas + campanhas + gestantes)
  - Indicadores compostos oficiais
  - Taxas de abandono por vacina
  - Denominadores detalhados por período e grupo de UFs
  - Tabela ano-a-ano do SINASC como denominador (2000-2012)
  - Nota sobre congelamento do SINASC 2009
  - Registros de clínicas privadas (Hexa, Pneumo 13V)
- Seção 5.4 nova: transição APIDOS → APIWEB (jul/2013)
- Seção 12: referências documentais detalhadas (8 PDFs)
- Seção 14: tabela de documentos técnicos
- Glossário expandido
- PROJECT.md: 949 linhas

---

## 3. ARTEFATOS PRODUZIDOS

### Documento principal
- `PROJECT.md` (949 linhas) — fonte de verdade sobre o projeto

### Scripts R exploratórios (em /outputs)
| Script | Fase | Descrição |
|--------|------|-----------|
| `00_explorar_dados.R` | Microdados | Exploração inicial dos CSVs |
| `01_converter_parquet.R` | Microdados | Rascunho de conversão CSV→Parquet |
| `02_upload_r2.R` | Microdados | Rascunho de upload para R2 |
| `GUIA_RAPIDO.R` | Microdados | Guia de uso rápido dos dados |
| `comparar_formatos_csv_api.R` | Microdados | Comparação CSV × API Elasticsearch |
| `comparar_formatos_csv_json_xml.R` | Microdados | Comparação entre formatos |
| `diagnostico_tipagem.R` | Ambos | Diagnóstico de tipos por variável |
| `verificar_json_disponivel.R` | Microdados | Disponibilidade JSON, comparação campo a campo |
| `explorar_auxiliares_pni.R` | Agregados | Exploração dos dicionários .cnv/.def |
| `explorar_auxiliares_pni_v2.R` | Agregados | Versão refinada |
| `explorar_pni_v2.R` | Agregados | Exploração dos .dbf agregados |
| `verificar_estrutura_dpni.R` | Agregados | Estrutura dos arquivos DPNI |
| `verificar_transicoes_dpni.R` | Agregados | Transições estruturais ao longo do tempo |

### Documentos de referência (arquivos do projeto, read-only)
8 PDFs com notas técnicas do DATASUS sobre cobertura, doses, taxas de
abandono, regras de cálculo por vacina, e denominadores populacionais.

---

## 4. O QUE FALTA FAZER

### Fase 1: Documentação (FASE ATUAL — em andamento)

**Feito:**
- [x] PROJECT.md completo e atualizado (v3, 949 linhas)

**Pendente:**
- [ ] **Organizar scripts exploratórios sem redundância** — há 13 scripts em
  /outputs, alguns com versões v2, outros com sobreposição de funcionalidade.
  Precisam ser revisados, consolidados e nomeados de forma consistente.
- [ ] **Criar scripts faltantes da fase de exploração dos microdados** — a
  exploração dos microdados foi menos sistematicamente documentada que a dos
  agregados. Alguns passos foram feitos diretamente na conversa sem gerar
  scripts reproduzíveis.
- [ ] **Armazenar dicionários (ambas as fases)** — os dicionários originais
  do Ministério (IMUNO.CNV, IMUNOCOB.DBF, Dicionario_tb_ria_rotina.pdf,
  .cnv diversos) precisam ser coletados e organizados na estrutura do
  repositório.
- [ ] **Criar documento de harmonização agregados ↔ microdados** — como
  mapear vacinas, doses, faixas etárias e municípios entre os dois sistemas.
- [ ] **Criar documento de tradução de códigos** — mapeamento completo de
  códigos IMUNO ao longo de toda a série temporal (65 códigos em 26 anos
  nos agregados + códigos do novo SI-PNI nos microdados).

### Fase 2: Pipeline de produção

- [x] Script definitivo: download JSON + conversão dos microdados (2020+)
  - Sincronização inteligente via HEAD requests (ETag + Content-Length)
  - Varre toda a série automaticamente, sem ANOS/MESES fixos
  - Dois padrões de URL, JSON chunked, Parquet character, ano/mes/uf
- [ ] Script definitivo: download + conversão dos agregados (1994-2019)
  - Precisa lidar com: 1504 .dbf, 3 eras estruturais, truncagem de
    município para 6 dígitos, encoding variável
- [ ] Script definitivo: download dos denominadores (SINASC + IBGE)
- [ ] Script de upload para R2 (via rclone)
- [ ] **Gerar manifesto de integridade junto com upload para R2** — arquivo
  `manifesto_microdata.csv` publicado no R2 com: ano, mes, uf,
  json_fonte_url, json_sha256 (hash do zip original do Ministério),
  parquet_sha256 (hash do .parquet no R2), n_registros, data_geracao.
  Permite auditoria externa: qualquer pessoa pode baixar o JSON do
  Ministério, calcular SHA-256, e comparar com o manifesto.
- [ ] Testes e validação do pipeline completo
- [ ] Cron na VPS para execução mensal

### Fase 3: Pacote R `sipni`

- [ ] Criar repositório do pacote
- [ ] Implementar funções de acesso aos dados (conexão ao R2 via Arrow)
- [ ] Implementar harmonização de vacinas (de-para entre sistemas de códigos)
- [ ] Implementar cálculo de cobertura (microdados + denominador)
- [ ] Implementar construção de séries temporais contínuas 1994-2025
- [ ] **Implementar `sipni::validar_integridade()`** — lê o manifesto do R2,
  compara com Parquets locais (hashes SHA-256), e reporta: partições
  ausentes, desatualizadas ou íntegras. Permite ao pesquisador ter certeza
  de que seus dados correspondem ao que o Ministério publicou.
- [ ] **Implementar `sipni::atualizar_dados()`** — lê o manifesto do R2,
  compara com dados locais, e baixa apenas partições novas ou modificadas.
  Evita que o pesquisador rebaixe toda a série a cada atualização.
- [ ] Documentação e vignettes
- [ ] Publicar no GitHub (com pkgdown)
- [ ] Submeter ao CRAN

### Fase 4: Expansão (futuro)

- [ ] Expandir pipeline para outros sistemas (SIM, SINASC, SIH)
- [ ] Reformular healthbR como meta-pacote (estilo tidyverse)
- [ ] API para consumidores não-R

---

## 5. DESCOBERTAS CRÍTICAS A NÃO ESQUECER

1. **CSV tem header** — contrário à suposição inicial. Quase todas as
   variáveis apareciam como valor distinto no mapeamento posicional porque
   eram o nome da coluna.

2. **CSV de 2020-2024 tem artefatos de float** — campos numéricos
   serializados com `.0`, zeros à esquerda perdidos. CSV de 2025 foi
   corrigido pelo Ministério.

3. **JSON é array em linha única** — arquivo pode exceder 2GB. `readLines()`
   do R falha. Solução: `readBin()` + busca de `},{` + `jsonlite`.

4. **Cobertura e doses usam sistemas de códigos IMUNO diferentes** —
   IMUNO.CNV para doses (85 vacinas individuais), IMUNOCOB.DBF para
   cobertura (26 indicadores compostos que somam múltiplas vacinas).

5. **Denominador SINASC variava por grupo de UFs (2000-2005)** — dois
   grupos com regras diferentes. Unificado a partir de 2006.

6. **SINASC 2009 congelado como denominador até ~2012** — fonte conhecida
   de distorção nas coberturas desse período.

7. **Transição APIDOS → APIWEB em jul/2013** — dados de 2013 podem ter
   registros de ambos os sistemas.

8. **Hexavalente = clínicas privadas** — entra nos indicadores compostos
   mas não é rotina da rede pública.

9. **Typo oficial:** `no_fantasia_estalecimento` (sem o "b"). É o nome
   real no banco — não corrigir.

10. **4 campos do dicionário ausentes nos dados:** `st_vida_paciente`,
    `dt_entrada_datalake`, `co_identificador_sistema`,
    `ds_identificador_sistema`.

---

## 6. CONTEXTO DO USUÁRIO

O usuário (Sidney) é psicólogo com interesse em ciência de dados, saúde
pública e programação em R. Segue abordagem metódica e por fases:
documentação completa primeiro, depois pipeline, depois pacote. Prioriza
fidelidade aos dados originais do Ministério e acessibilidade para a
comunidade de pesquisa. O projeto roda em sessões de conversa com Claude,
usando computer use para criar e editar scripts R e documentação.

---

## 7. ARQUIVOS-CHAVE PARA O PRÓXIMO PROMPT

- **PROJECT.md** (`/mnt/user-data/outputs/PROJECT.md`, 949 linhas) — fonte
  de verdade sobre decisões, arquitetura e estado atual. Deve ser lido
  primeiro.
- **Scripts em /outputs** — 13 scripts R exploratórios, precisando de
  organização.
- **Transcrições em /mnt/transcripts/** — 16 arquivos com registro completo
  de todas as conversas. O `journal.txt` indexa todas.
- **PDFs do projeto** (`/mnt/project/`) — 8 notas técnicas do DATASUS.

---

## 8. SUGESTÃO DE PRÓXIMOS PASSOS IMEDIATOS

O próximo passo natural dentro da Fase 1 (Documentação) seria:

1. **Organizar os 13 scripts exploratórios** — revisar cada um, eliminar
   redundâncias, renomear com convenção consistente, e anotar qual
   descoberta cada script documenta.

2. **Criar scripts faltantes dos microdados** — documentar em scripts R
   reproduzíveis as investigações que foram feitas na conversa mas não
   geraram scripts (ex: comparação byte-a-byte do CSV, queries à API
   Elasticsearch).

3. **Coletar e organizar dicionários** — baixar IMUNO.CNV, IMUNOCOB.DBF,
   demais .cnv do FTP, e organizar na estrutura do repositório.

Só depois de completar a Fase 1 (documentação sólida) faz sentido avançar
para a Fase 2 (pipeline de produção).
