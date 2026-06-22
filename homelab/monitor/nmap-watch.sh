#!/usr/bin/env bash
#
# nmap-watch.sh — découverte LAN : alerte L5 sur nouvel hôte/port (sans ndiff).
#
# Scanne le sous-réseau LAN, extrait la liste "ip port" des ports ouverts,
# compare au baseline précédent (comm). Tout ajout/suppression -> alerte L5
# (POST /webhooks/alerte, source "nmap"), puis baseline mis à jour. Aucun
# changement -> alerte résolue.
#
# NB : l'exposition PUBLIQUE ne se teste pas d'ici (Bbox sans hairpin NAT)
# -> rôle du scanner externe GCP (phase 6, reporté).
#
# Cron sur LXC management (PAS la DMZ). Prérequis : nmap, curl.
# Secret : /opt/monitor/monitor.env (chmod 600) -> SUPERVISION_WEBHOOK_SECRET=...
#
# cf. tla1852/homelab-secu (phase 6, surveillance interne).

set -euo pipefail

ENV_FILE="${ENV_FILE:-/opt/monitor/monitor.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

SUBNET="${SUBNET:-192.168.1.0/24}"
PORTS="${PORTS:-22,53,80,443,445,3000,3306,3389,5000,5001,5006,5049,5055,5432,5678,6690,7575,8000,8006,8080,8086,8090,8096,8123,8200,8310,8443,8989,9000,9090,32400}"
L5_URL="${L5_URL:-http://192.168.1.43:3000}"
STATE_DIR="${STATE_DIR:-/opt/monitor}"
SECRET="${SUPERVISION_WEBHOOK_SECRET:?SUPERVISION_WEBHOOK_SECRET requis (monitor.env)}"

command -v nmap >/dev/null || { echo "nmap absent (apt-get install -y nmap)"; exit 1; }

baseline="$STATE_DIR/lan-baseline.txt"
current="$STATE_DIR/lan-current.txt"

post() { # $1 severite  $2 statut  $3 message
  local msg; msg=$(printf '%s' "$3" | tr -cd '[:alnum:] .,:_/()-')
  curl -s -m 10 -X POST "$L5_URL/webhooks/alerte" \
    -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
    -d "{\"message\":\"${msg}\",\"severite\":\"$1\",\"source\":\"nmap\",\"statut\":\"$2\",\"externe_id\":\"nmap:lan-diff:${SUBNET}\",\"payload\":{\"subnet\":\"${SUBNET}\"}}" \
    -o /dev/null -w "L5: %{http_code}\n"
}

# Scan -> lignes "ip port" (ports ouverts), triées/dédupliquées.
nmap --open -p "$PORTS" "$SUBNET" -oG - 2>/dev/null \
  | grep "Ports:" \
  | while read -r line; do
      ip=$(printf '%s' "$line" | awk '{print $2}')
      printf '%s' "$line" | grep -oE '[0-9]+/open' | sed 's#/open##' \
        | while read -r p; do echo "$ip $p"; done
    done | sort -u > "$current"

nb=$(wc -l < "$current" | tr -d ' ')

# Premier passage : baseline.
if [ ! -f "$baseline" ]; then
  cp "$current" "$baseline"
  post "info" "resolue" "Baseline LAN etablie sur ${SUBNET} (${nb} services ouverts)"
  echo "Baseline établie (${nb} services)."
  exit 0
fi

added=$(comm -13 "$baseline" "$current" | paste -sd' ' -)
removed=$(comm -23 "$baseline" "$current" | paste -sd' ' -)

if [ -z "$added" ] && [ -z "$removed" ]; then
  post "info" "resolue" "LAN conforme sur ${SUBNET} (${nb} services, aucun changement)"
  echo "OK: aucun changement (${nb} services)."
else
  msg="Changement reseau LAN sur ${SUBNET}."
  [ -n "$added" ]   && msg="${msg} Nouveaux: ${added}."
  [ -n "$removed" ] && msg="${msg} Disparus: ${removed}."
  post "warning" "ouverte" "$msg"
  cp "$current" "$baseline"   # nouvelle baseline -> pas de ré-alerte en boucle
  echo "ALERTE: ${msg}"
fi
