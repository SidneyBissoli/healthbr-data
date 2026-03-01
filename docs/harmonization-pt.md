# Harmonização: Dados Agregados (1994–2019) ↔ Microdados (2020–2025+)

> **Status:** Rascunho v1 — 2026-02-25
>
> Este documento mapeia como traduzir entre os dois sistemas de dados de
> vacinação do SUS para construir séries temporais contínuas de 1994 a 2025+.
> Itens marcados com `[TODO]` indicam lacunas que precisam de investigação
> empírica nos dados.

---

## 1. VISÃO GERAL

O projeto integra duas fontes com estruturas incompatíveis:

| Propriedade         | Agregados (1994–2019)                         | Microdados (2020–2025+)                          |
|---------------------|-----------------------------------------------|--------------------------------------------------|
| **Origem**          | .dbf no FTP do DATASUS                        | JSON no S3 do OpenDATASUS                        |
| **Granularidade**   | 1 linha = total de doses (município × vacina × dose × faixa) | 1 linha = 1 dose aplicada a 1 indivíduo   |
| **Cód. vacina**     | `IMUNO` (IMUNO.CNV, 85 vacinas individuais)   | `co_vacina` / `ds_vacina`                        |
| **Cód. dose**       | `DOSE` (DOSE.CNV: 01=D1, 02=D2, etc.)        | `co_dose_vacina` / `ds_dose_vacina`              |
| **Faixa etária**    | `FX_ETARIA` (FXET.CNV, faixas pré-definidas) | `nu_idade_paciente` (idade exata em dias/meses/anos) |
| **Município**       | `MUNIC` (7 dígitos pré-2013, 6 pós-2013)     | `co_municipio_estabelecimento` (6 dígitos)       |
| **Cobertura**       | Pré-calculada pelo MS (arquivos CPNI)         | Calculada por nós (microdados + denominador)     |
| **Cód. cobertura**  | `IMUNOCOB.DBF` (26 indicadores compostos)     | Não existe — precisa ser reconstruído             |

### Princípio de harmonização

A harmonização ocorre no **pacote R `sipni`**, não nos dados publicados.
Os dados são publicados exatamente como o Ministério fornece. O pacote
traduz entre sistemas de códigos, agrega microdados, aplica denominadores
e entrega séries temporais contínuas ao pesquisador.

---

## 2. EIXO 1 — VACINAS

### 2.1 Dois sistemas de códigos nos agregados

**Descoberta crítica:** Os arquivos de doses (DPNI) e de cobertura (CPNI)
usam sistemas de códigos IMUNO **diferentes**.

- **Doses (DPNI)** → `IMUNO.CNV`: 85 vacinas individuais. Cada código = 1 produto.
- **Cobertura (CPNI)** → `IMUNOCOB.DBF`: 26 indicadores compostos. Cada código
  pode somar múltiplas vacinas com o mesmo componente antigênico.

Os microdados (2020+) têm apenas códigos de vacina individual (`co_vacina`),
análogos ao IMUNO.CNV. Para calcular cobertura a partir dos microdados,
é necessário replicar a lógica dos indicadores compostos do IMUNOCOB.

### 2.2 Códigos IMUNO.CNV conhecidos (agregados — doses)

| Cód. | Vacina                                           |
|:----:|--------------------------------------------------|
| 02   | BCG                                              |
| 06   | Febre Amarela (FA)                               |
| 08   | Hepatite B (HB)                                  |
| 52   | Pentavalente (DTP+HB+Hib)                        |
| 60   | Hexavalente (DTPa+Hib+HB+VIP)                    |
| 61   | Rotavírus Humano (VORH)                          |

> **Nota:** A lista acima é parcial. Os 85 códigos completos estão no
> dicionário IMUNO.CNV. [TODO] Publicar a tabela completa decodificada
> de IMUNO.CNV (todos os 85 códigos com descrição) e correlacionar com
> a matriz 65 vacinas × 26 anos já exportada como CSV.

### 2.3 Códigos IMUNOCOB.DBF conhecidos (agregados — cobertura)

| Cód. | Indicador composto          | Soma de vacinas                                                   |
|:----:|-----------------------------|-------------------------------------------------------------------|
| 072  | BCG total                   | BCG rotina + BCG comunicantes hanseníase                          |
| 073  | Hepatite B total            | HB + Pentavalente + Hexavalente                                   |
| 074  | Poliomielite total          | VOP + VIP + Hexavalente + Esq. Seq. VIP/VOP                      |
| 080  | Penta total                 | Pentavalente + Hexavalente                                        |

