#!/usr/bin/env node
// HyperFrames Studio — prompt → Claude Code (headless, abonnement) → composition
// HyperFrames → hf-render → MP4. Node 22, zéro dépendance. Derrière le Caddy
// interne (tailnet only) : aucune auth applicative.
//
// Données : $STUDIO_DATA/jobs/<id>/{meta.json, events.ndjson, project/, v<n>.mp4}
// Un job = une conversation Claude (session reprise à chaque retouche),
// chaque génération/retouche produit une version v<n>.mp4.

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { createReadStream, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync, appendFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { join, dirname, basename, extname } from "node:path";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.PORT ?? 8080);
const DATA = process.env.STUDIO_DATA ?? "/srv/studio";
const JOBS = join(DATA, "jobs");
const HERE = dirname(fileURLToPath(import.meta.url));
const CLAUDE_BIN = process.env.CLAUDE_BIN ?? "claude";
const CLAUDE_TIMEOUT_MS = Number(process.env.CLAUDE_TIMEOUT_MIN ?? 20) * 60_000;
const MAX_UPLOAD = 25 * 1024 * 1024;
const FORMATS = { portrait: "1080x1920", landscape: "1920x1080", square: "1080x1080" };
const MODELS = ["sonnet", "opus"];

mkdirSync(JOBS, { recursive: true });

// ── Persistance ─────────────────────────────────────────────────────────────
const dir = (id) => join(JOBS, id);
const load = (id) => JSON.parse(readFileSync(join(dir(id), "meta.json"), "utf8"));
const save = (m) => writeFileSync(join(dir(m.id), "meta.json"), JSON.stringify(m, null, 2));
const validId = (id) => /^[a-z0-9-]{6,40}$/.test(id) && existsSync(join(dir(id), "meta.json"));

const listeners = new Map(); // id → Set<res>
function emit(id, ev) {
  const line = JSON.stringify({ t: Date.now(), ...ev });
  appendFileSync(join(dir(id), "events.ndjson"), line + "\n");
  for (const res of listeners.get(id) ?? []) res.write(`data: ${line}\n\n`);
}
function setStatus(m, status, extra = {}) {
  Object.assign(m, { status }, extra);
  save(m);
  emit(m.id, { kind: "status", status, ...extra });
}

// Jobs interrompus par un redémarrage du service
for (const id of readdirSync(JOBS)) {
  try {
    const m = load(id);
    if (["queued", "generating", "rendering"].includes(m.status)) setStatus(m, "error", { error: "interrompu (redémarrage du service)" });
  } catch {}
}

// ── File d'attente (un job à la fois : Claude puis rendu) ────────────────────
const queue = [];
let busy = false;
function enqueue(id, prompt) {
  queue.push({ id, prompt });
  pump();
}
async function pump() {
  if (busy || !queue.length) return;
  busy = true;
  const { id, prompt } = queue.shift();
  try { await runVersion(id, prompt); } catch (e) {
    const m = load(id);
    const v = m.versions.at(-1);
    if (v && v.status !== "done") v.status = "error";
    setStatus(m, "error", { error: String(e.message ?? e).slice(0, 2000) });
  } finally { busy = false; pump(); }
}

const systemPrompt = (m) => `Tu es le moteur d'un studio vidéo. Le dossier courant est un projet HyperFrames déjà initialisé (index.html, hyperframes.json, CLAUDE.md, AGENTS.md) : lis CLAUDE.md et suis le skill hyperframes.
Contraintes :
- Format ${FORMATS[m.format]} (${m.format}), durée visée ${m.duration} s, sauf si la demande dit autrement.
- Images fournies par l'utilisateur : assets/uploads/ (${m.uploads.length ? m.uploads.join(", ") : "aucune"}). Pas d'autre média externe que les bibliothèques déjà référencées.
- Vérifie avec \`hyperframes check\` (et \`hyperframes snapshot\` si utile) jusqu'à zéro erreur. Le CLI est installé globalement : appelle \`hyperframes …\` directement, pas via npx ni npm run.
- NE LANCE PAS \`hyperframes render\` : le studio rend lui-même la vidéo après toi.
- Réponds en français. Termine par une phrase qui décrit la vidéo obtenue.`;

