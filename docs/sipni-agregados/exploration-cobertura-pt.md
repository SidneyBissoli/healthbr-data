# Exploração: Dados Agregados de Cobertura Vacinal — SI-PNI (1994–2019)

> Documento consolidando a exploração dos arquivos CPNI (cobertura vacinal)
> do FTP do DATASUS. Sintetiza descobertas da sessão de exploração
> sistemática que baixou e inspecionou todos os 26 arquivos CPNI do Acre
> (1994–2019), amostras de consolidados (UF, BR, IG) e validou a
> equivalência BR = soma dos estaduais. Serve como base para o pipeline
> de produção.
>
> Criado em 27/fev/2026.
>
> **Documentos relacionados:**
> - `strategy-expansion-pt.md` — ciclo de vida, fases e critérios de
>   avanço.
> - `docs/sipni-agregados/exploration-pt.md` — exploração dos dados de
>   **doses** (DPNI). Documento irmão; este documento segue a mesma
>   estrutura.
> - `reference-pipelines-pt.md` — infraestrutura compartilhada e
>   documentação dos pipelines existentes.

---

## 1. VISÃO GERAL

| Propriedade              | Valor                                                      |
|--------------------------|------------------------------------------------------------|
| Nome oficial             | Cobertura Vacinal — Programa Nacional de Imunizações (PNI) |
| Fonte                    | FTP do DATASUS                                             |
| URL                      | `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/`    |
| Formato                  | .dbf (dBase III)                                           |
| Número de arquivos       | 752 (CPNI)                                                 |
| Período                  | 1994–2019                                                  |
| Granularidade            | 1 linha = cobertura por município × vacina (× dose × faixa etária até 2012) |
| Eras estruturais         | 2 schemas: 9 cols (1994–2012), 7 cols (2013–2019)          |
| Dicionário principal     | `IMUNOCOB.DBF` (26 indicadores compostos de cobertura)     |
| Destino no R2            | `s3://healthbr-data/sipni/agregados/cobertura/`            |

**Relação com os demais submódulos SI-PNI:**

| Submódulo                | Prefixo arquivo | Dicionário       | Status          |
|--------------------------|:---------------:|:----------------:|:---------------:|
| Microdados rotina (2020+)| —               | co_vacina        | ✅ Completo      |
| Microdados COVID (2021+) | —               | vacina_codigo    | Pipeline pronto |
| Agregados doses          | DPNI            | IMUNO.CNV        | Bootstrap OK    |
| **Agregados cobertura**  | **CPNI**        | **IMUNOCOB.DBF** | **Este documento** |

---

## 2. VIAS DE ACESSO AOS DADOS

### 2.1 FTP do DATASUS (ÚNICA FONTE)

```
URL dados:       ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/DADOS/
URL dicionários: ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/
```

Não existe JSON, CSV ou API para os dados agregados de cobertura. A única
forma de obter esses dados é baixar os .dbf do FTP ou usar o
TabNet/TabWin. O OpenDATASUS não disponibiliza esses dados.

### 2.2 Nomenclatura dos arquivos

```
CPNI{UF}{AA}.DBF
```

Onde:
- `CPNI` = Cobertura do PNI
- `{UF}` = Sigla da UF (AC, AL, ..., TO) ou indicadores especiais:
  - `UF` = consolidado por UF (1 linha por UF, sem municípios)
  - `BR` = consolidado nacional
  - `IG` = registros com UF ignorada/desconhecida
- `{AA}` = Ano com 2 dígitos (94=1994, 00=2000, 19=2019)

**Exemplos:**
- `CPNIAC98.DBF` → Cobertura, Acre, 1998
- `CPNISP15.DBF` → Cobertura, São Paulo, 2015
- `CPNIUF07.DBF` → Cobertura consolidada por UF, 2007
- `CPNIBR12.DBF` → Cobertura consolidada nacional, 2012

### 2.3 Volume e tipos de arquivo

752 arquivos CPNI no FTP, divididos em três categorias:

