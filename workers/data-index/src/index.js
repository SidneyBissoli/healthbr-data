/**
 * healthbr-data — página-índice de https://data.sidneybissoli.com/
 *
 * O domínio é ligado direto ao bucket R2 `healthbr-data`, que só serve
 * objetos pelo caminho exato: a raiz `/` não é objeto e devolvia o 404 da
 * Cloudflare. Este Worker responde SÓ na rota `data.sidneybissoli.com/`
 * (a raiz exata, ver wrangler.jsonc); todo outro caminho continua indo ao R2
 * sem passar por aqui, e a Cache Rule do domínio segue valendo.
 *
 * A página é estática exceto pelo bloco dos cubos do SIH, lido do próprio
 * `sih/cubos/manifest.json` no bucket (binding BUCKET) a cada pedido — a
 * resposta sai com Cache-Control de 5 minutos, o mesmo TTL do manifesto.
 *
 * Deploy: `npx wrangler deploy` nesta pasta (ou pela API, ver README.md).
 */

const DATASETS = [
  ["SI-PNI — vacinação de rotina (microdados)", "sipni/microdados/", "2020–presente", "sipni/manifest.json"],
  ["SI-PNI — vacinação COVID-19 (microdados)", "sipni/covid/microdados/", "2021–presente", "sipni/manifest.json"],
  ["SI-PNI — agregados históricos (doses e cobertura)", "sipni/agregados/", "1994–2019", "sipni/manifest.json"],
  ["SI-PNI — dicionários oficiais", "sipni/dicionarios/", "2019", "sipni/manifest.json"],
  ["SINASC — nascidos vivos (microdados)", "sinasc/", "1994–2022", "sinasc/manifest.json"],
  ["SIH — internações, AIH reduzida (RD, microdados)", "sih/rd/", "1992–presente", "sih/rd/manifest.json"],
  ["SIH — serviços profissionais por internação (SP, microdados)", "sih/sp/", "1997–presente", "sih/sp/manifest.json"],
  ["SIH — cubos anuais (causas, séries mensais, ICSAP por município)", "sih/cubos/", "1992–2025", "sih/cubos/manifest.json"],
];

const GITHUB = "https://github.com/SidneyBissoli/healthbr-data";
const CARDS = `${GITHUB}/tree/master/guides/dataset-cards`;

