#!/usr/bin/env bash
#
# create-lxc-anytype.sh — LXC Ubuntu 24.04 + any-sync self-hosted (Docker Compose)
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
# - Puis : clone anyproto/any-sync-dockercompose, .env (EXTERNAL_LISTEN_HOSTS,
#          secrets MinIO auto-générés), make start (mongo, redis, minio,
#          coordinator, consensus, filenode, 3 sync-nodes), récupération du
#          etc/client.yml sur l'hôte Proxmox pour import dans les clients.
#
# ⚠️ Contrairement aux autres stacks, any-sync N'EST PAS du HTTP : les clients
# parlent le protocole any-sync directement sur les ports 1001-1006/tcp (yamux)
# et 1011-1016/udp (QUIC). Pas de vhost Caddy possible — les clients joignent
# les IP listées dans EXTERNAL_LISTEN_HOSTS. Ces hôtes sont figés dans la
# config réseau (network ID) générée au premier démarrage : les régénérer
# ensuite casse les comptes existants. Donc TOUT renseigner au premier run
# (IP LAN auto-détectée + hôtes supplémentaires demandés, ex. IP tailnet).
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-anytype.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="24"           # images ~1 Go + MongoDB + MinIO (blobs fichiers, quota filenode 1 TiB)
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts : anytype / 2 / 4096)
read -rp "Nom du container (hostname) [anytype] : " CT_NAME; CT_NAME="${CT_NAME:-anytype}"
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
# COUCHE APPLICATIVE — any-sync (le socle ci-dessus fournit Docker + nesting)
# ═════════════════════════════════════════════════════════════════════════════
APP_DIR="/opt/any-sync-dockercompose"
REPO_URL="https://github.com/anyproto/any-sync-dockercompose.git"

APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')

info "Configuration d'any-sync (IP LAN détectée : ${APP_IP})..."
echo "Les hôtes ci-dessous sont FIGÉS dans la config réseau au premier démarrage."
echo "Ajouter dès maintenant toute IP/nom par lesquels les clients joindront le"
echo "serveur (ex. IP tailnet du CT si tailscale y sera installé). Vide = LAN seul."
read -rp "Hôtes supplémentaires (séparés par des espaces) [] : " EXTRA_HOSTS
LISTEN_HOSTS="${APP_IP}${EXTRA_HOSTS:+ ${EXTRA_HOSTS}}"

# Secrets MinIO générés côté hôte Proxmox (défauts publics dans .env.example).
S3_ACCESS_KEY="anytype-$(openssl rand -hex 6)"
S3_SECRET_KEY="$(openssl rand -hex 24)"

info "Clone du repo + génération du .env (base .env.example, EXTERNAL_LISTEN_HOSTS=\"${LISTEN_HOSTS}\")..."
pct exec "$VMID" -- bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get -y -qq install make jq >/dev/null
    rm -rf '$APP_DIR'
    git clone -q --depth 1 '$REPO_URL' '$APP_DIR'
    cd '$APP_DIR'
    cp .env.example .env

    # set_env KEY VALUE : remplace la ligne si la clé existe, sinon l'ajoute.
    set_env() {
        if grep -q \"^\${1}=\" .env; then
            sed -i \"s|^\${1}=.*|\${1}=\${2}|\" .env
        else
            echo \"\${1}=\${2}\" >> .env
        fi
    }

    # Adresses annoncées aux clients (protocole any-sync direct, pas de proxy HTTP).
    set_env EXTERNAL_LISTEN_HOSTS '\"$LISTEN_HOSTS\"'

    # Secrets MinIO (défauts publics : minio_access_key / minio_secret_key).
    set_env AWS_ACCESS_KEY_ID '$S3_ACCESS_KEY'
    set_env AWS_SECRET_ACCESS_KEY '$S3_SECRET_KEY'

    chmod 600 .env
"
unset S3_ACCESS_KEY S3_SECRET_KEY

info "Génération de la config réseau + démarrage (make start)..."
pct exec "$VMID" -- bash -c "
    set -e
    cd '$APP_DIR'
    make start
"

info "Récupération du client.yml (config réseau à importer dans chaque client)..."
CLIENT_YML="/root/anytype-client-ct${VMID}.yml"
pct pull "$VMID" "${APP_DIR}/etc/client.yml" "$CLIENT_YML"

echo
info "═══ any-sync (Anytype self-hosted) déployé ═══"
info "  Réseau    : ports clients ${APP_IP}:1001-1006/tcp + 1011-1016/udp (pas de HTTP, pas de vhost Caddy)"
info "  client.yml: ${CLIENT_YML} (copié depuis le CT) — à distribuer sur chaque appareil"
info "  App       : ${APP_DIR} (dans le CT ${VMID}) — .env en 600, données dans ./storage"
info "  MAJ       : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && git pull && make update' (lire l'Upgrade Guide du repo avant)"
info "  Logs      : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && docker compose logs -f'"
echo
info "Étapes suivantes (plan privé) :"
info "  1. Clients desktop/mobile : écran de connexion -> icône réseau (ou Settings ->"
info "     Data & Sync) -> Self-hosted -> importer ${CLIENT_YML##*/}"
info "  2. Créer le compte (vault) DEPUIS un client déjà branché sur ce réseau ;"
info "     sauvegarder la recovery phrase (aucune récupération possible sinon)."
info "  3. Sauvegarde : inclure ${APP_DIR}/etc (clés réseau !) et ./storage dans le plan backup."
info "⚠️  Ne JAMAIS régénérer ${APP_DIR}/etc après création des comptes (network ID)."
