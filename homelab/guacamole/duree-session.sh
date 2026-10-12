#!/usr/bin/env bash
# =====================================================================
# duree-session.sh — durée d'inactivité avant déconnexion de Guacamole
#
# À lancer DANS le LXC Guacamole, en root :
#   pct exec <VMID> -- bash /root/duree-session.sh [minutes]
#
# Défaut Guacamole : 60 minutes sans activité, puis nouveau login (mot de
# passe + TOTP). Ce script règle « api-session-timeout » (360 min = 6 h si
# rien n'est précisé). C'est un délai d'INACTIVITÉ, pas une durée absolue.
# Un redémarrage du conteneur déconnecte toujours tout le monde.
# =====================================================================
set -euo pipefail

MIN="${1:-360}"
APP_DIR="/opt/guacamole"

info() { echo -e "\e[32m[+]\e[0m $*"; }
die()  { echo -e "\e[31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "À lancer en root."
[[ "$MIN" =~ ^[0-9]+$ ]] && (( MIN >= 5 && MIN <= 1440 )) || die "Durée attendue : 5 à 1440 minutes."
cd "${APP_DIR}" 2>/dev/null && [[ -f docker-compose.yml ]] || die "${APP_DIR}/docker-compose.yml introuvable : mauvais conteneur ?"

cp docker-compose.yml docker-compose.yml.avant-session
awk -v min="${MIN}" '
    /^      API_SESSION_TIMEOUT:/ { next }
                                  { print }
    /^      WEBAPP_CONTEXT:/      { print "      API_SESSION_TIMEOUT: \"" min "\"" }
' docker-compose.yml.avant-session > docker-compose.yml

grep -q "API_SESSION_TIMEOUT: \"${MIN}\"" docker-compose.yml && docker compose config -q \
    || { cp docker-compose.yml.avant-session docker-compose.yml; die "docker-compose.yml : modification invalide, fichier restauré."; }

info "Redémarrage de Guacamole (sessions en cours coupées)"
docker compose up -d guacamole >/dev/null

for _ in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)" == "200" ]] && break
    sleep 2
done
[[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)" == "200" ]] \
    || die "Guacamole ne répond pas. Logs : docker logs guacamole"

docker exec guacamole printenv API_SESSION_TIMEOUT | grep -qx "${MIN}" \
    || die "Variable non vue par le conteneur."
info "Déconnexion après ${MIN} minutes d'inactivité."