> [TODO] Publicar a tabela completa decodificada de IMUNOCOB.DBF (todos
> os 26 indicadores compostos com descrição e fórmula de composição).

### 2.4 Códigos `co_vacina` nos microdados (2020+)

Os microdados incluem pares `co_vacina` (código numérico) e `ds_vacina`
(descrição textual). Exemplos conhecidos:

> [TODO] Extrair a lista completa de valores únicos de `co_vacina` ×
> `ds_vacina` dos microdados (todos os meses de 2020 a 2025). Este é o
> passo essencial para construir a tabela de-para com IMUNO.CNV.
>
> **Método sugerido:**
> ```r
> library(arrow)
> ds <- open_dataset("s3://healthbr-data/sipni/microdados/")
> ds |>
>   distinct(co_vacina, ds_vacina) |>
>   collect() |>
>   arrange(co_vacina)
> ```

### 2.5 Tabela de-para: IMUNO.CNV ↔ `co_vacina` (microdados)

> [TODO] Este é o mapeamento central do documento. Requer:
>
> 1. Lista completa de IMUNO.CNV (85 códigos)
> 2. Lista completa de `co_vacina` × `ds_vacina` dos microdados
> 3. Correspondência por descrição e/ou componente antigênico
>
> **Hipótese a testar:** Os códigos `co_vacina` dos microdados são os
> mesmos do IMUNO.CNV? Se sim, o mapeamento é direto (1:1). Se não,
> é necessário construir de-para por nome/componente.
>
> **Estratégia de investigação:**
> - Baixar amostra de microdados e extrair `co_vacina` × `ds_vacina`
> - Comparar com IMUNO.CNV decodificado
> - Verificar se há correspondência numérica ou apenas semântica

### 2.6 Transições de vacina ao longo do tempo

As vacinas do calendário básico sofreram substituições em datas específicas.
Para construir séries temporais contínuas de **cobertura por doença**
(não por produto), é necessário somar vacinas com o mesmo componente
antigênico em cada período:

| Componente             | 1ª geração (1994–2002)   | 2ª geração (2003–2012)           | 3ª geração (2013+)                     |
|------------------------|--------------------------|----------------------------------|----------------------------------------|
| Coqueluche/dift./tét.  | DTP isolada              | Tetravalente (DTP/Hib)           | Pentavalente (DTP/HB/Hib)             |
| Haemophilus b          | Hib isolada (1999–2002)  | Tetravalente (DTP/Hib)           | Pentavalente (DTP/HB/Hib)             |
| Hepatite B             | HB isolada               | HB isolada                       | HB + Pentavalente + Hexavalente        |
| Sarampo                | Sarampo monovalente      | Tríplice Viral (SRC)             | Tríplice Viral D1 + Tetraviral (D2)   |
| Poliomielite           | VOP isolada              | VOP + VIP                        | VOP + VIP + Hexa + Esq. Seq.          |

#### Linha do tempo das substituições

```
1994 ─── DTP, VOP, HB, BCG, FA, Sarampo
         │
1999 ─── + Hib isolada
         │
2002 ─── − DTP, − Hib, − Sarampo monovalente
2003 ─── + Tetravalente (DTP/Hib), + Tríplice Viral (em 1 ano)
         │
2006 ─── + Rotavírus (VORH)
         │
2010 ─── + Pneumo 10V, + Meningo C conjugada
         │
jul/2012  + Pentavalente (DTP/HB/Hib), + Esq. Sequencial VIP/VOP
2013 ─── + Tetraviral, + Hepatite A (DU), − Tetravalente na rotina
         │
2020 ─── Transição para microdados individuais
```

### 2.7 Indicadores compostos de cobertura

Para calcular cobertura por **doença** (e não por **produto**), é preciso
somar doses de vacinas com o mesmo componente antigênico. Os agregados
fazem isso automaticamente via IMUNOCOB. Nos microdados, precisamos
replicar essa lógica.

#### Tabela de composição dos indicadores

