#!/usr/bin/env bash
#
# create-lxc-rustdesk.sh — LXC Ubuntu 24.04 + serveur RustDesk OSS (hbbs + hbbr)
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
# - Puis : déploie rustdesk-server (image Docker épinglée) : hbbs (rendez-vous /
#          ID) + hbbr (relais), network_mode host, clé ed25519 générée au 1er
#          démarrage et imposée aux clients (-k _), imprime le runbook client.
#
# RustDesk = protocole TCP/UDP brut : PAS de reverse proxy HTTP (Caddy) possible
# pour 21115-21117. Exposition publique via le DDNS fix.survivalmode.familyds.org
# + forwards routeur directs vers ce LXC (cf. runbook en fin de script).
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-rustdesk.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="8"            # hbbs/hbbr très légers (SQLite + clé) : 8 Go largement suffisant
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts : rustdesk / 1 / 512)
read -rp "Nom du container (hostname) [rustdesk] : " CT_NAME; CT_NAME="${CT_NAME:-rustdesk}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [1] : " CT_CORES; CT_CORES="${CT_CORES:-1}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (ex: 512) [512] : " CT_RAM; CT_RAM="${CT_RAM:-512}"
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
# COUCHE APPLICATIVE — RUSTDESK SERVER (le socle ci-dessus fournit Docker + nesting)
# ═════════════════════════════════════════════════════════════════════════════
# Version épinglée. Pour monter de version : bump RUSTDESK_VERSION puis
# `docker compose pull && docker compose up -d` dans ${APP_DIR}.
RUSTDESK_VERSION="1.1.16"
RUSTDESK_IMAGE="rustdesk/rustdesk-server:${RUSTDESK_VERSION}"
APP_DIR="/opt/rustdesk"

# Hôte public (DDNS Synology) : sert d'ID server côté clients ET est annoncé
# par hbbs comme relais (-r), pour que le relais reste joignable hors LAN.
read -rp "Hôte public RustDesk (FQDN DDNS) [fix.survivalmode.familyds.org] : " RD_RELAY
RD_RELAY="${RD_RELAY:-fix.survivalmode.familyds.org}"
[[ "$RD_RELAY" =~ ^[a-zA-Z0-9.-]+$ ]] || err "Hôte invalide."

info "Déploiement de rustdesk-server ${RUSTDESK_VERSION}..."
pct exec "$VMID" -- env APP_DIR="$APP_DIR" RUSTDESK_IMAGE="$RUSTDESK_IMAGE" RD_RELAY="$RD_RELAY" bash -s <<'RUSTDESK'
set -euo pipefail
mkdir -p "$APP_DIR/data"

HBBS_CMD="hbbs -k _"
[[ -n "$RD_RELAY" ]] && HBBS_CMD="hbbs -r ${RD_RELAY}:21117 -k _"

# network_mode host : hbbs a besoin de l'IP réelle des clients (NAT hole punching).
# Ports : 21115/tcp (test NAT), 21116/tcp+udp (ID/rendez-vous), 21117/tcp (relais),
#         21118-21119/tcp (clients web, optionnel).
cat > "$APP_DIR/docker-compose.yml" <<COMPOSE
services:
  hbbs:
    image: ${RUSTDESK_IMAGE}
    container_name: hbbs
    command: ${HBBS_CMD}
    network_mode: host
    volumes:
      - ./data:/root
    depends_on:
      - hbbr
    restart: unless-stopped

  hbbr:
    image: ${RUSTDESK_IMAGE}
    container_name: hbbr
    command: hbbr -k _
    network_mode: host
    volumes:
      - ./data:/root
    restart: unless-stopped
COMPOSE

cd "$APP_DIR"
docker compose up -d --quiet-pull

# La paire de clés ed25519 est générée par hbbs au premier démarrage.
for i in $(seq 1 30); do
    [[ -s "$APP_DIR/data/id_ed25519.pub" ]] && break
    [[ $i -eq 30 ]] && { echo "Clé publique non générée après 60s" >&2; exit 1; }
    sleep 2
done
chmod 600 "$APP_DIR/data/id_ed25519"
cp "$APP_DIR/data/id_ed25519.pub" /root/rustdesk-key.txt
RUSTDESK

RD_KEY=$(pct exec "$VMID" -- cat "${APP_DIR}/data/id_ed25519.pub")
APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
RD_HOST="${RD_RELAY:-$APP_IP}"

echo
info "Terminé ! Container ${VMID} (${CT_NAME}) prêt."
info "═══ RustDesk server déployé ═══"
info "  IP        : ${APP_IP}"
info "  Accès     : pct enter ${VMID}   ou   ssh ${ADMIN_USER}@<ip> (si openssh installé)"
info "  Données   : ${APP_DIR}/data (clé privée id_ed25519 : à sauvegarder, la perdre = reconfigurer tous les clients)"
info "  Clé pub.  : ${RD_KEY}   (aussi dans /root/rustdesk-key.txt du container)"
info "  Logs      : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && docker compose logs -f'"
echo
echo -e "\e[33m================ RUNBOOK : configuration des clients ================\e[0m"
cat <<RUNBOOK

  Client RustDesk > Paramètres > Réseau > Serveur ID/Relais :
    Serveur ID     : ${RD_HOST}
    Serveur relais : ${RD_HOST}      (facultatif si identique à l'ID)
    Serveur API    : (laisser vide — pas de serveur Pro)
    Clé            : ${RD_KEY}

  La clé est imposée (-k _) : un client sans la bonne clé est refusé.

  PRÉREQUIS accès Internet (sinon seuls les clients LAN fonctionneront) :
    - DNS : ${RD_HOST} doit résoudre vers l'IP publique de la maison (DDNS Synology)
    - Routeur : forwards directs (pas de Caddy, protocole non HTTP) vers ${APP_IP}
        21115/tcp, 21116/tcp, 21116/udp, 21117/tcp
    - Bail DHCP fixe pour ce CT sur le routeur (sinon les forwards cassent)
    - Sur le LAN, le nom public n'est joignable que si le routeur fait du NAT
      loopback ; à défaut, les postes du LAN peuvent viser ${APP_IP} (même clé).

  Sécurité : la clé protège le serveur, pas les postes. Sur chaque poste
  contrôlé : mot de passe permanent fort ou acceptation manuelle des connexions.

  Mise à jour :
    pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && sed -i "s/:${RUSTDESK_VERSION}/:<nouvelle>/" docker-compose.yml && docker compose pull && docker compose up -d'
RUNBOOK
echo -e "\e[33m======================================================================\e[0m"
