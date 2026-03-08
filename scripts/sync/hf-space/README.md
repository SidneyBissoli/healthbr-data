---
title: healthbr-data Sync Status
emoji: "\U0001F4CA"
colorFrom: green
colorTo: blue
sdk: docker
app_port: 8501
tags:
  - streamlit
  - health
  - brazil
  - data-quality
license: cc-by-4.0
pinned: false
short_description: SI-PNI data sync status official vs redistributed
---

# healthbr-data — Synchronization Status Dashboard

This dashboard compares the official SI-PNI vaccination data published by Brazil's Ministry of Health with the [healthbr-data](https://huggingface.co/datasets/SidneyBissoli/healthbr-data) redistribution on Cloudflare R2.

**Datasets monitored:**
- SI-PNI Microdata (routine vaccination, 2020+)
- SI-PNI COVID vaccination microdata
- SI-PNI Aggregated doses (1994–2019)
- SI-PNI Aggregated coverage (1994–2019)

Updated weekly via GitHub Actions.

Source code: [github.com/SidneyBissoli/healthbr-data](https://github.com/SidneyBissoli/healthbr-data)
