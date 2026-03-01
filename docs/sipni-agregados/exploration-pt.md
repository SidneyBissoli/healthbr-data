# Exploração: Dados Agregados de Doses Aplicadas — SI-PNI (1994–2019)

> Documento consolidando a exploração dos arquivos DPNI (doses aplicadas)
> do FTP do DATASUS. Sintetiza descobertas dos scripts exploratórios
> `02-explore-aggregates.R`, `03-explore-helpers.R`,
> `04-check-structure-dpni.R`, `05-check-transitions-dpni.R` e
> `06-compare-typing.R`. Serve como base para o pipeline de produção.
>
> Criado em 26/fev/2026.
>
> **Documento relacionado:** `strategy-expansion-pt.md` — ciclo de vida,
> fases e critérios de avanço.

---

## 1. VISÃO GERAL

| Propriedade              | Valor                                                    |
|--------------------------|----------------------------------------------------------|
| Nome oficial             | Doses Aplicadas — Programa Nacional de Imunizações (PNI) |
| Fonte                    | FTP do DATASUS                                           |
| URL                      | `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/`  |
| Formato                  | .dbf (dBase III)                                         |
| Número de arquivos       | 752 (DPNI)                                               |
| Período                  | 1994–2019                                                |
| Granularidade            | 1 linha = total de doses por município × vacina × dose × faixa etária |
| Eras estruturais         | 3 (7 cols, 12 cols, 12 cols com município 6 dígitos)     |
| Dicionário principal     | `IMUNO.CNV` (85 vacinas individuais)                     |
| Destino no R2            | `s3://healthbr-data/sipni/agregados/doses/`              |

**Relação com os demais submódulos SI-PNI:**

| Submódulo                | Prefixo arquivo | Dicionário IMUNO | Status         |
|--------------------------|:---------------:|:----------------:|:--------------:|
| Microdados rotina (2020+)| —               | co_vacina        | ✅ Completo     |
| Microdados COVID (2021+) | —               | vacina_codigo    | Pipeline pronto |
| **Agregados doses**      | **DPNI**        | **IMUNO.CNV**    | **Este documento** |
| Agregados cobertura      | CPNI            | IMUNOCOB.DBF     | Fase 2–3       |

---

## 2. VIAS DE ACESSO AOS DADOS

### 2.1 FTP do DATASUS (ÚNICA FONTE)

```
URL dados:       ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/
URL dicionários: ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/
```

Não existe JSON, CSV ou API para os dados agregados 1994–2019. A única
forma de obter esses dados é baixar os .dbf do FTP ou usar o TabNet/TabWin
(que lê os mesmos .dbf). O OpenDATASUS não disponibiliza esses dados.

### 2.2 Nomenclatura dos arquivos

```
DPNI{UF}{AA}.DBF
```

Onde:  
- `DPNI` = Doses do PNI  
- `{UF}` = Sigla da UF (AC, AL, ..., TO) ou indicadores especiais:  
  - `UF` = consolidado por UF (1 linha por UF, sem municípios)  
  - `BR` = consolidado nacional  
  - `IG` = registros com UF ignorada/desconhecida  
- `{AA}` = Ano com 2 dígitos (94=1994, 00=2000, 19=2019)  

**Exemplos:**  
- `DPNIAC98.DBF` → Doses, Acre, 1998  
- `DPNISP15.DBF` → Doses, São Paulo, 2015  
- `DPNIUF07.DBF` → Doses consolidadas por UF, 2007  
- `DPNIBR12.DBF` → Doses consolidadas nacional, 2012  
- `DPNIIG04.DBF` → Doses com UF ignorada, 2004  

### 2.3 Volume e tipos de arquivo

752 arquivos DPNI no FTP, divididos em três categorias:

