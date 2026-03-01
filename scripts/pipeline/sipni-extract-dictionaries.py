#!/usr/bin/env python3
"""
extrair_dicionarios_e_valores.py
================================
Script para a VPS Hetzner. Faz duas coisas:

  PARTE 1: Baixa e parseia os dicionários do FTP do DATASUS
           (IMUNO.CNV, DOSE.CNV, FXET.CNV, IMUNOCOB.DBF)

  PARTE 2: Extrai valores únicos dos microdados no R2
           (co_vacina × ds_vacina, co_dose_vacina × ds_dose_vacina,
            nu_idade_paciente, co_estrategia_vacinacao)

Resultado: 6 CSVs prontos para construir as tabelas de-para do
           HARMONIZACAO.md

Pré-requisitos na VPS:
  pip install polars dbfread --break-system-packages
  # rclone já configurado (remote r2)
  # curl disponível

Uso:
  python3 extrair_dicionarios_e_valores.py
"""

import os
import csv
import subprocess
import sys
from pathlib import Path

# ─── Configuração ────────────────────────────────────────────────────────────

DIR_TRABALHO = Path("/root/harmonizacao")
DIR_DICIONARIOS = DIR_TRABALHO / "dicionarios_ftp"
DIR_MICRODADOS = DIR_TRABALHO / "valores_microdados"
DIR_SAIDA = DIR_TRABALHO / "resultados"

FTP_BASE = "ftp://ftp.datasus.gov.br/dissemin/publicos/PNI/AUXILIARES"
R2_MICRODADOS = "r2:healthbr-data/sipni/microdados"

# Dicionários a baixar do FTP
DICIONARIOS_CNV = ["IMUNO.CNV", "DOSE.CNV", "FXET.CNV"]
DICIONARIOS_DBF = ["IMUNOCOB.DBF"]


# ═════════════════════════════════════════════════════════════════════════════
# PARTE 1: DICIONÁRIOS DO FTP
# ═════════════════════════════════════════════════════════════════════════════

def baixar_ftp(arquivo: str, destino: Path) -> bool:
    """Baixa arquivo do FTP do DATASUS."""
    url = f"{FTP_BASE}/{arquivo}"
    destino.parent.mkdir(parents=True, exist_ok=True)
    print(f"  Baixando {url} ...", end=" ", flush=True)
    result = subprocess.run(
        ["curl", "-s", "--connect-timeout", "30", "--max-time", "120",
         "--retry", "3", "-o", str(destino), url],
        capture_output=True
    )
    if result.returncode == 0 and destino.exists() and destino.stat().st_size > 0:
        print(f"OK ({destino.stat().st_size} bytes)")
        return True
    else:
        print("FALHOU")
        return False


