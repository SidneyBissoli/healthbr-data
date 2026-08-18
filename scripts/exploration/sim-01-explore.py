"""
sim-01-explore.py — Exploração SIM (Fase 2), versão Python.

Equivalente de sim-01-explore.R para ambientes sem read.dbc (o PC Windows do
mantenedor). Foi com este script que os números de docs/sim/exploration-pt.md
foram produzidos em 18/ago/2026.

Dependências: pip install datasus-dbc dbfread polars pyarrow
  - datasus_dbc.decompress(): .dbc -> .dbf (mesmo algoritmo do read.dbc)
  - dbfread (raw=True): valores brutos do DBF (com padding); o R (foreign::read.dbf,
    usado por read.dbc) apara espaços e devolve NA para vazio — conferido à parte.

Uso:
  python sim-01-explore.py fetch            # baixa as amostras para ./dbc/
  python sim-01-explore.py schema values counts br derived parquet   # análises
  python sim-01-explore.py                  # tudo (fetch + análises)
Os arquivos de trabalho ficam ao lado do script (dbc/, dbf/, *.parquet).
"""
import sys, os, re, json, time, urllib.request
import polars as pl

S = os.path.dirname(os.path.abspath(__file__))
STEPS = set(sys.argv[1:]) or {"fetch", "schema", "values", "counts", "br", "derived", "parquet"}

# ============================================================================
# FETCH — amostras do FTP
# ============================================================================
if "fetch" in STEPS:
    OUT = os.path.join(S, "dbc"); os.makedirs(OUT, exist_ok=True)
    B = "ftp://ftp.datasus.gov.br/dissemin/publicos/SIM/"

    UPPER_YEARS = {2007, 2010, 2011, 2012}
    def cid10(uf, y):
        ext = ".DBC" if y in UPPER_YEARS else ".dbc"
        return f"CID10/DORES/DO{uf}{y}{ext}"
    def cid9(uf, yy):
        return f"CID9/DORES/DOR{uf}{yy:02d}.DBC"
    def prelim(uf, y):
        return f"PRELIM/DORES/DO{uf}{y}.dbc"

    targets = []
    # AC — every year (schema evolution)
    for yy in range(79, 96): targets.append(cid9("AC", yy))
    for y in range(1996, 2025): targets.append(cid10("AC", y))
    for y in (2025, 2026): targets.append(prelim("AC", y))
    # DF — volume reference at key years
    for yy in (79, 85, 90, 95): targets.append(cid9("DF", yy))
    for y in (1996, 2000, 2005, 2010, 2015, 2020, 2024): targets.append(cid10("DF", y))
    targets.append(prelim("DF", 2025))
    # derived files (one each, most recent + one old)
    for t in ("DOFET", "DOEXT", "DOINF", "DOMAT", "DOREXT"):
        targets.append(f"CID10/DOFET/{t}24.DBC")
    targets.append("CID10/DOFET/DOFET96.DBC")
    targets.append("CID9/DOFET/DOFET95.DBC")
    targets.append("CID9/DOIGN/DORIG95.DBC")
    # BR vs UF comparison year 1996 (small)
    UFS = "AC AL AM AP BA CE DF ES GO MA MG MS MT PA PB PE PI PR RJ RN RO RR RS SC SE SP TO".split()
    for uf in UFS: targets.append(cid10(uf, 1996))
    targets.append(cid10("BR", 1996))
    # also 1994 CID9 all UFs vs BR (row-count check for CID9)
    for uf in UFS: targets.append(cid9(uf, 94))
    targets.append(cid9("BR", 94))
    # one big modern file for size/throughput reference
    targets.append(cid10("SP", 2024))
    targets.append(cid10("BR", 2024))

    for t in targets:
        dest = os.path.join(OUT, os.path.basename(t))
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            continue
        for attempt in range(3):
            try:
                t0 = time.time()
                urllib.request.urlretrieve(B + t, dest)
                print(f"ok   {t} {os.path.getsize(dest)/1024:.0f} KiB {time.time()-t0:.1f}s", flush=True)
                break
            except Exception as e:
                print(f"fail {t} ({e})", flush=True)
                if os.path.exists(dest): os.remove(dest)
                time.sleep(3)

# ============================================================================
# ANÁLISES
# ============================================================================

