#!/usr/bin/env bash
#
# nmap-watch.sh — surveille l'exposition réseau et alerte L5 sur dérive.
#
# Scanne une cible (par défaut l'IP publique via le DDNS) sur un jeu de ports
# sensibles. Tout port ouvert NON présent dans la liste attendue (EXPECTED)
# déclenche une alerte CRITIQUE dans L5 (POST /webhooks/alerte). Exposition
# conforme -> l'alerte est marquée résolue (dédup par externe_id).
#
# Pensé pour tourner en cron sur un LXC de la zone management (PAS la DMZ).
# Prérequis : nmap, curl. Secret dans /opt/monitor/monitor.env (chmod 600) :
#   SUPERVISION_WEBHOOK_SECRET=...
#
# cf. tla1852/homelab-secu (phase 6, surveillance interne).

set -euo pipefail

# ----- Config (surchargeable par env / monitor.env) -----
ENV_FILE="${ENV_FILE:-/opt/monitor/monitor.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

TARGET="${TARGET:-survivalmode.familyds.org}"   # DDNS -> IP publique courante
EXPECTED="${EXPECTED:-443}"                       # ports publics légitimes (csv)
PORTS="${PORTS:-22,80,443,445,3000,3306,3389,5000,5001,5006,5049,5055,5432,5678,6690,7575,8000,8006,8080,8086,8090,8096,8123,8200,8310,8443,8989,9000,9090,32400}"
L5_URL="${L5_URL:-http://192.168.1.43:3000}"
SECRET="${SUPERVISION_WEBHOOK_SECRET:?SUPERVISION_WEBHOOK_SECRET requis (monitor.env)}"

command -v nmap >/dev/null || { echo "nmap absent (apt-get install -y nmap)"; exit 1; }

# ----- Scan -----
open=$(nmap -Pn --open -p "$PORTS" "$TARGET" 2>/dev/null \
  | awk -F/ '/\/open\//{print $1}' | sort -n | paste -sd, -)
exp=$(echo "$EXPECTED" | tr ',' '\n' | sed '/^$/d' | sort -n | paste -sd, -)

# ----- Ports ouverts non attendus -----
unexpected=""
for p in $(echo "$open" | tr ',' ' '); do
  case ",$exp," in *",$p,"*) ;; *) unexpected="${unexpected}${p}," ;; esac
done
unexpected="${unexpected%,}"

post() { # $1 severite  $2 statut  $3 message
  curl -s -m 10 -X POST "$L5_URL/webhooks/alerte" \
    -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
    -d "{\"message\":\"$3\",\"severite\":\"$1\",\"source\":\"nmap\",\"statut\":\"$2\",\"externe_id\":\"nmap:exposure:${TARGET}\",\"payload\":{\"target\":\"${TARGET}\",\"open\":\"${open}\",\"expected\":\"${exp}\"}}" \
    -o /dev/null -w "L5: %{http_code}\n"
}

if [ -n "$unexpected" ]; then
  post "critique" "ouverte" "Exposition: port(s) inattendu(s) sur ${TARGET} : ${unexpected} (ouverts: ${open:-aucun})"
  echo "ALERTE exposition: inattendus=${unexpected} (ouverts=${open})"
else
  post "info" "resolue" "Exposition conforme sur ${TARGET} (ouverts: ${open:-aucun}, attendus: ${exp})"
  echo "OK: exposition conforme (ouverts=${open:-aucun})"
fi
