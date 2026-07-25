#!/usr/bin/env bash
#
# create-lxc-pioche.sh — LXC Ubuntu 24.04 + Supabase self-hosted (backend Pioche)
#
# Socle live repris BYTE-POUR-BYTE depuis
# tla1852/proxmox-scripts/main/create-lxc.sh. Seules variations autorisées :
# DISK_GB et les défauts des questions. La couche applicative est ajoutée APRÈS
# le verrouillage de root, sous la frontière commentée en bas.
#
# - Demande : nom, coeurs, RAM
# - Réseau : DHCP sur vmbr0
# - Options : onboot=1, unprivileged=1, nesting=1, rootfs sur local-lvm
# - Post-install : apt upgrade + curl, docker, git, unzip, python3
# - Crée l'utilisateur "thibault" (sudo + docker), mot de passe demandé
# - Puis : Supabase self-hosted (compose officiel supabase/docker) dans
#          /opt/pioche/supabase — JWT_SECRET + ANON_KEY/SERVICE_ROLE_KEY signés
#          localement, .env dérivé de .env.example, puis application des
#          migrations + seed du repo tla1852/vacation-v2 (schéma Pioche)
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-pioche.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="24"           # ~12 images Docker Supabase + données PostgreSQL (skill : variable)
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts skill : pioche / 2 / 6144)
read -rp "Nom du container (hostname) [pioche] : " CT_NAME; CT_NAME="${CT_NAME:-pioche}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [2] : " CT_CORES; CT_CORES="${CT_CORES:-2}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (ex: 6144) [6144] : " CT_RAM; CT_RAM="${CT_RAM:-6144}"
[[ "$CT_RAM" =~ ^[0-9]+$ && "$CT_RAM" -ge 128 ]] || err "RAM invalide (minimum 128 Mo)."

while true; do
    read -rsp "Mot de passe pour l'utilisateur ${ADMIN_USER} : " ADMIN_PASS; echo
    read -rsp "Confirmation : " ADMIN_PASS2; echo
    [[ -n "$ADMIN_PASS" && "$ADMIN_PASS" == "$ADMIN_PASS2" ]] && break
    echo "Les mots de passe sont vides ou ne correspondent pas, on recommence."
done

# ----- Template -----
info "Recherche du template ${TEMPLATE_PATTERN}..."
TEMPLATE=$(pveam list "$TEMPLATE_STORAGE" | awk -v p="$TEMPLATE_PATTERN" '$1 ~ p {print $1}' | sort -V | tail -n1)
if [[ -z "$TEMPLATE" ]]; then
    info "Template absent, téléchargement..."
    pveam update >/dev/null
    REMOTE_TEMPLATE=$(pveam available --section system | awk -v p="$TEMPLATE_PATTERN" '$2 ~ p {print $2}' | sort -V | tail -n1)
    [[ -n "$REMOTE_TEMPLATE" ]] || err "Aucun template ${TEMPLATE_PATTERN} disponible au téléchargement."
    pveam download "$TEMPLATE_STORAGE" "$REMOTE_TEMPLATE"
    TEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${REMOTE_TEMPLATE}"
fi
info "Template : $TEMPLATE"

# ----- Création -----
VMID=$(pvesh get /cluster/nextid)
info "Création du CT ${VMID} (${CT_NAME}) : ${CT_CORES} coeur(s), ${CT_RAM} Mo, ${DISK_GB} Go sur ${STORAGE}, DHCP sur ${BRIDGE}"

pct create "$VMID" "$TEMPLATE" \
    --hostname "$CT_NAME" \
    --cores "$CT_CORES" \
    --memory "$CT_RAM" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=auto" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1

info "Démarrage du container..."
pct start "$VMID"

info "Attente du réseau (DHCP)..."
for i in $(seq 1 30); do
    if pct exec "$VMID" -- ping -c1 -W2 deb.debian.org >/dev/null 2>&1 || \
       pct exec "$VMID" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        break
    fi
    [[ $i -eq 30 ]] && err "Pas de réseau dans le container après 60s."
    sleep 2
done
info "Réseau OK : $(pct exec "$VMID" -- hostname -I | awk '{print $1}')"

# ----- Mise à jour + paquets de base -----
info "Mise à jour du système..."
pct exec "$VMID" -- bash -c "export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get -y -qq upgrade
    apt-get -y -qq install curl git unzip python3 ca-certificates sudo"

info "Installation de Docker..."
pct exec "$VMID" -- bash -c "curl -fsSL https://get.docker.com | sh >/dev/null
    systemctl enable --now docker"

# ----- Utilisateur admin -----
info "Création de l'utilisateur ${ADMIN_USER}..."
pct exec "$VMID" -- bash -c "useradd -m -s /bin/bash '${ADMIN_USER}' 2>/dev/null || true
    usermod -aG sudo,docker '${ADMIN_USER}'"
echo "${ADMIN_USER}:${ADMIN_PASS}" | pct exec "$VMID" -- chpasswd
unset ADMIN_PASS ADMIN_PASS2

