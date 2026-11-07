#!/usr/bin/env bash
#
# setup-app.sh — couche applicative vulnwatch, appliquée à un CT existant (créé par
# create-lxc-vulnwatch.sh, qui appelle ce script). Sur l'hôte Proxmox, en root.
# Relançable : sert aussi de MISE À JOUR (git pull + deploy/install.sh, conf conservée).
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/vulnwatch/setup-app.sh) <VMID>
#
# 1re installation seulement :
# - rôle Proxmox VulnWatch (VM.Audit, VM.GuestAgent.Audit|VM.Monitor, VM.Snapshot,
#   VM.Snapshot.Rollback, Sys.Audit) + user vulnwatch@pve + token « scan »
#   -> ni console, ni modification de config, ni création/suppression d'invité
# - CA Proxmox copié dans le CT (vérification TLS de l'API)
# - mot de passe web généré (affiché + /root/vulnwatch-password.txt dans le CT)
# - secret webhook L5 lu dans /opt/l5/.env du CT L5 (SUPERVISION_WEBHOOK_SECRET)
# Toujours :
# - clone/pull de tla1852/vulnwatch (repo privé : PAT demandé, jamais stocké)
# - deploy/install.sh dans le CT (Trivy, skopeo, venv, systemd)

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

VMID="${1:-}"
[[ -n "$VMID" ]] || err "Usage : setup-app.sh <VMID> (CT créé par create-lxc-vulnwatch.sh)"
pct status "$VMID" 2>/dev/null | grep -q running || err "CT ${VMID} introuvable ou arrêté."

REPO="tla1852/vulnwatch"
APP_DIR="/opt/vulnwatch/app"
L5_CT="${L5_CT:-143}"
L5_URL="${L5_URL:-http://192.168.1.43:3000}"
CADDY_INTERNAL_IP="${CADDY_INTERNAL_IP:-192.168.1.72}"
PVE_USER="vulnwatch@pve"
PVE_ROLE="VulnWatch"

FIRST=1
pct exec "$VMID" -- test -f /etc/vulnwatch/env && FIRST=0

read -rsp "PAT GitHub (lecture du repo privé ${REPO}) : " GH_PAT; echo
[[ -n "$GH_PAT" ]] || err "PAT requis pour cloner ${REPO}."

# ----- Code -----
info "Récupération de ${REPO}..."
pct exec "$VMID" -- env GH_PAT="$GH_PAT" REPO="$REPO" APP_DIR="$APP_DIR" bash -s <<'CLONE'
set -euo pipefail
url="https://x-access-token:${GH_PAT}@github.com/${REPO}.git"
if [[ -d "$APP_DIR/.git" ]]; then
    git -C "$APP_DIR" pull -q --ff-only "$url" main
else
    mkdir -p "$(dirname "$APP_DIR")"
    git clone -q "$url" "$APP_DIR"
    git -C "$APP_DIR" remote set-url origin "https://github.com/${REPO}.git"   # pas de jeton sur disque
fi
git -C "$APP_DIR" log --oneline -1
CLONE
unset GH_PAT

if [[ $FIRST -eq 0 ]]; then
    info "Conf existante conservée : mise à jour du code seulement."
    pct exec "$VMID" -- bash "$APP_DIR/deploy/install.sh"
    info "vulnwatch mis à jour (CT ${VMID})."
    exit 0
fi

# ----- Rôle + token Proxmox (moindre privilège) -----
info "Rôle ${PVE_ROLE} + ${PVE_USER} + token 'scan'..."
PRIVS="VM.Audit,VM.GuestAgent.Audit,VM.Snapshot,VM.Snapshot.Rollback,Sys.Audit"
pveum role add "$PVE_ROLE" --privs "$PRIVS" 2>/dev/null \
  || pveum role modify "$PVE_ROLE" --privs "$PRIVS" 2>/dev/null \
  || { PRIVS="${PRIVS/VM.GuestAgent.Audit/VM.Monitor}"   # PVE 8
       pveum role add "$PVE_ROLE" --privs "$PRIVS" 2>/dev/null || pveum role modify "$PVE_ROLE" --privs "$PRIVS"; }