| Tipo | Prefixo | Arquivos | Conteúdo |
|------|---------|:--------:|----------|
| Estaduais | DPNI{UF}{AA} | 27 UFs × 26 anos = 702 | Granularidade municipal |
| Consolidado por UF | DPNIUF{AA} | 26 | Totais por UF, sem município |
| Consolidado nacional | DPNIBR{AA} | 26 | Todos os municípios do Brasil num único arquivo |
| UF ignorada | DPNIIG{AA} | 0 | **Não existem** (FTP retorna 550) |

**Descobertas da validação (Fase 4):**

- Arquivos DPNIIG não existem no FTP. Tentativas de download retornam
  FTP status 550 ("Requested action not taken; file unavailable").
- Arquivos de UFs ausentes nos primeiros anos (ex: DPNIMG94.DBF) não
  retornam erro — o FTP entrega um .dbf válido porém vazio (0 linhas,
  apenas header de ~257 bytes).
- Arquivos DPNIBR são grandes (DPNIBR98.DBF = 26 MB com 976.481 linhas;
  DPNIBR08.DBF = 295 MB, timeout em testes locais).
- Arquivos DPNIUF são leves (~140–460 KB).

Os **arquivos estaduais** são os que o pipeline processa (ver decisão
9.8 para justificativa da exclusão dos consolidados).

Tamanho individual dos estaduais: poucos KB (estados pequenos, anos
antigos) a alguns MB (SP, anos recentes). Estimativa de volume total de
registros (baseada em extrapolação do Acre): na ordem de dezenas de
milhões de linhas ao empilhar os 702 arquivos estaduais.

---

## 3. ESTRUTURA DOS DADOS

### 3.1 Três eras estruturais

Os arquivos DPNI passaram por duas transições estruturais ao longo de
26 anos. A exploração sistemática dos 26 anos do Acre (script
`05-check-transitions-dpni.R`) identificou os pontos exatos de mudança.

#### Era 1: 1994–2003 (7 colunas)

| Coluna     | Tipo R    | Descrição                                  | Exemplo        |
|------------|:---------:|-------------------------------------------|----------------|
| `ANO`      | integer   | Ano de referência                          | `1998`         |
| `UF`       | character | Código UF (2 dígitos)                      | `12`           |
| `MUNIC`    | character | Código município IBGE (**7 dígitos**)      | `1200401`      |
| `FX_ETARIA`| character | Código faixa etária (dicionário FXET.CNV)  | `01`           |
| `IMUNO`    | character | Código vacina (dicionário IMUNO.CNV)       | `02`           |
| `DOSE`     | character | Código tipo de dose (dicionário DOSE.CNV)  | `01`           |
| `QT_DOSE`  | integer   | Quantidade de doses aplicadas              | `245`          |

#### Era 2: 2004–2012 (12 colunas)

| Coluna     | Tipo R    | Descrição                                  | Exemplo        |
|------------|:---------:|-------------------------------------------|----------------|
| `ANO`      | character | Ano de referência (mudou de integer)       | `"2005"`       |
| `UF`       | character | Código UF                                  | `"12"`         |
| `MUNIC`    | character | Código município IBGE (**7 dígitos**)      | `"1200401"`    |
| `FX_ETARIA`| character | Código faixa etária                        | `"01"`         |
| `IMUNO`    | character | Código vacina                              | `"52"`         |
| `DOSE`     | character | Código tipo de dose                        | `"01"`         |
| `QT_DOSE`  | integer   | Quantidade de doses aplicadas              | `389`          |
| `ANOMES`   | character | Ano-mês (YYYYMM)                          | `"200501"`     |
| `MES`      | character | Mês (01–12)                                | `"01"`         |
| `DOSE1`    | integer   | Primeiras doses (para cálculo de abandono) | `120`          |
| `DOSEN`    | integer   | Últimas doses                              | `98`           |
| `DIFER`    | integer   | Diferença D1 − DN (abandono)               | `22`           |

**Novidades em relação à Era 1:** granularidade mensal (ANOMES, MES) e
campos para taxa de abandono (DOSE1, DOSEN, DIFER).