# Verrouillage de root (accès via pct enter + sudo)
pct exec "$VMID" -- passwd -l root >/dev/null

echo
info "Terminé ! Container ${VMID} (${CT_NAME}) prêt."
info "  IP        : $(pct exec "$VMID" -- hostname -I | awk '{print $1}')"
info "  Accès     : pct enter ${VMID}   ou   ssh ${ADMIN_USER}@<ip> (si openssh installé)"
info "  Docker    : $(pct exec "$VMID" -- docker --version)"

# ═════════════════════════════════════════════════════════════════════════════
# COUCHE APPLICATIVE — Supabase self-hosted pour Pioche (vacation-v2)
# ═════════════════════════════════════════════════════════════════════════════
APP_DIR="/opt/pioche"
SUPABASE_DIR="${APP_DIR}/supabase"          # copie du dossier docker/ officiel
PIOCHE_REPO="https://github.com/tla1852/vacation-v2.git"
KONG_PORT="8000"

APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')

info "Configuration Supabase (backend Pioche)..."

# Studio (console d'admin, servie par Kong avec basic auth)
read -rp  "Login Studio (DASHBOARD_USERNAME) [supabase] : " DASHBOARD_USERNAME
DASHBOARD_USERNAME="${DASHBOARD_USERNAME:-supabase}"
while true; do
    read -rsp "Mot de passe Studio (DASHBOARD_PASSWORD) : " DASHBOARD_PASSWORD; echo
    read -rsp "Confirmation : " DASHBOARD_PASSWORD2; echo
    [[ -n "$DASHBOARD_PASSWORD" && "$DASHBOARD_PASSWORD" == "$DASHBOARD_PASSWORD2" ]] && break
    echo "Mots de passe vides ou différents, on recommence."
done

# SMTP : indispensable au magic link (seule méthode d'auth de Pioche).
# Vide = on laisse les valeurs d'exemple, à configurer plus tard dans le .env.
read -rp  "SMTP host (Entrée pour configurer plus tard) : " SMTP_HOST || true
SMTP_PORT=""; SMTP_USER=""; SMTP_PASS=""; SMTP_SENDER=""
if [[ -n "$SMTP_HOST" ]]; then
    read -rp  "SMTP port [587]                  : " SMTP_PORT; SMTP_PORT="${SMTP_PORT:-587}"
    read -rp  "SMTP user                        : " SMTP_USER
    read -rsp "SMTP password                    : " SMTP_PASS; echo
    read -rp  "Email expéditeur (SMTP_ADMIN_EMAIL) : " SMTP_SENDER
fi

# ----- Secrets générés côté hôte Proxmox -----
POSTGRES_PASSWORD="$(openssl rand -hex 24)"
JWT_SECRET="$(openssl rand -hex 32)"
SECRET_KEY_BASE="$(openssl rand -hex 32)"
VAULT_ENC_KEY="$(openssl rand -hex 16)"     # exactement 32 caractères

# JWTs HS256 signés localement (rôles anon / service_role), exp ~20 ans
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
sign_jwt() {
    local role="$1" now exp header payload data sig
    now=$(date +%s); exp=$(( now + 20 * 365 * 24 * 3600 ))
    header='{"alg":"HS256","typ":"JWT"}'
    payload=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$now" "$exp")
    data="$(printf %s "$header" | b64url).$(printf %s "$payload" | b64url)"
    sig=$(printf %s "$data" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)
    printf '%s.%s' "$data" "$sig"
}
ANON_KEY="$(sign_jwt anon)"
SERVICE_ROLE_KEY="$(sign_jwt service_role)"

# ----- Clone du compose officiel (sparse : uniquement docker/) -----
info "Récupération du compose Supabase officiel..."
pct exec "$VMID" -- bash -c "
    set -e
    rm -rf '$APP_DIR'
    mkdir -p '$APP_DIR'
    git clone -q --depth 1 --filter=blob:none --sparse https://github.com/supabase/supabase '$APP_DIR/supabase-src'
    cd '$APP_DIR/supabase-src'
    git sparse-checkout set docker >/dev/null
    cp -r docker '$SUPABASE_DIR'
    rm -rf '$APP_DIR/supabase-src'
"

