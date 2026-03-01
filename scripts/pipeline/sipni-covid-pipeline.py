#!/usr/bin/env python3
# ==============================================================================
# pipeline_covid.py — Pipeline: CSV por UF (S3) → Parquet → R2
# ==============================================================================
#
# Processa microdados de vacinação COVID-19 do OpenDATASUS:
#   - Fonte: 27 UFs × 5 partes CSV = 135 arquivos (~272 GB bruto)
#   - polars (Rust): CSV → Parquet multi-threaded
#   - Particionamento: ano/mes/uf (usando estabelecimento_uf)
#   - Dados publicados exatamente como o Ministério fornece
#
# Diferenças do pipeline de rotina:
#   - CSV (não JSON) — sem necessidade de jq
#   - Organizado por UF na fonte (não por mês)
#   - 32 colunas (não 56), UTF-8, delimitador ;, campos entre aspas
#   - Arquivos grandes (SP ~13 GB/parte) → leitura em batches
#
# Estimativa: ~4-8h para bootstrap completo (depende da banda)
# ==============================================================================

import os
import sys
import csv
import time
import hashlib
import subprocess
import shutil
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime

# ==============================================================================
# CONFIGURAÇÃO
# ==============================================================================

DIR_TEMP     = Path("/root/temp_pipeline_covid")
CONTROLE_CSV = Path("/root/data/controle_versao_covid.csv")

RCLONE_REMOTE = "r2"
R2_BUCKET     = "healthbr-data"
R2_PREFIX     = "sipni/covid/microdados"

# Hash global da publicação (identificador fixo de todas as partes CSV)
HASH_PUB = "f58e39ef-bcdd-4fc4-bae5-f3c5a2858afe"
BASE_URL = ("https://s3.sa-east-1.amazonaws.com/"
            "ckan.saude.gov.br/SIPNI/COVID/uf")

UFS = [
    "AC", "AL", "AM", "AP", "BA", "CE", "DF", "ES", "GO", "MA",
    "MG", "MS", "MT", "PA", "PB", "PE", "PI", "PR", "RJ", "RN",
    "RO", "RR", "RS", "SC", "SE", "SP", "TO"
]
N_PARTES = 5            # partes 00000–00004 por UF

BATCH_SIZE = 500_000    # linhas por batch (leitura de arquivos grandes)
SIZE_THRESHOLD = 3_000_000_000  # 3 GB: acima disso usa leitura em batches


# ==============================================================================
# FUNÇÕES: URLS E REDE
# ==============================================================================

def url_parte(uf, parte_idx):
    """Monta URL de uma parte CSV no S3."""
    return (f"{BASE_URL}/uf%3D{uf}/"
            f"part-{parte_idx:05d}-{HASH_PUB}.c000.csv")


def head_request(url, retries=3):
    """HEAD request com retry."""
    for i in range(retries):
        try:
            req = urllib.request.Request(url, method='HEAD')
            with urllib.request.urlopen(req, timeout=30) as resp:
                return {
                    'url': url,
                    'etag': resp.headers.get('ETag', ''),
                    'content_length': int(resp.headers.get('Content-Length', 0)),
                    'last_modified': resp.headers.get('Last-Modified', '')
                }
        except (urllib.error.HTTPError, urllib.error.URLError, OSError):
            if i < retries - 1:
                time.sleep(1 * (i + 1))
    return None


def baixar_arquivo(url, destino, content_length=0):
    """Download com verificação de cache por tamanho."""
    destino = Path(destino)
    if destino.exists() and content_length:
        if destino.stat().st_size == content_length:
            return False  # cache OK, não baixou

    destino.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, destino)
    return True  # baixou


# ==============================================================================
# FUNÇÕES: CONTROLE DE VERSÃO
# ==============================================================================

CONTROLE_FIELDS = [
    'uf', 'etags_concat', 'content_length_total', 'n_registros',
    'n_partes', 'data_processamento'
]


def carregar_controle():
    if CONTROLE_CSV.exists():
        with open(CONTROLE_CSV, 'r') as f:
            return list(csv.DictReader(f))
    return []


def salvar_controle(rows):
    CONTROLE_CSV.parent.mkdir(parents=True, exist_ok=True)
    with open(CONTROLE_CSV, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=CONTROLE_FIELDS)
        w.writeheader()
        w.writerows(rows)


def consultar_uf(uf):
    """HEAD em todas as 5 partes de uma UF. Retorna metadados agregados."""
    infos = []
    for p in range(N_PARTES):
        info = head_request(url_parte(uf, p))
        if info:
            infos.append(info)
        else:
            print(f"    AVISO: {uf} parte {p} inacessível")

    if not infos:
        return None

    return {
        'uf': uf,
        'etags_concat': '|'.join(i['etag'] for i in infos),
        'content_length_total': sum(i['content_length'] for i in infos),
        'partes': infos,
        'n_partes': len(infos)
    }