| Tipo | Prefixo | Arquivos | Conteúdo |
|------|---------|:--------:|----------|
| Estaduais | CPNI{UF}{AA} | 27 UFs × 26 anos = 702 | Granularidade municipal |
| Consolidado por UF | CPNIUF{AA} | 26 | Totais por UF, sem município |
| Consolidado nacional | CPNIBR{AA} | 26 | Todos os municípios do Brasil num único arquivo |
| UF ignorada | CPNIIG{AA} | 0–26 | **Não existem ou vazios** |

**Descobertas da exploração:**

- Arquivos CPNIIG não existem no FTP para a maioria dos anos (download
  falha). Para 2018, o FTP entrega um .dbf vazio (0 linhas, 258 bytes
  de header).
- Arquivos de UFs ausentes nos primeiros anos (mesmas 12 UFs de 1994
  que no DPNI) retornam .dbf válido porém vazio (0 linhas, ~323 bytes
  de header).
- Arquivos CPNIBR contêm exatamente os mesmos registros municipais que
  os 27 estaduais somados (validado: CPNIBR98 = 49.561 linhas = soma
  dos 27 estaduais de 1998, diferença zero).
- CPNIUF tem schema diferente dos estaduais: 8 colunas (sem MUNIC).
- CPNIBR08 contém valores de DOSE extras (D1, D3, SD) não presentes
  nos arquivos estaduais, sugerindo que consolidados podem incluir
  processamento adicional além da simples agregação.

Tamanho individual dos estaduais: 8–122 KB (muito menores que os DPNI).
Volume total estimado: ~3 milhões de registros ao empilhar os 702
arquivos estaduais (vs 84 milhões do DPNI doses).

---

## 3. ESTRUTURA DOS DADOS

### 3.1 Duas eras estruturais

Diferente do DPNI que tem 3 eras (7→12→12 colunas), o CPNI tem apenas
**2 schemas distintos**. A Era 1 e a Era 2 compartilham o mesmo schema
de 9 colunas; a mudança estrutural ocorre apenas em 2013.

#### Era 1–2: 1994–2012 (9 colunas)

| Coluna     | Tipo R (Era 1) | Tipo R (Era 2) | Descrição                                  | Exemplo        |
|------------|:--------------:|:--------------:|-------------------------------------------|----------------|
| `ANO`      | integer        | character      | Ano de referência                          | `1998` / `"2008"` |
| `UF`       | integer        | character      | Código UF (2 dígitos)                      | `12` / `"12"`  |
| `MUNIC`    | character      | character      | Código município IBGE (**7 dígitos**)      | `"1200401"`    |
| `FX_ETARIA`| character      | character      | Código faixa etária (dicionário FXET.CNV)  | `"50"`         |
| `IMUNO`    | character      | character      | Código indicador cobertura (IMUNOCOB.DBF)  | `"072"`        |
| `DOSE`     | character      | character      | Código tipo de dose (dicionário DOSE.CNV)  | `"01"`         |
| `QT_DOSE`  | integer        | character      | Quantidade de doses aplicadas              | `63` / `"188"` |
| `POP`      | integer        | character      | População-alvo (denominador)               | `158` / `"273"` |
| `COBERT`   | **numeric**    | **numeric**    | Cobertura pré-calculada pelo MS (%)        | `39.87`        |

**Nota sobre tipos:** ANO, UF, QT_DOSE e POP mudam de integer para
character na transição 2003→2004 (mesmo comportamento do DPNI). COBERT
permanece numeric com ponto decimal em todo o período 1994–2012.

#### Era 3: 2013–2019 (7 colunas)

