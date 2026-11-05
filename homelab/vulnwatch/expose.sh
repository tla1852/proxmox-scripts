#!/usr/bin/env bash
#
# expose.sh — expose vulnwatch en https://vulnwatch.ts.tlagrange.pro, TAILNET UNIQUEMENT
# (sur l'hôte Proxmox, en root). Modifie les confs LIVE par ajout ciblé, jamais par
# écrasement : chaque étape montre le diff, demande confirmation, garde une
# sauvegarde .bak-<date> et revient en arrière si la validation échoue.
#
#   1. Caddy interne (CT 100) : vhost filtré remote_ip 100.64.0.0/10 → <ip-vulnwatch>:8080
#   2. Headscale (CT 145)     : extra_record MagicDNS → 100.64.0.2
#
# Volontairement PAS d'accès bureau (edge/Authelia) ni de CNAME public : l'UI pilote des
# mises à jour root sur tout le homelab. Défense en profondeur côté app : seul le Caddy
# interne est accepté comme pair TCP, et le client (X-Forwarded-For) doit être en 100.64.0.0/10.
#
# Idempotent : une étape déjà faite est sautée.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/vulnwatch/expose.sh)

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

NAME="vulnwatch.ts.tlagrange.pro"
VW_CT="${VW_CT:-$(pct list | awk '$3 == "vulnwatch" {print $1}')}"
[[ -n "$VW_CT" ]] || err "CT vulnwatch introuvable (VW_CT=<id>)."
CADDY_CT="${CADDY_CT:-100}"
HEADSCALE_CT="${HEADSCALE_CT:-145}"
CADDY_FILE="/opt/caddy-internal/Caddyfile"
HEADSCALE_FILE="/opt/headscale/config/config.yaml"
STAMP=$(date +%Y%m%d-%H%M%S)

VW_IP=$(pct exec "$VW_CT" -- hostname -I | awk '{print $1}')
[[ -n "$VW_IP" ]] || err "IP du CT ${VW_CT} introuvable."
pct exec "$VW_CT" -- curl -fsS -m5 http://127.0.0.1:8080/health >/dev/null \
    || err "vulnwatch ne répond pas dans le CT ${VW_CT}."
info "vulnwatch : CT ${VW_CT}, ${VW_IP}:8080"

confirm() { local r; read -rp "$1 [o/N] : " r; [[ "$r" =~ ^[oOyY]$ ]]; }

# Montre le diff live → candidat, demande, sauvegarde, écrit EN PLACE (même
# inode : les Caddyfile sont bind-montés fichier par fichier dans Docker).
apply_file() { # <ct> <fichier live> <fichier candidat local>
    local ct=$1 live=$2 cand=$3
    pct exec "$ct" -- cat "$live" | diff -u --label "live" --label "nouveau" - "$cand" || true
    confirm "Appliquer sur CT ${ct}:${live} ?" || { warn "Étape sautée."; return 1; }
    pct exec "$ct" -- cp -p "$live" "${live}.bak-${STAMP}"
    pct exec "$ct" -- bash -c "cat > '$live'" < "$cand"
    info "Écrit (sauvegarde ${live}.bak-${STAMP})."
}
restore() { pct exec "$1" -- bash -c "cat '${2}.bak-${STAMP}' > '$2'"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ----- 1. Caddy interne -----
info "1/2 Caddy interne (CT ${CADDY_CT})"
if pct exec "$CADDY_CT" -- grep -q "^${NAME} {" "$CADDY_FILE"; then
    info "Vhost déjà présent, rien à faire."
else
    pct exec "$CADDY_CT" -- cat "$CADDY_FILE" > "$TMP/internal"
    printf '\n# vulnwatch — veille CVE + MAJ à distance (CT %s). TAILNET SEULEMENT : pas d\x27edge, 403 hors 100.64.0.0/10\n%s {\n\t@tailnet remote_ip 100.64.0.0/10\n\thandle @tailnet {\n\t\treverse_proxy %s:8080\n\t}\n\trespond 403\n}\n' \
        "$VW_CT" "$NAME" "$VW_IP" >> "$TMP/internal"
    if apply_file "$CADDY_CT" "$CADDY_FILE" "$TMP/internal"; then
        if pct exec "$CADDY_CT" -- docker exec caddy-internal caddy reload --config /etc/caddy/Caddyfile; then
            info "Caddy interne rechargé (le cert LE DNS-01 arrive en ~1 min)."
        else
            restore "$CADDY_CT" "$CADDY_FILE"
            pct exec "$CADDY_CT" -- docker exec caddy-internal caddy reload --config /etc/caddy/Caddyfile || true
            err "Reload refusé : Caddyfile interne restauré."
        fi
    fi
fi

# ----- 2. Headscale extra_record -----
info "2/2 MagicDNS Headscale (CT ${HEADSCALE_CT})"
if pct exec "$HEADSCALE_CT" -- grep -q "\"${NAME}\"" "$HEADSCALE_FILE"; then
    info "extra_record déjà présent, rien à faire."
else
    pct exec "$HEADSCALE_CT" -- cat "$HEADSCALE_FILE" > "$TMP/hs"
    # Insère après le dernier record *.ts.tlagrange.pro, avec la même indentation
    last=$(grep -n 'name: *"[a-z0-9-]*\.ts\.tlagrange\.pro"' "$TMP/hs" | tail -1 | cut -d: -f1)
    [[ -n "$last" ]] || err "Aucun extra_record *.ts.tlagrange.pro trouvé dans ${HEADSCALE_FILE} : ajout manuel."
    indent=$(sed -n "${last}p" "$TMP/hs" | sed -E 's/^([[:space:]]*).*/\1/')
    awk -v n="$last" -v l="${indent}- { name: \"${NAME}\", type: A, value: \"100.64.0.2\" }" \
        '{print} NR==n{print l}' "$TMP/hs" > "$TMP/hs.new"
    if apply_file "$HEADSCALE_CT" "$HEADSCALE_FILE" "$TMP/hs.new"; then
        pct exec "$HEADSCALE_CT" -- docker restart headscale >/dev/null
        sleep 5
        if pct exec "$HEADSCALE_CT" -- docker inspect -f '{{.State.Running}}' headscale | grep -q true \
           && ! pct exec "$HEADSCALE_CT" -- docker inspect -f '{{.State.Restarting}}' headscale | grep -q true; then
            info "Headscale redémarré."
        else
            restore "$HEADSCALE_CT" "$HEADSCALE_FILE"
            pct exec "$HEADSCALE_CT" -- docker restart headscale >/dev/null || true
            err "Headscale ne redémarre pas : config restaurée (docker logs headscale)."
        fi
    fi
fi

echo
info "Terminé."
info "  Tailnet : https://${NAME}   (MagicDNS → Caddy interne → ${VW_IP}:8080)"
info "  Test    : depuis le tailnet, https://${NAME} → page de connexion ; depuis le LAN direct → 403"
info "  Rappel  : réserver le bail DHCP ${VW_IP} (CT ${VW_CT}) : les agents n'acceptent que cette IP"