DBC = os.path.join(S, "dbc"); DBF = os.path.join(S, "dbf"); os.makedirs(DBF, exist_ok=True)
import datasus_dbc, dbfread

def to_dbf(name):
    src = os.path.join(DBC, name); dst = os.path.join(DBF, re.sub(r"\.dbc$", ".dbf", name, flags=re.I))
    if not os.path.exists(dst):
        datasus_dbc.decompress(src, dst)
    return dst

def fields(name):
    d = dbfread.DBF(to_dbf(name), load=False, encoding="latin-1", char_decode_errors="replace")
    return [(f.name, f.type, f.length, f.decimal_count) for f in d.fields], len(d)

def read_df(name):
    """All columns as Utf8 (raw text, stripped like read.dbc/foreign does NOT strip -> keep raw)."""
    d = dbfread.DBF(to_dbf(name), load=False, encoding="latin-1", char_decode_errors="replace",
                    raw=True)
    cols = [f.name for f in d.fields]
    rows = {c: [] for c in cols}
    for rec in d:
        for c in cols:
            v = rec[c]
            rows[c].append(v.decode("latin-1") if isinstance(v, bytes) else (None if v is None else str(v)))
    return pl.DataFrame({c: pl.Series(rows[c], dtype=pl.Utf8) for c in cols})

def year_of(name):
    m = re.match(r"^DOR?([A-Z]{2})(\d{2,4})\.dbc$", name, re.I)
    uf, y = m.group(1), m.group(2)
    y = int(y); y = y if y > 100 else (1900 + y if y >= 79 else 2000 + y)
    return uf, y

# ─────────────────────────────────────────────────────────────────────────────
if "schema" in STEPS:
    print("=== SCHEMA EVOLUTION (AC, all years) ===")
    ac = sorted([f for f in os.listdir(DBC) if re.match(r"^DOR?AC\d+\.dbc$", f, re.I)], key=lambda f: year_of(f)[1])
    prev = None; sch = {}
    for f in ac:
        fl, n = fields(f); uf, y = year_of(f)
        names = [x[0] for x in fl]
        sch[y] = fl
        added = [c for c in names if prev is not None and c not in prev]
        removed = [c for c in prev if c not in names] if prev is not None else []
        print(f"{y}: {len(names):3d} cols, {n:6d} rows  file={f}" + (f"\n      +{added}" if added else "") + (f"\n      -{removed}" if removed else ""))
        prev = names
    # signature groups
    print("\n--- distinct schemas (by ordered column list) ---")
    sig = {}
    for y, fl in sch.items():
        key = tuple(x[0] for x in fl)
        sig.setdefault(key, []).append(y)
    for i, (k, ys) in enumerate(sorted(sig.items(), key=lambda kv: min(kv[1])), 1):
        print(f"schema {i:2d}: {len(k):3d} cols, years {ys}")
    print("\n--- full field list, latest year (name type len dec) ---")
    for x in sch[max(sch)]:
        print("   ", x)
    print("\n--- full field list, 1979 ---")
    for x in sch[1979]:
        print("   ", x)
    print("\n--- full field list, 1996 ---")
    for x in sch[1996]:
        print("   ", x)
    json.dump({str(y): [list(x) for x in fl] for y, fl in sch.items()}, open(os.path.join(S, "schemas_ac.json"), "w"), indent=1)
    # columns common to all years
    allsets = [set(x[0] for x in fl) for fl in sch.values()]
    common = set.intersection(*allsets)
    print("\ncommon to ALL years (1979-2026):", sorted(common))
    common10 = set.intersection(*[set(x[0] for x in fl) for y, fl in sch.items() if y >= 1996])
    print("common to CID10 era (1996-2026):", len(common10), sorted(common10))
    # numeric fields (type N) — anywhere
    numeric = {}
    for y, fl in sch.items():
        for nm, t, ln, dc in fl:
            if t != "C": numeric.setdefault((nm, t, ln, dc), []).append(y)
    print("\nnon-character DBF fields (name,type,len,dec): years")
    for k, ys in sorted(numeric.items()):
        print("   ", k, f"{min(ys)}-{max(ys)} ({len(ys)})")