#### Era 3: 2013–2019 (12 colunas)

Mesmas 12 colunas da Era 2, com uma diferença crítica:

| Mudança                     | Era 2 (2004–2012)  | Era 3 (2013–2019) |
|-----------------------------|--------------------|---------------------|
| Código município            | **7 dígitos** (com verificador) | **6 dígitos** (sem verificador) |

Exemplo: município de Rio Branco (AC)  
- Era 2: `1200401` (7 dígitos, último dígito = verificador IBGE)  
- Era 3: `120040` (6 dígitos, padrão IBGE atual)  

### 3.2 Resumo das transições

| Transição      | Quando      | O que muda                                      |
|:--------------:|:-----------:|-------------------------------------------------|
| Era 1 → Era 2 | 2003 → 2004 | 7 → 12 colunas; ANO integer → character; surgem ANOMES, MES, DOSE1, DOSEN, DIFER |
| Era 2 → Era 3 | 2012 → 2013 | Código município 7 → 6 dígitos                 |

### 3.3 Tipo de ANO

| Período   | Tipo R de ANO | Exemplo     |
|:---------:|:-------------:|:-----------:|
| 1994–2003 | integer       | `1998`      |
| 2004–2019 | character     | `"2005"`    |

Essa mudança é relevante para o pipeline: ao empilhar, ANO precisa ser
normalizado para character em todos os anos.

---

## 4. DICIONÁRIOS

### 4.1 Localização

```
ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/
```

Conteúdo do diretório (inventário feito no script `02-explore-aggregates.R`
e `03-explore-helpers.R`):  
- 17 arquivos `.cnv` (conversão código → nome, formato proprietário TabWin)  
- 62 arquivos `.def` (definição de tabulação TabWin)  
- 1 arquivo `.dbf` (`IMUNOCOB.DBF` — dicionário de cobertura)  

### 4.2 IMUNO.CNV — dicionário de vacinas (doses)

Este é o dicionário principal para os arquivos DPNI. Contém 85 entradas
mapeando código numérico → nome da vacina. Formato .cnv do TabWin: a
primeira linha indica número de entradas e largura do campo; as linhas
seguintes contêm código posicional e descrição.

Exemplos de entradas:

| Código | Descrição                                    |
|:------:|----------------------------------------------|
| `02`   | BCG                                          |
| `05`   | DTP (Tríplice Bacteriana)                    |
| `06`   | Febre Amarela                                |
| `08`   | Hepatite B                                   |
| `09`   | Sarampo                                      |
| `21`   | Tetravalente (DTP/Hib)                       |
| `39`   | Tríplice Viral                               |
| `42`   | Pneumo 10V                                   |
| `43`   | Meningo C conjugada                          |
| `46`   | Rotavírus Humano                             |
| `52`   | Pentavalente (DTP+HB+Hib)                   |
| `60`   | Hexavalente                                  |
| `61`   | Rotavírus                                    |

### 4.3 Outros .cnv relevantes para DPNI

| Arquivo     | Campo correspondente | Conteúdo                        |
|-------------|:--------------------:|---------------------------------|
| `DOSE.CNV`  | `DOSE`               | Tipos de dose (D1, D2, DU, REF) |
| `FXET.CNV`  | `FX_ETARIA`          | Faixas etárias                   |
| `TP_UF.CNV` | `UF`                 | Códigos de UF                    |

### 4.4 Arquivos .def (definições de tabulação)

Os `.def` não são dados — são metadados do TabWin que definem quais .cnv
se aplicam a quais campos dos .dbf. Úteis como documentação de referência,
mas não necessários para o pipeline. Exemplo de `dpnibr.def`: indica que
o campo IMUNO usa `IMUNO.CNV`, DOSE usa `DOSE.CNV`, etc.

### 4.5 IMUNOCOB.DBF (dicionário de cobertura — NÃO se aplica a doses)

