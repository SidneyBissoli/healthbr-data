"""Gera as tabelas CID-9 versionadas que o builder 2.5.0 e o servidor usam:

  tables/cid9-codes.json       — os 8.240 códigos de 6 dígitos das tabelas
                                 CID9_01..17 + CID9_SUP do TAB_SIH_199201-199712.zip
                                 (DATASUS), cada um com a rubrica CID-9 (OMS 1975),
                                 a categoria de 3 dígitos, o rótulo do DATASUS, o
                                 capítulo CID-9 da tabela de origem, o capítulo
                                 CID-10 equivalente e se o DATASUS o marca válido.
  tables/cid9-chapters.json    — o mapa categoria CID-9 → capítulo CID-10 (faixas
                                 + exceções), documentado em analise-002 §3.

Cadeia (nada é digitado à mão):
  TAB_SIH_199201-199712.zip (FTP do DATASUS, pasta Auxiliar) → extraído em
  insumos/tab/ (gitignored; bash fetch-insumos.sh baixa do canal) →
  estudo-1992-1997-cnv.py → insumos/cid9_codes.csv (gitignored) → este script →
  os dois JSON em tables/ (versionados).

Uso:  python tables/generators/cid9-tables.py   (a partir de scripts/pipeline/sih-cubos/)
"""
import csv
import json
import os
import re
from collections import Counter
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))          # tables/generators/
TABLES = os.path.dirname(HERE)                             # tables/ (versionado)
CSV_IN = os.path.join(HERE, "insumos", "cid9_codes.csv")   # gerado por estudo-1992-1997-cnv.py
OUT_CODES = os.path.join(TABLES, "cid9-codes.json")
OUT_CHAPTERS = os.path.join(TABLES, "cid9-chapters.json")

# Categoria CID-9 (3 dígitos) → capítulo CID-10 equivalente, por faixa.
# Fonte: docs/analise-002-sih-1992-1997.md §3 (bate com os 10 grupos IDB do
# DATASUS); as três exceções são categorias que a CID-10 moveu de capítulo.
RANGES = [
    (1, 139, 1),     # I   Infecciosas e parasitárias
    (140, 239, 2),   # II  Neoplasias
    (240, 279, 4),   # IV  Endócrinas, nutricionais e metabólicas
    (280, 289, 3),   # III Sangue e órgãos hematopoéticos
    (290, 319, 5),   # V   Transtornos mentais
    (320, 359, 6),   # VI  Sistema nervoso
    (360, 379, 7),   # VII Olho e anexos
    (380, 389, 8),   # VIII Ouvido e apófise mastoide
    (390, 459, 9),   # IX  Aparelho circulatório
    (460, 519, 10),  # X   Aparelho respiratório
    (520, 579, 11),  # XI  Aparelho digestivo
    (580, 629, 14),  # XIV Aparelho geniturinário
    (630, 676, 15),  # XV  Gravidez, parto e puerpério
    (680, 709, 12),  # XII Pele e tecido subcutâneo
    (710, 739, 13),  # XIII Osteomuscular e tecido conjuntivo
    (740, 759, 17),  # XVII Malformações congênitas
    (760, 779, 16),  # XVI Afecções do período perinatal
    (780, 799, 18),  # XVIII Sintomas e sinais
    (800, 999, 19),  # XIX Lesões e envenenamentos
]
PREFIX_CHAPTER = {"E": 20, "V": 21}  # E800–E999 causas externas; V01–V82 fatores
EXCEPTIONS = {"135": 3, "279": 3, "446": 13}  # sarcoidose, imunidade, poliarterite


def chapter_for(category):
    if category in EXCEPTIONS:
        return EXCEPTIONS[category]
    if category[0] in PREFIX_CHAPTER:
        return PREFIX_CHAPTER[category[0]]
    n = int(category)
    for lo, hi, ch in RANGES:
        if lo <= n <= hi:
            return ch
    return None


def clean_label(rubric, label):
    # Rótulos dos códigos E vêm com a rubrica na frente ("E800.0 Empregado ...");
    # categorias sem subdivisão vêm como "014 - Tuberculose ...".
    label = re.sub(r"^E\d{3}\.\d\s+", "", label)
    label = re.sub(r"^\d{3}\s+-\s+", "", label)
    label = re.sub(r"^\d{3},\d\s+", "", label)
    return label.strip()