# ─────────────────────────────────────────────────────────────────────────────
if "values" in STEPS:
    print("\n=== VALUE FORMATS ===")
    def show(name, cols, n=5):
        df = read_df(name)
        print(f"\n--- {name} ({df.height} rows) ---")
        for c in cols:
            if c not in df.columns: print(f"  {c}: (absent)"); continue
            s = df[c]
            vals = s.drop_nulls().unique().to_list()
            lens = sorted(set(len(v) for v in vals))
            blank = (s.str.strip_chars() == "").sum() + s.null_count()
            ex = [v for v in vals if v.strip()][:n]
            print(f"  {c:10s} n_distinct={len(vals):6d} lens={lens} blank/null={blank:5d} ex={ex}")
    show("DORDF79.DBC", ["DTOBITO", "DTNASC", "IDADE", "SEXO", "CAUSABAS", "CODMUNRES", "MUNIRES", "MUNIOCOR", "ESTCIV", "OCUP", "TIPOBITO", "NUMERODO", "LOCOCOR", "ASSISTMED", "LINHAA", "LINHAB", "CAUSABAS_O"][:20])
    show("DORDF95.DBC", ["DTOBITO", "DTNASC", "IDADE", "SEXO", "CAUSABAS", "CODMUNRES", "MUNIRES", "MUNIOCOR", "ESTCIV", "OCUP", "TIPOBITO", "NUMERODO", "LOCOCOR", "ASSISTMED", "LINHAA", "LINHAB", "CAUSABAS_O"])
    show("DODF1996.dbc", ["DTOBITO", "DTNASC", "IDADE", "SEXO", "CAUSABAS", "CODMUNRES", "CODMUNOCOR", "ESTCIV", "OCUP", "TIPOBITO", "NUMERODO", "LOCOCOR", "ASSISTMED", "LINHAA", "LINHAB", "CAUSABAS_O", "RACACOR", "ESC", "CODESTAB", "HORAOBITO", "CIRCOBITO", "DTATESTADO"])
    show("DODF2010.DBC", ["DTOBITO", "DTNASC", "IDADE", "SEXO", "CAUSABAS", "CODMUNRES", "CODMUNOCOR", "ESTCIV", "OCUP", "TIPOBITO", "NUMERODO", "LOCOCOR", "ASSISTMED", "LINHAA", "LINHAB", "CAUSABAS_O", "RACACOR", "ESC", "ESC2010", "CODESTAB", "HORAOBITO", "CIRCOBITO", "DTATESTADO", "DTCADASTRO", "DTRECEBIM", "CONTADOR"])
    show("DODF2024.dbc", ["DTOBITO", "DTNASC", "IDADE", "SEXO", "CAUSABAS", "CODMUNRES", "CODMUNOCOR", "ESTCIV", "OCUP", "TIPOBITO", "NUMERODO", "LOCOCOR", "ASSISTMED", "LINHAA", "LINHAB", "CAUSABAS_O", "RACACOR", "ESC", "ESC2010", "ESCMAE2010", "CODESTAB", "HORAOBITO", "CIRCOBITO", "DTATESTADO", "DTCADASTRO", "DTRECEBIM", "CONTADOR", "PESO", "IDADEMAE", "ORIGEM", "ATESTANTE", "STCODIFICA", "CODIFICADO", "VERSAOSIST", "VERSAOSCB", "DTCONINV", "FONTEINV", "OPOR_DO", "COMUNSVOIM"])
    show("DODF2025.dbc", ["DTOBITO", "NUMERODO", "CAUSABAS", "CODMUNRES", "CONTADOR", "OPOR_DO"])
    # trailing spaces? padding?
    df = read_df("DODF2024.dbc")
    pad = {c: int((df[c].str.len_chars() != df[c].str.strip_chars().str.len_chars()).sum()) for c in df.columns}
    print("\ncolumns with leading/trailing whitespace in raw DBF (DODF2024):", {k: v for k, v in pad.items() if v})
    empt = {c: int((df[c].str.strip_chars() == "").sum()) for c in df.columns}
    print("blank counts per column (DODF2024):", empt)
    # duplicates NUMERODO/CONTADOR
    print("CONTADOR distinct:", df["CONTADOR"].n_unique(), "of", df.height, "min/max:", df["CONTADOR"].min(), df["CONTADOR"].max())

