#!/usr/bin/env python3
"""Transforme la sortie ccusage (env DAILY_JSON / BLOCK_JSON) et la POST sur L5.

Lu depuis l'environnement (rempli par poller.sh) :
  L5_URL, L5_WEBHOOK_SECRET, DAYS, DAILY_JSON, BLOCK_JSON
"""
import json, os, urllib.request

url = os.environ["L5_URL"].rstrip("/") + "/webhooks/claude-usage"
secret = os.environ.get("L5_WEBHOOK_SECRET", "")
ndays = int(os.environ.get("DAYS", "35"))

daily = json.loads(os.environ.get("DAILY_JSON", "{}")).get("daily", [])
days = [{
    "jour": d.get("period"),
    "input": d.get("inputTokens", 0),
    "output": d.get("outputTokens", 0),
    "cacheCreation": d.get("cacheCreationTokens", 0),
    "cacheRead": d.get("cacheReadTokens", 0),
    "total": d.get("totalTokens", 0),
    "cost": d.get("totalCost", 0),
} for d in daily[-ndays:] if d.get("period")]

blocks = json.loads(os.environ.get("BLOCK_JSON", "{}")).get("blocks", [])
act = next((b for b in blocks if b.get("isActive")), None)
if act:
    proj = act.get("projection") or {}
    burn = act.get("burnRate") or {}
    block = {
        "active": True,
        "start": act.get("startTime"),
        "reset": act.get("endTime"),
        "total": act.get("totalTokens", 0),
        "cost": act.get("costUSD", 0),
        "projectionCost": proj.get("totalCost"),
        "costPerHour": burn.get("costPerHour"),
    }
else:
    block = {"active": False}

payload = json.dumps({"days": days, "block": block}).encode()
req = urllib.request.Request(
    url, data=payload, method="POST",
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {secret}"})
with urllib.request.urlopen(req, timeout=20) as r:
    print(f"L5 {r.status}: {r.read().decode()} ({len(days)} jours, bloc={block.get('active')})")
