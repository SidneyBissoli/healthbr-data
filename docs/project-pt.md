# Projeto: *Redistribuição e Harmonização de Dados de Vacinação do SUS*

> Este documento foi escrito para ser lido por um humano ou por um LLM (como
> Claude Code) que precise entender o projeto sem ter participado das conversas
> anteriores. Ele é a fonte de verdade sobre decisões, arquitetura e estado atual.
>
> Última atualização: 2026-03-01 (v4 — estado atual: 4 datasets publicados no R2,
> dataset cards no HF, sistema de sincronização operacional (manifesto + comparison
> engine + dashboard HF), pré-lançamento)
>
> **Documentos relacionados:**  
> - `strategy-expansion-pt.md` — Ciclo de vida de módulos, lições aprendidas,
>   inventário e priorização.  
> - `strategy-dissemination-pt.md` — Divulgação, financiamento, checklist de
>   lançamento.  
> - `strategy-synchronization.md` — Sistema de verificação de integridade
>   (comparison engine, dashboard HF, manifesto no R2).  
> - `strategy-languages-pt.md` — Regras de idioma por artefato.  
> - `reference-pipelines-pt.md` — Manual de operação dos pipelines.

---

## 1. O QUE É ESTE PROJETO

Redistribuição e harmonização dos dados de vacinação do SUS (SI-PNI) cobrindo
**toda a série histórica de 1994 a 2025+**, servidos gratuitamente em formato
Parquet via protocolo S3 no Cloudflare R2.

O projeto integra três fontes distintas num único ponto de acesso:

1. **Dados agregados históricos (1994-2019)** — doses aplicadas e cobertura
   vacinal por município, oriundos do antigo SI-PNI (arquivos .dbf no FTP do
   DATASUS).

2. **Microdados individuais (2020-2025+)** — registros de doses aplicadas
   (1 linha = 1 dose), oriundos do novo SI-PNI integrado à RNDS (JSONs no
   S3 do OpenDATASUS).

3. **Dados populacionais (denominadores)** — nascidos vivos do SINASC e
   estimativas municipais do IBGE, necessários para calcular cobertura vacinal
   a partir dos microdados.

O projeto faz parte do **healthbr-data**, iniciativa mais ampla de
redistribuição de dados públicos de saúde do Brasil (SIM, SINASC, SIH no
futuro). O SI-PNI é o primeiro sistema implementado e serve como modelo
para os demais.

O projeto tem quatro componentes:

1. **Pipeline de dados** (este repositório) — roda numa VPS, baixa fontes
   brutas, converte para Parquet, sobe para o R2.

2. **Repositório de dados e dicionários** — Parquets no R2 + dicionários
   originais do Ministério da Saúde publicados como referência.

3. **Sistema de sincronização** — comparison engine (Python, cron semanal)
   que verifica se os dados redistribuídos estão em sincronia com as fontes
   oficiais, com dashboard público no Hugging Face Spaces.

4. **Pacote R `sipni`** (repositório separado) — permite ao pesquisador
   construir séries temporais de cobertura vacinal por qualquer vacina e
   geografia com poucas linhas de código.

---

## 2. POR QUE ESTE PROJETO EXISTE

### O problema

Os dados de vacinação do SUS estão fragmentados em dois sistemas incompatíveis,
distribuídos em formatos difíceis de usar, e sem documentação unificada:

**Dados agregados (1994-2019):**  
- Arquivos .dbf no FTP do DATASUS (formato TabWin dos anos 90)  
- Códigos de vacina opacos sem dicionário facilmente acessível  
- Estrutura que muda ao longo do tempo (7→12 colunas em doses; 9→7 em cobertura)  
- Código de município muda de tamanho (7→6 dígitos em 2013)  
- Dicionários (.cnv) em diretório separado, formato proprietário do TabWin  

**Microdados (2020-2025+):**  
- Publicados em CSV e JSON no OpenDATASUS  
- CSV tem artefatos: campos numéricos convertidos para float (sufixo `.0`),
  zeros à esquerda perdidos em vários códigos (raça/cor, CEP, etc.)  
- JSON preserva tipos corretamente (tudo string, zeros à esquerda intactos)  
- 56 colunas reais em ambos os formatos (CSV adiciona uma 57ª vazia pelo `;`
  final), com dicionário oficial de 60 campos  
- Exigem trabalho significativo de limpeza antes de qualquer análise  

**Para construir uma série temporal de cobertura vacinal 1994-2025, o
pesquisador hoje precisa:**  
1. Baixar ~1500 .dbf do FTP + centenas de JSONs/CSVs do OpenDATASUS  
2. Decodificar dois sistemas de códigos de vacina diferentes  
3. Harmonizar estruturas que mudaram ao longo de 30 anos  
4. Obter denominadores populacionais de uma terceira fonte (SINASC/IBGE)  
5. Saber quais doses e faixas etárias usar para cada cálculo de cobertura  
6. Lidar com mudanças no código de município IBGE  

Esse trabalho é repetido por cada pesquisador, introduzindo inconsistências.

### Alternativas existentes e suas limitações

**Base dos Dados (basedosdados.org):**  
- Cobre vacinação, mas apenas dados agregados municipais (doses/cobertura)  
- Não tem microdados individuais  
- Dados recentes pagos (modelo freemium)  

**PCDaS (Fiocruz):**  
- Cobre SIM, SINASC, SIH. Não cobre vacinação de rotina.  

**microdatasus (pacote R):**  
- Focado nos sistemas antigos do DATASUS (.dbc via FTP)  
- Não cobre o novo SI-PNI (2020+)  
- Não cobre os dados agregados de vacinação (PNI)  

**TabNet/TabWin:**  
- Interface web/desktop para tabulação dos agregados  
- Não permite download em massa, não é programático  

### Proposta de valor

Este projeto oferece:  
- **Série histórica completa 1994-2025+** em formato único (Parquet)  
- **Microdados individuais** (2020+) com 56 campos nomeados e tipados  
- **Dados agregados harmonizados** (1994-2019) com códigos decodificados  
- **Denominadores populacionais** para cálculo de cobertura  
- **Dicionários originais** do Ministério da Saúde preservados  
- **Atualização mensal** (pipeline automatizado)  
- **Gratuito** (sem paywall nos dados recentes)  
- **Acessível offline** (download via S3, sem intermediário)  
- **Pacote R** que entrega cobertura vacinal com poucas linhas de código  

---

## 3. ARQUITETURA

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│  1. VPS (Hetzner, €4/mês)                                        │
│     ├── Cron mensal: git pull + Rscript                          │
│     ├── Baixa fontes brutas (DATASUS FTP + OpenDATASUS S3)       │
│     ├── Converte para Parquet particionado                       │
│     └── Sobe para R2 via rclone                                  │
│                                                                  │
│  2. Cloudflare R2 (armazenamento primário)                       │
│     └── Serve Parquets via protocolo S3                          │
│     └── Egress gratuito (diferença-chave vs AWS S3)              │
│                                                                  │
│  3. Hugging Face (espelho para descobribilidade)                 │
│     └── README aponta para R2 como fonte primária                │
│                                                                  │
│  4. Pacote R "sipni" (consumo)                                   │
│     └── Conecta às 4 fontes harmonizadas no R2                   │
│     └── Calcula cobertura vacinal com denominador correto        │
│     └── Entrega séries temporais e dados prontos para ggplot     │
│                                                                  │
│  5. GitHub (código-fonte)                                        │
│     └── Versiona pipeline + pacote (repos separados)             │
│     └── VPS faz git pull e executa                               │
│                                                                  │
│  6. Sistema de sincronização                                     │
│     ├── Comparison engine (Python, cron semanal no Hetzner)      │
│     ├── manifest.json por módulo no R2 (metadados de cada        │
│     │   partição processada: ETag fonte, SHA-256, contagem)      │
│     └── Dashboard público (Streamlit no HF Spaces)               │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Estrutura no R2

