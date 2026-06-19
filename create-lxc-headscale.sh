#!/usr/bin/env bash
#
# create-lxc-headscale.sh — LXC Ubuntu 24.04 + Headscale (plan de contrôle Tailscale self-hosted)
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
# - Puis : déploie Headscale (Docker), config patchée depuis l'exemple de la
#          version épinglée, crée l'utilisateur tailnet + une pré-auth key,
#          imprime le runbook d'enrôlement des appareils.
#
# Plan privé du homelab (cf. tla1852/homelab-secu, phase 2). Le plan de contrôle
# écoute sur :8080 ; il sera exposé en HTTPS public via l'edge Caddy (phase 1),
# qui reverse-proxie ${HS_DOMAIN} -> <IP de ce LXC>:8080. À construire AVANT l'edge.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-headscale.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="8"            # plan de contrôle léger (SQLite) : 8 Go largement suffisant
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts : headscale / 1 / 1024)
read -rp "Nom du container (hostname) [headscale] : " CT_NAME; CT_NAME="${CT_NAME:-headscale}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [1] : " CT_CORES; CT_CORES="${CT_CORES:-1}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (ex: 1024) [1024] : " CT_RAM; CT_RAM="${CT_RAM:-1024}"
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

# ═════════════════════════════════════════════════════════════════════════════
# COUCHE APPLICATIVE — HEADSCALE (le socle ci-dessus fournit Docker + nesting)
# ═════════════════════════════════════════════════════════════════════════════
# Version épinglée : la config est dérivée de l'exemple de CETTE version pour
# éviter toute dérive de schéma. Pour monter de version : bump HEADSCALE_VERSION
# + re-vérifier le config-example.yaml amont.
HEADSCALE_VERSION="0.23.0"
HEADSCALE_IMAGE="headscale/headscale:${HEADSCALE_VERSION}"
APP_DIR="/opt/headscale"
TAILNET_USER="thibault"

info "Configuration de Headscale ${HEADSCALE_VERSION}..."

# server_url = URL HTTPS publique servie par l'edge Caddy (phase 1).
# base_domain = suffixe MagicDNS interne au tailnet ; NE DOIT PAS chevaucher le
# domaine de server_url (contrainte Headscale).
read -rp  "Domaine public du plan de contrôle (server_url) [headscale.survivalmode.familyds.org] : " HS_DOMAIN
HS_DOMAIN="${HS_DOMAIN:-headscale.survivalmode.familyds.org}"
read -rp  "base_domain MagicDNS (suffixe interne tailnet) [ts.lan] : " HS_BASE_DOMAIN
HS_BASE_DOMAIN="${HS_BASE_DOMAIN:-ts.lan}"

info "Déploiement (image ${HEADSCALE_IMAGE}, config patchée depuis l'exemple amont)..."
pct exec "$VMID" -- bash -c "
    set -e
    mkdir -p '$APP_DIR/config' '$APP_DIR/lib'
    # Config de référence pour la version épinglée (schéma garanti compatible).
    curl -fsSL 'https://raw.githubusercontent.com/juanfont/headscale/v${HEADSCALE_VERSION}/config-example.yaml' \
        -o '$APP_DIR/config/config.yaml'
    # Patches ciblés (clés mono-ligne).
    sed -i \
        -e 's|^server_url:.*|server_url: https://${HS_DOMAIN}|' \
        -e 's|^listen_addr:.*|listen_addr: 0.0.0.0:8080|' \
        -e 's|^\([[:space:]]*\)base_domain:.*|\1base_domain: ${HS_BASE_DOMAIN}|' \
        '$APP_DIR/config/config.yaml'

    cat > '$APP_DIR/docker-compose.yml' <<COMPOSE
services:
  headscale:
    image: ${HEADSCALE_IMAGE}
    container_name: headscale
    restart: unless-stopped
    command: serve
    ports:
      - '8080:8080'
      - '127.0.0.1:9090:9090'
    volumes:
      - ./config:/etc/headscale
      - ./lib:/var/lib/headscale
COMPOSE

    cd '$APP_DIR'
    docker compose up -d
"

# Attente du démarrage puis création de l'utilisateur tailnet + pré-auth key.
info "Attente du démarrage de Headscale..."
sleep 8
HS_EXEC=(pct exec "$VMID" -- docker exec headscale headscale)
"${HS_EXEC[@]}" users create "$TAILNET_USER" >/dev/null 2>&1 || info "(utilisateur ${TAILNET_USER} déjà présent ou daemon pas prêt)"
PREAUTH_KEY="$("${HS_EXEC[@]}" preauthkeys create --user "$TAILNET_USER" --reusable --expiration 24h 2>/dev/null | tail -n1 || true)"

APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo
info "═══ Headscale déployé ═══"
info "  Control plane (interne) : http://${APP_IP}:8080   → à exposer en https://${HS_DOMAIN} via l'edge Caddy"
info "  Config                  : ${APP_DIR}/config/config.yaml (server_url=https://${HS_DOMAIN}, base_domain=${HS_BASE_DOMAIN})"
info "  CLI                     : pct exec ${VMID} -- docker exec headscale headscale <cmd>"
info "  Logs                    : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && docker compose logs -f'"
echo
echo -e "\e[33m================ RUNBOOK : enrôlement des appareils ================\e[0m"
cat <<RUNBOOK

  PRÉREQUIS (sinon l'enrôlement échouera) :
    - L'edge Caddy (phase 1) doit servir https://${HS_DOMAIN} -> ${APP_IP}:8080
    - DNS : ${HS_DOMAIN} doit résoudre vers l'IP publique de la maison
    - Routeur : 80/443 forwardés vers le LXC edge

  Pré-auth key (valide 24h, réutilisable) :
    ${PREAUTH_KEY:-<non générée — voir ci-dessous>}

  Sur chaque appareil (Tailscale installé) :
    tailscale up --login-server https://${HS_DOMAIN} --authkey <PRE_AUTH_KEY>

  Sur le NAS Synology (remplace l'accès QuickConnect AVANT de le couper) :
    - Installer le paquet Tailscale (Centre de paquets)
    - Tailscale > se connecter > serveur perso : https://${HS_DOMAIN}
    - Drive accessible ensuite via l'IP tailnet du NAS / le nom MagicDNS

  Régénérer une clé plus tard :
    pct exec ${VMID} -- docker exec headscale headscale preauthkeys create --user ${TAILNET_USER} --reusable --expiration 24h

  Lister les noeuds enrôlés :
    pct exec ${VMID} -- docker exec headscale headscale nodes list

  ACL (cloisonnement famille/amis) : à poser plus tard, phase 2 / tier "confiance".
RUNBOOK
echo -e "\e[33m====================================================================\e[0m"