# ----- .env dérivé de .env.example -----
info "Génération du .env (secrets injectés)..."
pct exec "$VMID" -- bash -c "
    set -e
    cd '$SUPABASE_DIR'
    cp .env.example .env
    set_env() { grep -q \"^\$1=\" .env && sed -i \"s|^\$1=.*|\$1=\$2|\" .env || echo \"\$1=\$2\" >> .env; }
    set_env POSTGRES_PASSWORD   '$POSTGRES_PASSWORD'
    set_env JWT_SECRET          '$JWT_SECRET'
    set_env ANON_KEY            '$ANON_KEY'
    set_env SERVICE_ROLE_KEY    '$SERVICE_ROLE_KEY'
    set_env DASHBOARD_USERNAME  '$DASHBOARD_USERNAME'
    set_env DASHBOARD_PASSWORD  '$DASHBOARD_PASSWORD'
    set_env SECRET_KEY_BASE     '$SECRET_KEY_BASE'
    set_env VAULT_ENC_KEY       '$VAULT_ENC_KEY'
    set_env SITE_URL            'pioche://'
    set_env ADDITIONAL_REDIRECT_URLS 'pioche://*,exp://*,http://localhost:8081/*'
    set_env API_EXTERNAL_URL    'http://${APP_IP}:${KONG_PORT}'
    set_env SUPABASE_PUBLIC_URL 'http://${APP_IP}:${KONG_PORT}'
    set_env STUDIO_DEFAULT_ORGANIZATION 'Pioche'
    set_env STUDIO_DEFAULT_PROJECT 'Pioche'
    if [[ -n '$SMTP_HOST' ]]; then
        set_env SMTP_HOST        '$SMTP_HOST'
        set_env SMTP_PORT        '$SMTP_PORT'
        set_env SMTP_USER        '$SMTP_USER'
        set_env SMTP_PASS        '$SMTP_PASS'
        set_env SMTP_ADMIN_EMAIL '$SMTP_SENDER'
        set_env SMTP_SENDER_NAME 'Pioche'
    fi
    chmod 600 .env
"
unset POSTGRES_PASSWORD JWT_SECRET SECRET_KEY_BASE VAULT_ENC_KEY \
      DASHBOARD_PASSWORD DASHBOARD_PASSWORD2 SMTP_PASS

info "Pull + démarrage de la stack Supabase (long au premier run : ~12 images)..."
pct exec "$VMID" -- bash -c "cd '$SUPABASE_DIR' && docker compose pull -q && docker compose up -d"

# ----- Attente : Postgres prêt ET schéma auth créé par GoTrue -----
# (les migrations Pioche référencent auth.users : GoTrue doit avoir booté)
info "Attente de PostgreSQL + du schéma auth (GoTrue)..."
for i in $(seq 1 60); do
    if pct exec "$VMID" -- docker exec supabase-db psql -U postgres -d postgres -tAc \
        "select 1 from pg_tables where schemaname='auth' and tablename='users'" 2>/dev/null | grep -q 1; then
        break
    fi
    [[ $i -eq 60 ]] && err "Schéma auth absent après 5 min — vérifier : docker compose logs auth"
    sleep 5
done
info "Schéma auth OK."

# ----- Migrations + seed Pioche (repo vacation-v2, public) -----
info "Application des migrations + seed Pioche..."
pct exec "$VMID" -- bash -c "
    set -e
    rm -rf '$APP_DIR/app'
    git clone -q --depth 1 '$PIOCHE_REPO' '$APP_DIR/app'
    for f in '$APP_DIR'/app/supabase/migrations/*.sql; do
        echo \"  -> \$(basename \"\$f\")\"
        docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < \"\$f\" >/dev/null
    done
    if [[ -f '$APP_DIR/app/supabase/seed.sql' ]]; then
        echo '  -> seed.sql (deck officiel Vir&Pioche)'
        docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < '$APP_DIR/app/supabase/seed.sql' >/dev/null
    fi
"

echo
info "═══ Supabase (Pioche) déployé ═══"
info "  API (Kong)  : http://${APP_IP}:${KONG_PORT}"
info "  Studio      : http://${APP_IP}:${KONG_PORT} (basic auth ${DASHBOARD_USERNAME}, mdp choisi)"
info "  ANON_KEY (app Expo, EXPO_PUBLIC_SUPABASE_ANON_KEY) :"
echo  "    ${ANON_KEY}"
info "  SERVICE_ROLE_KEY + tous les secrets : ${SUPABASE_DIR}/.env (600) dans le CT ${VMID}"
info "  Postgres direct (pooler Supavisor)  : psql -h ${APP_IP} -p 5432 -U postgres.your-tenant-id"
info "  MAJ migrations : pct exec ${VMID} -- bash -c 'cd ${APP_DIR}/app && git pull && docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < supabase/migrations/<nouvelle>.sql'"
info "  Logs           : pct exec ${VMID} -- bash -c 'cd ${SUPABASE_DIR} && docker compose logs -f auth kong'"
echo
[[ -z "$SMTP_HOST" ]] && info "⚠️  SMTP non configuré : le magic link (seule méthode d'auth) ne partira pas. Renseigner SMTP_* dans ${SUPABASE_DIR}/.env puis 'docker compose up -d auth'."
info "⚠️  Réseau interne / tailnet uniquement — jamais public-facing en l'état (HTTP clair)."
info "⚠️  Dès la bêta : sauvegardes Postgres externalisées hors homelab (règle du cadrage)."
unset DASHBOARD_USERNAME SMTP_HOST SMTP_PORT SMTP_USER SMTP_SENDER ANON_KEY SERVICE_ROLE_KEY
