"""
healthbr-data Sync Status Dashboard

Streamlit app that visualizes the synchronization status between
official data sources (SI-PNI, SINASC) and the healthbr-data
redistribution on Cloudflare R2.

Reads a static sync-status.json (updated weekly by GitHub Actions).
"""

import json
from datetime import datetime
from pathlib import Path

import pandas as pd
import streamlit as st

st.set_page_config(
    page_title="healthbr-data Sync Status",
    page_icon="\U0001F4CA",
    layout="wide",
)

# ---------------------------------------------------------------------------
# Load data
# ---------------------------------------------------------------------------

# In Docker, the working directory is /app and sync-status.json is in src/
STATUS_FILE = Path(__file__).parent / "sync-status.json"

if not STATUS_FILE.exists():
    st.error("sync-status.json not found. Dashboard not yet initialized.")
    st.stop()

data = json.loads(STATUS_FILE.read_text(encoding="utf-8"))

# ---------------------------------------------------------------------------
# Status helpers
# ---------------------------------------------------------------------------

STATUS_EMOJI = {
    "in_sync": "\U0001F7E2",      # green
    "outdated": "\U0001F7E1",     # yellow
    "missing": "\U0001F534",      # red
    "extra": "\u26A0\uFE0F",      # warning
    "not_published": "\u26AA",    # white/gray
    "check_failed": "\u2753",     # question mark
}

STATUS_LABEL = {
    "in_sync": "In sync",
    "outdated": "Outdated",
    "missing": "Missing",
    "extra": "Extra",
    "not_published": "Not published",
    "check_failed": "Check failed",
}

DATASET_LABELS = {
    "sipni-microdados": "SI-PNI Microdata (2020+)",
    "sipni-covid": "SI-PNI COVID",
    "sipni-agregados-doses": "SI-PNI Aggregated \u2014 Doses (1994\u20132019)",
    "sipni-agregados-cobertura": "SI-PNI Aggregated \u2014 Coverage (1994\u20132019)",
    "sinasc": "SINASC \u2014 Live Births (1994\u20132022)",
}


def overall_emoji(summary: dict) -> str:
    """Return a single emoji for the dataset's overall status."""
    for key in ("missing", "outdated", "check_failed"):
        if summary.get(key, 0) > 0:
            return STATUS_EMOJI.get(key, "\U0001F534")
    return STATUS_EMOJI["in_sync"]


def fmt_size(size_bytes) -> str:
    """Format bytes into a human-readable string."""
    if size_bytes is None:
        return "\u2014"
    if size_bytes >= 1e9:
        return f"{size_bytes / 1e9:.2f} GB"
    if size_bytes >= 1e6:
        return f"{size_bytes / 1e6:.1f} MB"
    if size_bytes >= 1e3:
        return f"{size_bytes / 1e3:.0f} KB"
    return f"{size_bytes} B"


def fmt_timestamp(ts: str | None) -> str:
    """Format an ISO timestamp for display."""
    if not ts:
        return "\u2014"
    try:
        dt = datetime.fromisoformat(ts)
        return dt.strftime("%Y-%m-%d %H:%M UTC")
    except (ValueError, TypeError):
        return ts


# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

st.title("healthbr-data \u2014 Synchronization Status")
st.caption(f"Last checked: {fmt_timestamp(data.get('generated_at'))}")

# ---------------------------------------------------------------------------
# Summary cards
# ---------------------------------------------------------------------------

cols = st.columns(len(DATASET_LABELS))
datasets = data.get("datasets", {})

for col, (ds_key, ds_label) in zip(cols, DATASET_LABELS.items()):
    ds = datasets.get(ds_key, {})
    summary = ds.get("summary", {})
    total = summary.get("total_checked", 0)
    synced = summary.get("in_sync", 0)
    emoji = overall_emoji(summary)

    with col:
        st.metric(
            label=ds_label,
            value=f"{emoji} {synced}/{total}",
            delta=None,
        )
        # Sub-counts
        parts = []
        for status_key in ("outdated", "missing", "not_published", "check_failed"):
            count = summary.get(status_key, 0)
            if count > 0:
                parts.append(
                    f"{STATUS_EMOJI.get(status_key, '')} {count} {STATUS_LABEL.get(status_key, status_key)}"
                )
        if parts:
            st.caption(" | ".join(parts))
        else:
            st.caption("All partitions in sync")

st.divider()

# ---------------------------------------------------------------------------
# Tabs (one per dataset)
# ---------------------------------------------------------------------------

tab_labels = list(DATASET_LABELS.values())
tabs = st.tabs(tab_labels)


def build_microdata_df(details: list) -> pd.DataFrame:
    """Build DataFrame for microdata (year-month partitions)."""
    rows = []
    for d in details:
        partition = d["partition"]  # "YYYY-MM"
        parts = partition.split("-")
        year, month = parts[0], parts[1]
        source = d.get("source", {})
        redist = d.get("redistribution", {})
        status = d.get("status", "")

        rows.append({
            "Year": year,
            "Month": month,
            "Source Size": fmt_size(source.get("size_bytes")),
            "Redistributed Size": fmt_size(redist.get("total_size_bytes")),
            "Files": redist.get("output_file_count", "\u2014"),
            "Records": f"{redist.get('total_records', 0):,}" if redist.get("total_records") else "\u2014",
            "Status": STATUS_EMOJI.get(status, "\u2753"),
            "Status Key": status,
            "Notes": d.get("notes") or "",
        })
    return pd.DataFrame(rows)