function esc(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

function mb(bytes) {
  return (bytes / 1048576).toLocaleString("pt-BR", { maximumFractionDigits: 0 });
}

async function cubesBlock(env, origin) {
  try {
    const obj = await env.BUCKET.get("sih/cubos/manifest.json");
    if (!obj) return "<p>Manifesto dos cubos indisponível no momento.</p>";
    const m = await obj.json();
    const years = Object.keys(m.years ?? {}).map(Number).sort((a, b) => a - b);
    if (years.length === 0) return "<p>Nenhum cubo publicado.</p>";
    let bytes = 0;
    let records = 0;
    const builders = new Set();
    for (const y of years) {
      const e = m.years[String(y)];
      records += Number(e.records_in_cube ?? 0);
      builders.add(e.builder_version);
      for (const f of Object.values(e.files ?? {})) bytes += Number(f.size_bytes ?? 0);
    }
    const first = years[0];
    const last = years[years.length - 1];
    return (
      `<p><strong>${years.length} anos</strong> (${first}–${last}), ` +
      `${records.toLocaleString("pt-BR")} internações, ${mb(bytes)} MB em ${years.length * 4} arquivos; ` +
      `manifesto gerado em ${esc(m.generated_at ?? "?")}; builder ${esc([...builders].sort().join(", "))}.</p>` +
      `<p>Por ano: <code>sih_causas_&lt;ano&gt;.parquet</code>, <code>sih_series_&lt;ano&gt;.parquet</code>, ` +
      `<code>sih_icsap_&lt;ano&gt;.parquet</code> e o sidecar de proveniência <code>sih_provenance_&lt;ano&gt;.json</code>, ` +
      `com SHA-256 e tamanho em <a href="${origin}/sih/cubos/manifest.json">sih/cubos/manifest.json</a>. ` +
      `Eras: 1992–1997 em CID-9 decodificada (UF do arquivo, valor nominal na moeda da época, ICSAP por lista derivada); ` +
      `raça/cor só de 2008. % ICSAP no universo do pacote csapAIH (coluna <code>exclusion</code>). ` +
      `Ficha completa: <a href="${CARDS}/sih-cubos-README.md">sih-cubos-README.md</a>.</p>`
    );
  } catch (e) {
    return `<p>Manifesto dos cubos não pôde ser lido (${esc(e instanceof Error ? e.message : String(e))}).</p>`;
  }
}

function page(origin, cubes) {
  const rows = DATASETS.map(
    ([name, prefix, period, manifest]) =>
      `<tr><td>${esc(name)}</td><td><code>${esc(prefix)}</code></td><td>${esc(period)}</td>` +
      `<td>${manifest ? `<a href="${origin}/${manifest}">manifest.json</a>` : `<a href="${CARDS}">ficha</a>`}</td></tr>`,
  ).join("\n");
  return `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>healthbr-data — dados públicos de saúde do Brasil em Parquet</title>
<meta name="description" content="Redistribuição aberta (CC-BY-4.0) de bases do DATASUS/Ministério da Saúde em Apache Parquet: SIH, SINASC, SI-PNI e cubos anuais de internações (1992–2025).">
<link rel="canonical" href="${origin}/">
<style>
  :root { color-scheme: light dark; --fg: #1a1a1a; --bg: #fff; --muted: #555; --line: #ddd; --link: #0b57d0; }
  @media (prefers-color-scheme: dark) { :root { --fg: #e6e6e6; --bg: #121212; --muted: #aaa; --line: #333; --link: #8ab4f8; } }
  body { margin: 0 auto; max-width: 56rem; padding: 2rem 1.25rem 3rem; font: 16px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; color: var(--fg); background: var(--bg); }
  h1 { font-size: 1.7rem; margin: 0 0 .25rem; } h2 { font-size: 1.2rem; margin: 2rem 0 .5rem; }
  p.lead { color: var(--muted); margin-top: 0; }
  table { border-collapse: collapse; width: 100%; font-size: .95rem; } th, td { text-align: left; padding: .45rem .5rem; border-bottom: 1px solid var(--line); vertical-align: top; }
  code { font-size: .9em; } a { color: var(--link); }
  footer { margin-top: 2.5rem; color: var(--muted); font-size: .9rem; border-top: 1px solid var(--line); padding-top: 1rem; }
  .en { color: var(--muted); font-size: .95rem; }
</style>
</head>
<body>
<h1>healthbr-data</h1>
<p class="lead">Dados públicos de saúde do Brasil, redistribuídos em Apache Parquet a partir do DATASUS / Ministério da Saúde, sob licença CC-BY-4.0. Este domínio serve o bucket inteiro: cada caminho abaixo é um objeto ou um prefixo, e cada dataset tem um <code>manifest.json</code> com hash e data de cada arquivo de origem.</p>
<p class="en">Brazilian public health data (DATASUS / Ministry of Health) redistributed as Apache Parquet under CC-BY-4.0. This domain serves the whole bucket; every dataset ships a <code>manifest.json</code> with the hash and download date of each source file. Full documentation in English at <a href="${GITHUB}">GitHub</a>.</p>

<h2>Datasets</h2>
<table>
<thead><tr><th>Dataset</th><th>Prefixo</th><th>Período</th><th>Manifesto</th></tr></thead>
<tbody>
${rows}
</tbody>
</table>
<p>Os microdados são particionados por <code>ano=AAAA/mes=MM/uf=XX/</code> (SIH) ou por ano/UF (demais) e se leem com Arrow, DuckDB ou pandas apontando para a partição, nunca para a raiz do dataset. Credenciais S3 somente-leitura e exemplos em R e Python: <a href="${CARDS}">fichas dos datasets</a>.</p>

<h2>Cubos anuais do SIH</h2>
${cubes}

<h2>Como usar</h2>
<ul>
  <li><strong>R:</strong> pacote <a href="https://github.com/SidneyBissoli/healthbR">healthbR</a> (CRAN) — <code>sih_data(year = 2023, uf = "SP", source = "r2")</code> lê o espelho direto.</li>
  <li><strong>Agentes e LLMs:</strong> servidor MCP <a href="https://github.com/SidneyBissoli/sih-br-mcp">sih-br-mcp</a> consulta os cubos com proveniência em cada resposta.</li>
  <li><strong>Qualquer linguagem:</strong> HTTPS neste domínio (<code>Range</code> aceito) ou S3 compatível; ver as fichas.</li>
</ul>

<footer>
<p>Fonte primária: Ministério da Saúde — DATASUS. Redistribuição: <a href="${GITHUB}">healthbr-data</a> (Sidney Bissoli), também em <a href="https://huggingface.co/SidneyBissoli">Hugging Face</a>. Licença dos dados redistribuídos: <a href="https://creativecommons.org/licenses/by/4.0/">CC-BY-4.0</a>. Os cubos do SIH são dados derivados; a lista ICSAP de 1992–1997 não é ato normativo.</p>
</footer>
</body>
</html>`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/" && url.pathname !== "/index.html") {
      // Não deveria acontecer (a rota é só a raiz); devolve o objeto do R2.
      return fetch(request);
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    const origin = url.origin;
    const html = page(origin, await cubesBlock(env, origin));
    return new Response(html, {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "public, max-age=300",
        "x-robots-tag": "index, follow",
      },
    });
  },
};