| Indicador composto                             | Componentes a somar (IMUNO.CNV)                                              | Dose cobertura | Pop. alvo  |
|------------------------------------------------|------------------------------------------------------------------------------|:--------------:|:----------:|
| Total contra tuberculose                       | BCG rotina + BCG-Hanseníase (− comunicantes)                                 | DU             | < 1 ano    |
| Total contra hepatite B                        | HB + Pentavalente + Hexavalente                                              | D3             | < 1 ano    |
| Total contra poliomielite                      | VOP + VIP + Hexavalente + Penta inativada + Esq. Seq. VIP/VOP               | D3             | < 1 ano    |
| Total contra coqueluche/difteria/tétano        | Tetravalente + Pentavalente + Hexavalente                                    | D3             | < 1 ano    |
| Total contra sarampo e rubéola                 | Tríplice Viral + Dupla Viral                                                 | D1             | 1 ano      |
| Total contra difteria e tétano                 | DTP + DTPa + Tetravalente + Penta + Hexa + DT infantil                       | D3             | < 1 ano    |
| Total contra haemophilus b                     | Hib + Tetravalente + Pentavalente + Hexavalente                              | D3             | < 1 ano    |

> [TODO] Mapear cada indicador composto para os códigos `co_vacina`
> correspondentes nos microdados. Construir funções R que implementem
> essas somas automaticamente.

#### Replicação nos microdados: pseudocódigo

Para reconstruir, por exemplo, "cobertura contra hepatite B" a partir
dos microdados de 2024:

```r
# Pseudocódigo — será implementado no pacote sipni
microdados_2024 |>
  filter(
    co_vacina %in% c("HB", "PENTA", "HEXA"),  # [TODO] códigos reais
    co_dose_vacina == "D3",                     # [TODO] código real de D3
    idade_em_meses(nu_idade_paciente) < 12      # [TODO] lógica de conversão
  ) |>
  count(co_municipio_estabelecimento, name = "doses_d3") |>
  left_join(denominador_sinasc_2024, by = "municipio") |>
  mutate(cobertura_pct = doses_d3 / nascidos_vivos * 100)
```

---

## 3. EIXO 2 — DOSES

### 3.1 Sistema de códigos de dose nos agregados

Os agregados usam o dicionário `DOSE.CNV` no campo `DOSE`:

| Código | Significado          | Abreviação |
|:------:|----------------------|:----------:|
| 01     | Primeira dose        | D1         |
| 02     | Segunda dose         | D2         |
| 03     | Terceira dose        | D3         |
| 04     | Dose única           | DU         |
| 05     | Primeiro reforço     | REF1       |
| 06     | Segundo reforço      | REF2       |

> [TODO] Confirmar códigos acima consultando DOSE.CNV do FTP. Verificar
> se existem códigos adicionais (ex: "D" para dose de recém-nascido HB,
> "Dose" para campanha).

**Nota importante sobre 2013+:** A partir de 2013, os arquivos de cobertura
(CPNI) perderam a coluna `DOSE` — cada código IMUNOCOB já embute a dose
correta do indicador. Nos arquivos de doses (DPNI), a coluna `DOSE`
permanece em todas as eras.

### 3.2 Sistema de códigos de dose nos microdados

Os microdados usam os campos `co_dose_vacina` e `ds_dose_vacina`:

> [TODO] Extrair lista completa de valores únicos de `co_dose_vacina` ×
> `ds_dose_vacina` dos microdados. Método:
>
> ```r
> ds |>
>   distinct(co_dose_vacina, ds_dose_vacina) |>
>   collect() |>
>   arrange(co_dose_vacina)
> ```

### 3.3 Tabela de-para: DOSE.CNV ↔ `co_dose_vacina`

> [TODO] Construir após obter ambas as listas. Questões a investigar:
>
> 1. Os códigos são numericamente equivalentes? (ex: `01` em ambos = D1?)
> 2. Há doses nos microdados sem correspondente nos agregados? (ex: doses
>    de reforço adicionais, doses de campanha)
> 3. A dose "D" de HB (recém-nascido) como é codificada nos microdados?

### 3.4 Qual dose conta para cobertura (por vacina)