const TOOLS = [
  "Read", "Write", "Edit", "Glob", "Grep", "Skill", "TodoWrite",
  "Bash(hyperframes check:*)", "Bash(hyperframes lint:*)", "Bash(hyperframes validate:*)",
  "Bash(hyperframes snapshot:*)", "Bash(hyperframes inspect:*)", "Bash(hyperframes docs:*)",
  "Bash(hyperframes info:*)", "Bash(hyperframes timeline:*)", "Bash(hyperframes compositions:*)",
  "Bash(hyperframes catalog:*)", "Bash(hyperframes add:*)", "Bash(ls:*)",
];
// Mêmes sous-commandes via npx / npm run (le CLAUDE.md du projet les suggère).
TOOLS.push(...TOOLS.filter((t) => t.startsWith("Bash(hyperframes ")).map((t) => t.replace("Bash(hyperframes ", "Bash(npx hyperframes ")),
  "Bash(npm run check:*)", "Bash(npm run lint:*)");

async function runVersion(id, prompt) {
  const m = load(id);
  const n = m.versions.length + 1;
  m.versions.push({ n, prompt, createdAt: new Date().toISOString(), status: "generating" });
  setStatus(m, "generating", { error: null });
  emit(id, { kind: "version", n, prompt });
  const project = join(dir(id), "project");

  // 1. Claude écrit / retouche la composition
  const args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
    "--model", m.model, "--append-system-prompt", systemPrompt(m),
    "--permission-mode", "acceptEdits", "--allowedTools", ...TOOLS,
    "--disallowedTools", "WebFetch", "WebSearch", "Task"];
  if (m.sessionId) args.push("--resume", m.sessionId);
  const t0 = Date.now();
  const result = await runClaude(id, args, project);
  if (result.sessionId) m.sessionId = result.sessionId;
  const v = m.versions[n - 1];
  v.summary = result.text;
  v.claudeSec = Math.round((Date.now() - t0) / 1000);
  if (result.isError) throw new Error(`Claude : ${result.text || "échec"}`);
  if (!m.title || n === 1) m.title = firstLine(result.text) || prompt.slice(0, 60);

  // 2. Rendu
  v.status = "rendering";
  setStatus(m, "rendering");
  const out = join(dir(id), `v${n}.mp4`);
  const t1 = Date.now();
  await runLogged(id, "render", "hf-render", [project, out], project);
  v.renderSec = Math.round((Date.now() - t1) / 1000);
  v.file = basename(out);
  v.bytes = statSync(out).size;
  v.status = "done";
  setStatus(m, "done");
}

