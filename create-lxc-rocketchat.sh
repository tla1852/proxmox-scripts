#!/usr/bin/env bash
#
# create-lxc-rocketchat.sh — LXC Ubuntu 24.04 + Rocket.Chat (Docker Compose)
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
# - Puis : déploie Rocket.Chat (registry.rocket.chat) + MongoDB 7 en replica
#          set mono-noeud (rs0, initié automatiquement via le healthcheck),
#          HTTP sur le port 3000. ROOT_URL demandé (défaut http://<ip>:3000),
#          à pointer vers le vhost Caddy si exposition publique (Livechat).
#
# Objectifs de l'instance (config post-install, cf. "Étapes suivantes") :
#   - canal perso où poster des liens traités par un bot (n8n : recettes,
#     news, achats)
#   - Livechat/Omnichannel pour contacts clients (ex. blind test)
#   - webhooks entrants pour notifs infra (supervision) + recherche boulot
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-rocketchat.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="16"           # images ~1,5 Go + MongoDB (messages, uploads dans Mongo par défaut)
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts : rocketchat / 2 / 4096)
read -rp "Nom du container (hostname) [rocketchat] : " CT_NAME; CT_NAME="${CT_NAME:-rocketchat}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [2] : " CT_CORES; CT_CORES="${CT_CORES:-2}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (ex: 4096) [4096] : " CT_RAM; CT_RAM="${CT_RAM:-4096}"
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
# COUCHE APPLICATIVE — Rocket.Chat (le socle ci-dessus fournit Docker + nesting)
# ═════════════════════════════════════════════════════════════════════════════
APP_DIR="/opt/rocketchat"

APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')

# ROOT_URL : URL par laquelle les clients joignent l'instance. Modifiable ensuite
# dans ${APP_DIR}/.env (docker compose up -d pour appliquer) quand le vhost Caddy
# existera (ex. https://chat.tlagrange.pro pour le Livechat public).
read -rp "ROOT_URL [http://${APP_IP}:3000] : " ROOT_URL; ROOT_URL="${ROOT_URL:-http://${APP_IP}:3000}"

info "Génération du docker-compose (Rocket.Chat + MongoDB 7 replica set rs0)..."
pct exec "$VMID" -- bash -c "
    set -e
    mkdir -p '$APP_DIR'
    cd '$APP_DIR'

    cat > .env <<ENV
ROOT_URL=${ROOT_URL}
RELEASE=latest
ENV
    chmod 600 .env

    cat > compose.yml <<'COMPOSE'
services:
  rocketchat:
    image: registry.rocket.chat/rocketchat/rocket.chat:\${RELEASE:-latest}
    restart: always
    environment:
      MONGO_URL: mongodb://mongodb:27017/rocketchat?replicaSet=rs0
      MONGO_OPLOG_URL: mongodb://mongodb:27017/local?replicaSet=rs0
      ROOT_URL: \${ROOT_URL}
      PORT: 3000
      DEPLOY_METHOD: docker
    depends_on:
      mongodb:
        condition: service_healthy
    ports:
      - \"3000:3000\"

  mongodb:
    image: mongo:7.0
    restart: always
    command: mongod --replSet rs0 --oplogSize 128
    volumes:
      - mongodb_data:/data/db
    # Le healthcheck initie le replica set mono-noeud au premier run
    # (rs.status() échoue tant que rs0 n'existe pas -> rs.initiate()).
    healthcheck:
      test: mongosh --quiet --eval \"try { rs.status().ok } catch (e) { rs.initiate({_id:'rs0',members:[{_id:0,host:'mongodb:27017'}]}).ok }\"
      interval: 10s
      timeout: 10s
      retries: 12
      start_period: 20s

volumes:
  mongodb_data:
COMPOSE
"

info "Démarrage de la stack (premier boot Rocket.Chat : 1-2 min)..."
pct exec "$VMID" -- bash -c "cd '$APP_DIR' && docker compose up -d --quiet-pull"

info "Attente de l'API Rocket.Chat..."
for i in $(seq 1 60); do
    if pct exec "$VMID" -- curl -fsS http://localhost:3000/api/info >/dev/null 2>&1; then
        break
    fi
    [[ $i -eq 60 ]] && err "Rocket.Chat ne répond pas après 5 min. Logs : pct exec ${VMID} -- docker compose -f ${APP_DIR}/compose.yml logs"
    sleep 5
done
RC_VERSION=$(pct exec "$VMID" -- curl -fsS http://localhost:3000/api/info | python3 -c "import sys,json;print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")

echo
info "═══ Rocket.Chat déployé ═══"
info "  URL       : http://${APP_IP}:3000 (version ${RC_VERSION}, ROOT_URL=${ROOT_URL})"
info "  App       : ${APP_DIR} (dans le CT ${VMID}) — .env en 600, données dans le volume mongodb_data"
info "  MAJ       : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && docker compose pull && docker compose up -d'"
info "  Logs      : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && docker compose logs -f'"
echo
info "Étapes suivantes (plan privé) :"
info "  1. Ouvrir http://${APP_IP}:3000 : le premier compte créé (setup wizard) est admin."
info "  2. Admin -> Comptes : désactiver l'inscription publique (instance perso)."
info "  3. Notifs infra/boulot : Admin -> Intégrations -> webhook entrant par canal"
info "     (#infra, #jobs) ; brancher Grafana/n8n dessus (POST JSON {\"text\":\"...\"})."
info "  4. Traitement des liens : webhook sortant sur un canal #liens -> n8n"
info "     (tri recette/news/achat), réponse via le webhook entrant."
info "  5. Chat clients (blind test) : Admin -> Omnichannel -> activer Livechat,"
info "     widget à intégrer sur le site ; nécessite ROOT_URL public en HTTPS"
info "     -> vhost Caddy (caddy-edge) vers ${APP_IP}:3000 + MAJ ROOT_URL dans ${APP_DIR}/.env."
info "  6. Apps mobiles/desktop : ajouter le serveur via l'URL (ROOT_URL)."