| Vacina                    | Dose cobertura | Pop. alvo | Período agregados     |
|---------------------------|:--------------:|:---------:|:---------------------:|
| BCG                       | DU             | < 1 ano   | 1994+                 |
| Hepatite B                | D3             | < 1 ano   | 1994+                 |
| Hepatite B (RN)           | D              | < 1 mês   | 2014+                 |
| Rotavírus (VORH)          | D2             | < 1 ano   | 2006+                 |
| Pneumo 10V/13V            | D3             | < 1 ano   | 2010+                 |
| Meningo C                 | D2             | < 1 ano   | 2010+                 |
| Penta (DTP/HB/Hib)        | D3             | < 1 ano   | 2º sem 2012+          |
| Esq. Seq. VIP/VOP         | D3             | < 1 ano   | 2º sem 2012+          |
| Poliomielite (total)      | D3             | < 1 ano   | 1994+                 |
| Tríplice Viral D1         | D1             | 1 ano     | 2000+ (rotina 2003+)  |
| Tríplice Viral D2         | D2 + DU Tetraviral | 1 ano | 2013+                |
| Tetraviral                | DU             | 1 ano     | 2013+                 |
| Hepatite A                | DU             | 1 ano     | 2014+                 |
| Febre Amarela             | DU/D1          | < 1 ano   | 1994+                 |
| DTP REF1                  | REF1           | 1 ano     | 1994+                 |
| Sarampo (histórico)       | DU             | < 1 ano   | 1994–2002             |
| Tetravalente (histórico)  | D3             | < 1 ano   | 2003–2012             |
| DTP (histórico)           | D3             | < 1 ano   | 1994–2002             |
| Hib (histórico)           | D3             | < 1 ano   | 1999–2002             |

**Regra especial — Hepatite B:** A dose "D" (recém-nascido, < 1 mês)
**não** entra no cálculo de abandono da HB porque faz parte do esquema
complementado pela Penta. Para cobertura em < 1 ano, conta-se D3.
Para cobertura em RN (< 1 mês), conta-se dose "D" com denominador = NV.

**Regra especial — Tríplice Viral D2:** A partir de 2013, a cobertura
de TV D2 soma: D2 da Tríplice Viral + DU da Tetraviral (novo esquema
com Tetraviral aos 15 meses).

---

## 4. EIXO 3 — FAIXAS ETÁRIAS

### 4.1 Faixas nos agregados

Os agregados usam `FX_ETARIA` com o dicionário `FXET.CNV`:

> [TODO] Decodificar FXET.CNV completo. Faixas conhecidas das notas técnicas:

| Faixa (agregados)     | Descrição                                   |
|-----------------------|---------------------------------------------|
| menor de 1 ano        | 0–11 meses                                  |
| 1 ano                 | 12–23 meses                                 |
| 2 anos                | 24–35 meses                                 |
| 3 anos                | 36–47 meses                                 |
| 4 anos                | 48–59 meses                                 |
| 5 a 6 anos            |                                              |
| 7 a 11 anos           | (variantes: 7 a 14, 7 a 17)                 |
| 12 a 14 anos          | Subdividido por sexo e gestação em dT        |
| 15 a 49 anos          | Subdividido: gestantes, não gestantes, homens|
| 50 a 59 anos          |                                              |
| 60 anos e mais        | (variantes: 60 a 64, 65 e mais)             |

**Nota (2013+):** A coluna `FX_ETARIA` desaparece dos arquivos CPNI a
partir de 2013. Cada código IMUNOCOB já embute a faixa etária correta.
Nos DPNI, `FX_ETARIA` permanece.

### 4.2 Idade nos microdados

Os microdados têm `nu_idade_paciente`, que contém a idade exata.

> [TODO] Investigar o formato de `nu_idade_paciente`:
>
> 1. É idade em dias, meses ou anos?
> 2. Há um prefixo que indica a unidade? (padrão DATASUS: 1xx = horas,
>    2xx = dias, 3xx = meses, 4xx = anos — ex: 301 = 1 mês, 415 = 15 anos)
> 3. Extrair distribuição de valores para confirmar o padrão.
>
> **Método:**
> ```r
> ds |>
>   count(nu_idade_paciente) |>
>   collect() |>
>   arrange(desc(n)) |>
>   head(50)
> ```

### 4.3 Recategorização: microdados → faixas dos agregados

Uma vez confirmado o formato de `nu_idade_paciente`, a função de
recategorização no pacote R seguirá esta lógica:

