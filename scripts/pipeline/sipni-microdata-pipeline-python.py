#!/usr/bin/env python3
# ==============================================================================
# pipeline_rapido.py — Pipeline otimizado: jq + polars → R2
# ==============================================================================
#
# Substituição do pipeline R para máxima velocidade:
#   - jq (C):     JSON array → JSONL em ~2s por arquivo de 800MB
#   - polars (Rust): JSONL → Parquet multi-threaded
#   - paralelo:   3 workers processam partes simultaneamente
#
# Para arquivos grandes (2025+, >1.5GB):
#   - jq --stream: parsing streaming com memória constante
#   - Processamento em batches de 500K registros
#
# Estimativa: ~2 min/mês (multi-part) e ~15 min/mês (arquivo grande)
# vs ~42 min/mês no pipeline R
# ==============================================================================

import os
import sys
import csv
import json
import time
import hashlib
import zipfile
import subprocess
import shutil
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime
from concurrent.futures import ProcessPoolExecutor, as_completed

# ==============================================================================
# CONFIGURAÇÃO
# ==============================================================================

DIR_TEMP     = Path("/root/temp_pipeline")
CONTROLE_CSV = Path("/root/data/controle_versao_microdata.csv")

RCLONE_REMOTE = "r2"
R2_BUCKET     = "healthbr-data"
R2_PREFIX     = "sipni/microdados"

ANO_INICIO = 2020
N_WORKERS  = 3            # workers paralelos (3 para 8GB RAM)
BATCH_SIZE = 500_000      # registros por batch (arquivos grandes)
SIZE_THRESHOLD = 1_500_000_000  # 1.5GB: acima disso usa streaming

MESES_PT = ["jan", "fev", "mar", "abr", "mai", "jun",
            "jul", "ago", "set", "out", "nov", "dez"]

# ==============================================================================
# FUNÇÕES: CONTROLE E SERVIDOR
# ==============================================================================

def head_request(url, retries=3):
    """HEAD request com retry."""
    for i in range(retries):
        try:
            req = urllib.request.Request(url, method='HEAD')
            with urllib.request.urlopen(req, timeout=30) as resp:
                return {
                    'url': url,
                    'etag': resp.headers.get('ETag', ''),
                    'content_length': int(resp.headers.get('Content-Length', 0))
                }
        except (urllib.error.HTTPError, urllib.error.URLError, OSError):
            if i < retries - 1:
                time.sleep(1 * (i + 1))
    return None


def download_file(url, dest, timeout=120):
    """Download a file with socket timeout (replaces urlretrieve)."""
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        with open(dest, 'wb') as f:
            shutil.copyfileobj(resp, f, length=8 * 1024 * 1024)


def consultar_servidor(ano, mes):
    """Testa ambos padrões de URL."""
    mes_pt = MESES_PT[mes - 1]
    urls = [
        f"https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/"
        f"PNI/json/vacinacao_{mes_pt}_{ano}.json.zip",
        f"https://s3.sa-east-1.amazonaws.com/ckan.saude.gov.br/"
        f"PNI/json/vacinacao_{mes_pt}_{ano}_json.zip"
    ]
    for url in urls:
        info = head_request(url)
        if info:
            return info
    return None


def carregar_controle():
    if CONTROLE_CSV.exists():
        with open(CONTROLE_CSV, 'r') as f:
            return list(csv.DictReader(f))
    return []


def salvar_controle(rows):
    CONTROLE_CSV.parent.mkdir(parents=True, exist_ok=True)
    fields = ['arquivo', 'etag_servidor', 'content_length', 'hash_md5_zip',
              'n_registros', 'n_partes_json', 'data_processamento',
              'ano', 'mes', 'url_origem']
    with open(CONTROLE_CSV, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)


def classificar_mes(ano, mes, info, controle):
    if not info:
        return "indisponivel"
    reg = [r for r in controle
           if r.get('ano') == str(ano) and r.get('mes') == str(mes)]
    if not reg:
        return "novo"
    r = reg[0]
    if (r.get('etag_servidor') == info['etag'] and
            str(r.get('content_length')) == str(info['content_length'])):
        return "inalterado"
    return "atualizado"