| Coluna     | Tipo R    | Descrição                                  | Exemplo        |
|------------|:---------:|-------------------------------------------|----------------|
| `ANO`      | character | Ano de referência                          | `"2018"`       |
| `UF`       | character | Código UF                                  | `"12"`         |
| `MUNIC`    | character | Código município IBGE (**6 dígitos**)      | `"120040"`     |
| `IMUNO`    | character | Código indicador cobertura (IMUNOCOB.DBF)  | `"000"`        |
| `QT_DOSE`  | character | Quantidade de doses aplicadas              | `"144"`        |
| `POP`      | character | População-alvo (denominador)               | `"222"`        |
| `COBERT`   | **character** | Cobertura (%) com **vírgula** como decimal | `"64,86"`  |

**Colunas removidas em 2013:** `FX_ETARIA` e `DOSE` desaparecem
completamente. A cobertura passa a ser reportada sem desagregação por
faixa etária ou tipo de dose — apenas por município × indicador.

### 3.2 Resumo das transições

| Transição       | Quando      | O que muda                                           |
|:---------------:|:-----------:|------------------------------------------------------|
| Tipos internos  | 2003 → 2004 | ANO, UF, QT_DOSE, POP: integer → character           |
| Estrutural      | 2012 → 2013 | 9 → 7 colunas (perda de FX_ETARIA e DOSE);           |
|                 |             | município 7 → 6 dígitos;                             |
|                 |             | COBERT: numeric (ponto) → character (vírgula)         |

A transição de 2013 é a mais significativa do CPNI: muda simultaneamente
o schema, o formato do município e o tipo/formato de COBERT.

### 3.3 Comparação com DPNI (doses)

| Aspecto                  | DPNI (doses)               | CPNI (cobertura)              |
|--------------------------|----------------------------|-------------------------------|
| Eras                     | 3 (7→12→12 cols)           | 2 (9→7 cols)                  |
| Transição em 2004        | Ganha 5 colunas            | Nenhuma mudança estrutural    |
| Transição em 2013        | Só município 7→6d          | Perde 2 cols + município + COBERT |
| Campos exclusivos        | ANOMES, MES, DOSE1, DOSEN, DIFER | POP, COBERT              |
| Campos compartilhados    | ANO, UF, MUNIC, FX_ETARIA*, IMUNO, DOSE*, QT_DOSE | idem |
| Dicionário IMUNO         | IMUNO.CNV (vacinas individuais) | IMUNOCOB.DBF (indicadores compostos) |
| Volume estimado          | 84M registros              | ~3M registros                 |

(*) FX_ETARIA e DOSE existem em ambos, mas desaparecem do CPNI em 2013
enquanto permanecem no DPNI.

---

## 4. DICIONÁRIOS

### 4.1 IMUNOCOB.DBF — dicionário de indicadores de cobertura

Diferente do DPNI (que usa IMUNO.CNV com vacinas individuais), os
arquivos CPNI usam o dicionário IMUNOCOB.DBF, que contém **indicadores
compostos de cobertura**. Cada código representa uma fórmula de cálculo
que pode agregar múltiplas vacinas.

Localização: `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/IMUNOCOB.DBF`

O dicionário contém 26 entradas (explorado no script
`03-explore-helpers.R`). Os códigos usados nos CPNI estaduais ao longo
de 26 anos somam **64 códigos únicos**, muitos dos quais surgiram
apenas na Era 3 (2013–2019) com a reformulação do sistema de
indicadores do PNI.

### 4.2 Outros dicionários relevantes

| Arquivo     | Campo correspondente | Período de uso | Conteúdo                        |
|-------------|:--------------------:|:--------------:|---------------------------------|
| `DOSE.CNV`  | `DOSE`               | 1994–2012      | Tipos de dose (D1, D2, DU, REF) |
| `FXET.CNV`  | `FX_ETARIA`          | 1994–2012      | Faixas etárias                   |
| `TP_UF.CNV` | `UF`                 | 1994–2019      | Códigos de UF                    |

DOSE.CNV e FXET.CNV são relevantes apenas para a Era 1–2, já que esses
campos desaparecem na Era 3.

---

## 5. EVOLUÇÃO DOS CÓDIGOS IMUNO (1994–2019)

64 códigos IMUNO distintos ao longo de 26 anos. Os indicadores de
cobertura evoluíram significativamente, refletindo mudanças no calendário
vacinal e no sistema de monitoramento do PNI.