def parsear_cnv(caminho: Path) -> list[dict]:
    """
    Parseia arquivo .CNV do TabWin.

    Formato .CNV (baseado na engenharia reversa das sessões anteriores):
    - Primeira linha: header com total de categorias e nome do dicionário
    - Linhas seguintes: código + descrição em formato posicional
      Colunas 1-2: espaços ou flags
      Colunas 3-12: descrição (trim)
      Colunas ~10+: código numérico

    O formato exato varia, então tentamos múltiplas estratégias.
    """
    registros = []
    try:
        # Tentar múltiplos encodings (DATASUS usa variantes)
        conteudo = None
        for enc in ["latin-1", "cp1252", "utf-8"]:
            try:
                conteudo = caminho.read_text(encoding=enc)
                break
            except UnicodeDecodeError:
                continue

        if conteudo is None:
            print(f"  ERRO: não conseguiu decodificar {caminho.name}")
            return registros

        linhas = conteudo.strip().split("\n")

        # Primeira linha é header — pular
        for i, linha in enumerate(linhas):
            if i == 0:
                # Header: geralmente "NNN <nome do dicionário>"
                print(f"  Header: {linha.strip()}")
                continue

            linha = linha.rstrip("\r")
            if not linha.strip():
                continue

            # Estratégia: formato TabWin típico
            # Os primeiros 2 chars podem ser flags/espaços
            # Depois vem a descrição (largura variável)
            # No final, o código numérico
            #
            # Exemplos observados:
            #   " 02BCG                  "
            #   " 06Febre Amarela        "
            #
            # Alternativa: separação por vírgula ou ponto-e-vírgula
            # em alguns .cnv mais novos

            # Tentar extrair código e descrição
            # Muitos .cnv têm o código nos primeiros N chars e descrição depois
            # Vamos tentar split inteligente

            # Formato posicional TabWin:
            # Posição 0:    flag (espaço ou letra)
            # Posição 1-3:  código (right-aligned, pode ter espaços)
            # Posição 4+:   descrição

            # Mas o formato varia bastante. Vamos tentar:
            # 1) Regex para "número seguido de texto" ou "texto seguido de número"

            import re

            # Padrão 1: código no início (com possíveis espaços)
            m = re.match(r'^[\s]*(\d+)\s*[,;]?\s*(.+)$', linha)
            if m:
                registros.append({
                    "codigo": m.group(1).strip(),
                    "descricao": m.group(2).strip()
                })
                continue

            # Padrão 2: formato TabWin posicional (flag + código + descrição)
            # Ex: " 02BCG"
            m = re.match(r'^.(\s*\d{1,3})\s*(.+)$', linha)
            if m:
                registros.append({
                    "codigo": m.group(1).strip(),
                    "descricao": m.group(2).strip()
                })
                continue

            # Padrão 3: descrição primeiro, código depois
            m = re.match(r'^(.+?)\s+(\d{1,4})\s*$', linha)
            if m:
                registros.append({
                    "codigo": m.group(2).strip(),
                    "descricao": m.group(1).strip()
                })
                continue

            # Se nenhum padrão casou, registrar a linha bruta
            registros.append({
                "codigo": "???",
                "descricao": linha.strip()
            })

    except Exception as e:
        print(f"  ERRO ao parsear {caminho.name}: {e}")

    return registros


def parsear_dbf(caminho: Path) -> list[dict]:
    """Parseia arquivo .DBF usando dbfread."""
    try:
        from dbfread import DBF
    except ImportError:
        print("  ERRO: dbfread não instalado. Rode: pip install dbfread --break-system-packages")
        return []

    registros = []
    try:
        # Tentar múltiplos encodings
        for enc in ["latin-1", "cp1252", "cp850", "utf-8"]:
            try:
                db = DBF(str(caminho), encoding=enc, ignore_missing_memofile=True)
                campos = db.field_names
                print(f"  Campos: {campos}")
                for rec in db:
                    registros.append(dict(rec))
                break
            except Exception:
                continue

        if not registros:
            print(f"  AVISO: nenhum registro lido de {caminho.name}")

    except Exception as e:
        print(f"  ERRO ao parsear {caminho.name}: {e}")

    return registros


def salvar_csv(registros: list[dict], caminho: Path):
    """Salva lista de dicts como CSV."""
    if not registros:
        print(f"  AVISO: nenhum registro para salvar em {caminho.name}")
        return

    caminho.parent.mkdir(parents=True, exist_ok=True)
    campos = list(registros[0].keys())
    with open(caminho, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=campos)
        writer.writeheader()
        writer.writerows(registros)
    print(f"  Salvo: {caminho} ({len(registros)} registros)")