```r
# Pseudocódigo — depende do formato real de nu_idade_paciente
classificar_faixa_pni <- function(idade_raw) {
  # [TODO] Implementar decodificação do formato DATASUS
  #   Se 1xx: idade em horas
  #   Se 2xx: idade em dias → converter para meses
  #   Se 3xx: idade em meses
  #   Se 4xx: idade em anos
  
  case_when(
    idade_meses < 1   ~ "menor_1_mes",
    idade_meses < 12  ~ "menor_1_ano",
    idade_meses < 24  ~ "1_ano",
    idade_meses < 36  ~ "2_anos",
    idade_meses < 48  ~ "3_anos",
    idade_meses < 60  ~ "4_anos",
    idade_anos < 7    ~ "5_6_anos",
    # ... demais faixas
  )
}
```

### 4.4 Populações-alvo para cobertura

As faixas relevantes para cálculo de cobertura no calendário infantil são:

| Pop. alvo  | Vacinas                                                                                   |
|:----------:|-------------------------------------------------------------------------------------------|
| < 1 mês    | Hepatite B dose "D" (RN)                                                                  |
| < 1 ano    | BCG, HB, Rotavírus, Pneumo, Meningo C, Penta, Esq.Seq., Pólio, FA, DTP, Tetra, Hib, Sarampo |
| 1 ano      | Tríplice Viral D1 e D2, Tetraviral, Hepatite A, DTP REF1                                 |
| 12–49 anos | Gestantes (dT + dTpa)                                                                     |

---

## 5. EIXO 4 — GEOGRAFIA (MUNICÍPIO)

### 5.1 O problema

| Período     | Fonte       | Dígitos  | Exemplo        |
|:-----------:|:-----------:|:--------:|:--------------:|
| 1994–2012   | Agregados   | **7**    | `3550308` (SP) |
| 2013–2019   | Agregados   | **6**    | `355030` (SP)  |
| 2020–2025+  | Microdados  | **6**    | `355030` (SP)  |

O 7º dígito é o **verificador** do IBGE. O padrão moderno (6 dígitos, sem
verificador) é o formato normalizado.

### 5.2 Regra de harmonização

```
Para dados agregados pré-2013:
  municipio_6dig = substr(MUNIC, 1, 6)

Para dados agregados 2013+ e microdados:
  municipio_6dig = MUNIC (já em 6 dígitos)
```

Nos microdados, o campo relevante é `co_municipio_estabelecimento`
(município do estabelecimento de saúde que aplicou a dose). Há também
`co_municipio_paciente` (município de residência do paciente).

> **Decisão de design:** Para cálculo de cobertura, o MS usa o município
> do **estabelecimento** (onde a dose foi aplicada), não o município de
> residência. O pacote `sipni` seguirá a mesma convenção.
>
> [TODO] Confirmar: os agregados registram por município do
> estabelecimento ou de residência? A nota técnica sugere que é por
> "local de aplicação", mas confirmar empiricamente.

### 5.3 NAs e registros sem município

Os agregados pré-2013 contêm NAs no campo MUNIC para alguns registros.
Há também arquivos com sufixo `IG` (ex: `CPNIIG04.DBF`) que contêm
registros "sem UF definida" — ignorância geográfica.

---

## 6. EIXO 5 — PERÍODO (TEMPORAL)

### 6.1 Granularidade temporal por fonte

| Fonte              | Período     | Granularidade mínima | Campo                           |
|--------------------|:-----------:|:--------------------:|----------------------------------|
| CPNI (cobertura)   | 1994–2019   | **Anual**            | `ANO`                            |
| DPNI (doses)       | 1994–2003   | **Anual**            | `ANO`                            |
| DPNI (doses)       | 2004–2019   | **Mensal**           | `ANOMES` (YYYYMM) + `MES`       |
| Microdados         | 2020–2025+  | **Diária**           | `dt_vacina` (YYYY-MM-DD)         |

### 6.2 Implicação para séries temporais

- **Séries anuais:** disponíveis para todo o período (1994–2025+). Método
  mais simples, sem perda de dados.
- **Séries mensais:** disponíveis apenas a partir de 2004 (DPNI) ou 2020
  (microdados para cobertura). Cobertura pré-calculada (CPNI) é apenas anual.
- **Séries diárias:** apenas com microdados (2020+).

### 6.3 Sobreposição em 2020?