# ─────────────────────────────────────────────────────────────────────────────
if "counts" in STEPS:
    print("\n=== ROW COUNTS (DF, key years) + all sample files ===")
    rows = []
    for f in sorted(os.listdir(DBC)):
        fl, n = fields(f)
        rows.append((f, n, len(fl), os.path.getsize(os.path.join(DBC, f)), os.path.getsize(to_dbf(f))))
    for f, n, nc, sz, szd in rows:
        print(f"  {f:16s} rows={n:8d} cols={nc:3d} dbc={sz/1024:9.0f} KiB dbf={szd/1024:9.0f} KiB ratio={szd/sz:5.1f}")

# ─────────────────────────────────────────────────────────────────────────────
if "br" in STEPS:
    print("\n=== DOBR vs sum of UF files ===")
    for yr, pat, br in ((1996, r"^DO(?!BR)[A-Z]{2}1996\.dbc$", "DOBR1996.dbc"),
                        (1994, r"^DOR(?!BR)[A-Z]{2}94\.DBC$", "DORBR94.DBC")):
        ufs = [f for f in os.listdir(DBC) if re.match(pat, f)]
        tot = sum(fields(f)[1] for f in ufs)
        _, nbr = fields(br)
        print(f"  {yr}: {len(ufs)} UF files, sum rows={tot}, {br} rows={nbr}, diff={nbr-tot}")
        # schema equal?
        fu = fields(ufs[0])[0]; fb = fields(br)[0]
        print(f"        schema equal to UF? {[x[0] for x in fu] == [x[0] for x in fb]}")
        if yr == 1996:
            dbr = read_df(br)
            # what does the BR file key on? check CODMUNRES UF distribution vs UF file
            ufcol = dbr["CODMUNRES"].str.slice(0, 2).value_counts().sort("CODMUNRES")
            print("  DOBR1996 CODMUNRES UF prefix counts:", dict(zip(ufcol["CODMUNRES"], ufcol["count"])))
            dsp = read_df("DOSP1996.dbc")
            print("  DOSP1996 rows", dsp.height, "| CODMUNRES prefixes:", dict(zip(*[s.to_list() for s in dsp["CODMUNRES"].str.slice(0,2).value_counts().sort("CODMUNRES")])))
            print("  DOSP1996 CODMUNOCOR prefixes:", dict(zip(*[s.to_list() for s in dsp["CODMUNOCOR"].str.slice(0,2).value_counts().sort("CODMUNOCOR")])))
            # UF file = residence-based? Check overlap of NUMERODO between DOSP1996 and DOBR1996 subset UF=35
            brsp = dbr.filter(pl.col("CODMUNRES").str.slice(0, 2) == "35")
            print("  DOBR1996 CODMUNRES=35 rows:", brsp.height, "vs DOSP1996 rows:", dsp.height)

