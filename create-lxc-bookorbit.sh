#!/usr/bin/env bash
#
# create-lxc-bookorbit.sh — LXC Ubuntu 24.04 de base + BookOrbit
#
# Reprend la base de create-lxc.sh (DHCP, onboot, unprivileged, nesting,
# user thibault, docker/curl/git/unzip/python3) puis installe BookOrbit
# (PostgreSQL 16 + pgvector, Node.js 24, uv, build pnpm, service systemd).
#
# Portage standalone du script community-scripts :
#   https://github.com/community-scripts/ProxmoxVE/blob/main/install/bookorbit-install.sh
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-bookorbit.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="12"            # plus gros que la base : postgres + node + livres
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"
GH_REPO="bookorbit/bookorbit"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions -----
read -rp "Nom du container (hostname) [bookorbit] : " CT_NAME
CT_NAME="${CT_NAME:-bookorbit}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [2] : " CT_CORES
CT_CORES="${CT_CORES:-2}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (BookOrbit conseillé >= 4096) [4096] : " CT_RAM
CT_RAM="${CT_RAM:-4096}"
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

# ----- Création (base) -----
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

# ----- Base : maj + paquets + docker -----
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
pct exec "$VMID" -- passwd -l root >/dev/null

# ----- Couche BookOrbit -----
info "Installation de BookOrbit (peut durer plusieurs minutes)..."
pct exec "$VMID" -- env GH_REPO="$GH_REPO" bash -s <<'BOOKORBIT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release   # fournit VERSION_CODENAME

echo ">> Dépendances build/media"
apt-get update -qq
apt-get -y -qq install build-essential ffmpeg poppler-utils jq openssl gnupg lsb-release

echo ">> PostgreSQL 16 + pgvector (PGDG)"
install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
apt-get update -qq
apt-get -y -qq install postgresql-16 postgresql-16-pgvector
systemctl enable --now postgresql

echo ">> Base de données bookorbit"
PG_DB_PASS=$(openssl rand -hex 16)
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
CREATE USER bookorbit WITH PASSWORD '${PG_DB_PASS}';
CREATE DATABASE bookorbit OWNER bookorbit;
SQL
sudo -u postgres psql -v ON_ERROR_STOP=1 -d bookorbit <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;
SQL

echo ">> Node.js 24 (NodeSource)"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null
apt-get -y -qq install nodejs

echo ">> uv"
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh >/dev/null
export PATH="/usr/local/bin:$PATH"

echo ">> Récupération de la dernière release ${GH_REPO}"
API="https://api.github.com/repos/${GH_REPO}/releases/latest"
APP_VER=$(curl -fsSL "$API" | jq -r '.tag_name')
TARBALL=$(curl -fsSL "$API" | jq -r '.tarball_url')
[[ -n "$APP_VER" && "$APP_VER" != "null" ]] || { echo "Pas de release trouvée"; exit 1; }
echo "$APP_VER" > ~/.bookorbit
mkdir -p /opt/bookorbit
curl -fsSL "$TARBALL" -o /tmp/bookorbit.tar.gz
tar -xzf /tmp/bookorbit.tar.gz -C /opt/bookorbit --strip-components=1
rm -f /tmp/bookorbit.tar.gz

echo ">> Build pnpm"
cd /opt/bookorbit
PNPM_VERSION=$(jq -r '.packageManager | ltrimstr("pnpm@")' /opt/bookorbit/package.json)
corepack enable
corepack prepare "pnpm@${PNPM_VERSION}" --activate
pnpm install --frozen-lockfile
pnpm --filter client run build-only
pnpm --filter server run build
cp -r /opt/bookorbit/client/dist /opt/bookorbit/server/public
mkdir -p /opt/bookorbit/server/migrations
cp -r /opt/bookorbit/server/src/db/migrations/. /opt/bookorbit/server/migrations/
chmod +x /opt/bookorbit/server/bin/kepubify/* || true

echo ">> Environnement Python (uv)"
uv venv /opt/bookorbit-python
uv pip install --python /opt/bookorbit-python/bin/python \
    -r /opt/bookorbit/server/requirements/kobo-cloudscraper.txt

echo ">> Dossiers de données"
mkdir -p /opt/bookorbit-data/covers /opt/bookorbit-data/book-bucket /opt/bookorbit-books

echo ">> Fichier .env"
LOCAL_IP=$(hostname -I | awk '{print $1}')
JWT_SECRET=$(openssl rand -hex 32)
SETUP_BOOTSTRAP_TOKEN=$(openssl rand -hex 16)
cat > /opt/bookorbit/.env <<ENV
NODE_ENV=production
PORT=3000
DATABASE_URL=postgres://bookorbit:${PG_DB_PASS}@127.0.0.1:5432/bookorbit
JWT_SECRET=${JWT_SECRET}
SETUP_BOOTSTRAP_TOKEN=${SETUP_BOOTSTRAP_TOKEN}
APP_URL=http://${LOCAL_IP}:3000
CLIENT_URL=http://${LOCAL_IP}:3000
NODE_OPTIONS=--max-old-space-size=2048
APP_DATA_PATH=/opt/bookorbit-data
KOBO_CLOUDSCRAPER_PYTHON=/opt/bookorbit-python/bin/python
BOOK_DOCK_PATH=/opt/bookorbit-data/book-bucket
APP_VERSION=${APP_VER}
ENV
chmod 600 /opt/bookorbit/.env

echo ">> Service systemd"
cat > /etc/systemd/system/bookorbit.service <<'UNIT'
[Unit]
Description=BookOrbit Service
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/bookorbit/server
EnvironmentFile=/opt/bookorbit/.env
ExecStartPre=/usr/bin/node /opt/bookorbit/server/dist/scripts/migrate.js
ExecStart=/usr/bin/node /opt/bookorbit/server/dist/main.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now bookorbit

# Token de bootstrap affiché pour le 1er setup
echo "BOOTSTRAP_TOKEN=${SETUP_BOOTSTRAP_TOKEN}" > /root/bookorbit-bootstrap.txt
echo ">> BookOrbit installé (version ${APP_VER})"
BOOKORBIT

# ----- Récap -----
IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
BOOT=$(pct exec "$VMID" -- cat /root/bookorbit-bootstrap.txt 2>/dev/null || true)
echo
info "Terminé ! Container ${VMID} (${CT_NAME}) prêt."
info "  BookOrbit : http://${IP}:3000"
info "  ${BOOT}"
info "  (token aussi dans le container : /root/bookorbit-bootstrap.txt)"
info "  Accès     : pct enter ${VMID}"
info "  Logs      : pct exec ${VMID} -- journalctl -u bookorbit -f"
