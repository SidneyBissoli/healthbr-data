"""Gera tables/csap-universe.json — o UNIVERSO de cálculo do % ICSAP, como o
pacote R csapAIH (Fúlvio B. Nedel; github.com/fulvionedel/csapAIH, GPL-3) o
define por padrão: antes de classificar, saem as internações por procedimento
obstétrico (procobst.rm), as com diagnóstico de parto (parto.rm, O80–O84) e as
AIH de longa permanência (longa.rm, IDENT = 5). A lista de diagnósticos CSAP
não muda; muda quem entra no numerador e no denominador.

Fontes, por era:
  - 2008+  (PROC_REA com 10 dígitos, SIGTAP): os 10 procedimentos de
           csapAIH::proc.obst(), copiados ao pé da letra.
  - 1992–2007 (PROC_REA com 8 dígitos, tabela antiga do SIH): os grupos
           "Partos normais", "Partos cesáreos" e "Abortamentos" de
           PROCOBST.CNV (TAB_SIH_199201-199712.zip do DATASUS, extraído em
           insumos/tab/, gitignored — bash fetch-insumos.sh) — o equivalente da lista do csapAIH na
           tabela da época; a tabela antiga vigorou até 2007 (conferido em
           2005/SE: os partos O80–O84 têm PROC_REA 35001011, 35025018,
           35009012, 35026014, todos aqui).
  - Diagnóstico de parto: CID-10 O80–O84 (csapAIH::partos); CID-9 650 (parto
           normal) e 669.5–669.7 (parto por fórceps/vácuo, extração pélvica,
           cesariana sem indicação) — códigos de 6 dígitos lidos de
           tables/cid9-codes.json.
  - Longa permanência: IDENT = "5" (IDENT.CNV: 1 normal, 5 longa permanência),
           em todas as eras.

Uso:  python tables/generators/csap-universe-tables.py   (a partir de scripts/pipeline/sih-cubos/)
"""
import json
import os
import re
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))          # tables/generators/
TABLES = os.path.dirname(HERE)                             # tables/ (versionado)
OUT = os.path.join(TABLES, "csap-universe.json")
PROCOBST_CNV = os.path.join(HERE, "insumos", "tab", "PROCOBST.CNV")
CID9_CODES = os.path.join(TABLES, "cid9-codes.json")

# csapAIH::proc.obst() — R/procobst.R (v0.0.4.8, 2026-01-16)
SIGTAP = [
    ("0310010012", "ASSISTENCIA AO PARTO S/ DISTOCIA"),
    ("0310010020", "ATENDIMENTO AO RECEM-NASCIDO EM SALA DE PARTO"),
    ("0310010039", "PARTO NORMAL"),
    ("0310010047", "PARTO NORMAL EM GESTACAO DE ALTO RISCO"),
    ("0411010018", "DESCOLAMENTO MANUAL DE PLACENTA"),
    ("0411010026", "PARTO CESARIANO EM GESTACAO ALTO RISCO"),
    ("0411010034", "PARTO CESARIANO"),
    ("0411010042", "PARTO CESARIANO C/ LAQUEADURA TUBARIA"),
    ("0411020013", "CURETAGEM POS-ABORTAMENTO / PUERPERAL"),
    ("0411020021", "EMBRIOTOMIA"),
]
# Grupos de PROCOBST.CNV que espelham a lista do csapAIH (4 e 5, "outras
# intervenções obstétricas", são faixas inteiras da tabela e ficam fora)
CNV_GROUPS = {"1": "partos normais", "2": "partos cesáreos", "3": "abortamentos"}
CID10_DELIVERY = ["O80", "O81", "O82", "O83", "O84"]
CID9_DELIVERY_RUBRICS = ["650", "669.5", "669.6", "669.7"]


def parse_procobst():
    rows = []
    with open(PROCOBST_CNV, encoding="latin-1") as fh:
        for ln in fh.read().splitlines()[1:]:
            m = re.match(r"^\s*(\d+)\s+(.*?)(\d{8})\s*$", ln)
            if not m:
                continue
            grp, name, code = m.group(1), m.group(2).strip(), m.group(3)
            if grp in CNV_GROUPS:
                rows.append({"code": code, "name": name, "group": CNV_GROUPS[grp]})
    if not rows:
        raise SystemExit(f"nenhum código lido de {PROCOBST_CNV}")
    seen = set()
    out = []
    for r in rows:
        if r["code"] in seen:
            raise SystemExit(f"código repetido em PROCOBST.CNV: {r['code']}")
        seen.add(r["code"])
        out.append(r)
    return out


def cid9_delivery_codes():
    with open(CID9_CODES, encoding="utf-8") as fh:
        codes = json.load(fh)["codes"]
    out = []
    for c in codes:
        rub = c["rubric"]
        cat = rub.split(".")[0]
        if rub in CID9_DELIVERY_RUBRICS or cat in CID9_DELIVERY_RUBRICS:
            out.append({"code6": c["code6"], "rubric": rub, "label": c["label"], "valid": c["valid"]})
    if not out:
        raise SystemExit("nenhum código CID-9 de parto encontrado")
    return out


def main():
    old = parse_procobst()
    cid9 = cid9_delivery_codes()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc = {
        "metadata": {
            "description": "Universo de cálculo do % ICSAP, como o pacote R csapAIH define por padrão (procobst.rm, parto.rm, longa.rm): internações excluídas do numerador E do denominador antes da classificação. A lista de diagnósticos CSAP (Portaria 221/2008) não muda.",
            "method_source": {
                "name": "csapAIH — Classificar Condições Sensíveis à Atenção Primária (pacote R)",
                "author": "Fúlvio Borges Nedel",
                "version": "0.0.4.8 (2026-01-16)",
                "url": "https://github.com/fulvionedel/csapAIH",
                "license": "GPL-3",
                "functions": ["csapAIH()", "proc.obst()", "partos()"],
            },
            "generated_by": "scripts/csap-universe-tables.py",
            "generated_at": now,
            "rules_order": ["procedimento_obstetrico", "parto", "longa_permanencia"],
            "notes": [
                "PROC_REA tem 10 dígitos (SIGTAP) de 2008 em diante e 8 dígitos (tabela antiga do SIH) de 1992 a 2007; as duas listas de procedimentos se aplicam pelo comprimento do código.",
                "A lista SIGTAP é a do csapAIH ao pé da letra; a da tabela antiga vem dos grupos partos normais, cesáreos e abortamentos de PROCOBST.CNV (DATASUS), o equivalente da época.",
                "Diagnóstico de parto em CID-9: 650 e 669.5–669.7 (não há na CID-9 da OMS um código de 'parto múltiplo' como O84; 651 é gestação múltipla e não conta).",
                "IDENT = 5 (AIH de longa permanência) vale em todas as eras (IDENT.CNV).",
            ],
        },
        "procedures_sigtap": [{"code": c, "name": n} for c, n in SIGTAP],
        "procedures_old_table": old,
        "delivery_diagnosis_cid10": CID10_DELIVERY,
        "delivery_diagnosis_cid9": {"rubrics": CID9_DELIVERY_RUBRICS, "codes6": cid9},
        "long_stay_ident": ["5"],
    }
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"{OUT}: SIGTAP {len(SIGTAP)}, tabela antiga {len(old)}, CID-9 parto {len(cid9)} códigos")


if __name__ == "__main__":
    main()
