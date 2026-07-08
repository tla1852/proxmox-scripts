#!/usr/bin/env bash
#
# create-lxc-appflowy.sh — LXC Ubuntu 24.04 + AppFlowy-Cloud (Docker Compose)
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
# - Puis : clone AppFlowy-Cloud (repo public), .env (secrets auto-générés),
#          docker compose up (nginx, postgres pgvector, redis, minio, gotrue,
#          appflowy_cloud, appflowy_worker, admin_frontend, appflowy_web ;
#          service "ai" exclu — nécessite une clé OpenAI et bouffe la RAM)
#
# Exposition prévue : UNIQUEMENT via le tailnet, derrière le Caddy interne
# (LXC 100) en appflowy.ts.tlagrange.pro → <IP LXC>:80 (nginx du compose).
# Voir homelab/internal/{Caddyfile,extra-records.yaml}.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-appflowy.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="24"           # stack ~1 Go d'images + PostgreSQL + MinIO (uploads/import Notion)
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts : appflowy / 2 / 6144)
read -rp "Nom du container (hostname) [appflowy] : " CT_NAME; CT_NAME="${CT_NAME:-appflowy}"
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
# COUCHE APPLICATIVE — AppFlowy-Cloud (le socle ci-dessus fournit Docker + nesting)
# ═════════════════════════════════════════════════════════════════════════════
APP_DIR="/opt/appflowy-cloud"
REPO_URL="https://github.com/AppFlowy-IO/AppFlowy-Cloud.git"
FQDN="appflowy.ts.tlagrange.pro"

info "Configuration d'AppFlowy-Cloud (${FQDN})..."

# Compte admin GoTrue (console /console + création des comptes utilisateurs).
read -rp  "Email admin GoTrue [thibault@tlagrange.pro]                    : " GOTRUE_ADMIN_EMAIL
GOTRUE_ADMIN_EMAIL="${GOTRUE_ADMIN_EMAIL:-thibault@tlagrange.pro}"
while true; do
    read -rsp "Mot de passe admin GoTrue                                    : " GOTRUE_ADMIN_PASSWORD; echo
    read -rsp "Confirmation                                                 : " GOTRUE_ADMIN_PASSWORD2; echo
    if [[ "$GOTRUE_ADMIN_PASSWORD" =~ [\'\"\\\|\&\$\`] ]]; then
        echo "Caractères interdits dans ce script : ' \" \\ | & \$ \` — on recommence."
        continue
    fi
    [[ -n "$GOTRUE_ADMIN_PASSWORD" && "$GOTRUE_ADMIN_PASSWORD" == "$GOTRUE_ADMIN_PASSWORD2" ]] && break
    echo "Mots de passe vides ou différents, on recommence."
done

# Secrets générés côté hôte Proxmox (openssl présent par défaut sur Debian).
POSTGRES_PASSWORD="$(openssl rand -hex 24)"
GOTRUE_JWT_SECRET="$(openssl rand -hex 32)"
S3_ACCESS_KEY="appflowy-$(openssl rand -hex 6)"
S3_SECRET_KEY="$(openssl rand -hex 24)"

info "Clone du repo + génération du .env (base deploy.env, secrets auto-générés)..."
pct exec "$VMID" -- bash -c "
    set -e
    rm -rf '$APP_DIR'
    git clone -q --depth 1 '$REPO_URL' '$APP_DIR'
    cd '$APP_DIR'
    cp deploy.env .env

    # set_env KEY VALUE : remplace la ligne si la clé existe, sinon l'ajoute.
    set_env() {
        if grep -q \"^\${1}=\" .env; then
            sed -i \"s|^\${1}=.*|\${1}=\${2}|\" .env
        else
            echo \"\${1}=\${2}\" >> .env
        fi
    }

    # URL publique vue par les clients (TLS terminé par le Caddy interne du
    # tailnet ; le lien Caddy -> nginx du compose reste en HTTP clair sur :80).
    set_env FQDN '$FQDN'
    set_env SCHEME https
    set_env WS_SCHEME wss
    set_env NGINX_PORT 80

    # Secrets (les défauts deploy.env sont publics : password / hello456 / minioadmin).
    set_env POSTGRES_PASSWORD '$POSTGRES_PASSWORD'
    set_env GOTRUE_JWT_SECRET '$GOTRUE_JWT_SECRET'
    set_env APPFLOWY_GOTRUE_JWT_SECRET '$GOTRUE_JWT_SECRET'
    set_env APPFLOWY_S3_ACCESS_KEY '$S3_ACCESS_KEY'
    set_env APPFLOWY_S3_SECRET_KEY '$S3_SECRET_KEY'

    # Auth sans SMTP : signup auto-confirmé, mais inscription publique fermée —
    # les comptes se créent via la console admin (/console).
    set_env GOTRUE_MAILER_AUTOCONFIRM true
    set_env GOTRUE_DISABLE_SIGNUP true
    set_env GOTRUE_ADMIN_EMAIL '$GOTRUE_ADMIN_EMAIL'
    set_env GOTRUE_ADMIN_PASSWORD '$GOTRUE_ADMIN_PASSWORD'

    chmod 600 .env
"
unset GOTRUE_ADMIN_PASSWORD GOTRUE_ADMIN_PASSWORD2 POSTGRES_PASSWORD \
      GOTRUE_JWT_SECRET S3_ACCESS_KEY S3_SECRET_KEY

info "Pull + démarrage (docker compose, service 'ai' exclu)..."
pct exec "$VMID" -- bash -c "
    set -e
    cd '$APP_DIR'
    SERVICES=\$(docker compose config --services | grep -vE '^(ai)\$')
    docker compose up -d \$SERVICES
"

APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo
info "═══ AppFlowy-Cloud déployé ═══"
info "  nginx     : http://${APP_IP}:80 (à référencer dans le Caddyfile interne)"
info "  Console   : https://${FQDN}/console (admin GoTrue — créer les comptes ici)"
info "  Web       : https://${FQDN}/ (client web)   API : /api   WS : /ws   MinIO : /minio-api"
info "  App       : ${APP_DIR} (dans le CT ${VMID}) — .env en 600, secrets auto-générés"
info "  MAJ       : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && git pull && docker compose pull && docker compose up -d'"
info "  Logs      : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && docker compose logs -f appflowy_cloud'"
echo
info "Étapes suivantes (plan privé) :"
info "  1. homelab/internal/Caddyfile : vhost ${FQDN} -> ${APP_IP}:80 (+ request_body 2GB pour l'import Notion), recharger le Caddy interne (LXC 100)"
info "  2. homelab/internal/extra-records.yaml : ${FQDN} -> 100.64.0.2, reporter dans Headscale (LXC 145) puis docker restart headscale"
info "  3. Clients desktop/mobile : Settings -> Cloud -> AppFlowy Cloud Self-hosted, Base URL https://${FQDN}"
info "⚠️  JAMAIS d'exposition publique : accès uniquement via le tailnet."
