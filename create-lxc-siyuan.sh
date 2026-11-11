#!/usr/bin/env bash
#
# create-lxc-siyuan.sh — LXC Ubuntu 24.04 + SiYuan Note (Docker, accès web)
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
# - Puis : déploie SiYuan (https://b3log.org/siyuan, remplaçant Notion) via
#          l'image officielle b3log/siyuan, mode serveur web, workspace
#          persistant /opt/siyuan/workspace, code d'accès généré.
#
# Exposition prévue : tailnet (Caddy interne LXC 100, siyuan.ts.tlagrange.pro)
# + en option accès bureau (edge CT 144 + Authelia). Voir
# homelab/siyuan/expose.sh. Pas d'abonnement SiYuan : pas de sync S3/WebDAV,
# mobile = navigateur via le tailnet.
#
# Doc upstream : README siyuan-note/siyuan, section Docker (sous-commande
# `serve` obligatoire depuis v3.7.0).
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-siyuan.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="16"           # workspace + assets (images, PDF) + snapshots locaux SiYuan
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts : siyuan / 2 / 2048)
read -rp "Nom du container (hostname) [siyuan] : " CT_NAME; CT_NAME="${CT_NAME:-siyuan}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [2] : " CT_CORES; CT_CORES="${CT_CORES:-2}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (kernel Go + index, conseillé >= 2048) [2048] : " CT_RAM; CT_RAM="${CT_RAM:-2048}"
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
# COUCHE APPLICATIVE — SIYUAN (le socle ci-dessus fournit Docker)
# ═════════════════════════════════════════════════════════════════════════════
APP_DIR="/opt/siyuan"
SIYUAN_IMAGE="b3log/siyuan:v3.8.10"   # épinglé ; MAJ via vulnwatch (compose-update)
FQDN="siyuan.ts.tlagrange.pro"

info "Déploiement de SiYuan (${SIYUAN_IMAGE})..."

pct exec "$VMID" -- env APP_DIR="$APP_DIR" SIYUAN_IMAGE="$SIYUAN_IMAGE" bash -s <<'SIYUAN'
set -euo pipefail
mkdir -p "$APP_DIR/workspace"
# L'entrypoint tourne en PUID/PGID 1000 : le workspace doit lui appartenir.
chown -R 1000:1000 "$APP_DIR/workspace"

# Code d'accès (écran de verrouillage) : seule auth applicative de SiYuan.
# Lu par compose depuis .env (pas en clair dans le docker-compose.yml).
if [[ ! -f "$APP_DIR/.env" ]]; then
    umask 077
    echo "SIYUAN_ACCESS_AUTH_CODE=$(openssl rand -hex 16)" > "$APP_DIR/.env"
fi
chmod 600 "$APP_DIR/.env"

# Port 6806 publié sur le LAN : le Caddy interne (LXC 100) et l'edge (CT 144)
# doivent le joindre. HTTP en clair sur le LAN homelab, TLS terminé par Caddy.
cat > "$APP_DIR/docker-compose.yml" <<COMPOSE
name: siyuan

services:
  siyuan:
    image: ${SIYUAN_IMAGE}
    container_name: siyuan
    restart: unless-stopped
    command: ["serve", "--workspace=/siyuan/workspace/"]
    environment:
      - TZ=Europe/Paris
      - PUID=1000
      - PGID=1000
      - SIYUAN_ACCESS_AUTH_CODE=\${SIYUAN_ACCESS_AUTH_CODE:?code absent de .env}
    ports:
      - "0.0.0.0:6806:6806"
    volumes:
      - ./workspace:/siyuan/workspace
COMPOSE

cd "$APP_DIR"
docker compose up -d

echo ">> Attente du démarrage de SiYuan..."
for i in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -m3 http://localhost:6806/ || true)
    [[ "$CODE" =~ ^(200|301|302|401)$ ]] && break
    [[ $i -eq 60 ]] && { docker logs siyuan | tail -20; echo "Timeout démarrage (2 min)"; exit 1; }
    sleep 2
done
echo ">> SiYuan répond (HTTP ${CODE})"
SIYUAN

# ----- Récap -----
APP_IP=$(pct exec "$VMID" -- sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1")  # pas hostname -I : docker0 sort parfois en 1er
AUTH_CODE=$(pct exec "$VMID" -- sed -n 's/^SIYUAN_ACCESS_AUTH_CODE=//p' "$APP_DIR/.env")
echo
info "═══ SiYuan déployé ═══"
info "  CT           : ${VMID} (${CT_NAME}), IP ${APP_IP}"
info "  HTTP interne : http://${APP_IP}:6806"
info "  URL          : https://${FQDN}  (après expose.sh)"
info "  Code d'accès : ${AUTH_CODE}"
info "                 (stocké dans ${APP_DIR}/.env du CT, à mettre dans le gestionnaire de mdp)"
info "  Données      : ${APP_DIR}/workspace  (à sauvegarder : c'est TOUT SiYuan)"
info "  Logs         : pct exec ${VMID} -- docker logs -f siyuan"
unset AUTH_CODE
echo
echo -e "\e[33m================ À FAIRE pour activer le service ================\e[0m"
cat <<RUNBOOK

  1. Réserver le bail DHCP ${APP_IP} (CT ${VMID}) sur la box.

  2. Exposition (hôte Proxmox) : vhost Caddy interne + MagicDNS + option bureau
       SIYUAN_CT=${VMID} bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/siyuan/expose.sh)

  3. Jeton API (n8n, boox-sync, Claude) : SiYuan → Paramètres → À propos →
     « Jeton API » ; appels : POST https://${FQDN}/api/... avec
     header « Authorization: Token <jeton> ».

  4. Import Notion : export Notion « Markdown & CSV » → SiYuan → Importer → Markdown.

  5. Homarr (optionnel) : pct set ${VMID} -tags "homarr.cloud" puis homarr-sync.

RUNBOOK
echo -e "\e[33m=================================================================\e[0m"