Contém 26 indicadores compostos de cobertura. Cada código representa uma
agregação de múltiplas vacinas (ex: "Hepatite B total" = HB + Penta + Hexa).
**Este dicionário é usado pelos arquivos CPNI (cobertura), não pelos DPNI
(doses).** Documentado aqui apenas para referência cruzada.

---

## 5. EVOLUÇÃO DOS CÓDIGOS DE VACINA (1994–2019)

A análise do Acre ao longo de 26 anos (script `02-explore-aggregates.R`)
revelou 65 códigos IMUNO distintos, refletindo a evolução do calendário
vacinal brasileiro. Três gerações de vacinas são visíveis:

### 5.1 Primeira geração (1994–2003)

Vacinas isoladas do calendário original: BCG, DTP, Sarampo monovalente,
Polio (VOP), Hepatite B, Febre Amarela, dT adulto, Hib (a partir de 1999).

### 5.2 Segunda geração (2004–2012)

Vacinas combinadas substituem as isoladas: Tetravalente (DTP/Hib) substitui
DTP+Hib separadas; surgem Rotavírus (2006), Pneumo 10V e Meningo C (2010).

### 5.3 Terceira geração (2013–2019)

Pentavalente substitui Tetravalente; VIP entra no esquema sequencial com
VOP; surgem Tetraviral, Hepatite A (2014), e a Hexavalente (clínicas
privadas e CRIEs).

### 5.4 Códigos transitórios

Alguns códigos aparecem apenas 1–3 anos, correspondendo a campanhas
pontuais (H1N1, multivacinação, MRC) ou a períodos de transição entre
formulações.

### 5.5 Matriz IMUNO × ano

A matriz completa de presença/ausência de cada código IMUNO por ano foi
exportada pelo script `02-explore-aggregates.R` como
`inventario_imuno_por_ano.csv`. Essa matriz é essencial para validação do
pipeline e para a harmonização com os microdados 2020+.

---

## 6. EVOLUÇÃO DE FX_ETARIA E DOSE

### 6.1 FX_ETARIA

As faixas etárias variam ao longo do tempo, com novas faixas surgindo e
outras desaparecendo conforme o calendário vacinal incorpora novos grupos
populacionais. A exploração do Acre (script `02-explore-aggregates.R`)
mapeou essas transições ano a ano. As faixas vão de códigos como `01`
(< 1 ano) a códigos de faixas mais velhas. A partir de 2013, FX_ETARIA
continua presente nos DPNI (diferente dos CPNI, onde desaparece).

### 6.2 DOSE

Os tipos de dose incluem: `01` (1ª dose), `02` (2ª dose), `03` (3ª dose),
`04` (1º reforço), `05` (2º reforço), `06` (dose única), entre outros.
O dicionário completo está em `DOSE.CNV`. Os códigos são estáveis ao longo
de todo o período.

---

## 7. DADOS AUSENTES NOS PRIMEIROS ANOS

Confirmado via `project-pt.md` (seção 7):

| Ano  | UFs sem dados                                                     |
|:----:|-------------------------------------------------------------------|
| 1994 | AL, AP, DF, MS, MG, PB, PR, RJ, RS, SP, SE, TO (12 UFs)        |
| 1995 | MS, MG, TO (3 UFs)                                               |
| 1996 | MG (1 UF)                                                         |
| 1997+| Todas as UFs disponíveis                                          |

Nos primeiros anos, arquivos de UFs ausentes não retornam erro FTP —
o servidor entrega um .dbf válido porém vazio (0 linhas, ~257 bytes de
header). O pipeline detecta esses arquivos por `nrow(df) == 0` e os
ignora silenciosamente.

---

## 8. ARTEFATOS E PROBLEMAS IDENTIFICADOS

### 8.1 Código de município 7 → 6 dígitos

