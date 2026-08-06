#!/usr/bin/env bash
# ==============================================================================
# setup-snapshot.sh — Provisiona a imagem base da VPS de manutenção
# ==============================================================================
#
# Rodar UMA VEZ (e a cada atualização de stack) numa VPS Hetzner limpa
# (Ubuntu 24.04, x86 — nunca ARM), como root:
#
#   1. hcloud server create --name healthbr-snapshot-builder \
#        --type cpx41 --image ubuntu-24.04 --location nbg1 \
#        --ssh-key <sua-chave>
#   2. scp este script para a VPS e execute: bash setup-snapshot.sh
#   3. Desligue e tire o snapshot ROTULADO (o maintenance.yml procura por ele):
#        hcloud server poweroff healthbr-snapshot-builder
#        hcloud server create-image healthbr-snapshot-builder \
#          --type snapshot --description "healthbr maintenance base" \
#          --label healthbr=maintenance
#   4. Delete a VPS builder:
#        hcloud server delete healthbr-snapshot-builder
#
# O snapshot NÃO contém credenciais nem repo — ambos são injetados em cada
# rodada pelo cloud-init do maintenance.yml. Contém apenas a stack de
# software (idêntica à da seção 2 do reference-pipelines-pt.md, mais
# read.dbc e boto3).
# ==============================================================================

set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# --- Stack base: R, jq, rclone, python ---------------------------------------
apt update
apt install -y r-base r-base-dev libcurl4-openssl-dev libssl-dev \
  libxml2-dev jq python3-pip git
curl https://rclone.org/install.sh | bash
pip3 install polars boto3 --break-system-packages

# --- Arrow C++ (necessário para o pacote R arrow) ----------------------------
apt install -y -V ca-certificates lsb-release wget
wget "https://apache.jfrog.io/artifactory/arrow/$(lsb_release --id --short | tr 'A-Z' 'a-z')/apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb"
apt install -y "./apache-arrow-apt-source-latest-$(lsb_release --codename --short).deb"
apt update
apt install -y libarrow-dev libparquet-dev libarrow-dataset-dev libarrow-acero-dev

# --- Pacotes R ----------------------------------------------------------------
Rscript -e "install.packages(c('pacman','here','arrow','dplyr','readr','jsonlite','fs','glue','curl','digest','foreign','remotes'), repos='https://cloud.r-project.org')"

# --- read.dbc (compilado do GitHub; blast incluso) ---------------------------
Rscript -e "remotes::install_github('danicat/read.dbc'); cat('read.dbc', as.character(packageVersion('read.dbc')), 'OK\n')"

# --- Verificação final --------------------------------------------------------
echo "=== Verificação ==="
jq --version
rclone --version | head -1
python3 -c "import polars, boto3; print('polars', polars.__version__)"
Rscript -e "suppressMessages({library(arrow); library(read.dbc)}); cat('R arrow + read.dbc OK\n')"
echo "=== TUDO INSTALADO — desligue e tire o snapshot (ver cabeçalho) ==="
