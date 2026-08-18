# SIH/SUS — Hospital Information System (healthbr-data)

This prefix (`s3://healthbr-data/sih/`) is a **namespace**: each SIH file
type published by DATASUS is a separate sub-dataset with its own schema,
manifest and documentation. **Do not open `sih/` itself with Arrow** — open
a sub-module partition.

| Sub-module | What one row is | Period | Path | Documentation |
|---|---|---|---|---|
| **RD** — AIH Reduzida | one hospital admission | 1992–present | `sih/rd/ano=YYYY/mes=MM/uf=XX/` | [sih/rd/README.md](rd/README.md) · [HF sih-rd](https://huggingface.co/datasets/SidneyBissoli/sih-rd) |
| **SP** — Serviços Profissionais | one act/procedure inside an admission (~11 per AIH) | 1997–present | `sih/sp/ano=YYYY/mes=MM/uf=XX/` | [sih/sp/README.md](sp/README.md) · [HF sih-sp](https://huggingface.co/datasets/SidneyBissoli/sih-sp) |

Join key: `sp.SP_NAIH = rd.N_AIH` (same year/month/UF partition).

Future sub-modules (low priority): `sih/rj/` (rejected AIH), `sih/er/`
(rejection errors).

**History:** until 2026-08-17 the RD data lived directly under
`sih/ano=…`. It was moved to `sih/rd/` when SP was added; update old paths.

---

**Português.** Este prefixo é um *namespace*: cada tipo de arquivo do SIH
é um sub-dataset com schema, manifesto e documentação próprios. Não abra
`sih/` diretamente no Arrow — aponte para uma partição de `sih/rd/` ou
`sih/sp/`. RD = uma linha por internação (1992–); SP = uma linha por
ato/procedimento dentro da internação (1997–). Chave de junção:
`SP_NAIH` = `N_AIH`. Até 17/ago/2026 o RD ficava direto em `sih/ano=…`.

Project: https://github.com/SidneyBissoli/healthbr-data · License CC-BY 4.0 ·
Source: Ministry of Health / DATASUS.
