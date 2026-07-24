#!/usr/bin/env bash
#
# setup-app.sh — couche applicative ClashBuzz Studio (web UI admin de la
# bibliothèque de playlists : génération Deezer/YouTube, comptes dédiés),
# appliquée à un CT existant (créé par create-lxc-clashbuzz-studio.sh, qui
# appelle ce script). Relançable tel quel si le run précédent a échoué :
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/clashbuzz-studio/setup-app.sh) <VMID>
#
# - Node 22 (NodeSource) + corepack/pnpm dans le CT
# - clone de tla1852/blindtest (repo privé : PAT GitHub demandé, mémorisé dans
#   le credential store git de thibault pour les mises à jour)
# - pnpm install + build de apps/studio, service systemd clashbuzz-studio
#   (port 8090, données/secrets dans /home/thibault/studio-data)
#
# Après coup : entrée Caddy interne clashbuzz-studio.ts.tlagrange.pro →
# <ip-ct>:8090 (tailnet only) + DNS extra-records — cf. README.md.

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

VMID="${1:-}"
[[ -n "$VMID" ]] || err "Usage : setup-app.sh <VMID> (CT créé par create-lxc-clashbuzz-studio.sh)"
pct status "$VMID" 2>/dev/null | grep -q running || err "CT ${VMID} introuvable ou arrêté (pct status ${VMID})."
pct exec "$VMID" -- id thibault >/dev/null 2>&1 || err "Utilisateur thibault absent dans le CT ${VMID} : socle incomplet."

REPO="tla1852/blindtest"
APP_DIR="/home/thibault/blindtest"
APP_PORT="8090"

info "Configuration de ClashBuzz Studio (CT ${VMID})..."

read -rsp "PAT GitHub (accès lecture au repo privé ${REPO}) : " GH_PAT; echo
[[ -n "$GH_PAT" ]] || err "PAT requis pour cloner ${REPO} (repo privé)."

# ----- Node 22 (NodeSource) + corepack/pnpm -----
if pct exec "$VMID" -- bash -c "command -v node && node -v | grep -q '^v22'" >/dev/null 2>&1; then
    info "Node 22 déjà présent."
else
    info "Installation de Node 22 (NodeSource)..."
    pct exec "$VMID" -- bash -c "export DEBIAN_FRONTEND=noninteractive
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
        apt-get -y -qq install nodejs"
fi
info "Node : $(pct exec "$VMID" -- node -v)"
pct exec "$VMID" -- corepack enable >/dev/null 2>&1 || true

# ----- Clone / mise à jour du repo (en thibault, PAT dans le credential store) -----
info "Clone de ${REPO}..."
pct exec "$VMID" -- su - thibault -c "
    set -euo pipefail
    git config --global credential.helper store
    printf 'https://tla1852:%s@github.com\n' '${GH_PAT}' > ~/.git-credentials
    chmod 600 ~/.git-credentials
    if [[ -d '${APP_DIR}/.git' ]]; then
        git -C '${APP_DIR}' pull --ff-only
    else
        git clone 'https://github.com/${REPO}.git' '${APP_DIR}'
    fi
"
unset GH_PAT

# ----- Build (pnpm via corepack, workspace filtré sur le studio) -----
info "pnpm install + build (apps/studio)..."
pct exec "$VMID" -- su - thibault -c "
    set -euo pipefail
    cd '${APP_DIR}'
    corepack pnpm install --filter @blindtest/studio --frozen-lockfile=false --no-optional 2>&1 | tail -2
    corepack pnpm --filter @blindtest/studio build
    mkdir -p /home/thibault/studio-data
"

# ----- Service systemd -----
info "Installation du service systemd..."
pct exec "$VMID" -- bash -c "cp '${APP_DIR}/deploy/clashbuzz-studio.service' /etc/systemd/system/clashbuzz-studio.service
    systemctl daemon-reload
    systemctl enable clashbuzz-studio
    systemctl restart clashbuzz-studio"

# ----- Vérification -----
sleep 3
if pct exec "$VMID" -- curl -fsS -m5 "http://localhost:${APP_PORT}/api/settings" | grep -q 'baseUrl'; then
    CT_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
    echo
    info "ClashBuzz Studio opérationnel !"
    info "  UI      : http://${CT_IP}:${APP_PORT}"
    info "  Suite   : vhost Caddy interne  clashbuzz-studio.ts.tlagrange.pro → ${CT_IP}:${APP_PORT}  (cf. README)"
    info "  Service : pct exec ${VMID} -- systemctl status clashbuzz-studio"
else
    err "Le service ne répond pas : pct exec ${VMID} -- journalctl -u clashbuzz-studio -n 30"
fi
