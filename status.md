# Status: Processamento dos 12 Arquivos Faltantes (Agregados-Doses)

Data: 2026-03-02

## Contexto

O sync check identificou 12 arquivos DBF no FTP do DATASUS que existiam mas nunca foram processados para a redistribuicao no R2. Sao arquivos grandes (100-216 MB) de BA, MG e SP dos anos 2013-2018, provavelmente ignorados na execucao original do pipeline por timeout de FTP.

### Arquivos faltantes

| UF | Arquivos | Anos |
|----|----------|------|
| BA | DPNIBA14, DPNIBA15, DPNIBA16 | 2014-2016 |
| MG | DPNIMG13, DPNIMG14, DPNIMG15, DPNIMG16, DPNIMG18 | 2013-2016, 2018 |
| SP | DPNISP13, DPNISP14, DPNISP15, DPNISP16 | 2013-2016 |

## Etapas concluídas

### 1. Script direcionado criado e enviado ao GitHub
- Criado `scripts/pipeline/sipni-agregados-doses-missing-12.R`
- Processa apenas os 12 arquivos faltantes (sem varrer as 702 combinacoes ano x UF)
- Timeout de FTP aumentado para 600s (vs 120s do pipeline original)
- 5 tentativas de download com backoff progressivo
- Commit: `d57a3b7` no branch `master`

### 2. Pipeline executado no servidor Hetzner (46.225.160.196)
- Todos os 12 arquivos processados com sucesso
- 0 erros
- Tempo total: 37.3 minutos
- CSV de controle atualizado para 686 arquivos

### 3. CSV de controle copiado para o repositorio local
- `data/controle_versao_sipni_agregados_doses.csv` — 687 linhas (686 arquivos + cabecalho)

### 4. Manifestos R2 regenerados
- `generate-retroactive-manifests.py` executado no servidor
- 4 manifestos atualizados e enviados ao R2:
  - sipni/manifest.json
  - sipni/covid/manifest.json
  - sipni/agregados/doses/manifest.json (686 arquivos Parquet)
  - sipni/agregados/cobertura/manifest.json

### 5. Sync check executado
- `sync_check.py` confirmou:
  - `sipni-agregados-doses: in_sync (in_sync=686, not_published=16)`
  - 0 arquivos faltantes
- `sync-status.json` gerado no servidor

## Etapa em andamento

### 6. Upload do sync-status.json para o HF Space
- Space: `SidneyBissoli/healthbr-sync-status`
- `huggingface_hub` instalado no servidor
- Login do HF realizado (token configurado)
- Falta executar:
  ```bash
  cd /root/healthbr-data && python3 /tmp/upload_hf.py
  ```
- Se `/tmp/upload_hf.py` foi perdido no restart, recriar:
  ```bash
  cat > /tmp/upload_hf.py << 'EOF'
  from huggingface_hub import HfApi
  api = HfApi()
  api.upload_file(
      path_or_fileobj="sync-status.json",
      path_in_repo="sync-status.json",
      repo_id="SidneyBissoli/healthbr-sync-status",
      repo_type="space",
  )
  print("Uploaded!")
  EOF
  ```

## Etapa pendente

### 7. Commit do CSV de controle atualizado
- Arquivo: `data/controle_versao_sipni_agregados_doses.csv`
- Aguardando conclusao da etapa 6 para commit final

## Verificacao

Apos conclusao de todas as etapas:
- Sync check deve mostrar 0 faltantes para agregados-doses
- Dashboard no HF Space deve refletir a atualizacao
- CSV de controle commitado no repositorio
