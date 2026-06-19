#!/usr/bin/env bash
#
# create-lxc-caddy.sh — LXC Ubuntu 24.04 + Caddy (edge / porte d'entrée publique HTTPS)
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
# - Puis : déploie Caddy (Docker), reverse proxy + Let's Encrypt HTTP-01 pour
#          Jellyfin (public) et le plan de contrôle Headscale.
#
# Edge du homelab (cf. tla1852/homelab-secu, phase 1). À construire APRÈS le LXC
# Headscale (il faut son IP). Vivra d'abord sur vmbr0 ; bascule en VLAN DMZ isolé
# + CrowdSec en phase 4 (CrowdSec = build xcaddy custom, hors périmètre v1).
#
# PRÉREQUIS RÉSEAU :
#   - Routeur : forward 80/443 -> IP de ce LXC (et plus vers le Synology)
#   - DNS : ${PUBLIC_DOMAIN} et ${HS_DOMAIN} résolvent vers l'IP publique maison
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-caddy.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="8"            # Caddy + certs : 8 Go suffisent
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts : caddy-edge / 1 / 1024)
read -rp "Nom du container (hostname) [caddy-edge] : " CT_NAME; CT_NAME="${CT_NAME:-caddy-edge}"
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
# COUCHE APPLICATIVE — CADDY EDGE (le socle ci-dessus fournit Docker + nesting)
# ═════════════════════════════════════════════════════════════════════════════
CADDY_IMAGE="caddy:2.8"
APP_DIR="/opt/caddy"

info "Configuration de l'edge Caddy..."

read -rp  "Email ACME (Let's Encrypt) [thibault@tlagrange.pro] : " ACME_EMAIL
ACME_EMAIL="${ACME_EMAIL:-thibault@tlagrange.pro}"
read -rp  "Domaine public Jellyfin [jellyfin.survivalmode.familyds.org] : " PUBLIC_DOMAIN
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-jellyfin.survivalmode.familyds.org}"
read -rp  "Upstream Jellyfin (host:port) [192.168.1.10:8096] : " JELLYFIN_UPSTREAM
JELLYFIN_UPSTREAM="${JELLYFIN_UPSTREAM:-192.168.1.10:8096}"
read -rp  "Domaine plan de contrôle Headscale [headscale.survivalmode.familyds.org] : " HS_DOMAIN
HS_DOMAIN="${HS_DOMAIN:-headscale.survivalmode.familyds.org}"
read -rp  "Upstream Headscale (IP du LXC headscale:8080) [192.168.1.20:8080] : " HS_UPSTREAM
HS_UPSTREAM="${HS_UPSTREAM:-192.168.1.20:8080}"

info "Génération du Caddyfile + docker-compose..."
pct exec "$VMID" -- bash -c "
    set -e
    mkdir -p '$APP_DIR/data' '$APP_DIR/config'

    cat > '$APP_DIR/Caddyfile' <<CADDY
{
    email ${ACME_EMAIL}
}

# --- Plan de contrôle Headscale (HTTPS public, reverse proxy interne) ---
${HS_DOMAIN} {
    reverse_proxy ${HS_UPSTREAM}
}

# --- Jellyfin (seul service applicatif public) ---
# Caddy propage la vraie IP cliente (X-Forwarded-For). Côté Jellyfin :
# Réseau > known proxies = IP de cet edge (durcissement, phase 4).
${PUBLIC_DOMAIN} {
    reverse_proxy ${JELLYFIN_UPSTREAM}
}
CADDY

    cat > '$APP_DIR/docker-compose.yml' <<COMPOSE
services:
  caddy:
    image: ${CADDY_IMAGE}
    container_name: caddy-edge
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '443:443/udp'
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
COMPOSE

    cd '$APP_DIR'
    docker compose up -d
"
unset ACME_EMAIL

APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo
info "═══ Edge Caddy déployé ═══"
info "  IP du LXC      : ${APP_IP}   ← cible des forwards 80/443 du routeur"
info "  Jellyfin       : https://${PUBLIC_DOMAIN}  -> ${JELLYFIN_UPSTREAM}"
info "  Headscale      : https://${HS_DOMAIN}  -> ${HS_UPSTREAM}"
info "  Caddyfile      : ${APP_DIR}/Caddyfile"
info "  Recharger conf : pct exec ${VMID} -- docker exec -w /etc/caddy caddy-edge caddy reload"
info "  Logs           : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && docker compose logs -f'"
echo
echo -e "\e[33m================ À FAIRE pour activer l'edge ================\e[0m"
cat <<RUNBOOK

  1. Routeur : forward TCP 80 + 443 (et UDP 443) -> ${APP_IP}
     Retirer les forwards 80/443 qui pointaient vers le Synology.

  2. DNS : vérifier que ${PUBLIC_DOMAIN} ET ${HS_DOMAIN} résolvent vers l'IP
     publique de la maison. ⚠️ DDNS Synology familyds.org : confirmer que le
     sous-domaine ${HS_DOMAIN} est bien servi (sinon : CNAME / wildcard / autre
     fournisseur DNS pour le sous-domaine Headscale).

  3. Vérifier l'émission des certificats Let's Encrypt :
     pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && docker compose logs | grep -i certificate'

  4. Test externe (4G / hors LAN) : https://${PUBLIC_DOMAIN} et https://${HS_DOMAIN}

  Durcissement (phase 4, plus tard) :
    - bascule de ce LXC en VLAN DMZ isolé (DMZ -> LAN = DENY)
    - image Caddy custom (xcaddy) avec bouncer CrowdSec + geoblock par vhost
    - GoAccess (visu trafic) accessible via tailnet uniquement
RUNBOOK
echo -e "\e[33m=============================================================\e[0m"
