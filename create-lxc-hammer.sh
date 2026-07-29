#!/usr/bin/env bash
#
# create-lxc-hammer.sh — LXC Ubuntu 24.04 + serveur de sync Hammer (Docker)
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
# - Puis : déploie le serveur de sync Hammer (https://hammer.ink, éditeur de
#          romans Kotlin Multiplatform) via l'image officielle GHCR, PostgreSQL
#          embarqué dans le volume /data — aucun autre service requis.
#
# Exposition prévue : UNIQUEMENT via le tailnet, derrière le Caddy interne
# (LXC 100) en hammer.ts.tlagrange.pro → <IP LXC>:8080. Les clients Hammer ne
# parlent QUE HTTPS : le vhost Caddy (cert Let's Encrypt DNS-01 Gandi) est
# indispensable, l'IP:8080 en direct ne fonctionnera pas depuis un client.
# Voir homelab/internal/{Caddyfile,extra-records.yaml}.
#
# Doc upstream : docs/HOW-TO-RUN-A-SERVER-DOCKER.md du repo
# Darkrock-Studios/hammer-editor. Premier compte créé = compte admin.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-hammer.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="12"           # image ~600 Mo + pgdata embarqué + cache : large
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts : hammer / 2 / 2048)
read -rp "Nom du container (hostname) [hammer] : " CT_NAME; CT_NAME="${CT_NAME:-hammer}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [2] : " CT_CORES; CT_CORES="${CT_CORES:-2}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (JVM + PostgreSQL embarqué, conseillé >= 2048) [2048] : " CT_RAM; CT_RAM="${CT_RAM:-2048}"
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
# COUCHE APPLICATIVE — HAMMER SYNC SERVER (le socle ci-dessus fournit Docker)
# ═════════════════════════════════════════════════════════════════════════════
APP_DIR="/opt/hammer"
HAMMER_IMAGE="ghcr.io/darkrock-studios/hammer-editor/server:latest"
FQDN="hammer.ts.tlagrange.pro"

info "Déploiement du serveur Hammer (${FQDN})..."

pct exec "$VMID" -- env APP_DIR="$APP_DIR" HAMMER_IMAGE="$HAMMER_IMAGE" FQDN="$FQDN" bash -s <<'HAMMER'
set -euo pipefail
mkdir -p "$APP_DIR"

# config.toml auto-chargé depuis /data/hammer_data/config.toml (bind mount ro).
# bindHosts volontairement absent : dans un container il lierait le loopback
# DU container et rendrait le serveur injoignable (cf. doc Docker upstream).
cat > "$APP_DIR/config.toml" <<TOML
# Nom public annoncé aux clients = vhost du Caddy interne (tailnet).
host = "${FQDN}"
port = 8080

# URL externe (liens générés) : TLS terminé par le Caddy interne.
publicUrl = "https://${FQDN}"
TOML

# Port 8080 publié sur toutes les interfaces : HTTP en clair, mais LAN homelab
# derrière NAT + exposition client uniquement via le Caddy interne (tailnet).
# Nécessaire : le Caddy (LXC 100) doit joindre ce port depuis le LAN.
cat > "$APP_DIR/docker-compose.yml" <<COMPOSE
name: hammer

services:
  hammer:
    image: ${HAMMER_IMAGE}
    container_name: hammer-server
    restart: unless-stopped
    # La JVM gère SIGTERM ; init reape les orphelins du PostgreSQL embarqué.
    init: true
    ports:
      - "0.0.0.0:8080:8080"
    volumes:
      - hammer-data:/data
      - ./config.toml:/data/hammer_data/config.toml:ro

volumes:
  hammer-data:
COMPOSE

cd "$APP_DIR"
docker compose up -d

# Attente du healthcheck embarqué dans l'image
echo ">> Attente du démarrage du serveur..."
for i in $(seq 1 60); do
    STATUS=$(docker inspect --format '{{.State.Health.Status}}' hammer-server 2>/dev/null || echo starting)
    [[ "$STATUS" == "healthy" ]] && break
    [[ "$STATUS" == "unhealthy" ]] && { docker logs hammer-server | tail -20; echo "Serveur unhealthy"; exit 1; }
    [[ $i -eq 60 ]] && { docker logs hammer-server | tail -20; echo "Timeout démarrage (2 min)"; exit 1; }
    sleep 2
done
echo ">> Serveur Hammer démarré (healthy)"
HAMMER

# ----- Récap -----
APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo
info "═══ Serveur Hammer déployé ═══"
info "  CT           : ${VMID} (${CT_NAME}), IP ${APP_IP}"
info "  HTTP interne : http://${APP_IP}:8080  (santé : /, healthcheck Docker)"
info "  URL clients  : https://${FQDN}  (une fois le Caddy interne à jour)"
info "  Config       : ${APP_DIR}/config.toml (bind ro dans /data/hammer_data/)"
info "  Données      : volume docker hammer-data (pgdata embarqué + caches)"
info "  Logs         : pct exec ${VMID} -- docker logs -f hammer-server"
echo
echo -e "\e[33m================ À FAIRE pour activer le service ================\e[0m"
cat <<RUNBOOK

  1. Caddy interne (repo, homelab/internal/Caddyfile) — ajouter puis déployer
     sur le LXC 100 :

       # Hammer — sync serveur d'écriture (CT ${VMID})
       ${FQDN} {
           reverse_proxy ${APP_IP}:8080
       }

  2. MagicDNS (repo, homelab/internal/extra-records.yaml) — ajouter, puis
     reporter dans /opt/headscale/config/config.yaml (LXC 145) et redémarrer
     headscale :

       - { name: "${FQDN}", type: A, value: "100.64.0.2" }

  3. Homarr (optionnel) : pct set ${VMID} -tags "homarr.cloud"
     puis lancer homarr-sync.

  4. Premier compte : installer un client Hammer (https://hammer.ink),
     serveur = https://${FQDN} → LE PREMIER COMPTE CRÉÉ EST L'ADMIN.
     Whitelist activée par défaut : gérer les comptes suivants via /admin.

RUNBOOK
echo -e "\e[33m=================================================================\e[0m"