> [TODO] Investigar: existem dados agregados (CPNI/DPNI) para o ano 2020?
> Os arquivos .dbf no FTP vão até 2019, mas é preciso confirmar se não há
> arquivos de 2020. Se houver sobreposição, validar cruzando:
>
> ```r
> # Agregados 2020 (se existirem)
> doses_agregados_2020 <- sum(dpni_2020$QT_DOSE)
>
> # Microdados 2020
> doses_microdados_2020 <- nrow(microdados_2020)
>
> # Comparar totais
> ```
>
> Se houver sobreposição, decidir: usar agregados (consistência com
> série anterior) ou microdados (maior granularidade)?

### 6.4 Dados preliminares do ano corrente

Para o ano em curso, os dados são preliminares até o fechamento em março
do ano seguinte. A cobertura preliminar usa meta mensal acumulada:

```
Pop. alvo mensal = Pop. alvo anual ÷ 12
Pop. alvo acumulada (mês N) = Pop. alvo mensal × N
```

---

## 7. EIXO 6 — DESCONTINUIDADES METODOLÓGICAS

### 7.1 Cobertura: pré-calculada vs calculada

| Período   | Método                                   | Implicação                                  |
|:---------:|------------------------------------------|---------------------------------------------|
| 1994–2019 | Cobertura pré-calculada pelo MS          | Denominador oficial daquela época           |
| 2020+     | Cobertura calculada por nós              | Denominador SINASC/IBGE mais recente        |

**Os valores devem ser comparáveis, mas não idênticos**, por:
- Diferenças no momento de extração dos dados
- Possíveis revisões nos denominadores SINASC
- Regras de arredondamento

**Recomendação:** Ao apresentar séries temporais, marcar a transição
(ex: linha vertical em 2020) e documentar a mudança metodológica.

### 7.2 Transição APIDOS → APIWEB (jul/2013)

| Sistema | Período       | Tipo                                          |
|---------|:-------------:|-----------------------------------------------|
| APIDOS  | até jun/2013  | Sistema DOS de avaliação do PNI               |
| APIWEB  | jul/2013+     | Sistema web que absorveu APIDOS + SIPNI       |

**Implicação:** Dados de 2013 podem ter registros de **ambos** os sistemas
para o mesmo município. A partir de 2013, dados do SIPNI (registro por
indivíduo) são agrupados aos do SIAPI e disponibilizados nos relatórios
agregados.

**Impacto prático:** A mudança para APIWEB coincide com:
- Desaparecimento de `FX_ETARIA` e `DOSE` nos CPNI (indicadores compostos)
- Inclusão de Hexavalente e Pneumo 13V (clínicas privadas)
- Mudança do código de município (7 → 6 dígitos)

### 7.3 Denominadores: evolução ao longo do tempo

#### Fontes do denominador por período

| Período     | Pop < 1 ano          | Pop 1 ano            | Demais faixas              |
|:-----------:|:--------------------:|:--------------------:|:--------------------------:|
| 1994–1999   | IBGE (todas as UFs)  | IBGE (todas as UFs)  | IBGE (todas as UFs)        |
| 2000–2005   | SINASC (Grupo B) / IBGE (Grupo A) | SINASC ano anterior (Grupo B) / IBGE (Grupo A) | IBGE Censo 2000 + estimativas |
| 2006+       | SINASC (todas as UFs)| SINASC ano anterior  | IBGE estimativas           |

**Grupo A** (sem SINASC, 2000–2005): AL, AM, BA, CE, MA, MG, MT, PA, PB, PI, RO, TO

**Grupo B** (com SINASC, 2000–2005): AC, AP, ES, GO, MS, PR, PE, RJ, RN, RS, RR, SC, SP, SE, DF

#### Congelamento SINASC 2009

O SINASC de 2009 foi repetido como denominador nos anos 2010, 2011 e 2012
(dado mais recente disponível à época). **Fonte conhecida de distorção
nas coberturas desse período.**

#### Referência: SINASC usado como denominador

| Ano dados | < 1 ano (SINASC) | 1 ano (SINASC) | UFs com SINASC      |
|:---------:|:-----------------:|:---------------:|:--------------------:|
| 2000      | 2000              | 2000            | Grupo B              |
| 2001      | 2001              | 2000            | Grupo B              |
| 2002      | 2002              | 2001            | Grupo B              |
| 2003      | 2003              | 2002            | Grupo B              |
| 2004      | 2004              | 2003            | Grupo B              |
| 2005      | 2005              | 2004            | Grupo B              |
| 2006      | 2006              | 2005            | Todas                |
| 2007      | 2007              | 2006            | Todas                |
| 2008      | 2008              | 2007            | Todas                |
| 2009      | 2009*             | 2008            | Todas                |
| 2010      | 2009*             | 2009            | Todas                |
| 2011      | 2009*             | 2009            | Todas                |
| 2012      | 2009*             | 2009            | Todas                |