def classificar_uf(uf, info_servidor, controle):
    """Classifica UF como nova, atualizada ou inalterada."""
    if not info_servidor:
        return "indisponivel"

    reg = [r for r in controle if r['uf'] == uf]
    if not reg:
        return "novo"

    r = reg[0]
    if (r.get('etags_concat') == info_servidor['etags_concat'] and
            str(r.get('content_length_total')) ==
            str(info_servidor['content_length_total'])):
        return "inalterado"

    return "atualizado"


# ==============================================================================
# FUNÇÕES: PREPARAR E GRAVAR PARQUET
# ==============================================================================

def preparar_df(df):
    """Adiciona colunas de partição e filtra registros inválidos.

    Particionamento: ano e mes extraídos de vacina_dataAplicacao,
    uf de estabelecimento_uf (consistente com pipeline de rotina).

    Records with invalid years (outside 2021-2025) are assigned
    ano='_invalid' to preserve data fidelity while keeping the
    partition structure clean.
    """
    import polars as pl

    ANO_MIN = "2021"
    ANO_MAX = str(datetime.now().year)

    # Garantir tudo como string
    df = df.cast({col: pl.Utf8 for col in df.columns})

    # vacina_dataAplicacao pode ser "2022-03-10" ou "2022-03-10T00:00:00.000Z"
    df = df.with_columns([
        pl.col('vacina_dataAplicacao').str.slice(0, 4).alias('ano'),
        pl.col('vacina_dataAplicacao').str.slice(5, 2).alias('mes'),
        pl.col('estabelecimento_uf').alias('uf')
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


# ==============================================================================
# PROCESSAMENTO: UMA PARTE CSV
# ==============================================================================

def processar_parte_csv(csv_path, uf_fonte, parte_idx, dir_staging):
    """Processa uma parte CSV → Parquet particionado.

    Arquivos < 3 GB: leitura completa com polars (rápido).
    Arquivos >= 3 GB: leitura em batches de 500K linhas (memória constante).
    """
    import polars as pl

    csv_path = Path(csv_path)
    dir_staging = Path(dir_staging)
    file_size = csv_path.stat().st_size

    csv_opts = dict(
        separator=';',
        infer_schema_length=0,   # tudo Utf8 (preserva zeros à esquerda)
        encoding='utf8',
        quote_char='"',
        ignore_errors=True       # pular linhas malformadas
    )

    if file_size < SIZE_THRESHOLD:
        # --- Modo direto: lê tudo de uma vez ---
        print(f"      Modo direto ({file_size / 1e9:.1f} GB)")

        df = pl.read_csv(str(csv_path), **csv_opts)
        df = preparar_df(df)
        n_valid = len(df)

        sufixo = f"{uf_fonte}-{parte_idx:05d}"
        gravar_particionado(df, sufixo, dir_staging)

        return n_valid

    else:
        # --- Modo batched: leitura incremental ---
        print(f"      Modo batched ({file_size / 1e9:.1f} GB, "
              f"batches de {BATCH_SIZE:,})")

        reader = pl.read_csv_batched(str(csv_path), batch_size=BATCH_SIZE,
                                     **csv_opts)
        n_total = 0
        batch_num = 0

        while True:
            batches = reader.next_batches(1)
            if not batches:
                break

            batch_num += 1
            df = batches[0]
            df = preparar_df(df)
            n_batch = len(df)
            n_total += n_batch

            sufixo = f"{uf_fonte}-{parte_idx:05d}-{batch_num:05d}"
            gravar_particionado(df, sufixo, dir_staging)

            print(f"        Batch {batch_num}: +{n_batch:,} "
                  f"| total {n_total:,}")

        print(f"      Concluido: {n_total:,} registros em {batch_num} batches")
        return n_total


# ==============================================================================
# PROCESSAMENTO: UMA UF COMPLETA
# ==============================================================================

def processar_uf(uf, info_servidor):
    """Processa todas as partes de uma UF: download → Parquet → R2."""

    dir_uf = DIR_TEMP / f"csv_{uf}"
    dir_staging = DIR_TEMP / f"staging_{uf}"
    dir_uf.mkdir(parents=True, exist_ok=True)

    if dir_staging.exists():
        shutil.rmtree(dir_staging)
    dir_staging.mkdir(parents=True)

    partes = info_servidor['partes']
    n_partes = len(partes)
    n_total = 0

    for i, parte_info in enumerate(partes):
        url = parte_info['url']
        parte_idx = i
        csv_name = f"part-{parte_idx:05d}.csv"
        csv_path = dir_uf / csv_name

        print(f"\n  --- Parte {i + 1}/{n_partes}: "
              f"{parte_info['content_length'] / 1e9:.1f} GB ---")

        # 1. Download
        t0 = time.time()
        baixou = baixar_arquivo(url, csv_path, parte_info['content_length'])
        dl_time = time.time() - t0

        if baixou and dl_time > 1:
            mb = csv_path.stat().st_size / 1e6
            print(f"    Download: {mb:.0f} MB em {dl_time:.1f}s "
                  f"({mb / dl_time:.0f} MB/s)")
        elif not baixou:
            print(f"    Cache OK")

        # 2. Processar CSV → Parquet
        t0 = time.time()
        n = processar_parte_csv(csv_path, uf, parte_idx, dir_staging)
        n_total += n
        proc_time = time.time() - t0
        print(f"    Processado: {n:,} registros em {proc_time:.1f}s")

        # 3. Liberar CSV para economizar disco
        csv_path.unlink(missing_ok=True)

    # 4. Upload staging → R2
    t0 = time.time()
    print(f"\n  Upload {uf} para R2...")
    destino = f"{RCLONE_REMOTE}:{R2_BUCKET}/{R2_PREFIX}/"
    result = subprocess.run(
        ['rclone', 'copy', str(dir_staging), destino,
         '--transfers', '16', '--checkers', '32',
         '--s3-no-check-bucket', '-v'],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"  ERRO rclone: {result.stderr[:500]}")
        raise RuntimeError(f"Upload {uf} falhou")
    up_time = time.time() - t0
    print(f"  Upload: {up_time:.1f}s")

    # 5. Atualizar controle
    controle = carregar_controle()
    controle = [r for r in controle if r['uf'] != uf]
    controle.append({
        'uf': uf,
        'etags_concat': info_servidor['etags_concat'],
        'content_length_total': str(info_servidor['content_length_total']),
        'n_registros': str(n_total),
        'n_partes': str(n_partes),
        'data_processamento': str(datetime.now())
    })
    salvar_controle(controle)

    # 6. Limpar
    shutil.rmtree(dir_staging, ignore_errors=True)
    shutil.rmtree(dir_uf, ignore_errors=True)

    gb_total = info_servidor['content_length_total'] / 1e9
    print(f"\n  ✓ {uf}: {n_total:,} registros ({n_partes}p, "
          f"{gb_total:.1f} GB CSV) → R2\n")

    return n_total


# ==============================================================================
# EXECUÇÃO
# ==============================================================================

def main():
    print()
    print("=" * 70)
    print("  Pipeline COVID-19: CSV por UF → Parquet → R2")
    print("=" * 70)
    print()

    # --- Verificações ---
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
    print(f"  temp:    {DIR_TEMP}")
    print(f"  UFs:     {len(UFS)}")
    print(f"  partes:  {N_PARTES} por UF ({len(UFS) * N_PARTES} arquivos)")
    print()

    t_inicio = time.time()

    # --- Fase 1: HEAD requests em todas as 135 partes ---
    print("Consultando servidor (HEAD em 135 arquivos)...\n")

    controle = carregar_controle()
    plano = []
    stats = {'novo': 0, 'atualizado': 0, 'inalterado': 0, 'indisponivel': 0}

    for uf in UFS:
        info = consultar_uf(uf)
        status = classificar_uf(uf, info, controle)

        tag = {'novo': '>> NOVO', 'atualizado': '>> ATUAL',
               'inalterado': '   ok', 'indisponivel': '   --'}

        size_str = ""
        if info:
            size_str = f" ({info['content_length_total'] / 1e9:.1f} GB)"

        print(f"  {uf}: {tag[status]}{size_str}")

        if status in ('novo', 'atualizado'):
            plano.append((uf, info, status))

        stats[status] += 1
        time.sleep(0.1)

    print(f"\nResumo: novos={stats['novo']}, atualizados={stats['atualizado']}, "
          f"inalterados={stats['inalterado']}, indisponiveis={stats['indisponivel']}")

    total_gb = sum(info['content_length_total']
                   for _, info, _ in plano) / 1e9
    print(f"A processar: {len(plano)} UF(s) ({total_gb:.1f} GB)\n")

    # --- Fase 2: Processar ---
    if not plano:
        print("Nada a fazer. Tudo atualizado.")
        return

    total_registros = 0

    for i, (uf, info, status) in enumerate(plano, 1):
        gb = info['content_length_total'] / 1e9
        print(f"{'=' * 70}")
        print(f"[{i}/{len(plano)}] {uf} ({status}, {gb:.1f} GB)")
        print(f"{'=' * 70}")

        try:
            n = processar_uf(uf, info)
            total_registros += n
        except Exception as e:
            print(f"  ERRO: {e}\n")

    # --- Resumo final ---
    elapsed = (time.time() - t_inicio) / 60

    print()
    print("=" * 70)
    print(f"  Concluido em {elapsed:.1f} minutos")
    print("=" * 70)

    if CONTROLE_CSV.exists():
        ctrl = carregar_controle()
        total = sum(int(r.get('n_registros', 0)) for r in ctrl)
        total_size = sum(int(r.get('content_length_total', 0))
                         for r in ctrl) / 1e9
        print(f"  UFs no controle:   {len(ctrl)}")
        print(f"  Registros totais:  {total:,}")
        print(f"  CSV bruto total:   {total_size:.1f} GB")
        print()

        print("  Por UF:")
        for r in sorted(ctrl, key=lambda x: -int(x.get('n_registros', 0))):
            n = int(r['n_registros'])
            gb = int(r['content_length_total']) / 1e9
            print(f"    {r['uf']}: {n:>14,} reg  ({gb:.1f} GB)")

    print("\nPipeline COVID concluido.")


if __name__ == '__main__':
    main()