function firstLine(s = "") {
  const l = s.split("\n").map((x) => x.trim()).filter(Boolean).pop() ?? "";
  return l.replace(/[*_`#>]/g, "").slice(0, 80);
}

function runClaude(id, args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(CLAUDE_BIN, args, { cwd, env: process.env, stdio: ["ignore", "pipe", "pipe"] });
    const timer = setTimeout(() => child.kill("SIGTERM"), CLAUDE_TIMEOUT_MS);
    let buf = "", err = "", out = { sessionId: null, text: "", isError: false };
    child.stdout.on("data", (b) => {
      buf += b;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        let ev; try { ev = JSON.parse(line); } catch { continue; }
        if (ev.type === "system" && ev.session_id) out.sessionId = ev.session_id;
        else if (ev.type === "assistant") {
          for (const c of ev.message?.content ?? []) {
            if (c.type === "text" && c.text.trim()) emit(id, { kind: "claude", text: c.text.trim().slice(0, 1500) });
            if (c.type === "tool_use") emit(id, { kind: "tool", name: c.name, detail: toolDetail(c.input) });
          }
        } else if (ev.type === "result") {
          out = { sessionId: ev.session_id ?? out.sessionId, text: ev.result ?? "", isError: !!ev.is_error };
        }
      }
    });
    child.stderr.on("data", (b) => { err = (err + b).slice(-3000); });
    child.on("error", reject);
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0 && !out.isError) { out.isError = true; out.text ||= `code ${code} ${err}`.trim(); }
      resolve(out);
    });
  });
}

function toolDetail(input = {}) {
  const v = input.file_path ?? input.command ?? input.pattern ?? input.skill ?? input.path ?? "";
  return String(v).replace(/^.*\/project\//, "").slice(0, 200);
}

function runLogged(id, kind, cmd, args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd, env: process.env, stdio: ["ignore", "pipe", "pipe"] });
    let tail = "", last = 0;
    const onData = (b) => {
      tail = (tail + b).slice(-4000);
      const now = Date.now();
      const lines = String(b).split(/[\r\n]+/).map((s) => s.trim()).filter(Boolean);
      if (lines.length && now - last > 800) { last = now; emit(id, { kind, text: lines.pop().slice(0, 300) }); }
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.on("error", reject);
    child.on("close", (code) => code === 0 ? resolve(tail) : reject(new Error(`rendu en échec (code ${code}) : ${tail.slice(-800)}`)));
  });
}

// ── Création d'un job ───────────────────────────────────────────────────────
function initProject(id, m) {
  return new Promise((resolve, reject) => {
    const child = spawn("hyperframes", ["init", "project", "--non-interactive", "--example", "blank", "--resolution", m.format, "--skip-skills"],
      { cwd: dir(id), env: process.env, stdio: ["ignore", "pipe", "pipe"] });
    let log = "";
    child.stdout.on("data", (b) => (log += b));
    child.stderr.on("data", (b) => (log += b));
    child.on("close", (code) => code === 0 ? resolve() : reject(new Error(`hyperframes init : ${log.slice(-800)}`)));
  });
}

function saveUploads(id, files = []) {
  const names = [];
  const up = join(dir(id), "project", "assets", "uploads");
  for (const f of files.slice(0, 10)) {
    const name = basename(String(f.name ?? "")).replace(/[^\w.-]+/g, "_").slice(0, 80);
    if (!name || ![".png", ".jpg", ".jpeg", ".webp", ".svg", ".gif", ".mp3", ".wav", ".m4a", ".mp4"].includes(extname(name).toLowerCase())) continue;
    mkdirSync(up, { recursive: true });
    writeFileSync(join(up, name), Buffer.from(String(f.data ?? ""), "base64"));
    names.push(name);
  }
  return names;
}

async function createJob(body) {
  const prompt = String(body.prompt ?? "").trim();
  if (!prompt) throw httpErr(400, "prompt vide");
  const format = FORMATS[body.format] ? body.format : "portrait";
  const duration = Math.min(60, Math.max(3, Number(body.duration) || 10));
  const model = MODELS.includes(body.model) ? body.model : "sonnet";
  const id = `${new Date().toISOString().slice(0, 10)}-${randomBytes(3).toString("hex")}`;
  mkdirSync(dir(id), { recursive: true });
  const m = { id, title: "", createdAt: new Date().toISOString(), format, duration, model, sessionId: null, status: "queued", error: null, uploads: [], versions: [] };
  save(m);
  try {
    await initProject(id, m);
    m.uploads = saveUploads(id, body.files);
    save(m);
  } catch (e) { rmSync(dir(id), { recursive: true, force: true }); throw e; }
  emit(id, { kind: "status", status: "queued" });
  enqueue(id, prompt);
  return m;
}

function revise(id, body) {
  const m = load(id);
  const prompt = String(body.prompt ?? "").trim();
  if (!prompt) throw httpErr(400, "prompt vide");
  if (["queued", "generating", "rendering"].includes(m.status)) throw httpErr(409, "job déjà en cours");
  const added = saveUploads(id, body.files);
  m.uploads.push(...added.filter((n) => !m.uploads.includes(n)));
  setStatus(m, "queued");
  enqueue(id, added.length ? `${prompt}\n\n(Nouveaux fichiers dans assets/uploads/ : ${added.join(", ")})` : prompt);
  return m;
}

// ── HTTP ────────────────────────────────────────────────────────────────────
const httpErr = (code, msg) => Object.assign(new Error(msg), { code });
const json = (res, code, data) => { res.writeHead(code, { "content-type": "application/json; charset=utf-8" }); res.end(JSON.stringify(data)); };

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on("data", (c) => { size += c.length; if (size > MAX_UPLOAD * 1.4) { reject(httpErr(413, "trop gros (25 Mo max)")); req.destroy(); } else chunks.push(c); });
    req.on("end", () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString() || "{}")); } catch { reject(httpErr(400, "JSON invalide")); } });
  });
}

function sendVideo(req, res, file) {
  const size = statSync(file).size;
  const m = /bytes=(\d*)-(\d*)/.exec(req.headers.range ?? "");
  if (!m) { res.writeHead(200, { "content-type": "video/mp4", "content-length": size, "accept-ranges": "bytes" }); return createReadStream(file).pipe(res); }
  const start = m[1] ? Number(m[1]) : size - Number(m[2]);
  const end = m[1] && m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
  res.writeHead(206, { "content-type": "video/mp4", "content-length": end - start + 1, "content-range": `bytes ${start}-${end}/${size}`, "accept-ranges": "bytes" });
  createReadStream(file, { start, end }).pipe(res);
}

createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const p = url.pathname.split("/").filter(Boolean);
  try {
    if (req.method === "GET" && url.pathname === "/") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      return res.end(readFileSync(join(HERE, "index.html")));
    }
    if (p[0] !== "api") throw httpErr(404, "introuvable");
    if (p[1] === "health") return json(res, 200, { ok: true, busy, queued: queue.length });
    if (p[1] !== "jobs") throw httpErr(404, "introuvable");

    if (p.length === 2 && req.method === "GET") {
      const jobs = readdirSync(JOBS).filter(validId).map(load).sort((a, b) => b.createdAt.localeCompare(a.createdAt));
      return json(res, 200, jobs);
    }
    if (p.length === 2 && req.method === "POST") return json(res, 201, await createJob(await readBody(req)));

    const id = p[2];
    if (!validId(id)) throw httpErr(404, "job introuvable");
    if (p.length === 3 && req.method === "GET") return json(res, 200, load(id));
    if (p.length === 3 && req.method === "DELETE") {
      if (["queued", "generating", "rendering"].includes(load(id).status)) throw httpErr(409, "job en cours");
      rmSync(dir(id), { recursive: true, force: true });
      return json(res, 200, { ok: true });
    }
    if (p[3] === "revise" && req.method === "POST") return json(res, 200, revise(id, await readBody(req)));
    if (p[3] === "video" && req.method === "GET") {
      const file = join(dir(id), `v${Number(p[4]) || load(id).versions.filter((v) => v.file).length}.mp4`);
      if (!existsSync(file)) throw httpErr(404, "vidéo absente");
      return sendVideo(req, res, file);
    }
    if (p[3] === "events" && req.method === "GET") {
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
      const f = join(dir(id), "events.ndjson");
      if (existsSync(f)) for (const l of readFileSync(f, "utf8").split("\n").filter(Boolean)) res.write(`data: ${l}\n\n`);
      if (!listeners.has(id)) listeners.set(id, new Set());
      listeners.get(id).add(res);
      const ka = setInterval(() => res.write(": ka\n\n"), 25_000);
      req.on("close", () => { clearInterval(ka); listeners.get(id)?.delete(res); });
      return;
    }
    throw httpErr(404, "introuvable");
  } catch (e) {
    if (!res.headersSent) json(res, e.code && Number.isInteger(e.code) ? e.code : 500, { error: e.message });
  }
}).listen(PORT, () => console.log(`HyperFrames Studio sur :${PORT}, données ${DATA}`));
