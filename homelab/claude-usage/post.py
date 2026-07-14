#!/usr/bin/env python3
"""Transforme la sortie ccusage (env DAILY_JSON / BLOCK_JSON), récupère le quota
réel via /api/oauth/usage, et POST le tout sur L5.

Env (rempli par poller.sh) : L5_URL, L5_WEBHOOK_SECRET, DAYS, DAILY_JSON, BLOCK_JSON
Le token OAuth est lu localement et N'EST JAMAIS envoyé à L5 (seuls les % le sont).
"""
import json, os, time, urllib.request

L5 = os.environ["L5_URL"].rstrip("/") + "/webhooks/claude-usage"
SECRET = os.environ.get("L5_WEBHOOK_SECRET", "")
NDAYS = int(os.environ.get("DAYS", "35"))
CRED = os.environ.get("CLAUDE_CRED", os.path.expanduser("~/.claude/.credentials.json"))
# Client OAuth public de Claude Code (pas un secret).
OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"


def fresh_access_token():
    """Token d'accès valide : celui du fichier, ou refresh si expiré (<5 min).

    Le refresh réécrit .credentials.json (écriture atomique via rename) pour
    rester cohérent avec Claude Code, qui relit ce fichier à chaque session.
    Aucun token ne quitte la machine (appel direct Anthropic uniquement).
    """
    with open(CRED) as f:
        data = json.load(f)
    oauth = data.get("claudeAiOauth") or {}
    token = oauth.get("accessToken")
    expires_ms = oauth.get("expiresAt") or 0
    if token and expires_ms / 1000 - time.time() > 300:
        return token
    refresh = oauth.get("refreshToken")
    if not refresh:
        print("  quota: token expiré et pas de refreshToken, skip")
        return None
    body = json.dumps({"grant_type": "refresh_token",
                       "refresh_token": refresh,
                       "client_id": OAUTH_CLIENT_ID}).encode()
    req = urllib.request.Request(OAUTH_TOKEN_URL, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            tok = json.loads(r.read())
    except Exception as e:
        print(f"  quota: refresh token KO ({e}), skip")
        return None
    oauth["accessToken"] = tok["access_token"]
    if tok.get("refresh_token"):
        oauth["refreshToken"] = tok["refresh_token"]
    oauth["expiresAt"] = int((time.time() + tok.get("expires_in", 3600)) * 1000)
    data["claudeAiOauth"] = oauth
    tmp = CRED + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CRED)
    print("  quota: token rafraîchi")
    return oauth["accessToken"]


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
        token = fresh_access_token()
    except Exception as e:
        print(f"  quota: credentials illisibles ({e}), skip")
        return None
    if not token:
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