def main():
    with open(CSV_IN, encoding="utf-8", newline="") as fh:
        rows = list(csv.DictReader(fh))
    codes = []
    seen = set()
    for r in rows:
        code6 = r["code6"]
        if code6 in seen:
            raise SystemExit(f"código repetido: {code6}")
        seen.add(code6)
        rubric = r["cid9"].replace(",", ".")  # 926,6 na tabela do DATASUS
        if not re.fullmatch(r"[EV]?\d{2,3}(\.\d)?", rubric):
            raise SystemExit(f"rubrica fora do padrão: {r}")
        category = rubric.split(".")[0]
        chapter = chapter_for(category)
        if chapter is None:
            raise SystemExit(f"categoria sem capítulo: {category} ({code6})")
        codes.append({
            "code6": code6,
            "rubric": rubric,
            "category": category,
            "chapter": chapter,
            "chapter_cid9": r["chapter"],  # 1..17 ou V, pela tabela CID9_xx de origem
            "label": clean_label(rubric, r["label"]),
            "valid": r["kind"] == "valido",
        })
    codes.sort(key=lambda c: c["code6"])
    n_valid = sum(c["valid"] for c in codes)
    by_chapter = Counter(c["chapter"] for c in codes if c["valid"])
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    chapters_doc = {
        "metadata": {
            "description": "Categoria CID-9 (OMS, 1975) → capítulo CID-10 equivalente, por faixa de categoria, com as exceções que a CID-10 moveu de capítulo. Usado pelo builder (cid_chapter dos cubos de 1992–1997) e pelo servidor.",
            "evidence": "docs/analise-002-sih-1992-1997.md §3 — bate com os 10 grupos IDB do DATASUS; exceções cobrem 0,15 % das AIH de 1992–1997",
            "generated_by": "scripts/cid9-tables.py",
            "generated_at": now,
        },
        "ranges": [{"from": lo, "to": hi, "chapter": ch} for lo, hi, ch in RANGES],
        "prefixes": [
            {"prefix": "E", "categories": "E800–E999", "chapter": 20, "code6_prefix": "1"},
            {"prefix": "V", "categories": "V01–V82", "chapter": 21, "code6_prefix": "2"},
        ],
        "exceptions": [
            {"category": "135", "chapter": 3, "note": "Sarcoidose: CID-9 cap. I → CID-10 D86 (cap. III)"},
            {"category": "279", "chapter": 3, "note": "Transtornos do mecanismo imunitário: CID-9 cap. III → CID-10 D80–D89 (cap. III; a faixa 240–279 vai para o IV)"},
            {"category": "446", "chapter": 13, "note": "Poliarterite nodosa e afins: CID-9 cap. VII circulatório → CID-10 M30–M31 (cap. XIII)"},
        ],
    }
    codes_doc = {
        "metadata": {
            "description": "Códigos de DIAG_PRINC do SIH/SUS de 1992–1997 (CID-9 OMS 1975 na codificação do DATASUS: prefixo 0/1/2 + categoria + subcategoria + dígito verificador módulo 11), decodificados por tabela — a tabela tem 2 exceções à fórmula do DV (080120, 080781).",
            "source": "DATASUS, TAB_SIH_199201-199712.zip (pasta Auxiliar do FTP do SIH/SUS), tabelas CID9_01.CNV … CID9_17.CNV e CID9_SUP.CNV",
            "evidence": "docs/analise-002-sih-1992-1997.md §3",
            "generated_by": "scripts/estudo-1992-1997-cnv.py → scripts/cid9-tables.py",
            "generated_at": now,
            "fields": {
                "code6": "código de 6 dígitos como aparece em DIAG_PRINC",
                "rubric": "rubrica CID-9 (NNN.N, NNN, ENNN.N, VNN.N)",
                "category": "categoria de 3 dígitos (com prefixo E/V) — o cid_group dos cubos",
                "chapter": "capítulo CID-10 equivalente (1–21), por tables/cid9-chapters.json",
                "chapter_cid9": "capítulo CID-9 da tabela de origem (1–17; V = classificação suplementar)",
                "label": "rótulo do DATASUS (Latin-1 convertido para UTF-8)",
                "valid": "false quando o DATASUS marca 'Código inválido - fora da CID'",
            },
            "total_codes": len(codes),
            "valid_codes": n_valid,
            "valid_by_chapter": {str(k): v for k, v in sorted(by_chapter.items())},
        },
        "codes": codes,
    }
    with open(OUT_CHAPTERS, "w", encoding="utf-8") as fh:
        json.dump(chapters_doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    with open(OUT_CODES, "w", encoding="utf-8") as fh:
        fh.write('{\n  "metadata": ')
        fh.write(json.dumps(codes_doc["metadata"], ensure_ascii=False, indent=2).replace("\n", "\n  "))
        fh.write(',\n  "codes": [\n')
        fh.write(",\n".join("    " + json.dumps(c, ensure_ascii=False) for c in codes))
        fh.write("\n  ]\n}\n")
    print(f"{OUT_CODES}: {len(codes)} códigos ({n_valid} válidos); por capítulo CID-10: {dict(sorted(by_chapter.items()))}")
    print(f"{OUT_CHAPTERS}: {len(RANGES)} faixas, 2 prefixos, {len(EXCEPTIONS)} exceções")


if __name__ == "__main__":
    main()