```
s3://healthbr-data/sipni/
  microdados/                          ← Novo SI-PNI rotina (2020-2025+)
    README.md                          ← Autodocumentação (EN)
    manifest.json                      ← Metadados de integridade
    ano=2024/mes=01/uf=AC/
      part-00000.parquet
  covid/                               ← SI-PNI COVID (2021-2025+)
    microdados/
      README.md
      manifest.json
      ano=2024/mes=01/uf=AC/
        part-00000.parquet
      ano=_invalid/                    ← Registros com datas fora do intervalo
  agregados/                           ← Antigo SI-PNI (1994-2019)
    doses/
      README.md
      manifest.json
      ano=1998/uf=AC/
        part-00000.parquet
    cobertura/
      README.md
      manifest.json
      ano=2005/uf=SP/
        part-00000.parquet
  dicionarios/                         ← Referência (originais do MS)
    microdados/
      dicionario_tb_ria_rotina.json    ← 56 campos do novo SI-PNI
    agregados/
      IMUNO.CNV                        ← Vacinas (doses)
      IMUNOCOB.DBF                     ← Vacinas (cobertura)
      DOSE.CNV                         ← Tipos de dose
      FXET.CNV                         ← Faixas etárias
```

**Acesso público:** O R2 não suporta acesso S3 anônimo. A solução é um token
read-only (Account API token, Object Read only) cujas credenciais são
publicadas intencionalmente nos dataset cards e READMEs. O token só permite
leitura de objetos no bucket `healthbr-data`.

**Dados populacionais (denominadores):** Não são publicados como módulo no R2.
A lógica de construção de denominadores (regras CGPNI por período e UF) será
incorporada ao pacote R `sipni`, que acessará as fontes diretamente via
pacotes R existentes (`brpop`, `sidrar`, `microdatasus`). Decisão de
28/fev/2026 — denominadores são dados fáceis de obter e não justificam
pipeline, armazenamento nem documentação de dataset próprios.

### Por que não GitHub Actions?

Volume de dados grande demais. ~1.8 GB/mês de microdados JSON, mais os agregados.
VPS a €4/mês não tem limite de tempo, tem disco persistente (cache), e cron.

### Por que R2 e não S3 ou HF direto?

- AWS S3: egress caro (~$0.09/GB).
- Hugging Face: gratuito, mas empresa de IA que pode mudar regras.
- Cloudflare R2: S3-compatível, egress zero. Se morrer, migra em horas.

---

## 4. FONTES DE DADOS

### 4.1 Microdados — Novo SI-PNI (2020-2025+)

**Origem:** OpenDATASUS (S3 do Ministério da Saúde)

**Fonte primária: JSON**
```
2020-2024: https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{mes}_{ano}.json.zip
2025+:     https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{mes}_{ano}_json.zip
```
Onde `{mes}` = jan, fev, mar, ... e `{ano}` = 4 dígitos.
**ATENÇÃO:** O padrão de URL mudou em 2025 (`.json.zip` → `_json.zip`). O
pipeline deve testar ambos os padrões.

**Fonte alternativa: CSV** (mantida para referência/fallback)
```
https://arquivosdadosabertos.saude.gov.br/dados/dbbni/vacinacao_{mes}_{ano}_csv.zip
```

**Por que JSON e não CSV?**
Investigação detalhada (verificar_json_disponivel.R) revelou que os CSVs de
2020-2024 contêm artefatos de exportação: campos numéricos serializados como
float (ex: `420750.0` em vez de `420750`), com perda de zeros à esquerda em
códigos como raça/cor (`3` em vez de `03`), CEP (`89087.0` em vez de `89087`).
O JSON preserva todos os valores como strings, com zeros à esquerda intactos.
O CSV de 2025 não apresenta esses artefatos (Ministério corrigiu a exportação),
mas o JSON é preferido por consistência em toda a série. JSON é ~1.3x maior
que CSV (28 GB a mais no total para 72 meses), trade-off aceitável para
eliminar toda lógica de reconstrução de zeros.

**Formato JSON:** Array JSON em linha única (arquivo pode exceder 2GB
descomprimido). Requer leitura binária parcial — `readLines()` do R falha
com erro de limite de string. Solução: ler N bytes com `readBin()`, localizar
delimitadores `},{` entre registros, e parsear fragmento com `jsonlite`.

**Formato CSV:** Header presente, encoding Latin-1, delimitador `;`, 56 colunas
reais (+ 1 artefato vazio do `;` final ao parsear).

**Cobertura temporal:** 2020 em diante (72 meses disponíveis até fev/2026).
JSON confirmado disponível para todos os meses de 2020 a 2025.

**Dicionário:** `Dicionario_tb_ria_rotina.pdf` (60 campos, dos quais 56
existem nos JSONs/CSVs). Validado cruzando CSV × JSON × dicionário.

### 4.2 Dados Agregados — Antigo SI-PNI (1994-2019)

**Origem:** FTP do DATASUS  
**URL dados:** `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/`  
**URL dicionários:** `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/`  

**Formato:** Arquivos .dbf (dBase III), leitura direta com `foreign::read.dbf()`.

**Volume:** 1504 arquivos .dbf (752 de cobertura CPNI* + 752 de doses DPNI*).

**Nomenclatura dos arquivos:**  
- `CPNIAC05.DBF` → Cobertura, Acre, 2005  
- `DPNIRJ16.DBF` → Doses, Rio de Janeiro, 2016  
- `CPNIUF99.DBF` → Cobertura consolidada por UF, 1999  
- `CPNIBR07.DBF` → Cobertura consolidada nacional, 2007  
- `CPNIIG04.DBF` → Cobertura de registros sem UF definida, 2004  

**Nota sobre consolidados (DPNI):** A exploração e validação na Fase 4
revelaram que os consolidados DPNI têm estrutura distinta dos estaduais
(DPNIUF sem coluna MUNIC; DPNIBR redundante com os estaduais; DPNIIG
inexistente no FTP). Por esse motivo, apenas os arquivos estaduais
(27 UFs × 26 anos) são publicados no R2. Racional completo em
`docs/sipni-agregados/exploration-pt.md`, decisão 9.8/9.9.

**Cobertura temporal:** 1994 a 2019.

**Granularidade de uma linha:**  
- Doses: `ano × uf × município × faixa_etária × vacina × tipo_dose → doses_aplicadas`  
- Cobertura: `ano × uf × município × (faixa_etária) × vacina → doses, população, cobertura%`  

### 4.3 Dados Populacionais (Denominadores)

**SINASC** (nascidos vivos por município): FTP do DATASUS.
Usado como denominador para cobertura em menores de 1 ano e 1 ano.
Para população de 1 ano, usa-se NV do **ano anterior** (defasagem).

**IBGE** (estimativas populacionais municipais): site do IBGE.
Usado para demais faixas etárias (Censo, contagens, projeções intercensitárias).

A combinação de fontes populacionais para o cálculo do denominador muda ao
longo do tempo e, entre 2000-2005, variava por grupo de UFs (ver seção 7).

**Notas técnicas de referência sobre denominadores (arquivos do projeto):**  
- `notatecnica.pdf` e `notatecnicaCobertura.pdf` — regras detalhadas por
  período, incluindo tabela com anos de referência do SINASC e IBGE por UF.  