def md5_file(path):
    h = hashlib.md5()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(8 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


# ==============================================================================
# FUNÇÕES: GRAVAR PARQUET PARTICIONADO
# ==============================================================================

def read_ndjson_as_strings(path):
    """Read NDJSON with all columns forced to String type.

    Avoids schema inference issues where polars guesses wrong types
    from the first 100 rows and then fails on later rows with
    ComputeError.
    """
    import polars as pl
    path = str(path)
    with open(path, 'rb') as f:
        first_line = f.readline()
    if not first_line.strip():
        return pl.DataFrame()
    columns = list(json.loads(first_line).keys())
    schema = {col: pl.String for col in columns}
    return pl.read_ndjson(path, schema=schema)


def gravar_particionado(df, sufixo, dir_staging):
    """Grava DataFrame polars como Parquet particionado por ano/mes/uf."""
    import polars as pl

    dir_staging = Path(dir_staging)

    for part_df in df.partition_by(['ano', 'mes', 'uf']):
        a = part_df['ano'][0]
        m = part_df['mes'][0]
        u = part_df['uf'][0]

        part_dir = dir_staging / f"ano={a}" / f"mes={m}" / f"uf={u}"
        part_dir.mkdir(parents=True, exist_ok=True)

        part_df.drop(['ano', 'mes', 'uf']).write_parquet(
            str(part_dir / f"part-{sufixo}.parquet")
        )


def preparar_df(df):
    """Adiciona colunas de partição e filtra registros inválidos.

    Records with invalid years (outside 2020-present) are assigned
    ano='_invalid' to preserve data fidelity while keeping the
    partition structure clean.
    """
    import polars as pl

    ANO_MIN = "2020"
    ANO_MAX = str(datetime.now().year)

    # Garantir tudo como string
    df = df.cast({col: pl.String for col in df.columns})

    df = df.with_columns([
        pl.col('dt_vacina').str.slice(0, 4).alias('ano'),
        pl.col('dt_vacina').str.slice(5, 2).alias('mes'),
        pl.col('sg_uf_estabelecimento').alias('uf')
    ]).filter(
        pl.col('uf').is_not_null() &
        (pl.col('uf').str.len_chars() == 2) &
        pl.col('ano').is_not_null() &
        (pl.col('ano').str.len_chars() == 4) &
        pl.col('mes').is_not_null()
    )

    # Redirect records with invalid years to ano=_invalid
    return df.with_columns(
        pl.when(
            (pl.col('ano') >= ANO_MIN) & (pl.col('ano') <= ANO_MAX)
        ).then(pl.col('ano'))
        .otherwise(pl.lit('_invalid'))
        .alias('ano')
    )


# ==============================================================================
# PROCESSAMENTO: ARQUIVOS PEQUENOS (< 1.5GB) — jq in-memory + polars
# ==============================================================================

def processar_parte_pequena(zip_path_str, json_nome, parte_idx, dir_staging_str):
    """
    Worker para partes pequenas (< 1.5GB cada).
    Roda em processo separado via ProcessPoolExecutor.

    1. Extrai JSON do zip
    2. jq -c '.[]' → JSONL (in-memory, ~2 segundos)
    3. polars.read_ndjson → DataFrame (all strings)
    4. Grava Parquet particionado
    """
    import polars as pl

    zip_path = Path(zip_path_str)
    dir_staging = Path(dir_staging_str)
    work_dir = dir_staging.parent / f"worker_{parte_idx:05d}"
    work_dir.mkdir(parents=True, exist_ok=True)

    try:
        # 1. Extrair só esta parte
        with zipfile.ZipFile(zip_path) as zf:
            zf.extract(json_nome, work_dir)

        json_path = work_dir / json_nome
        jsonl_path = work_dir / "data.jsonl"

        # 2. jq: JSON array → JSONL
        with open(jsonl_path, 'w') as out:
            proc = subprocess.run(
                ['jq', '-c', '.[]', str(json_path)],
                stdout=out, stderr=subprocess.PIPE, timeout=600
            )

        # Liberar JSON (~800MB)
        json_path.unlink(missing_ok=True)

        if proc.returncode != 0:
            print(f"    jq ERRO parte {parte_idx}: {proc.stderr.decode()[:200]}")
            return 0

        # 3. polars: JSONL → DataFrame (all columns as String)
        df = read_ndjson_as_strings(jsonl_path)
        jsonl_path.unlink(missing_ok=True)  # Liberar JSONL

        # 4. Preparar e gravar
        df = preparar_df(df)
        n_valid = len(df)
        sufixo = f"{parte_idx:05d}"
        gravar_particionado(df, sufixo, dir_staging)

        return n_valid

    except Exception as e:
        print(f"    ERRO parte {parte_idx}: {e}")
        raise

    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


# ==============================================================================
# PROCESSAMENTO: ARQUIVOS GRANDES (>= 1.5GB) — jq --stream + batches
# ==============================================================================

def processar_parte_grande(json_path, dir_staging, part_idx=1):
    """
    Para JSONs grandes (2025+): jq --stream com memória constante.

    jq --stream emite um objeto por linha no stdout.
    Python lê em batches de 500K linhas, converte com polars, grava Parquet.
    Pico de memória: ~600MB independente do tamanho do arquivo.
    """
    import polars as pl

    dir_staging = Path(dir_staging)
    file_size = json_path.stat().st_size

    print(f"    Modo streaming ({file_size / 1e9:.1f} GB)")

    proc = subprocess.Popen(
        ['jq', '-cn', '--stream', 'fromstream(1|truncate_stream(inputs))',
         str(json_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=4 * 1024 * 1024  # 4MB buffer
    )

    batch_num = 0
    n_total = 0
    lines = []

    for line in proc.stdout:
        lines.append(line)

        if len(lines) >= BATCH_SIZE:
            batch_num += 1

            # Escrever batch em arquivo temporário para polars
            tmp_jsonl = dir_staging.parent / f"batch_{batch_num:05d}.jsonl"
            with open(tmp_jsonl, 'wb') as f:
                f.writelines(lines)
            lines = []

            # polars lê e converte (all columns as String)
            df = read_ndjson_as_strings(tmp_jsonl)
            tmp_jsonl.unlink()

            df = preparar_df(df)
            n_batch = len(df)
            n_total += n_batch

            sufixo = f"{part_idx:02d}-{batch_num:05d}"
            gravar_particionado(df, sufixo, dir_staging)

            print(f"      Batch {batch_num}: +{n_batch:,.0f} "
                  f"| total {n_total:,.0f}")

    # Batch final
    if lines:
        batch_num += 1
        tmp_jsonl = dir_staging.parent / f"batch_{batch_num:05d}.jsonl"
        with open(tmp_jsonl, 'wb') as f:
            f.writelines(lines)

        df = read_ndjson_as_strings(tmp_jsonl)
        tmp_jsonl.unlink()

        df = preparar_df(df)
        n_total += len(df)

        sufixo = f"{part_idx:02d}-{batch_num:05d}"
        gravar_particionado(df, sufixo, dir_staging)

    proc.wait()

    if proc.returncode != 0:
        stderr = proc.stderr.read().decode()[:500]
        print(f"    jq --stream AVISO: {stderr}")

    print(f"    Streaming concluido: {n_total:,.0f} registros "
          f"em {batch_num} batches")

    return n_total


# ==============================================================================
# FUNÇÃO PRINCIPAL: PROCESSAR UM MÊS
# ==============================================================================

def processar_mes(ano, mes, info):
    url = info['url']
    mes_pt = MESES_PT[mes - 1]
    nome_zip = url.rsplit('/', 1)[-1]

    DIR_TEMP.mkdir(parents=True, exist_ok=True)
    zip_path = DIR_TEMP / nome_zip

    # --- 1. Download ---
    t0 = time.time()
    if zip_path.exists() and info['content_length']:
        if zip_path.stat().st_size == info['content_length']:
            print(f"  Cache OK")
        else:
            print(f"  Rebaixando...")
            download_file(url, zip_path)
    else:
        print(f"  Baixando {nome_zip}...")
        download_file(url, zip_path)

    dl_time = time.time() - t0
    mb = zip_path.stat().st_size / 1e6
    if dl_time > 1:
        print(f"  Download: {mb:.0f} MB em {dl_time:.1f}s "
              f"({mb / dl_time:.0f} MB/s)")

    hash_zip = md5_file(zip_path)

    # --- 2. Listar partes ---
    with zipfile.ZipFile(zip_path) as zf:
        json_entries = sorted(
            [(n, zf.getinfo(n).file_size) for n in zf.namelist()
             if n.lower().endswith('.json')],
            key=lambda x: x[0]
        )

    json_nomes = [n for n, _ in json_entries]
    tamanhos = [s for _, s in json_entries]
    n_partes = len(json_nomes)
    maior = max(tamanhos) if tamanhos else 0

    print(f"  {n_partes} parte(s) | MD5: {hash_zip} | "
          f"maior: {maior / 1e9:.1f} GB")

    # --- 3. Staging ---
    dir_staging = DIR_TEMP / "staging_parquet"
    if dir_staging.exists():
        shutil.rmtree(dir_staging)
    dir_staging.mkdir(parents=True)

    # --- 4. Processar ---
    t0 = time.time()
    n_total = 0

    if maior < SIZE_THRESHOLD:
        # === MODO PARALELO: múltiplas partes pequenas ===
        print(f"  Modo paralelo: {N_WORKERS} workers (jq + polars)")

        with ProcessPoolExecutor(max_workers=N_WORKERS) as executor:
            futures = {}
            for i, nome in enumerate(json_nomes, 1):
                f = executor.submit(
                    processar_parte_pequena,
                    str(zip_path), nome, i, str(dir_staging)
                )
                futures[f] = i

            done = 0
            for future in as_completed(futures):
                n = future.result()
                n_total += n
                done += 1
                if done % 5 == 0 or done == n_partes:
                    elapsed = time.time() - t0
                    print(f"    {done}/{n_partes} partes "
                          f"| {n_total:,.0f} reg "
                          f"| {elapsed:.0f}s")
    else:
        # === MODO STREAMING: arquivo(s) grande(s) ===
        # Extrair e processar um por vez
        dir_json = DIR_TEMP / f"json_{mes_pt}_{ano}"
        dir_json.mkdir(parents=True, exist_ok=True)

        for i, nome in enumerate(json_nomes, 1):
            print(f"\n  --- Parte {i}/{n_partes}: {nome} ---")

            with zipfile.ZipFile(zip_path) as zf:
                zf.extract(nome, dir_json)

            json_path = dir_json / nome
            n = processar_parte_grande(json_path, dir_staging, part_idx=i)
            n_total += n

            # Liberar
            json_path.unlink(missing_ok=True)

        shutil.rmtree(dir_json, ignore_errors=True)

    proc_time = time.time() - t0
    print(f"  Processamento: {proc_time:.1f}s | {n_total:,.0f} registros")

    # --- 5. Upload ---
    t0 = time.time()
    print(f"  Upload para R2...")
    destino = f"{RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/"
    result = subprocess.run(
        ['rclone', 'copy', str(dir_staging), destino,
         '--transfers', '16', '--checkers', '32',
         '--s3-no-check-bucket', '-v'],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"  ERRO rclone: {result.stderr[:500]}")
        raise RuntimeError("Upload falhou")
    up_time = time.time() - t0
    print(f"  Upload: {up_time:.1f}s")

    # --- 6. Controle ---
    controle = carregar_controle()
    controle = [r for r in controle
                if not (r.get('ano') == str(ano) and r.get('mes') == str(mes))]
    controle.append({
        'arquivo': nome_zip,
        'etag_servidor': info['etag'],
        'content_length': str(info['content_length']),
        'hash_md5_zip': hash_zip,
        'n_registros': str(n_total),
        'n_partes_json': str(n_partes),
        'data_processamento': str(datetime.now()),
        'ano': str(ano),
        'mes': str(mes),
        'url_origem': url
    })
    salvar_controle(controle)

    # --- 7. Limpar ---
    shutil.rmtree(dir_staging, ignore_errors=True)
    zip_path.unlink(missing_ok=True)

    print(f"  ✓ {mes_pt}/{ano}: {n_total:,.0f} registros "
          f"({n_partes}p) → R2\n")
    return n_total


# ==============================================================================
# EXECUÇÃO
# ==============================================================================

def main():
    print()
    print("=" * 70)
    print("  Pipeline otimizado: jq (C) + polars (Rust) + paralelo → R2")
    print("=" * 70)
    print()

    # --- Verificações ---
    try:
        v = subprocess.run(['jq', '--version'], capture_output=True, text=True)
        print(f"  jq:      {v.stdout.strip()}")
    except FileNotFoundError:
        sys.exit("ERRO: jq nao encontrado. Instale: apt install -y jq")

    try:
        subprocess.run(
            ['rclone', 'lsd', f'{RCLONE_REMOTE}:{R2_BUCKET}'],
            capture_output=True, check=True
        )
        print(f"  rclone:  {RCLONE_REMOTE}:{R2_BUCKET} OK")
    except (FileNotFoundError, subprocess.CalledProcessError):
        sys.exit("ERRO: rclone nao acessivel")

    import polars as pl
    print(f"  polars:  {pl.__version__}")
    print(f"  CPUs:    {os.cpu_count()}")
    print(f"  workers: {N_WORKERS}")
    print(f"  temp:    {DIR_TEMP}")
    print()

    t_inicio = time.time()

    # --- Grade de meses ---
    ano_atual = datetime.now().year
    mes_atual = datetime.now().month

    grade = [(a, m)
             for a in range(ANO_INICIO, ano_atual + 1)
             for m in range(1, 13)
             if not (a == ano_atual and m > mes_atual)]

    print(f"Meses a verificar: {len(grade)}")
    print("HEAD requests...\n")

    # --- Fase 1: HEAD ---
    controle = carregar_controle()
    plano = []
    stats = {'novo': 0, 'atualizado': 0, 'inalterado': 0, 'indisponivel': 0}

    for ano, mes in grade:
        info = consultar_servidor(ano, mes)
        status = classificar_mes(ano, mes, info, controle)

        tag = {'novo': '>> NOVO', 'atualizado': '>> ATUAL',
               'inalterado': '   ok', 'indisponivel': '   --'}
        print(f"  {MESES_PT[mes-1]}/{ano}: {tag[status]}")

        if status in ('novo', 'atualizado'):
            plano.append((ano, mes, info, status))

        stats[status] += 1
        time.sleep(0.2)

    print(f"\nResumo: novos={stats['novo']}, atualizados={stats['atualizado']}, "
          f"inalterados={stats['inalterado']}, indisponiveis={stats['indisponivel']}")
    print(f"A processar: {len(plano)}\n")

    # --- Fase 2: Processar ---
    if not plano:
        print("Nada a fazer. Tudo atualizado.")
        return

    total_registros = 0

    for i, (ano, mes, info, status) in enumerate(plano, 1):
        mes_pt = MESES_PT[mes - 1]
        print(f"{'=' * 70}")
        print(f"[{i}/{len(plano)}] {mes_pt}/{ano} ({status})")
        print(f"{'=' * 70}")

        try:
            n = processar_mes(ano, mes, info)
            total_registros += n
        except Exception as e:
            print(f"  ERRO: {e}\n")

    # --- Resumo ---
    elapsed = (time.time() - t_inicio) / 60

    print()
    print("=" * 70)
    print(f"  Concluido em {elapsed:.1f} minutos")
    print("=" * 70)

    if CONTROLE_CSV.exists():
        ctrl = carregar_controle()
        total = sum(int(r.get('n_registros', 0)) for r in ctrl)
        print(f"  Meses no controle: {len(ctrl)}")
        print(f"  Registros totais:  {total:,.0f}")
        print()

        # Listar últimos 10
        print("  Ultimos processados:")
        for r in ctrl[-10:]:
            print(f"    {r['arquivo']}: {int(r['n_registros']):,.0f} "
                  f"({r['n_partes_json']}p) @ {r['data_processamento']}")

    print("\nPipeline concluido.")


if __name__ == '__main__':
    main()