### 5.1 Era 1 (1994–2003): 8–15 indicadores

Período estável com indicadores clássicos: BCG, Polio, DTP/Tetravalente,
Hepatite B, Sarampo/Tríplice Viral, Febre Amarela, Hib (a partir de
1999). Códigos predominantes na faixa 006–075.

### 5.2 Era 2 (2004–2012): 19–21 indicadores

Expansão com novos indicadores: Rotavírus (2006), Pneumo 10V e
Meningo C (2010). Inclusão de BCG individual (002) e novos indicadores
compostos. Códigos na faixa 002–080.

### 5.3 Era 3 (2013–2019): 26–45 indicadores

Reformulação completa dos indicadores. Grande influxo de novos códigos
(091–111) com flutuação significativa entre anos: 32 códigos em 2013,
pico de 45 em 2015–2016, estabilização em 26 em 2017–2019. Os códigos
adicionados entre 2014–2016 e removidos em 2017 (062–071, 081–090,
108–111) sugerem indicadores experimentais ou transitórios.

### 5.4 Mudanças notáveis

- **1998→1999:** +6 indicadores (expansão do calendário com Hib)
- **2003→2004:** +7/−2 (reformulação: saem 009/018, entram indicadores
  compostos)
- **2012→2013:** +20/−9 (maior reestruturação: novos códigos 091–102,
  saem indicadores antigos)
- **2016→2017:** −18 (simplificação: remoção de indicadores detalhados)

---

## 6. CAMPO COBERT: COBERTURA PRÉ-CALCULADA

O campo COBERT é exclusivo dos arquivos CPNI e contém a cobertura
vacinal **pré-calculada pelo Ministério da Saúde**. É o resultado da
fórmula:

```
COBERT = (QT_DOSE / POP) × 100
```

### 6.1 Formato do campo

| Período   | Tipo R    | Separador decimal | Exemplo     |
|:---------:|:---------:|:-----------------:|:-----------:|
| 1994–2012 | numeric   | ponto (.)         | `39.87`     |
| 2013–2019 | character | **vírgula (,)**   | `"64,86"`   |

A mudança de formato em 2013 é um artefato da serialização do .dbf.
O `foreign::read.dbf()` interpreta o campo como numeric quando o .dbf
armazena com ponto decimal, mas preserva como character quando o .dbf
usa vírgula. Isso é consistente com a localidade brasileira (vírgula
como separador decimal) adotada pelo sistema do PNI a partir de 2013.

### 6.2 Decisão de tratamento

O campo COBERT será publicado **exatamente como está na fonte**: numeric
convertido para string (Era 1–2: `"39.87"`) e character preservado
(Era 3: `"64,86"`). Não cabe ao pipeline normalizar o separador
decimal — essa é uma transformação que o pesquisador ou o pacote R
fará conforme sua necessidade. A representação com vírgula é o formato
original do Ministério da Saúde na Era 3.

---

## 7. DADOS AUSENTES NOS PRIMEIROS ANOS

Padrão idêntico ao DPNI:

| Ano  | UFs sem dados                                                     |
|:----:|-------------------------------------------------------------------|
| 1994 | AL, AP, DF, MS, MG, PB, PR, RJ, RS, SP, SE, TO (12 UFs)        |
| 1995 | MS, MG, TO (3 UFs)                                               |
| 1996 | MG (1 UF)                                                         |
| 1997+| Todas as UFs disponíveis                                          |

Arquivos de UFs ausentes retornam .dbf válido porém vazio (0 linhas,
~323 bytes de header). Pipeline detecta por `nrow(df) == 0`.

---

## 8. ARTEFATOS E PROBLEMAS IDENTIFICADOS

### 8.1 Código de município 7 → 6 dígitos

Mesma descontinuidade do DPNI. Até 2012, `MUNIC` contém 7 dígitos
(com verificador IBGE). A partir de 2013, contém 6 dígitos (sem
verificador).

