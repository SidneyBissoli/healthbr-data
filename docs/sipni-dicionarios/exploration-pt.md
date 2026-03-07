# Exploração: Dicionários de Dados — SI-PNI (PNI/AUXILIARES)

> Documento consolidando a exploração dos arquivos auxiliares do SI-PNI
> disponíveis no FTP do DATASUS. Inventaria os 79 arquivos em
> `PNI/AUXILIARES/`, classifica-os por tipo e finalidade, documenta o
> formato proprietário .cnv (TabWin), e registra as decisões de publicação.
>
> Criado em 03/mar/2026.
>
> **Documento relacionado:** `strategy-expansion-pt.md` — ciclo de vida,
> fases e critérios de avanço.

---

## 1. VISÃO GERAL

| Propriedade              | Valor                                                          |
|--------------------------|----------------------------------------------------------------|
| Nome oficial             | Arquivos Auxiliares — Programa Nacional de Imunizações (PNI)   |
| Fonte                    | FTP do DATASUS                                                 |
| URL                      | `ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/`   |
| Formatos                 | .cnv (TabWin proprietário), .def (TabWin configuração), .dbf   |
| Número de arquivos       | 79 (17 .cnv + 61 .def + 1 .dbf)                               |
| Data no FTP              | Todos com timestamp 23/mai/2019                                |
| Tamanho total            | ~230 KB                                                        |
| Destino no R2            | `s3://healthbr-data/sipni/dicionarios/`                        |

**Relação com os demais submódulos SI-PNI:**

Estes dicionários decodificam os campos numéricos presentes nos dados
agregados de doses (DPNI) e cobertura (CPNI) publicados em
`sipni/agregados/doses/` e `sipni/agregados/cobertura/`. Sem eles, os
códigos numéricos nos campos IMUNO, DOSE e FX_ETARIA dos .dbf são opacos.

| Campo no .dbf  | Dicionário         | Entradas | Dataset            |
|:--------------:|:------------------:|:--------:|:------------------:|
| IMUNO          | IMUNO.CNV          | 85       | Agregados doses    |
| IMUNO          | IMUNOCOB.DBF       | 26       | Agregados cobertura|
| DOSE           | DOSE.CNV           | 12       | Agregados doses    |
| FX_ETARIA      | FXET.CNV           | 101      | Agregados doses    |

---

## 2. VIA DE ACESSO

### 2.1 FTP do DATASUS (ÚNICA FONTE)

```
ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES/
```

Acesso anônimo, sem autenticação. Todos os arquivos baixados com sucesso
em 03/mar/2026. Não existe fonte alternativa (S3, API, OpenDATASUS) para
estes arquivos auxiliares.

---

## 3. INVENTÁRIO E CLASSIFICAÇÃO

Os 79 arquivos dividem-se em três categorias funcionais:

### 3.1 Dicionários de dados (.cnv e .dbf) — 18 arquivos

Contêm tabelas de lookup que mapeiam códigos numéricos dos .dbf a labels
legíveis. São o conteúdo de valor para publicação.