def processar_dicionarios():
    """Baixa e parseia todos os dicionários do FTP."""
    print("\n" + "=" * 70)
    print("PARTE 1: DICIONÁRIOS DO FTP DO DATASUS")
    print("=" * 70)

    # Baixar .CNV
    for nome in DICIONARIOS_CNV:
        destino = DIR_DICIONARIOS / nome
        print(f"\n--- {nome} ---")

        if destino.exists():
            print(f"  Já existe ({destino.stat().st_size} bytes), usando cache")
        else:
            if not baixar_ftp(nome, destino):
                continue

        registros = parsear_cnv(destino)
        print(f"  {len(registros)} registros parseados")

        # Salvar CSV parseado
        nome_csv = nome.replace(".CNV", ".csv")
        salvar_csv(registros, DIR_SAIDA / f"dicionario_{nome_csv}")

        # Mostrar primeiros registros
        for r in registros[:5]:
            print(f"    {r['codigo']:>4} = {r['descricao']}")
        if len(registros) > 5:
            print(f"    ... (+{len(registros) - 5} registros)")

    # Baixar .DBF
    for nome in DICIONARIOS_DBF:
        destino = DIR_DICIONARIOS / nome
        print(f"\n--- {nome} ---")

        if destino.exists():
            print(f"  Já existe ({destino.stat().st_size} bytes), usando cache")
        else:
            if not baixar_ftp(nome, destino):
                continue

        registros = parsear_dbf(destino)
        print(f"  {len(registros)} registros parseados")

        nome_csv = nome.replace(".DBF", ".csv")
        salvar_csv(registros, DIR_SAIDA / f"dicionario_{nome_csv}")

        for r in registros[:5]:
            print(f"    {r}")
        if len(registros) > 5:
            print(f"    ... (+{len(registros) - 5} registros)")

    # Tentar baixar dicionários adicionais que podem existir
    extras = [
        "FXETAR.CNV", "FXETAR2.CNV", "DOSE2.CNV",
        "UF.CNV", "MUNIC.CNV", "MUNICIP.CNV"
    ]
    print(f"\n--- Tentando dicionários extras ---")
    for nome in extras:
        destino = DIR_DICIONARIOS / nome
        if not destino.exists():
            if baixar_ftp(nome, destino):
                registros = parsear_cnv(destino)
                if registros:
                    nome_csv = nome.replace(".CNV", ".csv")
                    salvar_csv(registros, DIR_SAIDA / f"dicionario_{nome_csv}")


# ═════════════════════════════════════════════════════════════════════════════
# PARTE 2: VALORES ÚNICOS DOS MICRODADOS (R2)
# ═════════════════════════════════════════════════════════════════════════════

