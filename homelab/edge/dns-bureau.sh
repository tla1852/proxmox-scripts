#!/usr/bin/env bash
#
# dns-bureau.sh — enregistrements DNS publics (Gandi LiveDNS) pour l'accès
# bureau aux services privés : <svc>.ts.tlagrange.pro CNAME -> DDNS maison.
#
# Sans effet sur les clients tailnet : MagicDNS (extra_records Headscale) répond
# 100.64.0.2 avant le DNS public. Enregistrements explicites plutôt qu'un
# wildcard *.ts : n'interfère pas avec les _acme-challenge du Caddy interne.
#
# Usage :
#   GANDI_API_TOKEN=<PAT LiveDNS> bash dns-bureau.sh           # crée / met à jour
#   GANDI_API_TOKEN=<PAT LiveDNS> bash dns-bureau.sh --delete  # retire tout

set -euo pipefail

ZONE="tlagrange.pro"
TARGET="survivalmode.familyds.org."
TTL=300
NAMES=(auth vault recette ludo homarr read n8n qbit radar pdf sonar wallos
       proxmox dsm telescope chat grafana veille clashbuzz-studio hammer)

: "${GANDI_API_TOKEN:?GANDI_API_TOKEN manquant}"
API="https://api.gandi.net/v5/livedns/domains/${ZONE}/records"

for n in "${NAMES[@]}"; do
    if [[ "${1:-}" == "--delete" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
            -H "Authorization: Bearer ${GANDI_API_TOKEN}" "${API}/${n}.ts/CNAME")
    else
        code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
            -H "Authorization: Bearer ${GANDI_API_TOKEN}" -H 'Content-Type: application/json' \
            -d "{\"rrset_values\":[\"${TARGET}\"],\"rrset_ttl\":${TTL}}" "${API}/${n}.ts/CNAME")
    fi
    echo "${n}.ts.${ZONE} -> ${code}"
done
