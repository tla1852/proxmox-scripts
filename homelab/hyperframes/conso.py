#!/usr/bin/env python3
"""conso.py — consommation Claude du Studio HyperFrames, par vidéo et par version.

Lit les sessions Claude Code du compte studio (~studio/.claude/projects/**/*.jsonl)
et rattache chaque message à la version dont la fenêtre de génération le contient
(meta.json des jobs : createdAt + claudeSec). Tokens dédupliqués par message.id.

    pct exec 127 -- python3 - < <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/hyperframes/conso.py)
"""
import glob
import json
import os
from datetime import datetime, timedelta

HOME = "/srv/studio"


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


# Fenêtres de génération de chaque version
windows = []
for meta in glob.glob(f"{HOME}/jobs/*/meta.json"):
    m = json.load(open(meta))
    for v in m.get("versions", []):
        if v.get("claudeSec") is None:
            continue
        start = ts(v["createdAt"]) - timedelta(seconds=5)
        windows.append({
            "job": m["id"], "title": (m.get("title") or v["prompt"])[:46], "model": m["model"],
            "n": v["n"], "prompt": v["prompt"][:46], "start": start,
            "end": ts(v["createdAt"]) + timedelta(seconds=v["claudeSec"] + 30),
            "msgs": {}, "dur": v["claudeSec"] + (v.get("renderSec") or 0),
        })

orphans = {}
for f in glob.glob(f"{HOME}/.claude/projects/**/*.jsonl", recursive=True):
    for line in open(f, errors="replace"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        msg = e.get("message") or {}
        u = msg.get("usage")
        if e.get("type") != "assistant" or not u or not e.get("timestamp"):
            continue
        t = ts(e["timestamp"])
        rec = (msg.get("model", "?"), u.get("input_tokens", 0), u.get("output_tokens", 0),
               u.get("cache_creation_input_tokens", 0), u.get("cache_read_input_tokens", 0))
        key = msg.get("id") or f"{f}:{e.get('uuid')}"
        w = next((w for w in windows if w["start"] <= t <= w["end"]), None)
        (w["msgs"] if w else orphans)[key] = rec


def sums(msgs):
    s = [0, 0, 0, 0]
    models = set()
    for model, *vals in msgs.values():
        models.add(model)
        for i, x in enumerate(vals):
            s[i] += x
    return s, models, len(msgs)


def k(x):
    return f"{x / 1000:,.0f}k".replace(",", " ")


print(f"{'vidéo':46} {'v':>2} {'modèle':6} {'durée':>6} {'appels':>6} {'entrée':>8} {'sortie':>8} {'cache+':>8} {'cache lu':>9}")
tot = {}
for w in sorted(windows, key=lambda w: w["start"]):
    s, models, n = sums(w["msgs"])
    label = w["title"] if w["n"] == 1 else "  ↳ " + w["prompt"][:42]
    print(f"{label:46} {w['n']:>2} {w['model']:6} {w['dur'] // 60:>3}m{w['dur'] % 60:02d} {n:>6} {k(s[0]):>8} {k(s[1]):>8} {k(s[2]):>8} {k(s[3]):>9}")
    t = tot.setdefault(w["model"], [0, 0, 0, 0, 0])
    for i in range(4):
        t[i] += s[i]
    t[4] += n

print()
for model, t in tot.items():
    print(f"TOTAL {model:7} appels={t[4]}  entrée={k(t[0])}  sortie={k(t[1])}  cache écrit={k(t[2])}  cache lu={k(t[3])}")
if orphans:
    s, models, n = sums(orphans)
    print(f"hors vidéo (tests, installation des skills…) : {n} appels, sortie={k(s[1])}, cache lu={k(s[3])}, modèles={sorted(models)}")