def extrair_valores_microdados():
    """
    Extrai valores únicos dos campos-chave dos microdados no R2.

    Usa polars para ler Parquets diretamente (via rclone mount ou
    download seletivo de colunas).

    Estratégia: para não baixar todos os Parquets (~50-100 GB), baixamos
    apenas as colunas necessárias de uma AMOSTRA representativa (6 meses
    espalhados pela série: jan/2020, jul/2021, jan/2023, jul/2024, jan/2025,
    último disponível).

    Se os valores forem estáveis entre meses, a amostra é suficiente.
    Se novos códigos aparecerem, rodamos a extração completa depois.
    """
    print("\n" + "=" * 70)
    print("PARTE 2: VALORES ÚNICOS DOS MICRODADOS (R2)")
    print("=" * 70)

    try:
        import polars as pl
    except ImportError:
        print("ERRO: polars não instalado. Rode: pip install polars --break-system-packages")
        return

    DIR_MICRODADOS.mkdir(parents=True, exist_ok=True)

    # Campos que precisamos extrair valores únicos
    campos_interesse = [
        "co_vacina", "ds_vacina",
        "co_dose_vacina", "ds_dose_vacina",
        "nu_idade_paciente",
        "co_estrategia_vacinacao", "ds_estrategia_vacinacao",
        "sg_vacina",
    ]

    # Meses amostrais (espalhados pela série para capturar variação)
    meses_amostra = [
        (2020, 1), (2020, 7),
        (2021, 1), (2021, 7),
        (2022, 6),
        (2023, 1), (2023, 7),
        (2024, 1), (2024, 6), (2024, 12),
        (2025, 1),
    ]

    # Escolher UFs pequenas para amostra rápida (AC, RR, AP = menores)
    ufs_amostra = ["AC", "RR", "AP"]

    print(f"\nEstratégia: amostrar {len(meses_amostra)} meses × "
          f"{len(ufs_amostra)} UFs pequenas")
    print(f"Campos: {', '.join(campos_interesse)}")

    # Listar o que existe no R2
    print("\nListando conteúdo do R2...")
    result = subprocess.run(
        ["rclone", "lsd", R2_MICRODADOS],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"ERRO rclone lsd: {result.stderr}")
        print("Verifique se rclone está configurado com o remote 'r2'")
        return

    anos_disponiveis = []
    for linha in result.stdout.strip().split("\n"):
        if "ano=" in linha:
            ano = linha.strip().split("ano=")[-1].strip("/")
            anos_disponiveis.append(ano)
    print(f"Anos no R2: {sorted(anos_disponiveis)}")

    # Baixar e processar amostras
    todos_valores = {campo: set() for campo in campos_interesse}
    # Para co_vacina × ds_vacina, queremos o par
    pares_vacina = set()
    pares_dose = set()
    pares_estrategia = set()
    dist_idade = {}  # nu_idade_paciente → contagem

    n_processados = 0
    n_registros_total = 0

    for ano, mes in meses_amostra:
        for uf in ufs_amostra:
            path_r2 = f"{R2_MICRODADOS}/ano={ano}/mes={mes:02d}/uf={uf}/"
            local_dir = DIR_MICRODADOS / f"ano={ano}_mes={mes:02d}_uf={uf}"
            local_dir.mkdir(parents=True, exist_ok=True)

            print(f"\n  {ano}/{mes:02d}/{uf}: ", end="", flush=True)

            # Verificar se existe no R2
            check = subprocess.run(
                ["rclone", "ls", path_r2],
                capture_output=True, text=True, timeout=30
            )
            if check.returncode != 0 or not check.stdout.strip():
                print("não encontrado, pulando")
                continue

            # Baixar Parquets desta partição
            result = subprocess.run(
                ["rclone", "copy", path_r2, str(local_dir),
                 "--transfers", "16", "--checkers", "32", "--no-traverse"],
                capture_output=True, text=True, timeout=300
            )
            if result.returncode != 0:
                print(f"erro no download: {result.stderr[:100]}")
                continue

            # Ler com polars
            parquets = list(local_dir.glob("*.parquet"))
            if not parquets:
                print("sem parquets")
                continue

            try:
                # Ler apenas as colunas de interesse (muito mais rápido)
                colunas_disponiveis = pl.read_parquet_schema(parquets[0])
                colunas_para_ler = [c for c in campos_interesse
                                    if c in colunas_disponiveis]

                df = pl.read_parquet(
                    parquets,
                    columns=colunas_para_ler,
                    n_rows=None  # todas as linhas (UFs pequenas = poucos registros)
                )
                n_registros = len(df)
                n_registros_total += n_registros
                n_processados += 1

                print(f"{n_registros:,} registros, {len(colunas_para_ler)} colunas", end="")

                # Extrair valores únicos
                for campo in colunas_para_ler:
                    vals = df[campo].drop_nulls().unique().to_list()
                    todos_valores[campo].update(str(v) for v in vals)

                # Pares co_vacina × ds_vacina
                if "co_vacina" in colunas_para_ler and "ds_vacina" in colunas_para_ler:
                    pares = (df.select(["co_vacina", "ds_vacina"])
                             .drop_nulls()
                             .unique()
                             .to_dicts())
                    for p in pares:
                        pares_vacina.add((str(p["co_vacina"]), str(p["ds_vacina"])))

                # Pares co_dose_vacina × ds_dose_vacina
                if "co_dose_vacina" in colunas_para_ler and "ds_dose_vacina" in colunas_para_ler:
                    pares = (df.select(["co_dose_vacina", "ds_dose_vacina"])
                             .drop_nulls()
                             .unique()
                             .to_dicts())
                    for p in pares:
                        pares_dose.add((str(p["co_dose_vacina"]),
                                        str(p["ds_dose_vacina"])))

                # Pares estratégia
                if "co_estrategia_vacinacao" in colunas_para_ler and "ds_estrategia_vacinacao" in colunas_para_ler:
                    pares = (df.select(["co_estrategia_vacinacao",
                                        "ds_estrategia_vacinacao"])
                             .drop_nulls()
                             .unique()
                             .to_dicts())
                    for p in pares:
                        pares_estrategia.add(
                            (str(p["co_estrategia_vacinacao"]),
                             str(p["ds_estrategia_vacinacao"])))

                # Distribuição de nu_idade_paciente (top 100)
                if "nu_idade_paciente" in colunas_para_ler:
                    contagens = (df.group_by("nu_idade_paciente")
                                 .len()
                                 .sort("len", descending=True)
                                 .to_dicts())
                    for c in contagens:
                        k = str(c["nu_idade_paciente"])
                        dist_idade[k] = dist_idade.get(k, 0) + c["len"]

                print(" ✓")

            except Exception as e:
                print(f"erro ao ler: {e}")
                continue

            finally:
                # Limpar arquivos baixados
                import shutil
                shutil.rmtree(local_dir, ignore_errors=True)

    # ─── Salvar resultados ────────────────────────────────────────────────

    DIR_SAIDA.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*50}")
    print(f"RESUMO: {n_processados} partições processadas, "
          f"{n_registros_total:,} registros totais")

    # 1. Pares vacina
    if pares_vacina:
        registros = sorted([{"co_vacina": c, "ds_vacina": d}
                            for c, d in pares_vacina],
                           key=lambda x: x["co_vacina"])
        salvar_csv(registros, DIR_SAIDA / "microdados_vacinas.csv")
        print(f"\n  co_vacina × ds_vacina: {len(registros)} pares únicos")
        for r in registros[:10]:
            print(f"    {r['co_vacina']:>6} = {r['ds_vacina']}")
        if len(registros) > 10:
            print(f"    ... (+{len(registros) - 10})")

    # 2. Pares dose
    if pares_dose:
        registros = sorted([{"co_dose_vacina": c, "ds_dose_vacina": d}
                            for c, d in pares_dose],
                           key=lambda x: x["co_dose_vacina"])
        salvar_csv(registros, DIR_SAIDA / "microdados_doses.csv")
        print(f"\n  co_dose_vacina × ds_dose_vacina: {len(registros)} pares únicos")
        for r in registros:
            print(f"    {r['co_dose_vacina']:>6} = {r['ds_dose_vacina']}")

    # 3. Pares estratégia
    if pares_estrategia:
        registros = sorted([{"co_estrategia": c, "ds_estrategia": d}
                            for c, d in pares_estrategia],
                           key=lambda x: x["co_estrategia"])
        salvar_csv(registros, DIR_SAIDA / "microdados_estrategias.csv")
        print(f"\n  co_estrategia × ds_estrategia: {len(registros)} pares únicos")
        for r in registros:
            print(f"    {r['co_estrategia']:>4} = {r['ds_estrategia']}")

    # 4. Distribuição de nu_idade_paciente (top 50)
    if dist_idade:
        registros = sorted(
            [{"nu_idade_paciente": k, "contagem": v}
             for k, v in dist_idade.items()],
            key=lambda x: -x["contagem"]
        )
        salvar_csv(registros[:200], DIR_SAIDA / "microdados_idade_dist.csv")
        print(f"\n  nu_idade_paciente: {len(dist_idade)} valores distintos")
        print(f"  Top 20 (para entender o formato):")
        for r in registros[:20]:
            print(f"    {r['nu_idade_paciente']:>10} → {r['contagem']:>10,} registros")

        # Análise do formato
        print(f"\n  Análise do formato de nu_idade_paciente:")
        exemplos = [r["nu_idade_paciente"] for r in registros[:100]]
        nums = [int(x) for x in exemplos if x.isdigit()]
        if nums:
            print(f"    Min: {min(nums)}, Max: {max(nums)}")
            # Padrão DATASUS: 1xx=horas, 2xx=dias, 3xx=meses, 4xx=anos
            faixas = {"1xx (horas)": 0, "2xx (dias)": 0,
                      "3xx (meses)": 0, "4xx (anos)": 0, "outro": 0}
            for n in nums:
                if 100 <= n < 200:
                    faixas["1xx (horas)"] += 1
                elif 200 <= n < 300:
                    faixas["2xx (dias)"] += 1
                elif 300 <= n < 400:
                    faixas["3xx (meses)"] += 1
                elif 400 <= n < 500:
                    faixas["4xx (anos)"] += 1
                else:
                    faixas["outro"] += 1
            for faixa, count in faixas.items():
                if count > 0:
                    print(f"    {faixa}: {count} valores")

    # 5. sg_vacina (siglas)
    if todos_valores.get("sg_vacina"):
        registros = sorted([{"sg_vacina": v}
                            for v in todos_valores["sg_vacina"]])
        salvar_csv(registros, DIR_SAIDA / "microdados_siglas_vacina.csv")
        print(f"\n  sg_vacina: {len(registros)} siglas únicas")
        for r in registros[:20]:
            print(f"    {r['sg_vacina']}")


