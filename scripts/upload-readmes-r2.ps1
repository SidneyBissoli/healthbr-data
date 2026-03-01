# =============================================================================
# Upload dataset READMEs to Cloudflare R2
# 4 files: 1 README.md (EN) per dataset
# Run from the project root (parquet-files/)
# =============================================================================

Write-Host "=== Uploading dataset READMEs to R2 ===" -ForegroundColor Cyan

# 1. SI-PNI Microdados (rotina)
Write-Host "`n[1/4] sipni/microdados/README.md" -ForegroundColor Yellow
rclone copyto "data/readme-sipni-microdados.md" "r2:healthbr-data/sipni/microdados/README.md" --transfers 16 --checkers 32 --verbose
if ($LASTEXITCODE -eq 0) { Write-Host "  OK" -ForegroundColor Green } else { Write-Host "  FAILED" -ForegroundColor Red }

# 2. SI-PNI COVID
Write-Host "`n[2/4] sipni/covid/microdados/README.md" -ForegroundColor Yellow
rclone copyto "data/readme-sipni-covid.md" "r2:healthbr-data/sipni/covid/microdados/README.md" --transfers 16 --checkers 32 --verbose
if ($LASTEXITCODE -eq 0) { Write-Host "  OK" -ForegroundColor Green } else { Write-Host "  FAILED" -ForegroundColor Red }

# 3. SI-PNI Agregados - Doses
Write-Host "`n[3/4] sipni/agregados/doses/README.md" -ForegroundColor Yellow
rclone copyto "data/readme-sipni-agregados-doses.md" "r2:healthbr-data/sipni/agregados/doses/README.md" --transfers 16 --checkers 32 --verbose
if ($LASTEXITCODE -eq 0) { Write-Host "  OK" -ForegroundColor Green } else { Write-Host "  FAILED" -ForegroundColor Red }

# 4. SI-PNI Agregados - Cobertura
Write-Host "`n[4/4] sipni/agregados/cobertura/README.md" -ForegroundColor Yellow
rclone copyto "data/readme-sipni-agregados-cobertura.md" "r2:healthbr-data/sipni/agregados/cobertura/README.md" --transfers 16 --checkers 32 --verbose
if ($LASTEXITCODE -eq 0) { Write-Host "  OK" -ForegroundColor Green } else { Write-Host "  FAILED" -ForegroundColor Red }

# Verify
Write-Host "`n=== Verifying uploads ===" -ForegroundColor Cyan
rclone ls r2:healthbr-data/sipni/ --include "README.md" --transfers 16 --checkers 32

Write-Host "`n=== Done (4 READMEs uploaded) ===" -ForegroundColor Green
