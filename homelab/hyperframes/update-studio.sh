#!/usr/bin/env bash
#
# update-studio.sh — met à jour le Studio HyperFrames (CT 127) et branche ses
# sources : repos GitHub (jeton lecture seule) + journal Télescope (L5, jeton
# lecture seule généré ici et posé des deux côtés). Sur l'hôte Proxmox, en root.
# Relançable : un jeton déjà posé est conservé si la saisie est vide.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/hyperframes/update-studio.sh) [ref]
#
# [ref] = commit/branche de proxmox-scripts à déployer (défaut : main)

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

REF="${1:-main}"
STUDIO_CT="${STUDIO_CT:-127}"
L5_CT="${L5_CT:-143}"
L5_DIR="/opt/l5"
L5_URL_VAL="${L5_URL_VAL:-http://192.168.1.43:3000}"
SRC="https://raw.githubusercontent.com/tla1852/proxmox-scripts/${REF}/homelab/hyperframes/studio"
ENVF="/etc/hyperframes-studio.env"

pct exec "$STUDIO_CT" -- test -f /opt/hyperframes-studio/server.mjs || err "Studio absent du CT ${STUDIO_CT}."
pct exec "$L5_CT" -- test -f "${L5_DIR}/docker-compose.yml" || err "Télescope (${L5_DIR}) absent du CT ${L5_CT} : préciser L5_CT=<id>."

# Écrit / remplace une clé du fichier d'env du Studio sans toucher aux autres
set_env() {
    [[ -n "$2" ]] || return 0
    printf '%s' "$2" | pct exec "$STUDIO_CT" -- bash -c "v=\$(cat); f=${ENVF}
        grep -v '^$1=' \$f > \$f.tmp || true; printf '%s=%s\n' '$1' \"\$v\" >> \$f.tmp
        cat \$f.tmp > \$f; rm -f \$f.tmp; chmod 600 \$f"
}

# ----- 1. Télescope : code à jour + jeton lecture seule -----
info "1/3 Télescope (CT ${L5_CT}) : mise à jour + jeton lecture seule..."
if pct exec "$L5_CT" -- grep -q '^L5_API_READ_TOKEN=.' "${L5_DIR}/.env"; then
    info "Jeton lecture seule déjà présent côté Télescope, conservé."
    L5_READ=$(pct exec "$L5_CT" -- sed -n 's/^L5_API_READ_TOKEN=//p' "${L5_DIR}/.env" | head -1)
else
    L5_READ=$(openssl rand -hex 32)
    printf '%s' "$L5_READ" | pct exec "$L5_CT" -- bash -c "v=\$(cat); f=${L5_DIR}/.env
        grep -v '^L5_API_READ_TOKEN=' \$f > \$f.tmp || true; printf 'L5_API_READ_TOKEN=%s\n' \"\$v\" >> \$f.tmp
        cat \$f.tmp > \$f; rm -f \$f.tmp"
fi
pct exec "$L5_CT" -- bash -c "cd ${L5_DIR} && git pull -q --ff-only && docker compose up -d --build api >/dev/null 2>&1" \
    || err "Rebuild Télescope en échec : pct exec ${L5_CT} -- bash -c 'cd ${L5_DIR} && docker compose logs --tail 30 api'"
info "Télescope reconstruit."

# ----- 2. Studio : code + secrets -----
info "2/3 Studio (CT ${STUDIO_CT}) : code ${REF} + secrets..."
pct exec "$STUDIO_CT" -- bash -c "for f in server.mjs index.html; do curl -fsSL -o /opt/hyperframes-studio/\$f.new ${SRC}/\$f && mv /opt/hyperframes-studio/\$f.new /opt/hyperframes-studio/\$f; done"
pct exec "$STUDIO_CT" -- install -d -o studio -g studio /srv/studio/repos
read -rsp "Jeton GitHub fine-grained lecture seule (vide = garder l'actuel) : " GH_TOKEN; echo
set_env GITHUB_TOKEN "$GH_TOKEN"
set_env L5_READ_TOKEN "$L5_READ"
set_env L5_URL "$L5_URL_VAL"
unset GH_TOKEN L5_READ
pct exec "$STUDIO_CT" -- systemctl restart hyperframes-studio

# ----- 3. Vérifications -----
info "3/3 Vérifications..."
sleep 8
N=$(pct exec "$STUDIO_CT" -- curl -fsS -m 20 http://localhost:8080/api/projects 2>/dev/null | grep -o '"name"' | wc -l || true)
[[ "$N" -gt 0 ]] && info "GitHub : ${N} repos visibles." || warn "GitHub : aucun repo (jeton absent ou refusé) : pct exec ${STUDIO_CT} -- journalctl -u hyperframes-studio -n 20"
CODE=$(pct exec "$STUDIO_CT" -- bash -c "set -a; . ${ENVF}; curl -s -o /dev/null -w '%{http_code}' -m 10 -H \"Authorization: Bearer \$L5_READ_TOKEN\" \"\$L5_URL/api/notes?projet_ref=blindtest&limit=1\"")
[[ "$CODE" == 200 ]] && info "Télescope : journal lisible (HTTP 200)." || warn "Télescope : HTTP ${CODE} sur /api/notes."

echo
info "Studio à jour : https://hyperframes.ts.tlagrange.pro (cocher les projets de référence)."