A descontinuidade mais relevante. Até 2012, `MUNIC` contém o código IBGE
completo com dígito verificador (7 dígitos). A partir de 2013, contém
apenas 6 dígitos (sem verificador). O padrão IBGE moderno usa 6 dígitos.

**Tratamento:** os dados são publicados como estão na fonte (7 dígitos até
2012, 6 dígitos a partir de 2013). A normalização para 6 dígitos
(remoção do verificador) é uma transformação determinística que fica a
cargo do pacote R, não do pipeline de publicação (ver decisão 9.6).

### 8.2 Tipo de ANO (integer vs character)

ANO é integer em 1994–2003 e character em 2004–2019. No Parquet final,
tudo será character (decisão do projeto: todos os campos como string).

### 8.3 Estrutura dos consolidados (UF, BR, IG)

A validação da Fase 4 revelou que os arquivos consolidados têm
estruturas distintas dos estaduais:

**DPNIUF (consolidado por UF):** 6 colunas — ANO, UF, FX_ETARIA, IMUNO,
DOSE, QT_DOSE. **Não contém MUNIC** (totais já agregados por UF), nem
ANOMES, MES, DOSE1, DOSEN, DIFER (mesmo na Era 2–3). Schema próprio que
não existe em nenhuma das 3 eras dos estaduais.

**DPNIBR (consolidado nacional):** 7 colunas na Era 1 (1998 testado) —
mesmo schema dos estaduais da Era 1, com MUNIC presente. É o Brasil
inteiro com granularidade municipal num único arquivo. DPNIBR98 tem
976.481 linhas (26 MB); DPNIBR08 tem 295 MB (não confirmado o schema
da Era 2 por timeout no download).

**DPNIIG (UF ignorada):** **Não existem.** Tentativas de download
retornam FTP 550 ("file unavailable").

Essas descobertas motivaram a decisão de excluir os consolidados do
pipeline (ver decisão 9.8).

### 8.4 Sem artefatos de float

Diferente dos CSVs de microdados (2020–2024), os .dbf não apresentam
artefatos de serialização como sufixo `.0` ou perda de zeros à esquerda.
O formato .dbf preserva os tipos nativamente. `foreign::read.dbf()` com
`as.is = TRUE` retorna tudo como character (para campos texto) ou integer
(para campos numéricos), sem distorções.

---

## 9. DECISÕES ESTRUTURANTES (Fase 3)

### 9.1 Formato fonte

| Critério                      | .dbf (único disponível)           |
|-------------------------------|-----------------------------------|
| Formato preserva dados?       | Sim — sem artefatos               |
| Alternativas existem?         | Não — FTP é a única fonte         |
| Decisão                       | **Usar .dbf diretamente**         |

Não há trade-off aqui: o .dbf é a única fonte. Diferente dos microdados
(onde existiam CSV e JSON), não existe escolha de formato.

### 9.2 Ferramenta de leitura

| Ferramenta            | Prós                               | Contras                          |
|-----------------------|------------------------------------|----------------------------------|
| `foreign::read.dbf()` | Nativo em R, sem dependências extras; `as.is=TRUE` preserva strings | Lento para arquivos grandes; single-threaded |
| Python + dbfread      | Mais rápido para volumes grandes   | Dependência Python, mais complexidade |

**Decisão: `foreign::read.dbf()`** em R. Justificativa: os arquivos .dbf
dos agregados são pequenos individualmente (KB a poucos MB). O gargalo
será o download FTP, não a leitura. A simplicidade do pipeline em R puro
compensa. Se a performance for insuficiente, migrar para Python é
reversível.

Nota: para os microdados, a decisão foi Python (jq + polars) porque os
JSONs chegam a centenas de MB comprimidos. Os .dbf dos agregados são
ordens de grandeza menores.

### 9.3 Tipos no Parquet

**Decisão: tudo character (string).** Consistente com a decisão
estabelecida para os microdados e com o princípio do projeto de preservar
dados exatamente como o Ministério fornece.