- `Nota_Tecnica_Imunizacoes_Cobertura_desde_1994.pdf` — versão expandida com
  tabelas de população-alvo e imunobiológicos.  
- `Imun_cobertura_desde_1994.pdf` — mesma informação em formato diferente.  

---

## 5. ESTRUTURA E TRANSIÇÕES DOS DADOS AGREGADOS

### 5.1 Arquivos de COBERTURA (CPNI)

**Três eras estruturais:**

| Período   | Colunas    | Campos                                                         | ANO       | MUNIC             |
|:---------:|:----------:|----------------------------------------------------------------|:---------:|:-----------------:|
| 1994-2003 | 9          | ANO, UF, MUNIC, FX_ETARIA, IMUNO, DOSE, QT_DOSE, POP, COBERT   | integer   | 7 dígitos         |
| 2004-2012 | 9          | (mesmos)                                                       | character | 7 dígitos (c/ NAs)|
| 2013-2019 | 7          | ANO, UF, MUNIC, IMUNO, QT_DOSE, POP, COB                       | character | 6 dígitos         |

**Transição principal (2013):** desaparecem FX_ETARIA e DOSE. A partir de 2013,
cada código IMUNO já embute a dose e faixa etária corretas (indicador composto
pré-calculado). Antes de 2013, a granularidade era maior.

### 5.2 Arquivos de DOSES (DPNI)

**Três eras estruturais:**

| Período   | Colunas    | Campos adicionais vs 1994-2003                        | ANO       | MUNIC     |
|:---------:|:----------:|-------------------------------------------------------|:---------:|:---------:|
| 1994-2003 | 7          | ANO, UF, MUNIC, FX_ETARIA, IMUNO, DOSE, QT_DOSE       | integer   | 7 dígitos |
| 2004-2012 | 12         | + ANOMES, MES, DOSE1, DOSEN, DIFER                    | character | 7 dígitos |
| 2013-2019 | 12         | (mesmos de 2004-2012)                                 | character | 6 dígitos |

**Transição principal (2004):** surgem ANOMES, MES (granularidade mensal) e
DOSE1, DOSEN, DIFER (campos para cálculo de taxa de abandono).

### 5.3 Marco comum: código de município (2013)

Em ambos (CPNI e DPNI), o código de município muda de 7 para 6 dígitos em 2013.
O 7º dígito é o verificador do IBGE.

**Pipeline de publicação:** mantém o código exatamente como na fonte (7 dígitos
até 2012, 6 dígitos a partir de 2013). A normalização para 6 dígitos é
transformação determinística que fica a cargo do pacote R `sipni`, não dos
dados publicados (princípio de fidelidade à fonte — ver seção 9).

### 5.4 Transição APIDOS → APIWEB (jul/2013)

O sistema de registro de vacinação mudou em julho de 2013:  
- **APIDOS** (até jun/2013): sistema DOS de avaliação do PNI  
- **APIWEB** (a partir jul/2013): sistema web que absorveu APIDOS + SIPNI  

Isso significa que dados de 2013 podem ter registros de ambos os sistemas
para o mesmo município. A partir de 2013, dados SIPNI (por indivíduo)
são agrupados aos do SIAPI e disponibilizados nos mesmos relatórios
agregados. Para dados exclusivos do SIPNI individualizado, a referência
era `http://sipni.datasus.gov.br`.

### 5.5 Sistemas de códigos IMUNO

**DESCOBERTA CRÍTICA:** Cobertura e doses usam sistemas de códigos diferentes.

**Doses (DPNI)** → dicionário `IMUNO.CNV` (85 vacinas individuais).
Cada código identifica uma vacina específica. Exemplos:  
- `02` = BCG  
- `06` = Febre Amarela  
- `08` = Hepatite B  
- `52` = Pentavalente (DTP+HB+Hib)  
- `60` = Hexavalente  
- `61` = Rotavírus  

**Cobertura (CPNI)** → dicionário `IMUNOCOB.DBF` (26 indicadores compostos).
Cada código representa uma cobertura que pode somar múltiplas vacinas:  
- `072` = BCG total (rotina + comunicantes hanseníase)  
- `073` = Hepatite B total (HB + Penta + Hexa somados)  
- `074` = Poliomielite total (VOP + VIP + Hexa + esquema sequencial)  
- `080` = Penta total (Penta + Hexa)  

### 5.6 Evolução dos códigos de vacina

A matriz IMUNO × ano (1994-2019) revela 65 códigos ao longo de 26 anos, com
três gerações de vacinas que refletem substituições do calendário:

- **1ª geração (1994-2003):** DTP isolada, Sarampo monovalente, Hib isolada
- **2ª geração (2004-2012):** Tetravalente (DTP/Hib), Rotavírus, Pneumo 10V, Meningo C
- **3ª geração (2013+):** Pentavalente, VIP/VOP sequencial, Tetraviral, Hepatite A

Alguns códigos aparecem por 1-3 anos (campanhas pontuais, H1N1, etc.).

---

## 6. ESTRUTURA DOS MICRODADOS (2020+)

### Características técnicas

| Propriedade          | JSON (fonte primária)                       | CSV (alternativa)                        |
|----------------------|---------------------------------------------|------------------------------------------|
| Encoding             | **UTF-8**                                   | **Latin-1**                              |
| Estrutura            | Array JSON (linha única gigante)            | Header + dados, delimitador **;**        |
| Colunas              | **56** colunas reais                        | **56** reais + 1 artefato do ; final     |
| Tipos                | Tudo **string** (character)                 | Misto (alguns campos como float no 2020-2024) |
| Zeros à esquerda     | **Preservados**                             | **Perdidos em 2020-2024** (corrigido em 2025) |
| Tamanho (zip)        | ~1.8 GB por mês                             | ~1.4 GB por mês                          |

### Artefatos do CSV (2020-2024) — motivo da escolha do JSON

| Campo CSV               | Valor CSV       | Valor JSON      | Problema                    |
|-------------------------|-----------------|-----------------|-----------------------------|
| co_municipio_paciente   | `420750.0`      | `420750`        | Sufixo `.0`                 |
| co_pais_paciente        | `10.0`          | `10`            | Sufixo `.0`                 |
| nu_cep_paciente         | `89087.0`       | `89087`         | Sufixo `.0`                 |
| co_estrategia_vacinacao | `1.0`           | `1`             | Sufixo `.0`                 |
| co_raca_cor_paciente    | `3`             | `03`            | Zero à esquerda perdido     |

Esses artefatos não existem nos CSVs de 2025 — o Ministério corrigiu a
exportação. Mas como o pipeline precisa cobrir 2020-2024, o JSON é a fonte
mais segura para toda a série.

### A coluna 57 (artefato — apenas no CSV)

No CSV, cada linha termina com `;`, fazendo o parser criar uma 57ª coluna
vazia. No JSON, não há esse artefato — são 56 colunas reais.

### Tipos de dados

**Decisão: tudo character no Parquet.** O JSON já traz todos os campos como
string, preservando zeros à esquerda em códigos como IBGE, CNES, CEP e raça/cor.
O pipeline converte JSON → Parquet mantendo o tipo character.

Exceções planejadas (tipagem futura no pacote R):  
- Campos `dt_*` → tipo `Date` (formato YYYY-MM-DD confirmado)  
- Campos numéricos puros sem zero à esquerda → `integer` (ex: `nu_idade_paciente`)  

### Pares código/descrição

