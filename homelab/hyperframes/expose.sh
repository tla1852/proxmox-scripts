#!/usr/bin/env bash
#
# expose.sh — expose le Studio HyperFrames en https://hyperframes.ts.tlagrange.pro
# (sur l'hôte Proxmox, en root). Modifie les confs LIVE par ajout ciblé, jamais
# par écrasement : chaque étape montre le diff, demande confirmation, garde une
# sauvegarde .bak-<date> et revient en arrière si la validation échoue.
#
#   1. Caddy interne (CT 100)  : vhost → <ip-studio>:8080
#   2. Headscale (CT 145)      : extra_record MagicDNS → 100.64.0.2
#   3. (option) accès bureau   : vhost dans le bloc « ACCÈS BUREAU » de l'edge
#      (CT 144, Authelia) + CNAME public Gandi hyperframes.ts → DDNS
#
# Idempotent : une étape déjà faite est sautée.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/hyperframes/expose.sh)

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

NAME="hyperframes.ts.tlagrange.pro"
STUDIO_CT="${STUDIO_CT:-127}"
CADDY_CT="${CADDY_CT:-100}"
HEADSCALE_CT="${HEADSCALE_CT:-145}"
EDGE_CT="${EDGE_CT:-144}"
CADDY_FILE="/opt/caddy-internal/Caddyfile"
HEADSCALE_FILE="/opt/headscale/config/config.yaml"
EDGE_FILE="/opt/caddy/Caddyfile"
STAMP=$(date +%Y%m%d-%H%M%S)

STUDIO_IP=$(pct exec "$STUDIO_CT" -- hostname -I | awk '{print $1}')
[[ -n "$STUDIO_IP" ]] || err "IP du CT ${STUDIO_CT} introuvable."
pct exec "$STUDIO_CT" -- curl -fsS -m5 http://localhost:8080/api/health >/dev/null \
    || err "Le Studio ne répond pas dans le CT ${STUDIO_CT}."
info "Studio : CT ${STUDIO_CT}, ${STUDIO_IP}:8080"

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
info "1/3 Caddy interne (CT ${CADDY_CT})"
if pct exec "$CADDY_CT" -- grep -q "^${NAME} {" "$CADDY_FILE"; then
    info "Vhost déjà présent, rien à faire."
else
    pct exec "$CADDY_CT" -- cat "$CADDY_FILE" > "$TMP/internal"
    printf '\n# HyperFrames Studio — prompt → vidéo MP4 (CT %s)\n%s {\n\treverse_proxy %s:8080\n}\n' \
        "$STUDIO_CT" "$NAME" "$STUDIO_IP" >> "$TMP/internal"
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
info "2/3 MagicDNS Headscale (CT ${HEADSCALE_CT})"
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

# ----- 3. Accès bureau (option) -----
info "3/3 Accès bureau (edge CT ${EDGE_CT} + Authelia + CNAME public)"
if confirm "Rendre aussi le Studio accessible depuis le bureau (IP bureau + Authelia 2FA) ?"; then
    if pct exec "$EDGE_CT" -- grep -q "^${NAME}," "$EDGE_FILE"; then
        info "Vhost bureau déjà présent sur l'edge."
    else
        pct exec "$EDGE_CT" -- cat "$EDGE_FILE" > "$TMP/edge"
        grep -q '^clashbuzz-studio\.ts\.tlagrange\.pro,$' "$TMP/edge" \
            || err "Ligne d'ancrage clashbuzz-studio.ts.tlagrange.pro, absente du Caddyfile edge : ajout manuel."
        sed "s|^clashbuzz-studio\.ts\.tlagrange\.pro,$|&\n${NAME},|" "$TMP/edge" > "$TMP/edge.new"
        if apply_file "$EDGE_CT" "$EDGE_FILE" "$TMP/edge.new"; then
            if pct exec "$EDGE_CT" -- bash -c "cd /opt/caddy && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile"; then
                info "Edge rechargé."
            else
                restore "$EDGE_CT" "$EDGE_FILE"
                pct exec "$EDGE_CT" -- bash -c "cd /opt/caddy && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile" || true
                err "Reload edge refusé : Caddyfile edge restauré."
            fi
        fi
    fi
    read -rsp "Jeton Gandi LiveDNS (vide = sauter le CNAME) : " GANDI_API_TOKEN; echo
    if [[ -n "$GANDI_API_TOKEN" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
            -H "Authorization: Bearer ${GANDI_API_TOKEN}" -H 'Content-Type: application/json' \
            -d '{"rrset_values":["survivalmode.familyds.org."],"rrset_ttl":300}' \
            "https://api.gandi.net/v5/livedns/domains/tlagrange.pro/records/hyperframes.ts/CNAME")
        unset GANDI_API_TOKEN
        [[ "$code" =~ ^20 ]] && info "CNAME hyperframes.ts → survivalmode.familyds.org (${code})." \
                             || warn "CNAME Gandi : HTTP ${code}."
    else
        warn "CNAME non créé : le bureau ne résoudra pas ${NAME}."
    fi
else
    info "Accès bureau non activé (tailnet uniquement)."
fi

echo
info "Terminé."
info "  Tailnet : https://${NAME}   (MagicDNS → Caddy interne → ${STUDIO_IP}:8080)"
info "  Test    : curl -sI https://${NAME}/api/health  depuis un appareil du tailnet"
info "  Rappel  : réserver le bail DHCP ${STUDIO_IP} (CT ${STUDIO_CT}) sur la box"