# ─────────────────────────────────────────────────────────────────────────────
if "derived" in STEPS:
    print("\n=== DERIVED FILES (DOFET/DOEXT/DOINF/DOMAT/DOREXT) ===")
    dbr = read_df("DOBR2024.dbc")
    print("DOBR2024 rows", dbr.height, "cols", dbr.width, "| CONTADOR distinct", dbr["CONTADOR"].n_unique(), "min/max", dbr["CONTADOR"].min(), dbr["CONTADOR"].max())
    print("DOBR2024 TIPOBITO:", dict(zip(*[s.to_list() for s in dbr["TIPOBITO"].value_counts().sort("TIPOBITO")])))
    KC = ["DTOBITO","DTNASC","HORAOBITO","SEXO","CODMUNRES","CODMUNOCOR","CAUSABAS","LINHAA","IDADE"]
    keyb = set(zip(*[dbr[c].to_list() for c in KC])); ctb = set(zip(dbr["CONTADOR"].to_list(), dbr["DTOBITO"].to_list()))
    for f in ("DOFET24.DBC", "DOEXT24.DBC", "DOINF24.DBC", "DOMAT24.DBC", "DOREXT24.DBC"):
        d = read_df(f); fl, _ = fields(f)
        same = [x[0] for x in fl] == [x[0] for x in fields("DOBR2024.dbc")[0]]
        extra = [c for c in d.columns if c not in dbr.columns]; missing = [c for c in dbr.columns if c not in d.columns]
        keys = set(zip(*[d[c].to_list() for c in KC])) if all(c in d.columns for c in KC) else set()
        inter = len(keys & keyb)
        ctd = set(zip(d["CONTADOR"].to_list(), d["DTOBITO"].to_list())) if "CONTADOR" in d.columns else set()
        print(f"     (CONTADOR,DTOBITO) pairs found in DOBR2024: {len(ctd & ctb)}/{len(ctd)}")
        print(f"\n  {f}: rows={d.height} cols={d.width} schema==DOBR2024:{same} extra={extra} missing={missing[:10]}{'...' if len(missing)>10 else ''}")
        print(f"     composite-key rows found in DOBR2024: {inter}/{len(keys)} (distinct keys)")
        if "TIPOBITO" in d.columns:
            print("     TIPOBITO:", dict(zip(*[s.to_list() for s in d["TIPOBITO"].value_counts().sort("TIPOBITO")])))
        if "CAUSABAS" in d.columns:
            print("     CAUSABAS chapter prefixes:", dict(list(zip(*[s.to_list() for s in d["CAUSABAS"].str.slice(0,1).value_counts().sort("count", descending=True)]))[:8]))
        if "IDADE" in d.columns:
            print("     IDADE first digit:", dict(zip(*[s.to_list() for s in d["IDADE"].str.slice(0,1).value_counts().sort("IDADE")])))
    # infer definitions
    inf = dbr.filter(pl.col("IDADE").str.slice(0, 1).is_in(["0", "1", "2", "3"]) | (pl.col("IDADE") == "400"))
    print("\n  DOBR2024 rows with IDADE < 1 year (codes 0xx-3xx, 400):", inf.height, "| DOINF24 rows:", read_df("DOINF24.DBC").height)
    ext = dbr.filter(pl.col("CAUSABAS").str.slice(0, 1).is_in(["V", "W", "X", "Y"]))
    print("  DOBR2024 rows CAUSABAS in V-Y (external causes):", ext.height, "| DOEXT24 rows:", read_df("DOEXT24.DBC").height)
    print("  DOBR2024 TIPOBITO=1 (fetal):", dbr.filter(pl.col("TIPOBITO") == "1").height, "| DOFET24 rows:", read_df("DOFET24.DBC").height)
    print("\n  DOFET96 vs DOFET95 vs DORIG95 (fields):")
    for f in ("DOFET96.DBC", "DOFET95.DBC", "DORIG95.DBC"):
        fl, n = fields(f); print(f"   {f}: rows={n} cols={len(fl)} {[x[0] for x in fl][:40]}")

# ─────────────────────────────────────────────────────────────────────────────
if "parquet" in STEPS:
    print("\n=== PARQUET SIZE TEST (all Utf8, zstd) ===")
    import pyarrow.parquet as pq, pyarrow as pa
    for f in ("DODF2024.dbc", "DOSP2024.dbc", "DOBR2024.dbc", "DORDF95.DBC", "DODF1996.dbc"):
        t0 = time.time(); df = read_df(f); t1 = time.time()
        out = os.path.join(S, re.sub(r"\.dbc$", ".parquet", f, flags=re.I))
        pq.write_table(df.to_arrow(), out, compression="zstd")
        sz = os.path.getsize(out); szd = os.path.getsize(os.path.join(DBC, f))
        print(f"  {f}: rows={df.height} dbc={szd/1024:.0f} KiB parquet={sz/1024:.0f} KiB ratio={sz/szd:.2f} read={t1-t0:.1f}s")
    dsp = read_df("DOSP2024.dbc")
    print("  DOSP2024 CODMUNRES UF prefixes:", dict(zip(*[s.to_list() for s in dsp["CODMUNRES"].str.slice(0,2).value_counts().sort("count", descending=True)])))
    print("  DOSP2024 CODMUNOCOR UF prefixes:", dict(zip(*[s.to_list() for s in dsp["CODMUNOCOR"].str.slice(0,2).value_counts().sort("count", descending=True)])))
    print("  DOSP2024 DTOBITO year (dd mm yyyy -> substr 5..8):", dict(zip(*[s.to_list() for s in dsp["DTOBITO"].str.slice(4,4).value_counts().sort("DTOBITO")])))
