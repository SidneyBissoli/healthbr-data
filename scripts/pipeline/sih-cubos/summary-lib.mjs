// Máquina COMPARTILHADA pelos derivadores de pré-agregados (derive-icsap-summary.mjs,
// PLAN-005; derive-causas-summary.mjs, PLAN-006). O que mora aqui é o que os dois
// fazem igual e não deve existir em duas cópias:
//
// - ler o manifesto do canal (URL ou arquivo) e escolher os anos;
// - baixar o cubo de um ano CONFERINDO o sha256 do manifesto, com `?v=<sha>`
//   como chave de cache por versão (a borda segura o objeto reescrito no lugar
//   por até 300 s — contrato do canal);
// - abrir o DuckDB com 4 threads;
// - escrever o sidecar de proveniência.
//
// O que NÃO mora aqui é o que os dois fazem diferente: o SQL do grão, o
// selftest e o formato do sidecar. Cada derivador é dono do seu.
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

export const DEFAULT_MANIFEST = "https://data.sidneybissoli.com/sih/cubos/manifest.json";

/** `--flag valor` e `--flag` (booleano), como nos outros scripts da pipeline. */
export function parseArgs(argv = process.argv.slice(2)) {
  return Object.fromEntries(
    argv
      .map((a, i, all) => (a.startsWith("--") ? [a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : true] : []))
      .filter((p) => p.length),
  );
}

/** Erro fatal com o prefixo do derivador que chamou. */
export function failWith(prefix) {
  return (msg) => {
    console.error(`${prefix}: ${msg}`);
    process.exit(1);
  };
}

/** Caminho com barra normal — o DuckDB não aceita a barra invertida do Windows. */
export const posix = (p) => p.replace(/\\/g, "/");

export async function duckdb() {
  const { DuckDBInstance } = await import("@duckdb/node-api");
  const inst = await DuckDBInstance.create(":memory:");
  const conn = await inst.connect();
  await conn.run("SET threads TO 4");
  const q = async (sql) => (await conn.runAndReadAll(sql)).getRowObjectsJS();
  return { conn, q, run: (sql) => conn.run(sql) };
}

export function sha256Of(path) {
  const h = createHash("sha256");
  h.update(readFileSync(path));
  return h.digest("hex");
}

async function fetchTo(url, path) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} em ${url}`);
  writeFileSync(path, Buffer.from(await res.arrayBuffer()));
}

/** Manifesto do canal por URL (padrão) ou arquivo local. */
export async function loadManifest(manifestArg, fail) {
  const arg = String(manifestArg ?? DEFAULT_MANIFEST);
  const manifest = arg.startsWith("http") ? await (await fetch(arg)).json() : JSON.parse(await readFile(arg, "utf8"));
  if (!manifest?.years || Object.keys(manifest.years).length === 0) fail("manifesto sem anos");
  return { manifest, base: String(manifest.base_url ?? DEFAULT_MANIFEST.replace("manifest.json", "")) };
}

/** `--years 1992,1993` ou todos os anos do manifesto, em ordem. */
export function wantedYears(manifest, yearsArg) {
  if (!yearsArg || yearsArg === "all") return Object.keys(manifest.years).map(Number).sort((a, b) => a - b);
  return String(yearsArg)
    .split(",")
    .map((s) => Number(s.trim()))
    .filter(Boolean);
}

/**
 * Garante o cubo `kind` do ano em workDir, conferido pelo sha256 do manifesto,
 * e devolve `{ path, sha }`. Reusa o arquivo já baixado quando o hash bate —
 * é o que faz os dois derivadores compartilharem o mesmo `.derive-cache` sem
 * baixar 1,6 GB duas vezes.
 */
export async function ensureCube({ kind, year, manifest, base, workDir, fail }) {
  const entry = manifest.years[String(year)];
  const file = entry?.files?.[kind];
  if (!file?.sha256) fail(`${year}: manifesto sem sha256 do cubo ${kind}`);
  const local = join(workDir, file.name);
  if (!existsSync(local) || sha256Of(local) !== file.sha256) {
    // ?v=<sha256>: chave de cache por versão — a borda pode segurar o objeto
    // reescrito no lugar por até 300 s (contrato do canal).
    await fetchTo(`${base}${file.name}?v=${file.sha256}`, local);
    const got = sha256Of(local);
    if (got !== file.sha256) fail(`${year}: sha256 baixado ${got} != ${file.sha256} do manifesto`);
  }
  return { path: local, sha: file.sha256 };
}

/** Sidecar de proveniência, com o carimbo de tempo no formato do canal (sem milissegundos). */
export function writeProvenance(dir, name, body) {
  const prov = { built_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"), ...body };
  writeFileSync(join(dir, name), JSON.stringify(prov, null, 2) + "\n");
  return prov;
}

export function ensureDirs(...dirs) {
  for (const d of dirs) mkdirSync(d, { recursive: true });
}