**Tratamento:** manter como na fonte. Normalização no pacote R.

### 8.2 COBERT com vírgula como separador decimal (2013–2019)

Descrito na Seção 6. Não é um artefato de serialização como os .0 dos
CSVs de microdados — é o formato nativo do campo no .dbf. O
`foreign::read.dbf(as.is = TRUE)` preserva corretamente como character.

### 8.3 Linhas com NA esparsos

Em pelo menos 2 anos (2004 e 2009 no Acre), existe 1 linha com
MUNIC=NA, QT_DOSE=NA, POP=NA. Esses registros parecem ser placeholders
para combinações de IMUNO/DOSE/FX_ETARIA sem dados naquele ano.

**Tratamento:** preservar como estão. O `as.character(NA)` gera `"NA"`
no R, mas o `arrow::write_parquet()` escreve corretamente como null no
Parquet quando o valor é `NA` no R. Nenhuma intervenção necessária.

### 8.4 Tipo de ANO (integer vs character)

ANO é integer em 1994–2003 e character em 2004–2019 (mesmo padrão do
DPNI). No Parquet final, tudo será string.

### 8.5 Tipos de QT_DOSE e POP (integer vs character)

QT_DOSE e POP são integer em 1994–2003 e character em 2004–2019.
No Parquet final, tudo será string (via `as.character()`).

### 8.6 Sem artefatos de float

Assim como nos DPNI, os .dbf não apresentam artefatos de serialização.
O formato .dbf preserva tipos nativamente.

### 8.7 Consolidados com conteúdo divergente

O CPNIBR08 contém valores de DOSE extras (`D1`, `D3`, `SD`) que não
aparecem nos arquivos estaduais correspondentes. Isso indica que os
consolidados nacionais podem incluir processamento adicional pelo
DATASUS (possivelmente agregação de dados municipais com lógica
diferente). Mais um motivo para excluí-los do pipeline (decisão 9.8).

---

## 9. DECISÕES ESTRUTURANTES (Fase 3)

### 9.1 Formato fonte

| Critério                      | .dbf (único disponível)           |
|-------------------------------|-----------------------------------|
| Formato preserva dados?       | Sim — sem artefatos               |
| Alternativas existem?         | Não — FTP é a única fonte         |
| Decisão                       | **Usar .dbf diretamente**         |

### 9.2 Ferramenta de leitura

**Decisão: `foreign::read.dbf()`** em R, mesma escolha do pipeline de
doses. Justificativa idêntica: arquivos pequenos, gargalo é FTP, não
parsing. Volume total estimado em ~3M registros (30x menor que doses).

### 9.3 Tipos no Parquet

**Decisão: tudo character (string).** Consistente com o projeto e com
o pipeline de doses. Campos numeric (ANO, UF, QT_DOSE, POP em
1994–2003, e COBERT em 1994–2012) são convertidos via `as.character()`.

### 9.4 Particionamento no R2

```
s3://healthbr-data/sipni/agregados/cobertura/
  ano=1994/uf=AC/
    part-0.parquet
  ...
  ano=2019/uf=TO/
    part-0.parquet
```

**Decisão: particionamento Hive `ano={YYYY}/uf={UF}/`.** Idêntico ao
pipeline de doses. Sem partição por mês (dados são anuais).

### 9.5 Tratamento das eras

**Decisão: publicar cada era com seu schema original, sem fabricar
colunas inexistentes.** Mesma lógica do DPNI.

Os dados de 1994–2012 têm 9 colunas porque o Ministério os publicou
com 9 colunas. Os dados de 2013–2019 têm 7 colunas porque FX_ETARIA
e DOSE foram removidos do sistema. Fabricar essas colunas com NA seria
criar um derivado.

**Era 1–2 (1994–2012) — 9 colunas:**

