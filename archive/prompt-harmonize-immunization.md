# Prompt: Rascunho do Documento de Harmonização Agregados ↔ Microdados

## Contexto

Estou construindo um sistema de redistribuição e harmonização de dados de vacinação do SUS (SI-PNI), cobrindo a série histórica completa de 1994 a 2025+. O projeto integra duas fontes de dados que usam estruturas e códigos incompatíveis:

1. **Dados agregados (1994-2019):** arquivos .dbf do FTP do DATASUS, com doses aplicadas e cobertura vacinal por município. Códigos de vacina do dicionário IMUNO.CNV (85 vacinas individuais para doses) e IMUNOCOB.DBF (26 indicadores compostos para cobertura).

2. **Microdados individuais (2020-2025+):** registros de doses aplicadas (1 linha = 1 dose) do OpenDATASUS, com 56 campos incluindo `co_vacina`, `ds_vacina`, `co_dose_vacina`, `ds_dose_vacina`, `nu_idade_paciente`, `co_municipio_estabelecimento`, entre outros.

O objetivo final é que um pesquisador possa construir uma série temporal contínua de cobertura vacinal de 1994 a 2025 para qualquer vacina e geografia, usando o pacote R `sipni`. Para isso, preciso de um documento que mapeie como traduzir entre os dois sistemas.

## O que preciso

Um rascunho do documento `HARMONIZACAO.md` que cubra os seguintes eixos de mapeamento:

### 1. Vacinas (eixo principal)
- De-para entre códigos IMUNO dos agregados e `co_vacina`/`ds_vacina` dos microdados
- Agrupamento por componente antigênico (ex: "cobertura contra poliomielite" = VOP + VIP + Hexa em ambos os sistemas)
- Transições de vacina ao longo do tempo: DTP → Tetravalente (2003) → Pentavalente (2012)
- Indicadores compostos de cobertura e como reconstruí-los a partir dos microdados

### 2. Doses
- De-para entre códigos de dose dos agregados (DOSE.CNV: 01=D1, 02=D2, 03=D3, etc.) e `co_dose_vacina`/`ds_dose_vacina` dos microdados
- Qual dose conta para cobertura em cada vacina

### 3. Faixas etárias
- Agregados têm faixas pré-definidas (FXET.CNV); microdados têm `nu_idade_paciente` (idade exata)
- Como recategorizar a idade dos microdados para coincidir com as faixas dos agregados
- Populações-alvo por vacina (< 1 ano, 1 ano, etc.)

### 4. Geografia
- Código de município: 7 dígitos nos agregados pré-2013, 6 dígitos pós-2013 e nos microdados
- Truncagem do verificador para normalizar

### 5. Período
- Agregados pré-2004: só granularidade anual
- Agregados 2004-2019: granularidade mensal (campo ANOMES nos DPNI)
- Microdados 2020+: data exata (`dt_vacina`)
- Sobreposição possível: dados de 2020 podem existir em ambas as fontes?

### 6. Descontinuidades metodológicas
- Cobertura pré-calculada pelo MS (agregados) vs calculada por nós (microdados)
- Diferenças nos denominadores ao longo do tempo
- Transição APIDOS → APIWEB em jul/2013

## Informações que tenho disponíveis

Os arquivos do projeto estão na aba "Arquivos" deste Projeto. Os mais relevantes para esta tarefa são:

- **`project-pt.md`** — documento principal do projeto (949 linhas), seções 5 (estrutura dos agregados), 6 (estrutura dos microdados), 7 (cálculo de cobertura) e 8 (compatibilidade entre sistemas) são as mais relevantes
- **`status-01.md`** — resumo das sessões de conversa com descobertas

Leia esses arquivos antes de começar.

## Formato esperado

Documento em Markdown, organizado por eixo de harmonização, com tabelas de de-para onde aplicável. Não precisa ser definitivo — é um rascunho para iterar. Onde houver lacunas de informação (ex: mapeamento exato de `co_vacina` para códigos IMUNO que ainda não foi levantado), marque com `[TODO]` e descreva o que precisa ser investigado.
