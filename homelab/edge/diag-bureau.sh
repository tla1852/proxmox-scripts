#!/usr/bin/env bash
#
# diag-bureau.sh — diagnostic de l'accès bureau (cf. README, « Accès bureau ») :
# résume les dernières requêtes vues par l'edge depuis l'IP du bureau (hôte,
# chemin, statut, taille, redirection), puis les erreurs Caddy et Authelia.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash diag-bureau.sh [nb_requetes] [ip]     # défauts : 60 46.255.204.70

set -uo pipefail

N="${1:-60}"
IP="${2:-46.255.204.70}"

echo "=== Requêtes edge depuis ${IP} (${N} dernières) ==="
pct exec 144 -- tail -n 20000 /opt/caddy/logs/access.log | N="$N" IP="$IP" python3 -c '
import json, os, sys, time
rows = []
for line in sys.stdin:
    try:
        e = json.loads(line)
    except ValueError:
        continue
    r = e.get("request", {})
    if os.environ["IP"] not in (r.get("remote_ip"), r.get("client_ip")):
        continue
    h = e.get("resp_headers", {})
    rows.append("%s %-4s %3s %7s %-28s %s%s" % (
        time.strftime("%d/%m %H:%M:%S", time.localtime(e.get("ts", 0))),
        r.get("method", "?"), e.get("status", "?"), e.get("size", "?"),
        r.get("host", "?").replace(".ts.tlagrange.pro", ".ts"),
        r.get("uri", "?").split("?")[0][:60],
        ("  -> " + h["Location"][0].split("?")[0][:50]) if h.get("Location") else ""))
print("\n".join(rows[-int(os.environ["N"]):]) or "(aucune requête de cette IP dans le journal)")
'

echo
echo "=== Erreurs Caddy edge (2 h) ==="
pct exec 144 -- sh -c "docker logs --since 2h caddy-edge 2>&1 | grep '\"level\":\"error\"' | tail -8 | cut -c1-600"

echo
echo "=== Authelia (2 h, erreurs et avertissements) ==="
pct exec 102 -- sh -c "docker logs --since 2h authelia 2>&1 | grep -E 'level=(error|warning)' | tail -8 | cut -c1-400"
