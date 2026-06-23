#!/usr/bin/env python3
"""Transforme la sortie ccusage (env DAILY_JSON / BLOCK_JSON), récupère le quota
réel via /api/oauth/usage, et POST le tout sur L5.

Env (rempli par poller.sh) : L5_URL, L5_WEBHOOK_SECRET, DAYS, DAILY_JSON, BLOCK_JSON
Le token OAuth est lu localement et N'EST JAMAIS envoyé à L5 (seuls les % le sont).
"""
import json, os, urllib.request

L5 = os.environ["L5_URL"].rstrip("/") + "/webhooks/claude-usage"
SECRET = os.environ.get("L5_WEBHOOK_SECRET", "")
NDAYS = int(os.environ.get("DAYS", "35"))
CRED = os.environ.get("CLAUDE_CRED", os.path.expanduser("~/.claude/.credentials.json"))


def daily_payload():
    daily = json.loads(os.environ.get("DAILY_JSON", "{}")).get("daily", [])
    return [{
        "jour": d.get("period"),
        "input": d.get("inputTokens", 0),
        "output": d.get("outputTokens", 0),
        "cacheCreation": d.get("cacheCreationTokens", 0),
        "cacheRead": d.get("cacheReadTokens", 0),
        "total": d.get("totalTokens", 0),
        "cost": d.get("totalCost", 0),
    } for d in daily[-NDAYS:] if d.get("period")]


def block_payload():
    blocks = json.loads(os.environ.get("BLOCK_JSON", "{}")).get("blocks", [])
    act = next((b for b in blocks if b.get("isActive")), None)
    if not act:
        return {"active": False}
    proj = act.get("projection") or {}
    burn = act.get("burnRate") or {}
    return {
        "active": True, "start": act.get("startTime"), "reset": act.get("endTime"),
        "total": act.get("totalTokens", 0), "cost": act.get("costUSD", 0),
        "projectionCost": proj.get("totalCost"), "costPerHour": burn.get("costPerHour"),
    }


def quota_payload():
    """Quota réel du plan (identique à l'app Claude) via le token OAuth local."""
    try:
        token = json.load(open(CRED))["claudeAiOauth"]["accessToken"]
    except Exception:
        return None
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={"Authorization": f"Bearer {token}",
                 "anthropic-beta": "oauth-2025-04-20",
                 "anthropic-version": "2023-06-01",
                 "User-Agent": "claude-cli"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            u = json.loads(r.read())
    except Exception as e:
        print(f"  quota indisponible: {e}")
        return None

    def g(key):
        o = u.get(key) or {}
        return o.get("utilization"), o.get("resets_at")

    fh, fhr = g("five_hour")
    sd, sdr = g("seven_day")
    op, opr = g("seven_day_opus")
    so, sor = g("seven_day_sonnet")
    return {
        "fiveHourPct": fh, "fiveHourReset": fhr,
        "sevenDayPct": sd, "sevenDayReset": sdr,
        "sevenDayOpusPct": op, "sevenDayOpusReset": opr,
        "sevenDaySonnetPct": so, "sevenDaySonnetReset": sor,
    }


days = daily_payload()
block = block_payload()
quota = quota_payload()

payload = json.dumps({"days": days, "block": block, "quota": quota}).encode()
req = urllib.request.Request(
    L5, data=payload, method="POST",
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {SECRET}"})
with urllib.request.urlopen(req, timeout=20) as r:
    qn = "—" if not quota else f"{quota.get('fiveHourPct')}%/5h"
    print(f"L5 {r.status}: {r.read().decode()} ({len(days)} jours, bloc={block.get('active')}, quota={qn})")