(*) SINASC 2009 congelado.

> [TODO] Determinar qual SINASC usar como denominador para os microdados
> de 2020+. Opções:
> - SINASC mais recente disponível (replicando a lógica do MS)
> - SINASC do próprio ano (se disponível, para maior precisão)
> - Documentar qual escolha foi feita e por quê

### 7.4 UFs sem dados nos primeiros anos

| Ano  | UFs sem dados                                                      |
|:----:|--------------------------------------------------------------------|
| 1994 | AL, AP, DF, MS, MG, PB, PR, RJ, RS, SP, SE, TO (12 UFs)          |
| 1995 | MS, MG, TO (3 UFs)                                                 |
| 1996 | MG (1 UF)                                                          |
| 1997+| Todas as UFs disponíveis                                           |

### 7.5 Hexavalente e clínicas privadas

A vacina Hexavalente (DTPa/Hib/HB/VIP) é administrada em clínicas
privadas e registrada no APIWEB. A Pneumo 13V também é administrada em
clínicas privadas e em alguns municípios que adquirem separadamente.

**Impacto:** Ambas entram nas somas dos indicadores compostos (cobertura
contra hepatite B, poliomielite, etc.). Antes da Penta entrar na rotina
(2º sem 2012), registros de Penta/Hexa nos dados referem-se exclusivamente
a vacinação indígena e CRIE.

---

## 8. TAXAS DE ABANDONO

A taxa de abandono mede a proporção que iniciou mas não completou o esquema:

```
Taxa de abandono (%) = (D1 − Dúltima) ÷ D1 × 100
```

### 8.1 Componentes por vacina

| Vacina              | D1 (numerador)                  | Dúltima              | Período               |
|---------------------|---------------------------------|:--------------------:|:---------------------:|
| Hepatite B          | D1 HB + Penta + Hexa           | D3                   | < 1 ano               |
| Rotavírus           | D1                              | D2                   | < 1 ano, desde 2006   |
| Pneumo 10V/13V      | D1 Pnc10 + Pnc13               | D3                   | < 1 ano, desde 2010   |
| Meningo C           | D1                              | D2                   | < 1 ano, desde 2010   |
| Esq. Seq. VIP/VOP   | D1                              | D3                   | < 1 ano, desde 2º sem 2012 |
| Penta               | D1 Penta + Hexa                 | D3                   | < 1 ano, desde 2º sem 2012 |
| Tríplice Viral       | D1                              | D2 TV + DU Tetraviral| 1 ano, desde 2013     |
| Poliomielite        | D1 VOP + VIP + ...              | D3                   | < 1 ano               |
| Tetra (DTP/Hib)     | D1 Tetra + Penta + Hexa        | D3                   | < 1 ano, 2003–2012    |

**Nota:** Dose "D" de HB (recém-nascido) **não** entra no cálculo de
abandono porque faz parte do esquema complementado pela Penta.

> [TODO] Verificar se os agregados já fornecem campos para cálculo de
> abandono diretamente (DOSE1, DOSEN, DIFER nos DPNI a partir de 2004).
> Se sim, documentar a correspondência com os campos equivalentes que
> precisam ser calculados nos microdados.

---

## 9. CAMPOS EXCLUSIVOS DOS MICRODADOS

Os seguintes campos estão disponíveis apenas nos microdados (2020+) e não
existem nos agregados. Eles permitem análises mais granulares que não
eram possíveis com os dados históricos:

| Campo                           | Descrição                                            |
|---------------------------------|------------------------------------------------------|
| `tp_sexo_paciente`              | Sexo do paciente                                     |
| `co_raca_cor_paciente`          | Raça/cor autodeclarada                               |
| `co_cnes_estabelecimento`       | CNES do estabelecimento de saúde                     |
| `co_lote_vacina`                | Lote da vacina                                       |
| `ds_vacina_fabricante`          | Fabricante da vacina                                 |
| `co_estrategia_vacinacao`       | Estratégia (rotina, campanha, bloqueio, etc.)        |
| `co_tipo_estabelecimento`       | Tipo (UBS, hospital, clínica privada, etc.)          |
| `co_natureza_estabelecimento`   | Natureza jurídica do estabelecimento                 |
| `ds_condicao_maternal`          | Condição maternal no momento da vacinação            |
| `co_etnia_indigena_paciente`    | Etnia indígena (quando aplicável)                    |

