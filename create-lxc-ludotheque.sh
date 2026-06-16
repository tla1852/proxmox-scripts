#!/usr/bin/env bash
#
# create-lxc-ludotheque.sh — LXC Ubuntu 24.04 + Ludothèque (Docker Compose)
#
# Généré via le skill `creation-lxc-proxmox` : socle live repris BYTE-POUR-BYTE
# depuis tla1852/proxmox-scripts/main/create-lxc.sh. Seules variations autorisées :
# DISK_GB et les défauts des questions. La couche applicative est ajoutée APRÈS
# le verrouillage de root, sous la frontière commentée en bas.
#
# - Demande : nom, coeurs, RAM
# - Réseau : DHCP sur vmbr0
# - Options : onboot=1, unprivileged=1, nesting=1, rootfs sur local-lvm
# - Post-install : apt upgrade + curl, docker, git, unzip, python3
# - Crée l'utilisateur "thibault" (sudo + docker), mot de passe demandé
# - Puis : clone ludothèque (repo privé), .env, docker compose up
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-ludotheque.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="12"            # +headroom pour le build de l'image Docker (skill : variable)
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts skill : ludotheque / 2 / 2048)
read -rp "Nom du container (hostname) [ludotheque] : " CT_NAME; CT_NAME="${CT_NAME:-ludotheque}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [2] : " CT_CORES; CT_CORES="${CT_CORES:-2}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (ex: 2048) [2048] : " CT_RAM; CT_RAM="${CT_RAM:-2048}"
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
# COUCHE APPLICATIVE — Ludothèque (le socle ci-dessus fournit Docker + nesting)
# ═════════════════════════════════════════════════════════════════════════════
APP_DIR="/opt/ludotheque"
REPO_URL="https://github.com/tla1852/ludotheque.git"
PORT="3000"

info "Configuration de l'application Ludothèque..."

# Secrets applicatifs. Repo privé → PAT GitHub (lecture). Le reste est optionnel.
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    read -rsp "GitHub PAT (repo privé, lecture) : " GITHUB_TOKEN; echo
fi
[[ -n "$GITHUB_TOKEN" ]] || err "PAT requis pour cloner le repo privé tla1852/ludotheque."

read -rsp "ADMIN_PASSWORD (mot de passe de l'app) : " APP_ADMIN_PASSWORD; echo
[[ -n "$APP_ADMIN_PASSWORD" ]] || err "ADMIN_PASSWORD requis."
read -rp  "STEAM_API_KEY (Entrée pour vide)      : " STEAM_API_KEY || true
read -rp  "IGDB_CLIENT_ID (Entrée pour vide)     : " IGDB_CLIENT_ID || true
read -rp  "IGDB_CLIENT_SECRET (Entrée pour vide) : " IGDB_CLIENT_SECRET || true
read -rp  "RAWG_API_KEY (Entrée pour vide)       : " RAWG_API_KEY || true

info "Clone du repo + génération du .env..."
pct exec "$VMID" -- bash -c "
    set -e
    rm -rf '$APP_DIR'
    git clone -q 'https://${GITHUB_TOKEN}@github.com/tla1852/ludotheque.git' '$APP_DIR'
    cd '$APP_DIR'
    cat > .env <<ENV
ADMIN_PASSWORD=${APP_ADMIN_PASSWORD}
STEAM_API_KEY=${STEAM_API_KEY:-}
IGDB_CLIENT_ID=${IGDB_CLIENT_ID:-}
IGDB_CLIENT_SECRET=${IGDB_CLIENT_SECRET:-}
RAWG_API_KEY=${RAWG_API_KEY:-}
ENV
    chmod 600 .env
    git remote set-url origin '$REPO_URL'   # retire le token du remote git
"
unset GITHUB_TOKEN APP_ADMIN_PASSWORD STEAM_API_KEY IGDB_CLIENT_ID IGDB_CLIENT_SECRET RAWG_API_KEY

info "Build + démarrage (docker compose)..."
pct exec "$VMID" -- bash -c "cd '$APP_DIR' && docker compose up -d --build"

APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo
info "═══ Ludothèque déployée ═══"
info "  URL     : http://${APP_IP}:${PORT}   (login admin)"
info "  App     : ${APP_DIR} (dans le CT ${VMID})"
info "  MAJ     : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && git pull && docker compose up -d --build'"
info "  Proxy   : ludo.survivalmode.familyds.org -> http://${APP_IP}:${PORT}"
