#!/usr/bin/env bash
# =====================================================================
# bypass-totp-lan.sh — pas de code TOTP à la maison ni sur le tailnet
#
# À lancer DANS le LXC Guacamole, en root :
#   pct exec <VMID> -- bash /root/bypass-totp-lan.sh
#
# Depuis le Shell web de Proxmox, JAMAIS depuis une session Guacamole : le
# redémarrage coupe la session et tue le script en plein remplacement du
# conteneur (ancien arrêté, nouveau bloqué en « Created »).
#
# Le mot de passe reste demandé partout ; seul le code TOTP saute pour :
#   - le LAN 192.168.1.0/24, SAUF l'edge (.68, accès bureau) et le Caddy
#     interne (.72) ;
#   - le tailnet 100.64.0.0/10.
# Exclure .72 rend la règle sûre en cas de panne : si Guacamole ne lit plus
# X-Forwarded-For, tout le trafic proxifié apparaît venir de .72 → TOTP.
#
# Pour voir la vraie IP client derrière le Caddy interne, active la valve
# RemoteIp de Tomcat en ne faisant confiance qu'au Caddy interne (.72).
# Le Caddy interne n'a pas de trusted_proxies : l'X-Forwarded-For posé par
# l'edge est écrasé, une requête du bureau arrive donc bien en .68.
# =====================================================================
set -euo pipefail

APP_DIR="/opt/guacamole"
CADDY_INTERNE_REGEX='192\.168\.1\.72'
# 192.168.1.0/24 moins .68 (edge) et .72 (Caddy interne), plus le tailnet
BYPASS="192.168.1.0/26, 192.168.1.64/30, 192.168.1.69/32, 192.168.1.70/31, 192.168.1.73/32, 192.168.1.74/31, 192.168.1.76/30, 192.168.1.80/28, 192.168.1.96/27, 192.168.1.128/25, 100.64.0.0/10"

info() { echo -e "\e[32m[+]\e[0m $*"; }
die()  { echo -e "\e[31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "À lancer en root."
cd "${APP_DIR}" 2>/dev/null && [[ -f docker-compose.yml ]] || die "${APP_DIR}/docker-compose.yml introuvable : mauvais conteneur ?"
grep -q '^      TOTP_ENABLED: "true"' docker-compose.yml || die "TOTP non activé dans docker-compose.yml : rien à contourner."

# La sauvegarde garde l'état d'avant le PREMIER passage : un second lancement
# ne doit pas l'écraser avec un compose déjà modifié.
[[ -f docker-compose.yml.avant-bypass-totp ]] || cp docker-compose.yml docker-compose.yml.avant-bypass-totp
cp docker-compose.yml docker-compose.yml.tmp-bypass-totp
BYPASS="${BYPASS}" REGEX="${CADDY_INTERNE_REGEX}" awk '
    /^      (TOTP_BYPASS_HOSTS|REMOTE_IP_VALVE_ENABLED|PROXY_ALLOWED_IPS_REGEX):/ { next }
                                  { print }
    /^      TOTP_ISSUER:/         {
        print "      TOTP_BYPASS_HOSTS: \"" ENVIRON["BYPASS"] "\""
        print "      REMOTE_IP_VALVE_ENABLED: \"true\""
        print "      PROXY_ALLOWED_IPS_REGEX: '\''" ENVIRON["REGEX"] "'\''"
    }
' docker-compose.yml.tmp-bypass-totp > docker-compose.yml

grep -q '^      TOTP_BYPASS_HOSTS:' docker-compose.yml && docker compose config -q \
    || { cp docker-compose.yml.tmp-bypass-totp docker-compose.yml; die "docker-compose.yml : modification invalide, fichier restauré."; }
rm -f docker-compose.yml.tmp-bypass-totp

info "Redémarrage de Guacamole (sessions en cours coupées)"
# Ignorer SIGHUP : une coupure du terminal ne doit pas laisser compose à mi-chemin.
nohup docker compose up -d guacamole >/dev/null 2>&1 </dev/null

for _ in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)" == "200" ]] && break
    sleep 2
done
[[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)" == "200" ]] \
    || die "Guacamole ne répond pas. Logs : docker logs guacamole"

docker exec guacamole printenv TOTP_BYPASS_HOSTS | grep -qF "100.64.0.0/10" \
    || die "Variable non vue par le conteneur."
docker exec guacamole sh -c 'grep -rl RemoteIpValve / --include=server.xml 2>/dev/null' | grep -q . \
    || die "Valve RemoteIp absente de server.xml : l'image n'a pas pris REMOTE_IP_VALVE_ENABLED. Retour arrière : cp docker-compose.yml.avant-bypass-totp docker-compose.yml && docker compose up -d guacamole"

info "TOTP sauté sur le LAN (hors edge .68 / Caddy .72) et le tailnet."
info "À vérifier : login depuis la maison → pas de code ; depuis le bureau → code demandé."