Isso significa que campos como `QT_DOSE`, `DOSE1`, `DOSEN`, `DIFER` e
`ANO` (que são integer no .dbf) serão convertidos para character no
Parquet. A tipagem para análise fica a cargo do pacote R `sipni` ou do
pesquisador.

### 9.4 Particionamento no R2

```
s3://healthbr-data/sipni/agregados/doses/
  ano=1994/uf=AC/
    part-0.parquet
  ano=1994/uf=AL/
    part-0.parquet
  ...
  ano=2019/uf=TO/
    part-0.parquet
```

**Decisão: particionamento Hive `ano={YYYY}/uf={UF}/`.**

Justificativa:  
- Consistente com os microdados (`ano=/mes=/uf=`)  
- Os .dbf já vêm por UF e ano — mapeamento direto  
- `ano=` e `uf=` são os filtros mais comuns em consultas de cobertura  
- Sem partição por `mes=` porque a Era 1 (1994–2003) não tem granularidade
  mensal. A coluna ANOMES (quando presente) fica dentro do Parquet.  

**Apenas arquivos estaduais** (27 UFs) são publicados. Consolidados
(UF, BR, IG) são excluídos — ver decisão 9.8 para justificativa.

### 9.5 Tratamento das 3 eras

**Decisão: publicar cada era com seu schema original, sem fabricar colunas
inexistentes.**

Os dados de 1994–2003 têm 7 colunas porque o Ministério os publicou com
7 colunas. Os dados de 2004–2019 têm 12 colunas porque o Ministério
adicionou 5 campos nesse período. Publicar os dados com colunas NA
fabricadas para forçar um schema unificado seria criar um derivado nosso,
não mais o documento original do Ministério — exatamente o tipo de
transformação que o projeto se propõe a evitar (ver seção 9 do
`project-pt.md`).

**Era 1 (1994–2003) — 7 colunas:**

| Coluna     | Tipo Parquet |
|------------|:------------:|
| ANO        | string (*)   |
| UF         | string       |
| MUNIC      | string       |
| FX_ETARIA  | string       |
| IMUNO      | string       |
| DOSE       | string       |
| QT_DOSE    | string (*)   |

**Era 2–3 (2004–2019) — 12 colunas:**

| Coluna     | Tipo Parquet |
|------------|:------------:|
| ANO        | string       |
| UF         | string       |
| MUNIC      | string       |
| FX_ETARIA  | string       |
| IMUNO      | string       |
| DOSE       | string       |
| QT_DOSE    | string (*)   |
| ANOMES     | string       |
| MES        | string       |
| DOSE1      | string (*)   |
| DOSEN      | string (*)   |
| DIFER      | string (*)   |

(*) Campos originalmente integer no .dbf, convertidos para string no
Parquet conforme decisão do projeto.

A harmonização entre eras (unificar as duas estruturas para análise
contínua 1994–2019) fica a cargo do pacote R, não dos dados publicados.
O `open_dataset()` do Arrow aceita schemas diferentes com
`unify_schemas = TRUE`, e o pacote R pode abstrair essa complexidade
para o pesquisador.

### 9.6 Tratamento do código de município

**Decisão: manter o código de município exatamente como o Ministério
publicou.** 1994–2012 com 7 dígitos; 2013–2019 com 6 dígitos.

Pela mesma lógica de fidelidade à fonte que governa o tratamento das eras,
o pipeline não deve truncar o código de município. O 7º dígito (verificador
IBGE) está nos dados originais e deve ser preservado. A normalização para
6 dígitos (remoção do verificador) é uma transformação — ainda que
determinística — e pertence ao pacote R, não aos dados publicados.

O pesquisador que usar `open_dataset()` diretamente verá exatamente o que
o Ministério disponibilizou. O pacote R abstrairá a normalização
automaticamente quando necessário.

### 9.7 Estrutura de destino no R2