| Arquivo       | Entradas | Largura | Decodifica          | Dataset         | Nota                         |
|---------------|:--------:|:-------:|---------------------|-----------------|------------------------------|
| IMUNO.CNV     | 85       | 2       | IMUNO (vacinas)     | Doses           | Dicionário principal de vacinas |
| IMUNOC.CNV    | 85       | 2       | IMUNO (vacinas)     | Doses           | = IMUNO.CNV (header com flag "L") |
| IMUNOCOB.DBF  | 26       | —       | IMUNO (indicadores) | Cobertura       | Formato .dbf, cols IMUNO+NOME |
| DOSE.CNV      | 12       | 2       | DOSE                | Doses           | Tipo de dose (D1–D4, reforço, etc.) |
| FXET.CNV      | 101      | 2       | FX_ETARIA           | Doses           | Faixa etária                 |
| ANO.CNV       | 26       | 4       | ANO                 | Ambos           | Anos 1994–2019               |
| ANOMES.CNV    | 218      | 6       | ANOMES              | Doses           | Ano-mês (rótulos longos)     |
| ANOMESC.CNV   | 203      | 6       | ANOMES              | Doses           | Ano-mês (rótulos curtos)     |
| MES.CNV       | 13       | 2       | ANOMES (mês)        | Doses           | Nome do mês                  |
| MESC.CNV      | 13       | 2       | ANO (mês)           | Doses           | Mês abreviado                |
| COBIMU.CNV    | 23       | 2       | IMUNO (agrupado)    | Cobertura       | Grupos de vacinas p/ cobertura |
| COBIMUC.CNV   | 51       | 3       | IMUNO (agrupado)    | Cobertura       | Grupos expandidos            |
| COBIMUNO.CNV  | 52       | 3       | IMUNO (agrupado)    | Cobertura       | Grupos + campanha Influenza  |
| COBIMUNO1.CNV | 23       | 2       | IMUNO (agrupado)    | Cobertura       | Variante de COBIMU (ordem diferente) |
| COBIMUNOW.CNV | 51       | 3       | IMUNO (agrupado)    | Cobertura       | = COBIMUC                    |
| IMUNOCT.CNV   | 11       | 3       | IMUNO (subset)      | Doses (subset)  | 11 vacinas selecionadas      |
| IMUNOt.CNV    | 11       | 3       | IMUNO (subset)      | Doses (subset)  | = IMUNOCT                    |
| IMUNOTC.CNV   | 9        | 2       | IMUNO (subset)      | Doses (subset)  | 9 vacinas selecionadas       |

**Duplicatas confirmadas:** IMUNOC ≡ IMUNO (dados idênticos, header
difere por flag "L"); COBIMUNOW ≡ COBIMUC; IMUNOt ≡ IMUNOCT.

### 3.2 Arquivos de configuração TabWin (.def) — 61 arquivos

Metadados de tabulação para o TabWin/TabNet. Definem: cabeçalhos HTML,
CSS, assignment de linhas/colunas/seleções, e referências a .cnv para
decodificação na interface. **Não contêm dados propriamente ditos.**

| Padrão          | Qty | Conteúdo                                          |
|-----------------|:---:|---------------------------------------------------|
| `dpni<UF>.def`  | 28  | Config de tabulação de doses por UF                |
| `dpniuf.def`    | 1   | Config de tabulação de doses consolidado UF        |
| `dpnibr.def`    | 1   | Config de tabulação de doses consolidado Brasil    |
| `cpni<UF>.def`  | 28  | Config de tabulação de cobertura por UF            |
| `cpniuf.def`    | 1   | Config de tabulação de cobertura consolidado UF    |
| `cpniuf1.def`   | 1   | Variante do consolidado UF (cobertura)             |
| `cpnibr.def`    | 1   | Config de tabulação de cobertura consolidado Brasil|

Os .def por UF diferem entre si apenas nos caminhos dos arquivos de
território (`territorio\AC_municip.cnv` vs `territorio\SP_municip.cnv`).
A estrutura de tabulação é idêntica.

**Decisão:** Os .def não serão publicados. São arquivos de configuração
de interface, não dicionários de dados. As tabelas de lookup que eles
referenciam (.cnv) já são publicadas diretamente.

---

## 4. FORMATO .CNV (TabWin)

O .cnv é um formato proprietário usado pelo TabWin para armazenar
tabelas de conversão (lookup tables). Estrutura:

### 4.1 Header (linha 1)

```
N_ENTRADAS  LARGURA_CAMPO [FLAGS]
```

- `N_ENTRADAS`: número de linhas de dados
- `LARGURA_CAMPO`: largura em caracteres do código no .dbf fonte
- `FLAGS` (opcional): "L" ou outros modificadores de display

Exemplo: `85 2` → 85 entradas, campo de 2 caracteres.

### 4.2 Linhas de dados (posicional, largura fixa)

```
Pos 1-5:                padding (espaços)
Pos 6-(5+LARGURA):      código sequencial
2 espaços separadores
Label (preenchido com espaços até posição ~60)
Código(s) fonte (mapeiam DE código no .dbf PARA este label)
```