def build_covid_df(details: list) -> pd.DataFrame:
    """Build DataFrame for COVID (UF partitions)."""
    rows = []
    for d in details:
        source = d.get("source", {})
        redist = d.get("redistribution", {})
        status = d.get("status", "")

        rows.append({
            "UF": d["partition"],
            "Source Parts": f"{source.get('parts_found', '\u2014')}/{source.get('parts_expected', '\u2014')}",
            "Source Size": fmt_size(source.get("size_bytes")),
            "Redistributed Size": fmt_size(redist.get("total_size_bytes")),
            "Files": redist.get("output_file_count", "\u2014"),
            "Status": STATUS_EMOJI.get(status, "\u2753"),
            "Status Key": status,
            "Notes": d.get("notes") or "",
        })
    return pd.DataFrame(rows)


def build_agregados_df(details: list) -> pd.DataFrame:
    """Build DataFrame for aggregated datasets (year-UF partitions)."""
    rows = []
    for d in details:
        partition = d["partition"]  # "YYYY-UF"
        parts = partition.split("-", 1)
        year = parts[0]
        uf = parts[1] if len(parts) > 1 else ""
        source = d.get("source", {})
        redist = d.get("redistribution", {})
        status = d.get("status", "")

        rows.append({
            "Year": year,
            "UF": uf,
            "Source File": source.get("filename", "\u2014"),
            "Source Size": fmt_size(source.get("size_bytes")),
            "Redistributed Size": fmt_size(redist.get("total_size_bytes")),
            "Records": f"{redist.get('total_records', 0):,}" if redist.get("total_records") else "\u2014",
            "Status": STATUS_EMOJI.get(status, "\u2753"),
            "Status Key": status,
            "Notes": d.get("notes") or "",
        })
    return pd.DataFrame(rows)


def render_status_filter(tab_key: str) -> list[str]:
    """Render a multiselect status filter and return selected status keys."""
    options = [
        f"{STATUS_EMOJI['in_sync']} In sync",
        f"{STATUS_EMOJI['missing']} Missing",
        f"{STATUS_EMOJI['outdated']} Outdated",
        f"{STATUS_EMOJI['not_published']} Not published",
    ]
    selected = st.multiselect(
        "Filter by status:",
        options,
        default=[],
        key=f"filter_{tab_key}",
    )
    if not selected:
        return []
    # Map back to status keys
    label_to_key = {
        "In sync": "in_sync",
        "Missing": "missing",
        "Outdated": "outdated",
        "Not published": "not_published",
    }
    keys = []
    for s in selected:
        label = s.split(" ", 1)[1] if " " in s else s
        if label in label_to_key:
            keys.append(label_to_key[label])
    return keys


def render_dataset_tab(ds_key: str, build_fn):
    """Render a dataset tab with filter and table."""
    ds = datasets.get(ds_key, {})
    details = ds.get("details", [])

    if not details:
        st.warning("No data available for this dataset.")
        return

    df = build_fn(details)
    display_cols = [c for c in df.columns if c != "Status Key"]

    # Status filter
    filter_keys = render_status_filter(ds_key)
    if filter_keys:
        df = df[df["Status Key"].isin(filter_keys)]

    # Size summary
    summary = ds.get("summary", {})
    total_source_bytes = sum(
        d.get("source", {}).get("size_bytes", 0) or 0
        for d in details
        if d.get("source", {}).get("exists")
    )
    total_redist_bytes = sum(
        d.get("redistribution", {}).get("total_size_bytes", 0) or 0
        for d in details
        if d.get("redistribution", {}).get("exists")
    )

    c1, c2, c3 = st.columns(3)
    with c1:
        st.metric("Source Total", fmt_size(total_source_bytes))
    with c2:
        st.metric("Redistributed Total", fmt_size(total_redist_bytes))
    with c3:
        if total_redist_bytes > 0:
            ratio = total_source_bytes / total_redist_bytes
            st.metric("Compression Ratio", f"{ratio:.2f}x")
        else:
            st.metric("Compression Ratio", "\u2014")

    # Table
    st.dataframe(
        df[display_cols],
        use_container_width=True,
        hide_index=True,
        height=min(400, 35 * len(df) + 38),
    )

    st.caption(f"Showing {len(df)} of {len(details)} partitions")


# --- Tab 0: Microdata ---
with tabs[0]:
    render_dataset_tab("sipni-microdados", build_microdata_df)

# --- Tab 1: COVID ---
with tabs[1]:
    render_dataset_tab("sipni-covid", build_covid_df)

# --- Tab 2: Agregados Doses ---
with tabs[2]:
    render_dataset_tab("sipni-agregados-doses", build_agregados_df)

# --- Tab 3: Agregados Cobertura ---
with tabs[3]:
    render_dataset_tab("sipni-agregados-cobertura", build_agregados_df)

# --- Tab 4: SINASC ---
with tabs[4]:
    render_dataset_tab("sinasc", build_agregados_df)

# ---------------------------------------------------------------------------
# Footer
# ---------------------------------------------------------------------------

st.divider()

st.markdown(
    "**Legend:** "
    f"{STATUS_EMOJI['in_sync']} In sync \u00A0\u00A0 "
    f"{STATUS_EMOJI['missing']} Missing/Action needed \u00A0\u00A0 "
    f"{STATUS_EMOJI['outdated']} Source updated after processing \u00A0\u00A0 "
    f"{STATUS_EMOJI['not_published']} Not yet published by Ministry"
)

st.caption(
    "This dashboard compares official data published by Brazil's "
    "Ministry of Health (SI-PNI, SINASC) with the [healthbr-data](https://huggingface.co/SidneyBissoli) "
    "redistribution on Cloudflare R2. Updated weekly via GitHub Actions. "
    "Source code: [github.com/SidneyBissoli/healthbr-data](https://github.com/SidneyBissoli/healthbr-data)"
)