---

## 10. RESUMO DOS TODOs

### Alta prioridade (necessários para implementar o pacote)

| #  | TODO                                                                 | Método                              |
|:--:|----------------------------------------------------------------------|-------------------------------------|
| 1  | Extrair lista completa `co_vacina` × `ds_vacina` dos microdados     | Query Arrow nos Parquets do R2      |
| 2  | Publicar tabela completa decodificada de IMUNO.CNV (85 códigos)     | Parsear .cnv do FTP                 |
| 3  | Construir tabela de-para IMUNO.CNV ↔ `co_vacina`                   | Cruzar #1 e #2 por descrição        |
| 4  | Extrair lista completa `co_dose_vacina` × `ds_dose_vacina`          | Query Arrow nos Parquets do R2      |
| 5  | Construir tabela de-para DOSE.CNV ↔ `co_dose_vacina`               | Cruzar DOSE.CNV com #4              |
| 6  | Investigar formato de `nu_idade_paciente`                            | Análise de distribuição de valores  |
| 7  | Publicar tabela completa de IMUNOCOB.DBF (26 indicadores)           | Parsear .dbf do FTP                 |

### Média prioridade (refinamento)

| #  | TODO                                                                 | Método                              |
|:--:|----------------------------------------------------------------------|-------------------------------------|
| 8  | Confirmar se dados agregados existem para 2020                       | Verificar FTP                       |
| 9  | Decodificar FXET.CNV completo                                       | Parsear .cnv do FTP                 |
| 10 | Confirmar município = estabelecimento nos agregados                  | Comparar com documentação           |
| 11 | Decidir SINASC a usar como denominador para 2020+                   | Análise + documentação              |
| 12 | Documentar campos DOSE1/DOSEN/DIFER nos DPNI 2004+                  | Análise dos .dbf                    |

### Baixa prioridade (completude)

| #  | TODO                                                                 | Método                              |
|:--:|----------------------------------------------------------------------|-------------------------------------|
| 13 | Mapear indicadores compostos para `co_vacina` dos microdados        | Após #3                             |
| 14 | Implementar funções R para todos os indicadores compostos           | Após #13                            |
| 15 | Validar coberturas calculadas contra TabNet para anos de overlap    | Cross-check empírico                |

---

## 11. REFERÊNCIAS

### Documentos técnicos consultados

| Documento                                          | Conteúdo relevante                                                    |
|----------------------------------------------------|-----------------------------------------------------------------------|
| `Regras_de_cálculo_das_coberturas_vacinais.pdf`    | Numeradores por vacina, composição de indicadores, notas sobre Hexa   |
| `Nota_técnica_cobertura_e_imunizações.pdf`         | Origem dos dados, regras por vacina, população-alvo por período/UF    |
| `Nota_técnica_cobertura.pdf`                       | Tabela cobertura × imuno × período × pop-alvo, indicadores compostos |
| `Nota_técnica_imunizações.pdf`                     | Tabela completa de imunobiológicos × doses × faixas etárias × sexo    |
| `Taxas_de_abandono.pdf`                            | Fórmulas de taxa de abandono por vacina multidose                     |
| `Cálculo_de_cobertura_20122013.pdf`                | Numeradores APIDOS vs APIWEB, regras 2012–2013                       |
| `Dicionário_de_dados.pdf`                          | Dicionário de campos dos microdados (60 campos)                       |

### Artefatos do projeto

| Artefato                          | Descrição                                         |
|-----------------------------------|----------------------------------------------------|
| `project-pt.md`                   | Documento principal do projeto (949 linhas)         |
| `inventario_imuno_por_ano.csv`    | Matriz 65 vacinas × 26 anos (IMUNO.CNV)            |
| `IMUNO.CNV`                       | Dicionário original de vacinas (doses)              |
| `IMUNOCOB.DBF`                    | Dicionário original de indicadores compostos        |
| `DOSE.CNV`                        | Dicionário original de tipos de dose                |
| `FXET.CNV`                        | Dicionário original de faixas etárias               |
