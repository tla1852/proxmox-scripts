#!/usr/bin/env bash
#
# update-lxc-bookorbit.sh — Met à jour BookOrbit dans un CT existant
#
# Reprend la logique d'install de create-lxc-bookorbit.sh : récupère la
# dernière release GitHub bookorbit/bookorbit, rebuild (pnpm client+server),
# relance le service systemd. Les migrations DB tournent via ExecStartPre.
#
# Préserve : /opt/bookorbit/.env (secrets), /opt/bookorbit-data,
# /opt/bookorbit-books, /opt/bookorbit-python, PostgreSQL.
#
# Idempotent : si déjà à la dernière version, ne fait rien (sauf --force).
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/update-lxc-bookorbit.sh) <VMID> [--force] [--no-snapshot]

set -euo pipefail

GH_REPO="bookorbit/bookorbit"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Arguments -----
VMID=""
FORCE=0
SNAPSHOT=1
for arg in "$@"; do
    case "$arg" in
        --force)       FORCE=1 ;;
        --no-snapshot) SNAPSHOT=0 ;;
        [0-9]*)        VMID="$arg" ;;
        *)             err "Argument inconnu : $arg" ;;
    esac
done
[[ -n "$VMID" ]] || err "Usage : $0 <VMID> [--force] [--no-snapshot]"
pct status "$VMID" >/dev/null 2>&1 || err "Container $VMID introuvable."
pct exec "$VMID" -- test -f /opt/bookorbit/.env || err "BookOrbit absent du CT $VMID (/opt/bookorbit/.env manquant)."

# ----- Vérif version (idempotence) -----
info "Vérification de la dernière release ${GH_REPO}..."
API="https://api.github.com/repos/${GH_REPO}/releases/latest"
LATEST=$(curl -fsSL "$API" | jq -r '.tag_name')
[[ -n "$LATEST" && "$LATEST" != "null" ]] || err "Impossible de récupérer la dernière release."
CURRENT=$(pct exec "$VMID" -- bash -c "cat ~/.bookorbit 2>/dev/null || echo inconnue")
info "Version actuelle : ${CURRENT} — dernière : ${LATEST}"
if [[ "$CURRENT" == "$LATEST" && $FORCE -eq 0 ]]; then
    info "Déjà à jour. Rien à faire (utilise --force pour rebuild quand même)."
    exit 0
fi

# ----- Snapshot de sécurité -----
if [[ $SNAPSHOT -eq 1 ]]; then
    SNAP="premaj_$(date +%Y%m%d_%H%M%S)"
    info "Snapshot ${SNAP}..."
    pct snapshot "$VMID" "$SNAP" --description "Avant MAJ BookOrbit ${CURRENT} -> ${LATEST}" \
        || info "Snapshot impossible (storage sans support snapshot ?), on continue."
fi

# ----- MAJ dans le container -----
info "Mise à jour vers ${LATEST} (peut durer plusieurs minutes)..."
pct exec "$VMID" -- env GH_REPO="$GH_REPO" bash -s <<'UPDATE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:$PATH"

API="https://api.github.com/repos/${GH_REPO}/releases/latest"
APP_VER=$(curl -fsSL "$API" | jq -r '.tag_name')
TARBALL=$(curl -fsSL "$API" | jq -r '.tarball_url')
[[ -n "$APP_VER" && "$APP_VER" != "null" ]] || { echo "Pas de release trouvée"; exit 1; }

echo ">> Arrêt du service"
systemctl stop bookorbit

echo ">> Sauvegarde du .env"
cp /opt/bookorbit/.env /root/bookorbit.env.bak

echo ">> Remplacement du code (data et .env préservés)"
# Purge le code applicatif uniquement ; les dossiers data sont hors /opt/bookorbit.
find /opt/bookorbit -mindepth 1 -maxdepth 1 ! -name '.env' -exec rm -rf {} +
curl -fsSL "$TARBALL" -o /tmp/bookorbit.tar.gz
tar -xzf /tmp/bookorbit.tar.gz -C /opt/bookorbit --strip-components=1
rm -f /tmp/bookorbit.tar.gz

echo ">> Build pnpm"
cd /opt/bookorbit
PNPM_VERSION=$(jq -r '.packageManager | ltrimstr("pnpm@")' package.json)
corepack enable
corepack prepare "pnpm@${PNPM_VERSION}" --activate
pnpm install --frozen-lockfile
pnpm --filter client run build-only
pnpm --filter server run build
cp -r /opt/bookorbit/client/dist /opt/bookorbit/server/public
mkdir -p /opt/bookorbit/server/migrations
cp -r /opt/bookorbit/server/src/db/migrations/. /opt/bookorbit/server/migrations/
chmod +x /opt/bookorbit/server/bin/kepubify/* || true

echo ">> Maj environnement Python (uv)"
uv pip install --python /opt/bookorbit-python/bin/python \
    -r /opt/bookorbit/server/requirements/kobo-cloudscraper.txt

echo ">> Maj APP_VERSION dans .env"
if grep -q '^APP_VERSION=' /opt/bookorbit/.env; then
    sed -i "s/^APP_VERSION=.*/APP_VERSION=${APP_VER}/" /opt/bookorbit/.env
else
    echo "APP_VERSION=${APP_VER}" >> /opt/bookorbit/.env
fi
echo "$APP_VER" > ~/.bookorbit

echo ">> Redémarrage (migrations via ExecStartPre)"
systemctl daemon-reload
systemctl start bookorbit
echo ">> BookOrbit mis à jour vers ${APP_VER}"
UPDATE

# ----- Vérif post-MAJ -----
sleep 3
if pct exec "$VMID" -- systemctl is-active --quiet bookorbit; then
    IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
    info "Terminé ! BookOrbit ${LATEST} actif : http://${IP}:3000"
    info "  Logs : pct exec ${VMID} -- journalctl -u bookorbit -f"
else
    err "Le service bookorbit n'est pas actif après MAJ. Voir : pct exec ${VMID} -- journalctl -u bookorbit -n 50"
fi