| Coluna     | Tipo Parquet |
|------------|:------------:|
| ANO        | string (*)   |
| UF         | string (*)   |
| MUNIC      | string       |
| FX_ETARIA  | string       |
| IMUNO      | string       |
| DOSE       | string       |
| QT_DOSE    | string (*)   |
| POP        | string (*)   |
| COBERT     | string (**)  |

**Era 3 (2013–2019) — 7 colunas:**

| Coluna     | Tipo Parquet |
|------------|:------------:|
| ANO        | string       |
| UF         | string       |
| MUNIC      | string       |
| IMUNO      | string       |
| QT_DOSE    | string       |
| POP        | string       |
| COBERT     | string       |

(*) Campos que são integer em parte do período, convertidos para string.

(**) COBERT é numeric com ponto decimal em 1994–2012 (convertido via
`as.character()`, resultado: `"39.87"`) e character com vírgula em
2013–2019 (preservado como está: `"64,86"`). Ambos ficam como string no
Parquet, mas com formatos diferentes. Esta inconsistência é da fonte,
não do pipeline — documentada para que pesquisadores saibam.

A harmonização entre eras (unificar os dois schemas) e a normalização
do separador decimal ficam a cargo do pacote R.

### 9.6 Tratamento do código de município

**Decisão: manter como na fonte.** 1994–2012 com 7 dígitos; 2013–2019
com 6 dígitos. Idêntico ao pipeline de doses.

### 9.7 Tratamento do campo COBERT

**Decisão: publicar exatamente como está na fonte.** Não normalizar o
separador decimal (vírgula → ponto) no pipeline. A representação com
vírgula é o formato original do Ministério na Era 3. O pipeline aplica
`as.character()` a tudo, o que:
- Para 1994–2012 (numeric): converte `39.87` → `"39.87"`
- Para 2013–2019 (character): mantém `"64,86"` inalterado

### 9.8 Exclusão dos consolidados

**Decisão: não publicar os arquivos consolidados no R2.** Apenas os 27
arquivos estaduais por ano são processados. Mesma decisão e racional
do DPNI.

**Racional:**

1. **CPNIIG (UF ignorada) não existe ou é vazio.** Downloads falham
   para a maioria dos anos; quando existem (2018), o .dbf tem 0 linhas.

2. **CPNIBR (consolidado nacional) é redundante.** Validado: CPNIBR98
   tem 49.561 linhas — soma exata dos 27 estaduais de 1998. Diferença
   zero.

3. **CPNIUF (consolidado por UF) é redundante e tem schema diferente.**
   8 colunas (sem MUNIC). Totais por UF são agregação trivial dos dados
   municipais.

4. **CPNIBR contém dados divergentes.** O CPNIBR08 inclui valores de
   DOSE (`D1`, `D3`, `SD`) que não aparecem nos estaduais, sugerindo
   processamento adicional nos consolidados. Incluí-los adicionaria
   complexidade sem valor informacional claro.

### 9.9 Pipeline unificado ou separado?

O `strategy-expansion-pt.md` sugeria avaliar se faz sentido um pipeline
unificado para DPNI e CPNI. Após a exploração, a recomendação é
**pipeline separado mas adaptado do DPNI**.

**Razões:**
- Os schemas são diferentes (CPNI tem POP e COBERT; DPNI tem ANOMES,
  MES, DOSE1, DOSEN, DIFER)
- As eras são diferentes (CPNI: 9→7; DPNI: 7→12→12)
- Os dicionários são diferentes (IMUNOCOB.DBF vs IMUNO.CNV)
- O volume é muito diferente (~3M vs 84M)
- A lógica de download é idêntica (mesmo FTP, mesmo padrão de URL)
- A lógica de conversão é idêntica (read.dbf + as.character + Parquet)

A melhor abordagem é copiar o pipeline de doses e adaptar minimamente:
mudar o prefixo do arquivo (DPNI→CPNI), o destino no R2, e o nome do
controle de versão. O processamento de campos é genérico (tudo vira
character) e não depende de quais colunas existem.

### 9.10 Tabela consolidada de decisões

