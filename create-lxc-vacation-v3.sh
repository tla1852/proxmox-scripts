#!/usr/bin/env bash
#
# create-lxc-vacation-v3.sh — LXC Ubuntu 24.04 + Supabase self-hosted (backend de dev vacation-v3)
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
# - Puis : Supabase self-hosted, compose officiel épinglé (tag self-hosted/vX),
#          dans /opt/vacation-v3/supabase — secrets générés par l'outil upstream
#          utils/generate-keys.sh, + Mailpit (UI protégée par basic auth) pour
#          recevoir les liens magiques en dev. Le schéma n'est PAS appliqué ici :
#          les migrations sont poussées depuis le poste de dev
#          (supabase db push --db-url ...), seul suivi de version du schéma.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-vacation-v3.sh)

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

# ----- Questions ----- (défauts skill : vacation-v3 / 2 / 6144)
read -rp "Nom du container (hostname) [vacation-v3] : " CT_NAME; CT_NAME="${CT_NAME:-vacation-v3}"
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

# ===== SOCLE INTOUCHABLE AU-DESSUS / COUCHE APPLICATIVE EN DESSOUS =====

# ═════════════════════════════════════════════════════════════════════════════
# COUCHE APPLICATIVE — Supabase self-hosted (dev) pour vacation-v3
# ═════════════════════════════════════════════════════════════════════════════
APP_DIR="/opt/vacation-v3"
SUPABASE_DIR="${APP_DIR}/supabase"       # copie du dossier docker/ officiel
SUPABASE_TAG="self-hosted/v0.8.4"        # release self-hosted épinglée (2026-11-05)
MAILPIT_IMAGE="axllent/mailpit:v1.33.1"
API_PORT="8000"                          # passerelle Envoy (API + Studio)
MAILPIT_PORT="8025"

APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')

info "Configuration Supabase (backend de dev vacation-v3)..."

# URL de l'appli web en dev (Vite sur claude-dev) : cible des liens magiques
read -rp "URL de l'appli en dev (SITE_URL) [http://192.168.1.85:5173] : " SITE_URL
SITE_URL="${SITE_URL:-http://192.168.1.85:5173}"

read -rp "Login Studio + Mailpit [supabase] : " DASH_USER; DASH_USER="${DASH_USER:-supabase}"
while true; do
    read -rsp "Mot de passe Studio + Mailpit : " DASH_PASS; echo
    read -rsp "Confirmation : " DASH_PASS2; echo
    if [[ -z "$DASH_PASS" || "$DASH_PASS" != "$DASH_PASS2" ]]; then
        echo "Mots de passe vides ou différents, on recommence."
    elif [[ "$DASH_PASS" == *[[:space:]:\$]* ]]; then
        echo "Ni espace, ni ':', ni '\$' (basic auth Mailpit + interpolation compose), on recommence."
    else
        break
    fi
done

info "Récupération du compose Supabase officiel (${SUPABASE_TAG})..."
pct exec "$VMID" -- env APP_DIR="$APP_DIR" SUPABASE_DIR="$SUPABASE_DIR" SUPABASE_TAG="$SUPABASE_TAG" bash -s <<'CLONE'
set -euo pipefail
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
git clone -q --depth 1 --branch "$SUPABASE_TAG" --filter=blob:none --sparse \
    https://github.com/supabase/supabase "$APP_DIR/supabase-src" 2>/dev/null
cd "$APP_DIR/supabase-src"
git sparse-checkout set docker >/dev/null
cp -r docker "$SUPABASE_DIR"
rm -rf "$APP_DIR/supabase-src"
CLONE

info "Génération du .env (secrets via utils/generate-keys.sh upstream)..."
pct exec "$VMID" -- env SUPABASE_DIR="$SUPABASE_DIR" APP_IP="$APP_IP" API_PORT="$API_PORT" \
    SITE_URL="$SITE_URL" DASH_USER="$DASH_USER" DASH_PASS="$DASH_PASS" \
    MAILPIT_IMAGE="$MAILPIT_IMAGE" MAILPIT_PORT="$MAILPIT_PORT" bash -s <<'ENVCONF'
set -euo pipefail
cd "$SUPABASE_DIR"
cp .env.example .env
chmod 600 .env
sh utils/generate-keys.sh --update-env >/dev/null
rm -f .env.old

set_env() {
    local k="$1" v="$2"
    v="${v//\\/\\\\}"; v="${v//|/\\|}"; v="${v//&/\\&}"
    if grep -q "^${k}=" .env; then sed -i "s|^${k}=.*|${k}=${v}|" .env; else echo "${k}=${v}" >> .env; fi
}