# ═════════════════════════════════════════════════════════════════════════════
# PARTE 3: RELATÓRIO FINAL
# ═════════════════════════════════════════════════════════════════════════════

def gerar_relatorio():
    """Gera relatório resumo dos resultados."""
    print("\n" + "=" * 70)
    print("RESULTADOS")
    print("=" * 70)

    print(f"\nArquivos gerados em {DIR_SAIDA}:")
    if DIR_SAIDA.exists():
        for f in sorted(DIR_SAIDA.glob("*.csv")):
            tamanho = f.stat().st_size
            with open(f) as fh:
                n_linhas = sum(1 for _ in fh) - 1  # descontar header
            print(f"  {f.name:40s} {n_linhas:>6} registros  ({tamanho:>8,} bytes)")

    print(f"\nDicionários brutos em {DIR_DICIONARIOS}:")
    if DIR_DICIONARIOS.exists():
        for f in sorted(DIR_DICIONARIOS.glob("*")):
            print(f"  {f.name:40s} ({f.stat().st_size:>8,} bytes)")

    print("\n" + "=" * 70)
    print("PRÓXIMOS PASSOS")
    print("=" * 70)
    print("""
1. Copie os CSVs de {dir_saida} para seu computador:
     scp root@IP:{dir_saida}/*.csv .

2. Com os CSVs em mãos, construa as tabelas de-para:
   - dicionario_IMUNO.csv  ↔  microdados_vacinas.csv   → de-para vacinas
   - dicionario_DOSE.csv   ↔  microdados_doses.csv     → de-para doses
   - dicionario_FXET.csv   ↔  microdados_idade_dist.csv → recategorização
   - dicionario_IMUNOCOB.csv → composição dos indicadores compostos

3. Verifique se co_vacina dos microdados usa os mesmos códigos numéricos
   que IMUNO.CNV. Se sim, o mapeamento é 1:1 e simplifica enormemente.

4. Atualize HARMONIZACAO.md preenchendo os [TODO]s.
""".format(dir_saida=DIR_SAIDA))


# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print("=" * 70)
    print("EXTRAÇÃO DE DICIONÁRIOS E VALORES ÚNICOS PARA HARMONIZAÇÃO")
    print(f"SI-PNI: Agregados (1994-2019) ↔ Microdados (2020-2025+)")
    print("=" * 70)

    # Criar diretórios
    for d in [DIR_TRABALHO, DIR_DICIONARIOS, DIR_MICRODADOS, DIR_SAIDA]:
        d.mkdir(parents=True, exist_ok=True)

    # Parte 1: Dicionários do FTP
    processar_dicionarios()

    # Parte 2: Valores únicos dos microdados
    extrair_valores_microdados()

    # Relatório
    gerar_relatorio()

    print("\nFinalizado! ✓")