```
s3://healthbr-data/
  sipni/
    agregados/
      doses/                          ← ESTE SUBMÓDULO
        ano=1994/uf=AC/
          part-0.parquet
        ...
        ano=2019/uf=TO/
          part-0.parquet
        README.md                     ← dataset card (Fase 5)
      cobertura/                      ← submódulo futuro
        ...
    microdados/                       ← já existe
      ...
    dicionarios/                      ← submódulo futuro
      ...
```

### 9.8 Tabela consolidada de decisões

| # | Decisão                    | Escolha                        | Alternativa rejeitada          | Motivo                                      |
|:-:|----------------------------|--------------------------------|--------------------------------|---------------------------------------------|
| 1 | Formato fonte              | .dbf (único disponível)        | —                              | Sem alternativa                             |
| 2 | Ferramenta de leitura      | R (`foreign::read.dbf`)        | Python (dbfread)               | Arquivos pequenos; simplicidade; reversível |
| 3 | Tipos no Parquet           | Tudo character                 | Tipagem seletiva               | Consistência com projeto; preserva dados    |
| 4 | Particionamento            | `ano=/uf=/`                    | `ano=/uf=/mes=`                | Era 1 sem mês; mapeamento direto dos .dbf   |
| 5 | Schema                     | Schema original por era (7 cols / 12 cols) | Schema unificado com NAs fabricados | Fidelidade à fonte; não criar derivados   |
| 6 | Código município           | Manter como na fonte (7d ou 6d) | Truncar para 6 dígitos          | Fidelidade à fonte; normalização no pacote R |
| 7 | ANO (integer → character)  | Converter para character        | Manter integer                 | Decisão global: tudo string                 |
| 8 | Consolidados (UF/BR/IG)   | Excluir do pipeline            | Incluir com uf=UF/BR/IG        | Ver justificativa abaixo                    |

### 9.9 Exclusão dos consolidados (UF, BR, IG)

**Decisão: não publicar os arquivos consolidados no R2.** Apenas os 27
arquivos estaduais por ano são processados.

**Racional:**

1. **DPNIIG (UF ignorada) não existe.** O FTP retorna status 550 para
   todos os anos testados. Não há o que publicar.

2. **DPNIBR (consolidado nacional) é redundante.** O arquivo BR contém
   exatamente os mesmos registros municipais que os 27 arquivos estaduais
   somados. DPNIBR98 tem 976.481 linhas — a soma dos 27 estaduais de
   1998. Publicá-lo duplicaria dados no R2 sem adicionar informação.
   Qualquer pesquisador que precise do Brasil inteiro pode usar
   `open_dataset()` sem filtro de UF.

3. **DPNIUF (consolidado por UF) é redundante e tem schema diferente.**
   Contém apenas 6 colunas (sem MUNIC, sem ANOMES/MES/DOSE1/DOSEN/DIFER)
   — um schema que não existe em nenhuma das 3 eras dos arquivos
   estaduais. Os totais por UF são uma agregação trivial que qualquer
   pesquisador pode reproduzir com `group_by(ANO, UF) |>
   summarise(QT_DOSE = sum(as.numeric(QT_DOSE)))` sobre os dados
   municipais. Incluir esses arquivos adicionaria um quarto schema ao
   dataset sem valor informacional novo, aumentando complexidade para
   o pesquisador que usar `open_dataset()`.

**Nota:** se no futuro houver demanda por acesso rápido a totais por UF
sem agregação, o pacote R pode oferecer uma função que faça isso. A
decisão é reversível — os .dbf continuam no FTP do DATASUS.

### 9.10 Tempo de bootstrap estimado

Os .dbf são leves. O gargalo é o download de 752 arquivos via FTP
(protocolo lento, conexão sequencial). Estimativa:
- Download: 1–3 horas (depende da velocidade do FTP do DATASUS e do
  servidor de execução)
- Leitura + conversão + upload: < 1 hora
- **Total estimado: 2–4 horas no Hetzner**