Exemplo (IMUNO.CNV, linha para Hepatite A):

```
     06  Hepatite A (HA)                                    88,45
```

- Código sequencial: `06`
- Label: `Hepatite A (HA)`
- Códigos fonte: `88,45` — significa que os valores `88` e `45` no campo
  IMUNO dos .dbf são ambos decodificados como "Hepatite A"

### 4.3 Mapeamento muitos-para-um

O campo `source_codes` permite que múltiplos códigos no .dbf mapeiem para
um mesmo label. Isso reflete mudanças de codificação ao longo do tempo —
vacinas que tiveram seu código alterado pelo Ministério da Saúde continuam
mapeando para o mesmo nome.

Encoding: Latin-1 (ISO 8859-1), consistente com todo o ecossistema DATASUS.

---

## 5. CONTEÚDO DOS DICIONÁRIOS PRIMÁRIOS

### 5.1 IMUNO.CNV — Vacinas (85 entradas)

Dicionário principal de imunobiológicos. Mapeia 86 códigos fonte únicos
para 85 labels de vacinas. Usado para decodificar o campo `IMUNO` nos
.dbf de doses aplicadas (DPNI).

Exemplos:

| Código fonte | Label                                    |
|:------------:|------------------------------------------|
| 02           | BCG (BCG)                                |
| 06           | Febre Amarela (FA)                       |
| 08, 82       | Hepatite B (HB)                          |
| 88, 45       | Hepatite A (HA)                          |
| 16           | Oral Poliomielite (VOP)                  |
| 21           | Tríplice Viral (SCR)                     |
| 42           | Pentavalente (DTP/HB/Hib)               |
| 84           | HPV                                      |

### 5.2 IMUNOCOB.DBF — Indicadores de cobertura (26 entradas)

Formato .dbf (não .cnv). Duas colunas: IMUNO (código de 3 caracteres) e
NOME (label). Usado para decodificar o campo `IMUNO` nos .dbf de
cobertura (CPNI). Representa indicadores compostos de cobertura, não
vacinas individuais.

Exemplos:

| IMUNO | NOME                                      |
|:-----:|-------------------------------------------|
| 072   | BCG                                       |
| 099   | Hepatite B em crianças até 30 dias        |
| 080   | Penta                                     |
| 074   | Poliomielite                              |
| 021   | Tríplice Viral D1                         |
| 094   | Dupla adulto e tríplice acelular gestante |

### 5.3 DOSE.CNV — Tipos de dose (12 entradas)

| Código | Label          | Códigos fonte |
|:------:|----------------|:-------------:|
| 1      | Dose única     | 04, 09        |
| 2      | 1ª dose        | 01, 32        |
| 3      | 2ª dose        | 02, 33        |
| 4      | 3ª dose        | 03, 34        |
| 5      | 4ª dose        | 07, 35        |
| 6      | 1º reforço     | 05, 5         |
| 7      | 2º reforço     | 06            |
| 8      | Revacinação    | 10            |
| 9      | Dose Inicial   | 36            |
| 10     | Dose Adicional | 37            |
| 11     | Dose           | 08            |
| 12     | Tratamento     | 11–31         |

### 5.4 FXET.CNV — Faixas etárias (101 entradas)

Dicionário extenso com 101 faixas etárias que cobrem desde "Idade
ignorada" até faixas específicas de gestantes. Códigos fonte usam
formatos mistos: numéricos (00-99) e alfanuméricos (A0-A9, B0-B9, etc.).

Exemplos:

| Código | Label                      | Códigos fonte    |
|:------:|----------------------------|:----------------:|
| 99     | Idade ignorada             | 00–99            |
| 00     | Sem discriminação de idade | 62               |
| 01     | Até 30 dias                | A9, F1, F2       |
| 10     | Menor de 1 ano             | 50, X3, X4, X6   |
| 12     | 1 ano                      | 51, F0, G2, X5   |

---

## 6. REFERÊNCIAS EXTERNAS NOS .DEF