pveum user add "$PVE_USER" --comment "vulnwatch (audit + snapshots, CT ${VMID})" 2>/dev/null || true
pveum acl modify / --users "$PVE_USER" --roles "$PVE_ROLE"
pveum user token remove "$PVE_USER" scan 2>/dev/null || true
PVE_TOKEN_SECRET=$(pveum user token add "$PVE_USER" scan --privsep 0 --output-format json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')
[[ -n "$PVE_TOKEN_SECRET" ]] || err "Secret du token ${PVE_USER}!scan introuvable."

PVE_IP=$(ip -4 -o addr show vmbr0 | awk '{print $4}' | cut -d/ -f1 | head -n1)
[[ -n "$PVE_IP" ]] || err "IP de vmbr0 introuvable."
pct exec "$VMID" -- install -d -m 0750 /etc/vulnwatch
if [[ -f /etc/pve/local/pveproxy-ssl.pem ]]; then
    PVE_VERIFY=1     # certificat personnalisé (ACME) : CA système
else
    pct push "$VMID" /etc/pve/pve-root-ca.pem /etc/vulnwatch/pve-root-ca.pem --perms 0644
    PVE_VERIFY=/etc/vulnwatch/pve-root-ca.pem
fi

# ----- Secret webhook L5 (push lecture seule) -----
L5_SECRET=""
if pct status "$L5_CT" 2>/dev/null | grep -q running; then
    # Même ordre que L5 (routes.ts) : SUPERVISION_WEBHOOK_SECRET, sinon GRAFANA_WEBHOOK_SECRET.
    for k in SUPERVISION_WEBHOOK_SECRET GRAFANA_WEBHOOK_SECRET; do
        L5_SECRET=$(pct exec "$L5_CT" -- sed -n "s/^${k}=//p" /opt/l5/.env 2>/dev/null | tr -d '"\r' | head -n1 || true)
        [[ -n "$L5_SECRET" ]] && break
    done
fi
[[ -n "$L5_SECRET" ]] || { warn "Secret L5 introuvable (CT ${L5_CT}) : push L5 désactivé (VW_L5_* dans /etc/vulnwatch/env)."; L5_URL=""; }

WEB_PASS=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)

info "Installation dans le CT (Trivy, skopeo, venv, systemd)... quelques minutes"
pct exec "$VMID" -- env \
    VW_PVE_URL="https://${PVE_IP}:8006" VW_PVE_TOKEN_ID="${PVE_USER}!scan" VW_PVE_TOKEN_SECRET="$PVE_TOKEN_SECRET" \
    VW_PVE_HOST_IP="$PVE_IP" VW_PASSWORD="$WEB_PASS" VW_L5_URL="$L5_URL" VW_L5_SECRET="$L5_SECRET" \
    VW_ALLOWED_PEERS="${CADDY_INTERNAL_IP},127.0.0.1,::1" \
    bash "$APP_DIR/deploy/install.sh"
pct exec "$VMID" -- sed -i "s|^VW_PVE_VERIFY=.*|VW_PVE_VERIFY=${PVE_VERIFY}|" /etc/vulnwatch/env
pct exec "$VMID" -- systemctl restart vulnwatch-web
unset PVE_TOKEN_SECRET L5_SECRET

pct exec "$VMID" -- bash -c "umask 077; printf '%s\n' '${WEB_PASS}' > /root/vulnwatch-password.txt"

# Test API Proxmox depuis le CT
if pct exec "$VMID" -- sudo -u vulnwatch bash -c 'set -a; . /etc/vulnwatch/env; cd /opt/vulnwatch/app; /opt/vulnwatch/venv/bin/python -c "from vulnwatch import proxmox; print(len(proxmox.list_guests()), \"invités vus\")"'; then
    info "API Proxmox OK."
else
    warn "API Proxmox injoignable depuis le CT : vérifier VW_PVE_URL / VW_PVE_VERIFY (0 pour tester) dans /etc/vulnwatch/env."
fi

echo
info "vulnwatch installé (CT ${VMID})."
info "  Mot de passe web : ${WEB_PASS}   (aussi dans /root/vulnwatch-password.txt du CT)"
info "  Clé agent        : $(pct exec "$VMID" -- cat /var/lib/vulnwatch/.ssh/id_ed25519.pub)"
unset WEB_PASS