set_env DASHBOARD_USERNAME  "$DASH_USER"
set_env DASHBOARD_PASSWORD  "$DASH_PASS"
set_env SUPABASE_PUBLIC_URL "http://${APP_IP}:${API_PORT}"
set_env API_EXTERNAL_URL    "http://${APP_IP}:${API_PORT}/auth/v1"
set_env POOLER_TENANT_ID    "vacation-v3"
set_env STUDIO_DEFAULT_ORGANIZATION "vacation-v3"
set_env STUDIO_DEFAULT_PROJECT      "vacation-v3 (dev)"

# Auth : lien magique. Inscription ouverte (un invité crée son compte en
# ouvrant son lien), redirections limitées aux URL de dev connues.
set_env SITE_URL                 "$SITE_URL"
set_env ADDITIONAL_REDIRECT_URLS "${SITE_URL}/**,http://localhost:5173/**,http://${APP_IP}:8080/**"
set_env DISABLE_SIGNUP           "false"
set_env ENABLE_EMAIL_SIGNUP      "true"
set_env ENABLE_EMAIL_AUTOCONFIRM "false"
set_env ENABLE_PHONE_SIGNUP      "false"
set_env ENABLE_ANONYMOUS_USERS   "false"

# SMTP -> Mailpit. User/pass VIDES : GoTrue (gomail) refuse l'AUTH SMTP en
# clair ; sans user, il saute l'étape AUTH (piège vu sur Pioche).
set_env SMTP_HOST        "mailpit"
set_env SMTP_PORT        "1025"
set_env SMTP_USER        ""
set_env SMTP_PASS        ""
set_env SMTP_ADMIN_EMAIL "noreply@vacation-v3.local"
set_env SMTP_SENDER_NAME "vacation-v3 (dev)"
set_env MAILPIT_UI_AUTH  "${DASH_USER}:${DASH_PASS}"

# Override compose : Mailpit dans le même réseau que supabase-auth
cat > docker-compose.mailpit.yml <<YML
services:
  mailpit:
    container_name: supabase-mailpit
    image: ${MAILPIT_IMAGE}
    restart: unless-stopped
    ports:
      - "${MAILPIT_PORT}:8025"
    environment:
      MP_SMTP_AUTH_ACCEPT_ANY: "1"
      MP_SMTP_AUTH_ALLOW_INSECURE: "1"
      MP_UI_AUTH: "\${MAILPIT_UI_AUTH}"
      MP_MAX_MESSAGES: "500"
YML
set_env COMPOSE_FILE "docker-compose.yml:docker-compose.mailpit.yml"
ENVCONF
unset DASH_PASS DASH_PASS2

info "Pull + démarrage de la stack (long au premier run : ~12 images)..."
pct exec "$VMID" -- bash -c "cd '$SUPABASE_DIR' && docker compose pull -q"
# Premier boot : l'init de Postgres peut dépasser le healthcheck de supabase-db,
# compose abandonne alors les services dépendants. On relance, la base est déjà prête.
for i in 1 2 3; do
    pct exec "$VMID" -- bash -c "cd '$SUPABASE_DIR' && docker compose up -d" && break
    [[ $i -eq 3 ]] && err "Stack incomplète après 3 essais — vérifier : docker compose logs db"
    info "Démarrage incomplet (init Postgres lente), nouvel essai dans 20 s..."
    sleep 20
done

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

ANON_KEY=$(pct exec "$VMID" -- grep '^ANON_KEY=' "${SUPABASE_DIR}/.env" | cut -d= -f2-)

echo
info "═══ Supabase vacation-v3 (dev) déployé ═══"
info "  API + Studio : http://${APP_IP}:${API_PORT}  (basic auth ${DASH_USER})"
info "  Mailpit      : http://${APP_IP}:${MAILPIT_PORT}  (mêmes identifiants) — liens magiques"
info "  SITE_URL     : ${SITE_URL}"
info "  À mettre dans apps/web/.env.local sur le poste de dev :"
echo  "    VITE_SUPABASE_URL=http://${APP_IP}:${API_PORT}"
echo  "    VITE_SUPABASE_ANON_KEY=${ANON_KEY}"
info "  Migrations depuis le poste de dev (pooler Supavisor, mode session) :"
echo  "    supabase db push --db-url 'postgresql://postgres.vacation-v3:<POSTGRES_PASSWORD>@${APP_IP}:5432/postgres'"
info "  POSTGRES_PASSWORD, SERVICE_ROLE_KEY & co : ${SUPABASE_DIR}/.env (600 root) — sudo grep ... dans le CT ${VMID}"
info "  Logs : pct exec ${VMID} -- bash -c 'cd ${SUPABASE_DIR} && docker compose logs -f auth api-gw'"
echo
info "⚠️  Instance de DEV : HTTP clair, LAN/tailnet uniquement, jamais exposée publiquement."
unset DASH_USER SITE_URL ANON_KEY