| # | Decisão                    | Escolha                        | Alternativa rejeitada          | Motivo                                      |
|:-:|----------------------------|--------------------------------|--------------------------------|---------------------------------------------|
| 1 | Formato fonte              | .dbf (único disponível)        | —                              | Sem alternativa                             |
| 2 | Ferramenta de leitura      | R (`foreign::read.dbf`)        | Python (dbfread)               | Arquivos pequenos; simplicidade; reversível |
| 3 | Tipos no Parquet           | Tudo character                 | Tipagem seletiva               | Consistência com projeto; preserva dados    |
| 4 | Particionamento            | `ano=/uf=/`                    | `ano=/uf=/fxetaria=`           | FX_ETARIA desaparece em 2013; mapeamento direto dos .dbf |
| 5 | Schema                     | Schema original por era (9 cols / 7 cols) | Schema unificado com NAs fabricados | Fidelidade à fonte; não criar derivados |
| 6 | Código município           | Manter como na fonte (7d ou 6d) | Truncar para 6 dígitos        | Fidelidade à fonte; normalização no pacote R |
| 7 | COBERT                     | Manter como na fonte (ponto ou vírgula) | Normalizar para ponto  | Fidelidade à fonte; normalização no pacote R |
| 8 | Consolidados (UF/BR/IG)   | Excluir do pipeline            | Incluir com uf=UF/BR/IG        | Redundantes; BR=soma(estados); schema diferente; conteúdo divergente |
| 9 | Pipeline unificado?        | Separado (adaptado do DPNI)    | Pipeline único doses+cobertura | Schemas e eras diferentes; simplicidade |

### 9.11 Tempo de bootstrap estimado

Volume ~30x menor que o DPNI doses. O gargalo é o mesmo (download FTP
sequencial de 702 arquivos), mas os arquivos CPNI são menores.
Estimativa conservadora: **2–3 horas no Hetzner**, provavelmente menos.

### 9.12 Infraestrutura

Mesmo servidor Hetzner e mesmo bucket R2 dos demais pipelines. Nenhuma
infraestrutura adicional necessária.

---

## 10. ESTRUTURA DE DESTINO NO R2

```
s3://healthbr-data/
  sipni/
    agregados/
      doses/                          ← já existe
        ano=1994/uf=AC/
          part-0.parquet
        ...
      cobertura/                      ← ESTE SUBMÓDULO
        ano=1994/uf=AC/
          part-0.parquet
        ...
        ano=2019/uf=TO/
          part-0.parquet
        README.md                     ← dataset card (Fase 5)
    microdados/                       ← já existe
      ...
    dicionarios/                      ← submódulo futuro
      ...
```

---

## 11. QUESTÕES EM ABERTO

1. **Volume exato de registros:** a estimativa de ~3M é baseada na
   extrapolação do Acre. O volume real será conhecido após o bootstrap.

2. **Conteúdo do IMUNOCOB.DBF vs códigos na Era 3:** o dicionário tem
   26 entradas, mas a Era 3 usa até 45 códigos em alguns anos. Códigos
   acima de 080 podem não estar no IMUNOCOB.DBF. Investigar se existe
   dicionário atualizado, ou se esses códigos são documentados em notas
   técnicas do PNI. Questão para o submódulo de dicionários, não
   bloqueante para o pipeline.

3. **Validação cruzada:** após o bootstrap, comparar contagens com o
   TabNet para validar integridade.

---

## 12. PRÓXIMOS PASSOS

1. Construir pipeline adaptado do DPNI doses
   (`scripts/pipeline/sipni-agregados-cobertura-pipeline-r.R`)
2. Testar com amostra pequena (1 UF, 3 eras)
3. Executar bootstrap completo no Hetzner
4. Validar contagens
5. Criar controle de versão
   (`data/controle_versao_sipni_agregados_cobertura.csv`)
6. Documentar pipeline no `reference-pipelines-pt.md`
7. Avançar para Fase 5 (publicação: README, dataset card)

---

*Última atualização: 27/fev/2026.*
