#!/usr/bin/env bash
#
# expose.sh — expose Immich en https://photos.survivalmode.familyds.org via
# l'edge (CT 144 : Caddy + CrowdSec), sur l'hôte Proxmox en root. Modifie les
# confs LIVE par ajout ciblé, jamais par écrasement : chaque étape montre le
# diff, demande confirmation, garde une sauvegarde .bak-<date> et revient en
# arrière si la validation échoue.
#
#   1. Firewall edge (/etc/pve/firewall/144.fw) : sortie vers <ip-immich>:2283
#   2. Caddyfile edge : vhost public photos.survivalmode.familyds.org
#
# Pas d'Authelia devant : l'app mobile et les liens de partage ne savent pas
# la traverser. Protection = auth Immich + CrowdSec (snippet « prot »).
# DNS : rien à faire, *.survivalmode.familyds.org est le wildcard DDNS Synology.
#
# Idempotent : une étape déjà faite est sautée.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/immich/expose.sh) <VMID>

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

NAME="photos.survivalmode.familyds.org"
IMMICH_CT="${1:-}"
[[ -n "$IMMICH_CT" ]] || err "Usage : expose.sh <VMID du CT Immich>"
EDGE_CT="${EDGE_CT:-144}"
PORT="2283"
EDGE_FILE="/opt/caddy/Caddyfile"
FW_FILE="/etc/pve/firewall/${EDGE_CT}.fw"
STAMP=$(date +%Y%m%d-%H%M%S)

IMMICH_IP=$(pct exec "$IMMICH_CT" -- hostname -I | awk '{print $1}')
[[ -n "$IMMICH_IP" ]] || err "IP du CT ${IMMICH_CT} introuvable."
pct exec "$IMMICH_CT" -- curl -fsS -m5 "http://localhost:${PORT}/api/server/ping" >/dev/null \
    || err "Immich ne répond pas dans le CT ${IMMICH_CT}."
info "Immich : CT ${IMMICH_CT}, ${IMMICH_IP}:${PORT}"

confirm() { local r; read -rp "$1 [o/N] : " r; [[ "$r" =~ ^[oOyY]$ ]]; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ----- 1. Firewall edge -----
info "1/2 Firewall edge (${FW_FILE})"
if grep -q "^OUT ACCEPT -dest ${IMMICH_IP} -p tcp -dport ${PORT}$" "$FW_FILE"; then
    info "Règle déjà présente, rien à faire."
else
    anchor='^# --- Sortant : accès bureau'
    grep -q "$anchor" "$FW_FILE" || err "Ligne d'ancrage « # --- Sortant : accès bureau » absente de ${FW_FILE} : ajout manuel."
    awk -v ip="$IMMICH_IP" -v port="$PORT" -v a="$anchor" \
        '$0 ~ a && !done {print "# Immich (vhost photos.survivalmode.familyds.org)"; print "OUT ACCEPT -dest " ip " -p tcp -dport " port; print ""; done=1} {print}' \
        "$FW_FILE" > "$TMP/fw"
    diff -u --label "live" --label "nouveau" "$FW_FILE" "$TMP/fw" || true
    if confirm "Appliquer sur ${FW_FILE} ?"; then
        cp -p "$FW_FILE" "/root/$(basename "$FW_FILE").bak-${STAMP}"
        cat "$TMP/fw" > "$FW_FILE"
        if pve-firewall compile >/dev/null 2>&1; then
            info "Firewall mis à jour (sauvegarde /root/$(basename "$FW_FILE").bak-${STAMP})."
        else
            cat "/root/$(basename "$FW_FILE").bak-${STAMP}" > "$FW_FILE"
            err "pve-firewall compile en échec : ${FW_FILE} restauré."
        fi
    else
        warn "Étape sautée : l'edge ne pourra pas joindre Immich."
    fi
fi

# ----- 2. Caddyfile edge -----
info "2/2 Caddyfile edge (CT ${EDGE_CT})"
if pct exec "$EDGE_CT" -- grep -q "^${NAME} {" "$EDGE_FILE"; then
    info "Vhost déjà présent, rien à faire."
else
    pct exec "$EDGE_CT" -- cat "$EDGE_FILE" > "$TMP/edge"
    grep -q '^(prot) {' "$TMP/edge" || err "Snippet (prot) absent du Caddyfile edge : ajout manuel."
    printf '\n# ===== Immich (photos) — public, sans Authelia (app mobile + liens de partage) =====\n%s {\n\timport prot\n\treverse_proxy %s:%s\n}\n' \
        "$NAME" "$IMMICH_IP" "$PORT" >> "$TMP/edge"
    pct exec "$EDGE_CT" -- cat "$EDGE_FILE" | diff -u --label "live" --label "nouveau" - "$TMP/edge" || true
    if confirm "Appliquer sur CT ${EDGE_CT}:${EDGE_FILE} ?"; then
        pct exec "$EDGE_CT" -- cp -p "$EDGE_FILE" "${EDGE_FILE}.bak-${STAMP}"
        # Écriture EN PLACE (même inode : Caddyfile bind-monté fichier par fichier)
        pct exec "$EDGE_CT" -- bash -c "cat > '$EDGE_FILE'" < "$TMP/edge"
        if pct exec "$EDGE_CT" -- bash -c "cd /opt/caddy && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile"; then
            info "Edge rechargé (cert Let's Encrypt HTTP-01 en ~1 min)."
        else
            pct exec "$EDGE_CT" -- bash -c "cat '${EDGE_FILE}.bak-${STAMP}' > '$EDGE_FILE'"
            pct exec "$EDGE_CT" -- bash -c "cd /opt/caddy && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile" || true
            err "Reload edge refusé : Caddyfile edge restauré."
        fi
    else
        warn "Étape sautée."
    fi
fi

echo
info "Terminé."
info "  Public : https://${NAME}   (edge CT ${EDGE_CT} → ${IMMICH_IP}:${PORT})"
info "  Test   : curl -s https://${NAME}/api/server/ping   → {\"res\":\"pong\"}"
info "  Mobile : app Immich → URL du serveur https://${NAME}"
info "  Bans   : pct exec ${EDGE_CT} -- docker exec crowdsec cscli decisions list"
warn "Penser à reporter la règle 144.fw et le vhost dans le repo (homelab/edge/)."
