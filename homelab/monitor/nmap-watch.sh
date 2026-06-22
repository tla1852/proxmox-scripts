#!/usr/bin/env bash
#
# nmap-watch.sh — découverte LAN + ndiff : alerte L5 sur nouvel hôte/port.
#
# Scanne le sous-réseau LAN, compare au baseline précédent (ndiff). Tout
# changement (nouvel hôte, nouveau port ouvert, disparition) -> alerte L5
# (POST /webhooks/alerte, source "nmap"), puis le baseline est mis à jour
# (évite la ré-alerte). Aucun changement -> alerte résolue.
#
# NB : l'exposition PUBLIQUE ne se teste pas d'ici (la Bbox ne fait pas de
# hairpin NAT) -> c'est le rôle du scanner externe GCP (phase 6, reporté).
#
# Cron sur un LXC management (PAS la DMZ). Prérequis : nmap (fournit ndiff), curl.
# Secret dans /opt/monitor/monitor.env (chmod 600) : SUPERVISION_WEBHOOK_SECRET=...
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

command -v nmap  >/dev/null || { echo "nmap absent (apt-get install -y nmap)"; exit 1; }
command -v ndiff >/dev/null || { echo "ndiff absent (paquet nmap)"; exit 1; }

baseline="$STATE_DIR/lan-baseline.xml"
current="$STATE_DIR/lan-current.xml"

post() { # $1 severite  $2 statut  $3 message
  local msg; msg=$(printf '%s' "$3" | tr -cd '[:alnum:] .,:_/()-')
  curl -s -m 10 -X POST "$L5_URL/webhooks/alerte" \
    -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
    -d "{\"message\":\"${msg}\",\"severite\":\"$1\",\"source\":\"nmap\",\"statut\":\"$2\",\"externe_id\":\"nmap:lan-diff:${SUBNET}\",\"payload\":{\"subnet\":\"${SUBNET}\"}}" \
    -o /dev/null -w "L5: %{http_code}\n"
}

# Scan (découverte d'hôtes active : seuls les hôtes up sont scannés).
nmap --open -p "$PORTS" "$SUBNET" -oX "$current" >/dev/null 2>&1

hosts=$(grep -c "<status state=\"up\"" "$current" 2>/dev/null || echo 0)

# Premier passage : on pose le baseline.
if [ ! -f "$baseline" ]; then
  cp "$current" "$baseline"
  post "info" "resolue" "Baseline LAN etablie sur ${SUBNET} (${hosts} hotes up)"
  echo "Baseline établie (${hosts} hôtes)."
  exit 0
fi

# ndiff : exit 1 si différences.
if ndiff "$baseline" "$current" >/dev/null 2>&1; then
  post "info" "resolue" "LAN conforme sur ${SUBNET} (${hosts} hotes up, aucun changement)"
  echo "OK: aucun changement."
else
  summary=$(ndiff "$baseline" "$current" 2>/dev/null | grep -E '^[+-]' | head -15 | paste -sd' ' -)
  post "warning" "ouverte" "Changement reseau LAN sur ${SUBNET} : ${summary:-voir log}"
  cp "$current" "$baseline"   # nouvelle baseline -> pas de ré-alerte en boucle
  echo "ALERTE: changement LAN -> ${summary}"
fi
