"""Parse the CID-9 CNV tables of TAB_SIH_199201-199712.zip and verify the
check-digit formula of the 6-digit DIAG_PRINC code.

Output (em insumos/, gitignored): cid9_codes.csv (code6, cid9, label, chapter, kind) and a report on
stdout. Encoding of CNV files is Latin-1.
"""
import csv, glob, os, re, sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
INSUMOS = os.path.join(HERE, "insumos")          # gitignored; bash fetch-insumos.sh
TAB = os.path.join(INSUMOS, "tab")

def parse_cnv(path):
    """Yield (seq, label, codes_field) for each data line of a CNV file."""
    with open(path, encoding="latin-1") as fh:
        lines = fh.read().splitlines()
    for ln in lines[1:]:
        m = re.match(r"^\s*(\d+)\s+(.*?)\s+((?:[0-9]{4,6}(?:-[0-9]{4,6})?,?\s*)+|,)$", ln)
        if not m:
            continue
        seq, label, codes = m.group(1), m.group(2).strip(), (m.group(3) or "").strip()
        yield int(seq), label, codes

def dv(code5):
    s = sum(int(d) * w for d, w in zip(code5, (6, 5, 4, 3, 2)))
    r = (11 - s % 11) % 11
    return 0 if r == 10 else r

rows = []          # code6, cid9, label, chapter, kind
seen = {}
bad = []
# chapter files CID9_01..17 + SUP (V codes)
files = [(f"CID9_{i:02d}.CNV", str(i)) for i in range(1, 18)] + [("CID9_SUP.CNV", "V")]
for fname, chap in files:
    for seq, label, codes in parse_cnv(os.path.join(TAB, fname)):
        for c in [x.strip() for x in codes.split(",") if x.strip()]:
            if not re.fullmatch(r"\d{6}", c):
                bad.append((fname, label, c)); continue
            m = re.match(r"^(V?\d{2,3}\.\d)\s+(.*)$", label)
            cid9 = m.group(1) if m else label.split()[0]
            lab = m.group(2) if m else label
            kind = "invalido" if "inv" in lab.lower() and "fora da cid" in lab.lower() else "valido"
            if c in seen and seen[c] != (cid9, chap):
                bad.append((fname, label, c, "dup", seen[c]))
            seen[c] = (cid9, chap)
            rows.append((c, cid9, lab, chap, kind))

# verify check digit
ok = sum(1 for r in rows if dv(r[0][:5]) == int(r[0][5]))
print(f"codigos nas tabelas CID9_01..17 + SUP: {len(rows)} ({len(seen)} distintos)")
print(f"digito verificador (pesos 6,5,4,3,2; mod 11; 10->0) confere em {ok}/{len(rows)}")
fails = [r for r in rows if dv(r[0][:5]) != int(r[0][5])]
print("falhas:", fails[:10])
print("problemas de parse:", bad[:10], len(bad))
kinds = Counter(r[4] for r in rows)
print("validos/invalidos:", dict(kinds))
by_chap = Counter(r[3] for r in rows if r[4] == "valido")
print("validos por capitulo:", dict(sorted(by_chap.items(), key=lambda x: (x[0] == 'V', int(x[0]) if x[0] != 'V' else 0))))

# structure check: code6 = '0' + cat(3) + sub(1) + dv  (V codes: '2' + 0NN + sub + dv)
struct_ok = 0
for c, cid9, lab, chap, kind in rows:
    cat, sub = cid9.split(".") if "." in cid9 else (cid9, "")
    if cat.startswith("V"):
        exp = "2" + cat[1:].zfill(3) + sub
    else:
        exp = "0" + cat.zfill(3) + sub
    if c[:5] == exp:
        struct_ok += 1
print(f"estrutura prefixo+categoria+subcategoria confere em {struct_ok}/{len(rows)}")

# CID9XINV: which 6-digit codes are listed as invalid there?
inv = set()
for seq, label, codes in parse_cnv(os.path.join(TAB, "CID9XINV.CNV")):
    for c in [x.strip() for x in codes.split(",") if x.strip()]:
        if re.fullmatch(r"\d{6}", c):
            inv.add(c)
print(f"CID9XINV.CNV: {len(inv)} codigos de 6 digitos; dv confere em {sum(1 for c in inv if dv(c[:5]) == int(c[5]))}")
print(f"  em comum com as tabelas de capitulo: {len(inv & set(seen))}; so no XINV: {len(inv - set(seen))}")

# CID9_3D categories
cats = {}
for seq, label, codes in parse_cnv(os.path.join(TAB, "CID9_3D.CNV")):
    m = re.match(r"^(\d{3}|V\d{2}|E\d{3})\s*-\s*(.*)$", label)
    if m and re.fullmatch(r"[0-9]{4}", codes.rstrip(",")):
        cats[codes.rstrip(",")] = (m.group(1), m.group(2))
print(f"CID9_3D.CNV: {len(cats)} categorias a 3 digitos")

# chapter ranges from CID9_CAP.CNV
chaps = []
for seq, label, codes in parse_cnv(os.path.join(TAB, "CID9_CAP.CNV")):
    chaps.append((seq, label, codes))
print("CID9_CAP.CNV:", len(chaps), "linhas")

with open(os.path.join(INSUMOS, "cid9_codes.csv"), "w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh)
    w.writerow(["code6", "cid9", "label", "chapter", "kind"])
    w.writerows(rows)
with open(os.path.join(INSUMOS, "cid9_cats.csv"), "w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh)
    w.writerow(["cat4", "cid9_cat", "label"])
    for k, (a, b) in sorted(cats.items()):
        w.writerow([k, a, b])
with open(os.path.join(INSUMOS, "cid9_xinv.txt"), "w") as fh:
    fh.write("\n".join(sorted(inv)))