Comparação: o bootstrap dos microdados leva ~22 horas. Os agregados são
pelo menos 5x mais rápidos.

### 9.11 Infraestrutura

Mesmo servidor Hetzner (CPX42) e mesmo bucket R2 dos microdados. Não
requer infraestrutura adicional. O pipeline pode rodar como script R
standalone — sem necessidade do stack Python/jq/polars que foi necessário
para os microdados.

---

## 10. QUESTÕES EM ABERTO

1. **Volume exato de registros:** a estimativa por extrapolação do Acre é
   grosseira. O volume real será conhecido após o bootstrap. Não é
   bloqueante para iniciar o pipeline.

2. ~~**Arquivos UF/BR/IG:** confirmar se a estrutura de colunas é idêntica
   aos arquivos por estado.~~ **Respondida na Fase 4:** estruturas são
   diferentes (UF tem 6 colunas sem MUNIC; BR tem schema de estadual
   mas é redundante; IG não existe). Consolidados excluídos do pipeline
   (decisão 9.8/9.9).

3. **Pipeline unificado doses + cobertura:** o `strategy-expansion-pt.md`
   sugere avaliar se faz sentido um pipeline unificado para DPNI e CPNI.
   A resposta depende de quão similares são os formatos (mesma leitura
   .dbf, mesmo FTP, mesma lógica de download — diferem apenas nos campos).
   Decisão adiada para quando a exploração de cobertura for formalizada.

4. **Validação cruzada:** após o bootstrap, comparar contagens agregadas
   com o TabNet para validar integridade. Exemplo: total de doses BCG
   no Brasil em 2010 deve bater com o TabNet.

---

## 11. SCRIPTS EXPLORATÓRIOS DE REFERÊNCIA

| Script                         | O que explora                                      |
|--------------------------------|----------------------------------------------------|
| `02-explore-aggregates.R`      | Evolução de IMUNO, FX_ETARIA, DOSE ao longo de 1994–2019 (Acre); .cnv e .def; volume; amostra visual |
| `03-explore-helpers.R`         | IMUNOCOB.DBF (cobertura); arquivos .def (tabulação TabWin); inventário de .cnv |
| `04-check-structure-dpni.R`    | Estrutura de 3 épocas de DPNI (1998, 2005, 2018); colunas, tipos, valores únicos |
| `05-check-transitions-dpni.R`  | Transições exatas: colunas (7→12), município (7→6 dígitos), tipo de ANO; todos os 26 anos do Acre |
| `06-compare-typing.R`          | Diagnóstico de tipagem por variável nos agregados (3 eras) e microdados; sugestão de tipos |

---

## 12. PRÓXIMOS PASSOS

O pipeline foi desenvolvido e validado na Fase 4. Script disponível em
`scripts/pipeline/sipni-agregados-doses-pipeline-r.R`.

**Testes realizados (Fase 4):**
- Leitura e conversão de .dbf das 3 eras (AC 1998, 2008, 2018) ✔
- Gravação e leitura de Parquet particionado (schemas preservados) ✔
- `open_dataset(unify_schemas = TRUE)` com eras misturadas ✔
- Detecção de .dbf vazio para UF ausente (MG 1994) ✔
- Mapeamento dos consolidados (UF, BR, IG) e decisão de exclusão ✔

**Próximas etapas:**

1. Executar bootstrap completo no Hetzner
2. Validar contagens contra TabNet
3. Validar exclusão dos consolidados: comparar `sum(QT_DOSE)` por ano
   nos 27 estaduais com o DPNIBR correspondente, para confirmar que o
   BR é de fato a soma dos estaduais e não contém registros adicionais
4. Criar controle de versão (`data/controle_versao_sipni_agregados_doses.csv`)
5. Documentar pipeline no `reference-pipelines-pt.md`
6. Avançar para Fase 5 (publicação: README, dataset card)

---

*Última atualização: 26/fev/2026.*