Os .def referenciam 23 .cnv que **não estão** em PNI/AUXILIARES. São
dicionários de território compartilhados entre sistemas do DATASUS:

```
territorio\<UF>_municip.cnv    → Municípios por UF
territorio\<UF>_regsaud.cnv    → Regiões de saúde
territorio\<UF>_macsaud.cnv    → Macrorregiões de saúde
territorio\<UF>_divadm.cnv     → Divisões administrativas estaduais
territorio\<UF>_micibge.cnv    → Microrregiões IBGE
territorio\<UF>_regmetr.cnv    → Regiões metropolitanas
territorio\br_municip.cnv      → Municípios (nacional)
territorio\br_capital.cnv      → Capitais
```

Esses dicionários territoriais são compartilhados com outros sistemas
(SIH, SIM, SINASC) e não são específicos do SI-PNI. Não serão incluídos
neste módulo.

---

## 7. DECISÕES DE PUBLICAÇÃO

### 7.1 O que publicar

| Decisão                    | Escolha                          | Justificativa |
|----------------------------|----------------------------------|---------------|
| Formato de publicação      | Originais + Parquet convertido   | Originais preservam fidelidade; Parquet permite consumo programático |
| Quais .cnv converter       | 6 primários (IMUNO, DOSE, FXET, ANO, MES, IMUNOCOB) | Decodificam campos dos datasets já publicados |
| Publicar .def?             | Não                              | Config de interface, sem valor para consumo de dados |
| Publicar variantes/duplicatas? | Sim, nos originais; não converter | Preservar fidelidade da fonte sem poluir os convertidos |
| Tipos no Parquet           | Tudo string                      | Consistência com o projeto; preserva zeros à esquerda |

### 7.2 Estrutura no R2

```
sipni/dicionarios/
├── originais/              ← 17 .cnv + 1 .dbf (exatamente como no FTP)
│   ├── IMUNO.CNV
│   ├── IMUNOCOB.DBF
│   ├── DOSE.CNV
│   ├── FXET.CNV
│   ├── ANO.CNV
│   ├── ANOMES.CNV
│   ├── ANOMESC.CNV
│   ├── MES.CNV
│   ├── MESC.CNV
│   ├── IMUNOC.CNV
│   ├── COBIMU.CNV
│   ├── COBIMUC.CNV
│   ├── COBIMUNO.CNV
│   ├── COBIMUNO1.CNV
│   ├── COBIMUNOW.CNV
│   ├── IMUNOCT.CNV
│   ├── IMUNOt.CNV
│   └── IMUNOTC.CNV
├── imuno.parquet           ← 85 linhas (code, label, source_codes)
├── imunocob.parquet        ← 26 linhas (imuno, nome)
├── dose.parquet            ← 12 linhas (code, label, source_codes)
├── fxet.parquet            ← 101 linhas (code, label, source_codes)
├── ano.parquet             ← 26 linhas (code, label, source_codes)
├── mes.parquet             ← 13 linhas (code, label, source_codes)
└── README.md
```

### 7.3 Schema dos Parquet convertidos

**Para .cnv (imuno, dose, fxet, ano, mes):**

| Coluna       | Tipo   | Descrição |
|--------------|--------|-----------|
| code         | string | Código sequencial no .cnv |
| label        | string | Nome legível (encoding UTF-8) |
| source_codes | string | Código(s) no .dbf que mapeiam para este label (vírgula-separados) |

**Para IMUNOCOB.DBF (imunocob):**

| Coluna | Tipo   | Descrição |
|--------|--------|-----------|
| imuno  | string | Código do indicador de cobertura (3 chars) |
| nome   | string | Nome do indicador (encoding UTF-8) |

---

## 8. ESTIMATIVAS

| Métrica | Valor |
|---------|-------|
| Tempo de pipeline | < 1 minuto (arquivos pequenos, processamento local) |
| Armazenamento R2 | < 1 MB (originais + parquets) |
| Complexidade | Baixa (parser .cnv + arrow::write_parquet) |

---

*Última atualização: 03/mar/2026.*