O Ministério publica os microdados com pares de colunas (ex: `co_vacina` +
`ds_vacina`, `co_dose_vacina` + `ds_dose_vacina`). Os dados são publicados
exatamente como o Ministério fornece — sem transformações.

### Typo oficial

A coluna 17 chama-se `no_fantasia_estalecimento` (sem o "b"). É o nome oficial
no banco e no JSON. Não é erro nosso.

### Campos ausentes no CSV/JSON vs dicionário

| Dict | Campo                    | Observação                          |
|:----:|-------------------------:|------------------------------------:|
| 13   | st_vida_paciente         | Ausente no CSV e no JSON            |
| 34   | dt_entrada_datalake      | Campo fantasma (ausente em tudo)    |
| 38   | co_identificador_sistema | Ausente no CSV e no JSON            |
| 59   | ds_identificador_sistema | Ausente no CSV e no JSON            |

**Nota:** `dt_deletado_rnds` (dict #58) está presente em ambos os formatos
(confirmado na comparação JSON×CSV de jan/2020), geralmente vazio.
Anteriormente era reportado como ausente no CSV — a inclusão pode ter
ocorrido com a adição do header, ou era lido incorretamente no mapeamento
posicional original. Total de colunas nos arquivos: **56** em ambos os
formatos (mesmos nomes, confirmado por comparação direta).

### Mapeamento completo (posição → nome oficial, 56 colunas)

```
 1  co_documento                        22  co_vacina
 2  co_paciente                         23  sg_vacina
 3  tp_sexo_paciente                    24  dt_vacina
 4  co_raca_cor_paciente                25  co_dose_vacina
 5  no_raca_cor_paciente                26  ds_dose_vacina
 6  co_municipio_paciente               27  co_local_aplicacao
 7  co_pais_paciente                    28  ds_local_aplicacao
 8  no_municipio_paciente               29  co_via_administracao
 9  no_pais_paciente                    30  ds_via_administracao
10  sg_uf_paciente                      31  co_lote_vacina
11  nu_cep_paciente                     32  ds_vacina_fabricante
12  ds_nacionalidade_paciente           33  dt_entrada_rnds (CORRIGIDO)
13  no_etnia_indigena_paciente          34  co_sistema_origem
14  co_etnia_indigena_paciente          35  ds_sistema_origem
15  co_cnes_estabelecimento             36  st_documento
16  no_razao_social_estabelecimento     37  co_estrategia_vacinacao
17  no_fantasia_estalecimento (typo)    38  ds_estrategia_vacinacao
18  co_municipio_estabelecimento        39  co_origem_registro
19  no_municipio_estabelecimento        40  ds_origem_registro
20  sg_uf_estabelecimento               41  co_vacina_grupo_atendimento
21  co_troca_documento                  42  ds_vacina_grupo_atendimento
                                        43  co_vacina_categoria_atendimento
                                        44  ds_vacina_categoria_atendimento
                                        45  co_vacina_fabricante
                                        46  ds_vacina
                                        47  ds_condicao_maternal
                                        48  co_tipo_estabelecimento
                                        49  ds_tipo_estabelecimento
                                        50  co_natureza_estabelecimento
                                        51  ds_natureza_estabelecimento
                                        52  nu_idade_paciente
                                        53  co_condicao_maternal
                                        54  no_uf_paciente
                                        55  no_uf_estabelecimento
                                        56  dt_deletado_rnds (*)
```

(*) Coluna 56 identificada na comparação JSON×CSV de jan/2020. Ausente no
mapeamento posicional original (que assumia 55 colunas sem header).
Geralmente vazia.

---

## 7. CÁLCULO DE COBERTURA VACINAL

### Fórmula

```
Cobertura (%) = (Doses aplicadas da vacina X, na dose indicada, no local e período)
                ÷ (População-alvo no mesmo local e período) × 100
```

### Dados agregados (1994-2019)

A cobertura já vem calculada nos campos `COBERT` (1994-2012) ou `COB`
(2013-2019) dos arquivos CPNI. Os campos `POP` e `QT_DOSE` também estão
disponíveis para recálculo.

### Microdados (2020-2025+)

A cobertura precisa ser calculada a partir dos microdados + denominador externo.
O numerador é a contagem de doses da vacina/dose indicada, agregada por
município e período. O denominador vem do SINASC (nascidos vivos) ou IBGE
(estimativas), conforme a faixa etária.

### Qual dose conta para cobertura? (tabela completa)

Cada vacina tem uma dose indicadora de cobertura, população-alvo e meta
definidas pelo PNI. As regras mudaram ao longo do tempo conforme vacinas
foram substituídas no calendário.

**Vacinas do calendário infantil atual (rotina):**

| Vacina                | Pop. alvo | Dose cobertura              | Meta | Período       | Numerador: soma de vacinas com mesmo componente     |
|-----------------------|:---------:|:---------------------------:|:----:|:-------------:|-----------------------------------------------------|
| BCG                   | < 1 ano   | DU                          | 90%  | 1994+         | DU rotina + DU comunicantes hanseníase              |
| Hepatite B            | < 1 ano   | D3                          | 95%  | 1994+         | D3 HB + D3 Penta + D3 Hexa                         |
| Hepatite B (RN)       | < 1 mês   | D                           | —    | 2014+         | Dose "D" HB (denominador = NV do ano)               |
| Rotavírus (VORH)      | < 1 ano   | D2                          | 90%  | 2006+         | D2 Rotavírus total                                  |
| Pneumo 10V/13V        | < 1 ano   | D3                          | 95%  | 2010+         | D3 Pneumo 10V + D3 Pneumo 13V                      |
| Meningo C             | < 1 ano   | D2                          | 95%  | 2010+         | D2 Meningo C                                        |
| Penta (DTP/Hib/HB)    | < 1 ano   | D3                          | 95%  | 2º sem 2012+  | D3 Penta + D3 Hexa                                  |
| Esq. Seq. VIP/VOP     | < 1 ano   | D3                          | 95%  | 2º sem 2012+  | D3 VOP quando registrada como esq. sequencial       |
| Poliomielite          | < 1 ano   | D3                          | 95%  | 1994+         | D3 VOP + D3 VIP + D3 Hexa + D3 Penta inativ. + D3 Esq.Seq. |
| Tríplice Viral D1     | 1 ano     | D1                          | 95%  | 2000+         | D1 Tríplice Viral                                   |
| Tríplice Viral D2     | 1 ano     | D2                          | 95%  | 2013+         | D2 Tríplice Viral + DU Tetraviral                   |
| Tetraviral            | 1 ano     | DU                          | —    | 2013+         | DU Tetraviral                                       |
| Hepatite A            | 1 ano     | DU                          | —    | 2014+         | DU Hepatite A                                       |
| Febre Amarela         | < 1 ano   | DU/D1                       | 100% | 1994+         | DU/D1 FA (todos os municípios)                      |
| DTP REF1              | 1 ano     | REF1                        | 95%  | 1994+         | REF1 DTP                                            |

**Vacinas históricas (substituídas ou descontinuadas):**

| Vacina                | Pop. alvo | Dose cobertura | Meta | Período       | Substituída por                        |
|-----------------------|-----------|:--------------:|:----:|:-------------:|----------------------------------------|
| Tríplice Bact. (DTP)  | < 1 ano   | D3             | 95%  | 1994-2002     | Tetravalente (2003)                    |
| Sarampo (monovalente) | < 1 ano   | DU             | 95%  | 1994-2002     | Tríplice Viral em 1 ano (2003)         |
| Haemophilus b (Hib)   | < 1 ano   | D3             | 95%  | 1999-2002     | Tetravalente (2003)                    |
| Tetra (DTP/Hib)       | < 1 ano   | D3             | 95%  | 2003-2012     | Pentavalente (2012)                    |

**Campanhas (registros separados nos agregados):**

| Vacina                     | Pop. alvo          | Dose    | Meta | Período       |
|----------------------------|--------------------|:-------:|:----:|:-------------:|
| Polio campanha (1ª etapa)  | <1 ano (94-99), 0-4 anos (00-10) | D | 95%  | 1994-2010 |
| Polio campanha (2ª etapa)  | <1 ano (94-99), 0-4 anos (00-10) | D | 95%  | 1994-2010 |
| Influenza campanha         | ≥65 (1999), ≥60 (2000-2010)      | D | 80%  | 1999-2010 |
| Tríplice Viral campanha    | 1 a 4 anos         | D1      | 95%  | 2004          |

**Gestantes:**

| Vacina                | Pop. alvo       | Dose cobertura | Período |
|-----------------------|:---------------:|:--------------:|:-------:|
| Gestante (dT + dTpa)  | 12 a 49 anos   | D2 + REF       | 1994+   |
| Gestante (dTpa)       | 12 a 49 anos   | DU + REF       | jul/2013+ |

**Nota sobre campanhas:** A partir de 2011, os dados de campanha de poliomielite
e influenza passaram a ser registrados somente no site do PNI, não mais nos
arquivos agregados do FTP.

### Indicadores compostos de cobertura

Para calcular cobertura por doença (e não por produto), é preciso somar doses
de vacinas com o mesmo componente. Os indicadores compostos oficiais são:

| Indicador composto                | Soma de vacinas                                        |
|-----------------------------------|--------------------------------------------------------|
| Total contra tuberculose          | BCG + BCG-Hanseníase (− comunicantes)                  |
| Total contra hepatite B           | HB + Pentavalente + Hexavalente                        |
| Total contra poliomielite         | VOP + VIP + Hexavalente                                |
| Total contra coqueluche/dift./tét.| Tetravalente + Pentavalente + Hexavalente              |
| Total contra sarampo e rubéola    | Tríplice Viral + Dupla Viral                           |
| Total contra difteria e tétano    | DTP + DTPa + Tetravalente + Penta + Hexa + DT infantil |
| Total contra haemophilus b        | Hib + Tetravalente + Pentavalente + Hexavalente        |

Essas somas são necessárias nos anos de transição entre vacinas (ex: 2002 DTP→Tetra,
2012 Tetra→Penta), quando o numerador precisa incluir ambas as formulações.

### Taxas de abandono

A taxa de abandono mede a proporção de vacinados que iniciaram o esquema mas
não completaram:

```
Taxa de abandono (%) = (D1 − Dúltima) ÷ D1 × 100
```

Calculada para vacinas com esquema multidose no calendário infantil:

| Vacina           | Cálculo                      | Período    |
|------------------|-------------------------- |------------|
| Hepatite B       | (D1 HB+Penta+Hexa − D3) / D1 | em < 1 ano |
| Rotavírus        | (D1 − D2) / D1              | em < 1 ano, a partir de 2006 |
| Pneumo 10V/13V   | (D1 10V+13V − D3) / D1      | em < 1 ano, a partir de 2010 |
| Meningo C        | (D1 − D2) / D1              | em < 1 ano, a partir de 2010 |
| Esq. Seq. VIP/VOP| (D1 − D3) / D1              | em < 1 ano, a partir de 2º sem 2012 |
| Penta            | (D1 Penta+Hexa − D3) / D1   | em < 1 ano, a partir de 2º sem 2012 |
| Tríplice Viral   | (D1 − D2 TV+Tetra) / D1     | em 1 ano, a partir de 2013 |
| Poliomielite     | (D1 VOP+VIP+... − D3) / D1  | em < 1 ano |
| Tetra (DTP/Hib)  | (D1 Tetra+Penta+Hexa − D3) / D1 | em < 1 ano, 2003-2012 |

Na Hepatite B, as doses "D" (recém-nascido < 1 mês) NÃO entram no cálculo
de abandono porque fazem parte do esquema complementado pela Penta.

### Denominador: fontes e regras ao longo do tempo

A fonte do denominador populacional mudou várias vezes, inclusive de forma
diferente entre grupos de UFs:

**Período 1994-1999 (todas as UFs):**  
Estimativas populacionais preliminares do IBGE para todas as faixas etárias.
Não foram usados dados da Contagem Populacional de 1996 nem revisões
posteriores (por orientação da CGPNI). Portanto a população-alvo NÃO é a
mesma disponível nas páginas de População Residente do DATASUS.

**Período 2000-2005 (regra split por UF):**  
Dois grupos de estados com regras diferentes:

- Grupo A (AL, AM, BA, CE, MA, MG, MT, PA, PB, PI, RO, TO):
  todas as faixas usam Censo 2000 e estimativas IBGE (sem SINASC).
- Grupo B (AC, AP, ES, GO, MS, PR, PE, RJ, RN, RS, RR, SC, SP, SE, DF):
  < 1 ano e 1 ano usam SINASC; demais faixas usam Censo 2000/estimativas.

Detalhe: para população de 1 ano, o SINASC usa nascidos vivos do **ano
anterior** (ex: pop de 1 ano em 2003 = NV de 2002).

**Período 2006+ (todas as UFs):**  
- < 1 ano: SINASC (nascidos vivos do próprio ano)  
- 1 ano: SINASC (nascidos vivos do ano anterior)  
- Demais faixas: Censo, contagens, projeções intercensitárias ou estimativas IBGE  

**Notas importantes sobre o denominador:**  
- Dados do SINASC podem ser revisados posteriormente sem atualização na
  população-alvo usada pelo PNI (congelamento do dado na época).  
- Quando o SINASC do ano não está disponível, usa-se o do ano anterior.  
- Para o ano corrente (dados preliminares), usa-se meta mensal acumulada:
  pop_anual ÷ 12 × nº de meses. Dados são finalizados em março do ano
  seguinte.  

### Dados ausentes por UF nos primeiros anos

| Ano  | UFs sem dados |
|:----:|:-------------:|
| 1994 | AL, AP, DF, MS, MG, PB, PR, RJ, RS, SP, SE, TO (12 UFs) |
| 1995 | MS, MG, TO (3 UFs) |
| 1996 | MG (1 UF) |
| 1997+ | Todas as UFs disponíveis |

### Notas sobre registros de clínicas privadas

A vacina Hexavalente (DTPa/Hib/HB/VIP) é administrada em clínicas privadas
e registrada no sistema APIWEB. A Pneumocócica 13 valente também é
administrada em clínicas privadas, além de alguns municípios que adquirem
a vacina separadamente. Ambas entram nas somas de cobertura dos indicadores
compostos correspondentes. Antes da Penta entrar na rotina (2º sem 2012),
registros de Penta/Hexa nos dados referem-se a vacinação indígena e nos
Centros de Referência de Imunobiológicos Especiais (CRIE).

### Tabela de referência: ano do SINASC usado como denominador

O SINASC de 1 ano usa NV do ano anterior. Quando dados não disponíveis,
repete-se o último disponível. Tabela extraída das notas técnicas:

| Ano dados | <1 ano (SINASC) | 1 ano (SINASC) | UFs com SINASC para <1 e 1 ano      |
|-----------|-----------------|-----------------|--------------------------------------|
| 1994-1999 | — (IBGE)        | — (IBGE)        | Nenhuma (todas usam IBGE)            |
| 2000      | 2000            | 2000            | Grupo B (AC,AP,ES,GO,MS,PR,PE,RJ,RN,RS,RR,SC,SP,SE,DF) |
| 2001      | 2001            | 2000            | Grupo B                              |
| 2002      | 2002            | 2001            | Grupo B                              |
| 2003      | 2003            | 2002            | Grupo B                              |
| 2004      | 2004            | 2003            | Grupo B                              |
| 2005      | 2005            | 2004            | Grupo B                              |
| 2006      | 2006            | 2005            | Todas as UFs                         |
| 2007      | 2007            | 2006            | Todas as UFs                         |
| 2008      | 2008            | 2007            | Todas as UFs                         |
| 2009      | 2009*           | 2008            | Todas as UFs                         |
| 2010      | 2009*           | 2009            | Todas as UFs                         |
| 2011      | 2009*           | 2009            | Todas as UFs                         |
| 2012      | 2009*           | 2009            | Todas as UFs                         |

(*) SINASC de 2009 repetido nos anos seguintes (dado mais recente disponível
à época da publicação). Este congelamento é uma fonte conhecida de distorção
nas coberturas calculadas para ~2010-2012.

---

## 8. COMPATIBILIDADE ENTRE AGREGADOS E MICRODADOS

### O que casa diretamente

- **Município:** ambos têm código IBGE (normalizar para 6 dígitos)
- **Período:** ambos permitem agregação por ano (e por mês nos microdados e
  nos DPNI a partir de 2004)
- **Doses aplicadas:** contagem extraível de ambos (QT_DOSE nos agregados,
  contagem de registros nos microdados)

### O que exige harmonização

- **Vacinas:** os nomes e códigos mudaram. DTP → Tetravalente → Pentavalente.
  Sarampo monovalente → Tríplice Viral. Para construir série contínua de
  cobertura contra poliomielite, por exemplo, é preciso somar VOP + VIP +
  Pentavalente conforme o período.
- **Faixa etária:** agregados têm faixas pré-definidas; microdados têm idade
  exata (`nu_idade_paciente`), que precisa ser recategorizada.
- **Tipo de dose:** agregados usam códigos numéricos (01=D1, 02=D2...);
  microdados têm `co_dose_vacina` e `ds_dose_vacina` com valores diferentes.

### O que não existe nos agregados

Sexo, raça/cor, estabelecimento (CNES), lote, fabricante, estratégia de
vacinação — são exclusivos dos microdados (2020+).

### Descontinuidade metodológica inevitável

A série 1994-2019 usa cobertura pré-calculada pelo Ministério (com denominadores
oficiais daquele ano). A série 2020+ terá cobertura calculada por nós a partir
dos microdados + denominadores SINASC/IBGE. Os valores devem ser comparáveis
mas não idênticos, por diferenças no momento de extração dos dados e possíveis
revisões nos denominadores.

---

## 9. DECISÃO SOBRE PUBLICAÇÃO DOS DADOS

### Princípio: publicar o que o Ministério publica, sem transformar

**Microdados (2020+):** publicados exatamente como o Ministério fornece. O
Ministério já inclui pares código/descrição (ex: `co_vacina` / `ds_vacina`).
Só muda: formato (JSON → Parquet), particionamento por ano/mês/UF.

**Agregados (1994-2019):** publicados com os códigos brutos dos .dbf. Os
dicionários originais (.cnv e IMUNOCOB.DBF) são publicados como arquivos
de referência separados no repositório. O pesquisador faz o join se quiser.

**Dicionários:** publicados na íntegra, nos formatos originais do Ministério.

**Populações (denominadores):** não são publicadas como módulo no R2.
A lógica de construção de denominadores será incorporada ao pacote R `sipni`
(ver seção 10).

### Por que não decodificar os agregados inline?

Decodificar criaria um derivado nosso, não mais o documento original do
Ministério. O projeto prioriza fidelidade à fonte. O pacote R `sipni` fará
o join automaticamente para o pesquisador — a conveniência fica no software,
não nos dados.

---

## 10. PACOTE R `sipni`

### Nome

`sipni` — validado com `pak::pkg_name_check()`. Disponível no CRAN e
Bioconductor. Curto, descritivo, sem prefixo `r` (convenção rOpenSci moderna).

### Valor do pacote

O pacote se justifica por integrar múltiplas fontes harmonizadas e resolver a
complexidade que nenhum pesquisador deveria repetir individualmente:

- Conecta a agregados, microdados e dicionários no R2
- Faz join código→nome automaticamente para os agregados
- Calcula cobertura a partir dos microdados + denominador SINASC/IBGE
  (acessa denominadores via pacotes R existentes, sem módulo R2 próprio)
- Harmoniza nomenclatura de vacinas ao longo de 30 anos
- Constrói série temporal contínua para qualquer vacina × geografia
- Valida integridade dos dados: `check_sync()` compara manifesto com fonte
  atual; `validate_local()` verifica checksums de Parquets locais

### Interface conceitual

```r
library(sipni)

# Série temporal de cobertura
sipni::cobertura("triplice_viral", uf = "DF", anos = 1994:2025)
# → tibble com ano, cobertura_pct, fonte (agregado/microdados), denominador

# Doses aplicadas brutas
sipni::doses(vacina = "pentavalente", municipio = "530010", anos = 2015:2025)

# Dados brutos de microdados
sipni::microdados(uf = "AC", ano = 2024, mes = 1)
# → arrow::open_dataset() com filtros aplicados
```

### Relação com healthbR

O `sipni` será pacote independente no CRAN. O `healthbR` poderá ser
meta-pacote (estilo tidyverse) no futuro, reunindo sipni, sim, sinasc, etc.

---

## 11. DECISÕES DE DESIGN (E POR QUÊ)

| Decisão | Alternativa rejeitada | Motivo |
|---------|:--------------:|--------|
| JSON como fonte dos microdados (rotina) | CSV | CSV de 2020-2024 tem artefatos (.0, perda de zeros). JSON ~1.3x maior, mas elimina toda lógica de reconstrução. |
| CSV como fonte dos microdados (COVID) | — | JSON não existe para COVID. CSV é o único formato disponível. |
| Tudo character no Parquet | Tipagem automática | JSON já traz tudo como string. Zeros à esquerda preservados nativamente. |
| R2 como armazenamento | HF direto / AWS S3 | Egress zero + S3 padrão. |
| Token read-only público (R2) | Acesso S3 anônimo | R2 não suporta anônimo. Token publicado, só permite leitura. |
| VPS Hetzner x86 para execução | GitHub Actions / ARM | Volume excede limites gratuitos. ARM não tem binários pré-compilados para Arrow/polars. |
| Dados brutos + dicionários separados | Dados decodificados inline | Fidelidade à fonte original. Conveniência via pacote. |
| Pipeline separado do pacote | Monorepo | Infraestrutura ≠ interface do pesquisador. |
| Município como na fonte (7d ou 6d) | Truncar para 6 dígitos no pipeline | Fidelidade à fonte; normalização fica no pacote R `sipni`. |
| Denominadores no pacote R, não no R2 | Módulo R2 `sipni/populacao/` | Dados fáceis de obter via pacotes existentes. Não justifica pipeline. |
| Dashboard de sincronização no HF Spaces | GitHub Pages / Vercel | Gratuito, Python-nativo, vive ao lado dos datasets, descobrível. |
| Manifesto por módulo no R2 | Controle de versão centralizado | Cada módulo é autocontido. Consumidores (dashboard, pacote R) leem o manifesto diretamente. |
| Nome `sipni` | `rsipni`, `vacinabr` | Convenção rOpenSci: curto, descritivo, sem prefixo `r`. |
| Precisão prevalece sobre velocidade | Pipeline mais rápido com CSV | 22h vs 8h de bootstrap, mas fidelidade aos dados originais é inegociável. |

---

## 12. O QUE FOI FEITO

### Fase exploratória (concluída)

**Microdados (2020+):**
- [x] Descoberta do formato: CSV com header (Latin-1) e JSON (UTF-8), 56 colunas
- [x] Localização do dicionário oficial (60 campos)
- [x] Mapeamento completo das 56 colunas (posição → nome oficial)
- [x] Validação cruzada CSV × JSON × dicionário (55/56 bateram; 1 corrigido)
- [x] Identificação de 4 campos ausentes e 1 typo oficial
- [x] Descoberta: CSV de 2020-2024 tem artefatos (float .0, zeros perdidos)
- [x] Descoberta: JSON preserva tipos corretamente (tudo string, zeros intactos)
- [x] Decisão: JSON como fonte primária
- [x] Definição de particionamento (ano/mes/uf)

**Dados agregados (1994-2019):**
- [x] Descoberta dos .dbf no FTP do DATASUS (1504 arquivos)
- [x] Mapeamento da nomenclatura de arquivos (CPNI/DPNI + UF + ano)
- [x] Identificação das 3 eras estruturais (CPNI e DPNI)
- [x] Localização dos dicionários em /AUXILIARES/ (17 .cnv + 62 .def + 1 .dbf)
- [x] Decodificação dos dicionários IMUNO.CNV e IMUNOCOB.DBF
- [x] Confirmação que cobertura e doses usam sistemas de códigos IMUNO diferentes
- [x] Análise da evolução dos 65 códigos de vacina ao longo de 26 anos
- [x] Matriz IMUNO × ano completa (exportada como CSV)

**COVID (2021+):**
- [x] Exploração do OpenDATASUS S3: CSV por UF (27 × 5 partes = 135 arquivos)
- [x] Confirmação: JSON não existe para COVID, apenas CSV
- [x] Estrutura: 32 campos, delimitador `;`, UTF-8, ~272 GB brutos
- [x] Decisão: CSV (único formato disponível) com correções documentadas

### Pipelines de produção (concluídos)

**SI-PNI Microdados (rotina):**
- [x] Pipeline Python (jq + polars): `sipni-pipeline-python.py`
- [x] Bootstrap completo: 736M+ registros, 21.7 horas no Hetzner x86
- [x] Dados no R2: `sipni/microdados/` particionado por ano/mes/uf
- [x] Controle de versão: `data/controle_versao_microdata.csv`

**SI-PNI COVID:**
- [x] Pipeline Python (polars direto): `sipni-covid-pipeline.py`
- [x] Bootstrap completo: 608M+ registros, 7.8 horas no Hetzner x86
- [x] Dados no R2: `sipni/covid/microdados/` particionado por ano/mes/uf
- [x] Reorganização R2: prefixo `sipni-covid/` → `sipni/covid/` (fev/2026)
- [x] Anos inválidos realocados para `ano=_invalid/` (~39 MB, 2.756 objetos)

**SI-PNI Agregados — Doses:**
- [x] Pipeline R (foreign + arrow + rclone): `sipni-agregados-doses-pipeline-r.R`
- [x] Bootstrap: 84M registros, 674 arquivos processados, 4h40
- [x] Validação DPNIBR: diferença zero (consolidado = soma dos estaduais)
- [x] Dados no R2: `sipni/agregados/doses/` particionado por ano/uf

**SI-PNI Agregados — Cobertura:**
- [x] Pipeline R: `sipni-agregados-cobertura-pipeline-r.R`
- [x] Bootstrap: 2.76M registros, 686 arquivos, 44 minutos
- [x] Dados no R2: `sipni/agregados/cobertura/` particionado por ano/uf

### Publicação (parcialmente concluída)

- [x] READMEs em inglês criados e publicados no R2 (4 datasets)
- [x] Dataset cards criados no Hugging Face (4 repos sob `SidneyBissoli/`)
- [x] Token read-only público configurado no R2
- [x] Exemplos de código R testados com os 4 datasets
- [x] Licença definida: CC-BY 4.0

### Documentação estratégica (concluída)

- [x] `project-pt.md` e `project-en.md` — arquitetura e decisões
- [x] `strategy-expansion-pt.md` — ciclo de vida de módulos, método de
  exploração, lições aprendidas, inventário
- [x] `strategy-dissemination-pt.md` — divulgação, financiamento, checklist
- [x] `strategy-synchronization.md` — comparison engine, dashboard, manifesto
- [x] `strategy-languages-pt.md` — regras de idioma
- [x] `reference-pipelines-pt.md` — manual de operação dos pipelines
- [x] `harmonization-pt.md` — mapeamento agregados ↔ microdados
- [x] `docs/covid/exploration-pt.md` — exploração do dataset COVID
- [x] `docs/sipni-agregados/exploration-pt.md` — exploração dos agregados (doses)
- [x] `docs/sipni-agregados/exploration-cobertura-pt.md` — exploração dos
  agregados (cobertura)
- [x] Guias rápidos bilíngues (`guides/quick-guide-*.R`)
- [x] Template de dataset card (`guides/dataset-card-template.md`)
- [x] 8 scripts de exploração organizados em `scripts/exploration/`
- [x] READMEs bilíngues na raiz do projeto (`README.md`, `README.pt.md`)

### Documentação de referência consultada
- `Regrascobertura2013.pdf` — Numeradores por vacina (APIDOS/APIWEB), 2012-2013
- `notatecnicaTx.pdf` — Taxas de abandono: fórmulas por vacina
- `notatecnicaCobertura.pdf` — Cobertura: regras por vacina, doses, notas
- `notatecnica.pdf` — Origem dos dados, coberturas, população-alvo por período/UF
- `Nota_Tecnica_Imunizacoes_Cobertura_desde_1994.pdf` — Cobertura desde 1994
- `Nota_Tecnica_Imunizacoes_Doses_aplicadas_desde_1994.pdf` — Doses desde 1994

---

## 13. O QUE FALTA FAZER

### Pré-lançamento (próximos passos imediatos)

- [ ] Criar repositório GitHub público (estrutura de pastas, README bilíngue,
  FUNDING.yml, licença)
- [x] Gerar `manifest.json` retroativamente para os 4 módulos já no R2
- [x] Implementar comparison engine (`sync_check.py`)
- [x] Criar HF Space (dashboard Streamlit de sincronização)
- [ ] Configurar GitHub Sponsors
- [ ] Publicar página de transparência financeira
- [ ] Lançamento público (divulgação nos canais do `strategy-dissemination-pt.md`)

### Documentação pendente

- [ ] Criar documento de tradução de códigos IMUNO ao longo de toda a série
  temporal (crosswalk 65 códigos × 26 anos)
- [ ] Publicar dicionários originais no R2 (`sipni/dicionarios/`)

### Pacote R `sipni`

- [ ] Criar repositório do pacote
- [ ] Implementar funções de acesso aos dados (R2 via Arrow)
- [ ] Implementar harmonização de vacinas (crosswalk agregados ↔ microdados)
- [ ] Implementar cálculo de cobertura (microdados + denominador via pacotes
  R existentes — `brpop`, `sidrar`, `microdatasus`)
- [ ] Implementar construção de séries temporais
- [ ] Implementar `check_sync()` e `validate_local()` (integridade via manifesto)
- [ ] Documentação e vignettes
- [ ] Publicar no GitHub (com pkgdown)
- [ ] Submeter ao CRAN

### Expansão (futuro — após lançamento e feedback)

- [ ] SIM (Mortalidade) — primeiro módulo fora do SI-PNI
- [ ] SINASC (Nascidos Vivos) — sinergia com SIM
- [ ] SIH (Internações Hospitalares) — alta complexidade
- [ ] Reformular healthbR como meta-pacote
- [ ] API para consumidores não-R

> **Sequência detalhada, critérios de prontidão e priorização:** ver
> `strategy-expansion-pt.md` (seções 8 e 9).  
> **Checklist completo de lançamento:** ver `strategy-dissemination-pt.md`
> (seção 8).

---

## 14. RECURSOS DO PROJETO

### FTP e URLs

| Recurso | URL |
|---------|-----|
| Microdados JSON (2020-2024) | `https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{mes}_{ano}.json.zip` |
| Microdados JSON (2025+) | `https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/PNI/json/vacinacao_{mes}_{ano}_json.zip` |
| Microdados CSV (fallback) | `https://arquivosdadosabertos.saude.gov.br/dados/dbbni/vacinacao_{mes}_{ano}_csv.zip` |
| Agregados .dbf | `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/` |
| Dicionários .cnv/.def | `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/` |
| TabNet cobertura | `http://tabnet.datasus.gov.br/cgi/dhdat.exe?bd_pni/cpnibr.def` |
| TabNet doses | `http://tabnet.datasus.gov.br/cgi/dhdat.exe?bd_pni/dpnibr.def` |
| SINASC (FTP) | `ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/` |

### URLs publicadas

| Recurso | URL |
|---------|-----|
| Hugging Face — SI-PNI Microdados | `https://huggingface.co/datasets/SidneyBissoli/sipni-microdados` |
| Hugging Face — SI-PNI COVID | `https://huggingface.co/datasets/SidneyBissoli/sipni-covid` |
| Hugging Face — SI-PNI Agregados Doses | `https://huggingface.co/datasets/SidneyBissoli/sipni-agregados-doses` |
| Hugging Face — SI-PNI Agregados Cobertura | `https://huggingface.co/datasets/SidneyBissoli/sipni-agregados-cobertura` |
| HF Space — Sync Status Dashboard | `https://huggingface.co/spaces/SidneyBissoli/healthbr-sync-status` |
| R2 endpoint (S3-compatível) | `https://<account-id>.r2.cloudflarestorage.com` |

### Documentos estratégicos do projeto

| Documento | Conteúdo |
|-----------|----------|
| `strategy-expansion-pt.md` | Ciclo de vida de módulos (6 fases), método de exploração, lições aprendidas, inventário de módulos, priorização |
| `strategy-dissemination-pt.md` | Divulgação, financiamento, template de README, checklist de lançamento |
| `strategy-synchronization.md` | Comparison engine, dashboard HF Spaces, manifesto no R2, integração com pacote R |
| `strategy-languages-pt.md` | Regras de idioma por tipo de artefato |
| `reference-pipelines-pt.md` | Manual de operação dos pipelines (arquitetura, números, comandos) |
| `harmonization-pt.md` | Mapeamento entre sistemas de códigos agregados ↔ microdados |

### Artefatos da exploração

| Artefato | Descrição |
|----------|-----------|
| `inventario_imuno_por_ano.csv` | Matriz 65 vacinas × 26 anos |
| `scripts/exploration/01-08` | 8 scripts exploratórios documentando descobertas |
| `docs/covid/exploration-pt.md` | Exploração completa do dataset COVID |
| `docs/sipni-agregados/exploration-pt.md` | Exploração dos agregados (doses) |
| `docs/sipni-agregados/exploration-cobertura-pt.md` | Exploração dos agregados (cobertura) |

### Documentos técnicos de referência (arquivos do projeto)

| Documento | Conteúdo |
|-----------|----------|
| `Regrascobertura2013.pdf` | Numeradores por vacina (APIDOS/APIWEB), regras 2012-2013 |
| `notatecnicaTx.pdf` | Fórmulas de taxa de abandono por vacina multidose |
| `notatecnicaCobertura.pdf` | Regras completas de cobertura por vacina, doses e notas |
| `notatecnica.pdf` | Origem dos dados, coberturas, população-alvo por período/UF |
| `Nota_Tecnica_Imunizacoes_Cobertura_desde_1994.pdf` | Tabela cobertura × imuno × dose × pop-alvo, indicadores compostos |
| `Imun_cobertura_desde_1994.pdf` | Mesma informação (layout diferente), tabela de imunobiológicos |
| `Nota_Tecnica_Imunizacoes_Doses_aplicadas_desde_1994.pdf` | Tabela completa: imunobiológicos × doses × faixas etárias × sexo |
| `Imun_doses_aplic_desde_1994.pdf` | Mesma informação (layout diferente) |

---

## 15. GLOSSÁRIO

| Termo | Significado |
|-------|-------------|
| SI-PNI | Sistema de Informação do Programa Nacional de Imunizações |
| RNDS | Rede Nacional de Dados em Saúde |
| DATASUS | Departamento de Informática do SUS |
| OpenDATASUS | Portal de dados abertos do Ministério da Saúde |
| SINASC | Sistema de Informações sobre Nascidos Vivos |
| IBGE | Instituto Brasileiro de Geografia e Estatística |
| API (sistema) | Sistema de Avaliação do PNI (antigo, não confundir com API web) |
| APIDOS | Sistema DOS de avaliação do PNI (até jun/2013) |
| APIWEB | Sistema web que substituiu APIDOS (a partir jul/2013) |
| SIPNI | SI-PNI novo (registra por indivíduo, não agregado) |
| TabWin/TabNet | Software/interface de tabulação do DATASUS |
| CRIE | Centros de Referência de Imunobiológicos Especiais |
| .dbf | Formato dBase III (usado pelos agregados antigos) |
| .cnv | Formato de conversão do TabWin (dicionário código→nome) |
| .def | Formato de definição de tabulação do TabWin |
| CNES | Cadastro Nacional de Estabelecimentos de Saúde |
| R2 | Cloudflare R2 (armazenamento S3-compatível, egress zero) |
| Arrow | Apache Arrow (biblioteca para leitura eficiente de Parquet) |
| Parquet | Formato colunar comprimido, padrão para big data |
| CPNI | Prefixo dos arquivos de Cobertura do PNI |
| DPNI | Prefixo dos arquivos de Doses do PNI |
| IMUNOCOB | Dicionário de indicadores compostos de cobertura |
| IMUNO.CNV | Dicionário de vacinas individuais (doses) |
| NV | Nascidos vivos |
| DU | Dose única |
| D1, D2, D3 | Primeira, segunda, terceira dose do esquema vacinal |
| REF1, REF2 | Primeiro e segundo reforço |
| Esq. Seq. | Esquema sequencial VIP/VOP |
| Penta | Pentavalente (DTP+HB+Hib) |
| Hexa | Hexavalente (DTPa+Hib+HB+VIP) — clínicas privadas |
| VORH | Vacina Oral de Rotavírus Humano |
| healthbr-data | Projeto guarda-chuva de redistribuição de dados de saúde pública do Brasil |
| Manifesto | Arquivo `manifest.json` no R2 com metadados de integridade por partição |
| Comparison engine | Script Python que compara metadados da fonte oficial com o manifesto no R2 |
| HF Spaces | Hugging Face Spaces — plataforma gratuita para hospedar apps Streamlit |
| Token read-only | Credencial de acesso ao R2 que só permite leitura de objetos |
| CC-BY 4.0 | Licença Creative Commons Atribuição 4.0 Internacional |
