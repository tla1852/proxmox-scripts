#!/usr/bin/env bash
#
# setup-app.sh — couche applicative de la stack de supervision, appliquée à un
# CT existant (créé par create-lxc-supervision.sh, qui appelle ce script).
# Relançable tel quel si le run précédent a échoué en cours de route :
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/supervision/setup-app.sh) <VMID>
#
# - node_exporter sur l'HÔTE PVE (réutilisé si quelque chose sert déjà :9100)
# - user API monitoring@pve + token 'supervision' (PVEAuditor, régénéré)
# - clone du repo dans le CT, secrets, docker compose up

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[ATTENTION]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

VMID="${1:-}"
[[ -n "$VMID" ]] || err "Usage : setup-app.sh <VMID> (CT créé par create-lxc-supervision.sh)"
pct status "$VMID" 2>/dev/null | grep -q running || err "CT ${VMID} introuvable ou arrêté (pct status ${VMID})."
pct exec "$VMID" -- docker --version >/dev/null 2>&1 || err "Docker absent dans le CT ${VMID} : socle incomplet."

REPO_URL="https://github.com/tla1852/proxmox-scripts.git"
CLONE_DIR="/opt/proxmox-scripts"
APP_DIR="${CLONE_DIR}/homelab/supervision"

info "Configuration de la stack de supervision (CT ${VMID})..."

# Secrets d'exécution (voir README.md pour où les trouver)
while true; do
    read -rsp "Mot de passe admin Grafana                                   : " GRAFANA_ADMIN_PASSWORD; echo
    read -rsp "Confirmation                                                 : " GRAFANA_ADMIN_PASSWORD2; echo
    [[ -n "$GRAFANA_ADMIN_PASSWORD" && "$GRAFANA_ADMIN_PASSWORD" == "$GRAFANA_ADMIN_PASSWORD2" ]] && break
    echo "Mots de passe vides ou différents, on recommence."
done
read -rsp "Secret webhook L5 (GRAFANA_WEBHOOK_SECRET de /opt/l5/.env)   : " SUPERVISION_WEBHOOK_SECRET; echo
[[ -n "$SUPERVISION_WEBHOOK_SECRET" ]] || err "Secret webhook requis (grep GRAFANA_WEBHOOK_SECRET /opt/l5/.env dans le CT L5)."
read -rsp "Mot de passe scrape GCP (cf. supervision-secrets.txt)        : " GCP_SCRAPE_PASSWORD; echo
[[ -n "$GCP_SCRAPE_PASSWORD" ]] || err "Mot de passe de scrape GCP requis."

# ----- node_exporter sur l'HÔTE Proxmox (détail matériel, port 9100) -----
# Si quelque chose sert déjà :9100, on ne réinstalle pas par-dessus.
if curl -fsS -m3 http://localhost:9100/metrics 2>/dev/null | grep -q '^node_'; then
    info "Un node_exporter répond déjà sur :9100 — réutilisé tel quel."
elif curl -fsS -m3 -o /dev/null http://localhost:9100/ 2>/dev/null; then
    warn "Le port 9100 est occupé par autre chose qu'un node_exporter :"
    ss -tlnp | grep ':9100 ' || true
    warn "Le job Prometheus 'node-pve' scrapera ce service — à corriger à la main."
else
    info "Installation de prometheus-node-exporter sur l'hôte PVE..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get -y -qq install prometheus-node-exporter
    systemctl enable --now prometheus-node-exporter \
        || err "prometheus-node-exporter ne démarre pas : journalctl -u prometheus-node-exporter -n 20"
fi

# ----- Utilisateur API Proxmox lecture seule + token pour pve-exporter -----
info "Création de monitoring@pve (PVEAuditor) + token 'supervision'..."
pveum user add monitoring@pve --comment "Supervision (pve-exporter, lecture seule)" 2>/dev/null || true
pveum acl modify / --users monitoring@pve --roles PVEAuditor
# Token régénéré à chaque run (idempotent) ; privsep=0 → hérite du rôle du user
pveum user token remove monitoring@pve supervision 2>/dev/null || true
PVE_TOKEN_VALUE=$(pveum user token add monitoring@pve supervision --privsep 0 --output-format json \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
[[ -n "$PVE_TOKEN_VALUE" ]] || err "Impossible de récupérer le secret du token monitoring@pve!supervision."

# ----- Clone du repo + secrets + démarrage -----
info "Clone du repo + génération des secrets..."
pct exec "$VMID" -- bash -c "
    set -e
    rm -rf '$CLONE_DIR'
    git clone -q '$REPO_URL' '$CLONE_DIR'
    cd '$APP_DIR'
    mkdir -p secrets
    cat > secrets/pve.yml <<PVE
default:
  user: monitoring@pve
  token_name: supervision
  token_value: ${PVE_TOKEN_VALUE}
  verify_ssl: false
PVE
    printf '%s' '${GCP_SCRAPE_PASSWORD}' > secrets/gcp_scrape_password
    cat > .env <<ENV
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
SUPERVISION_WEBHOOK_SECRET=${SUPERVISION_WEBHOOK_SECRET}
ENV
    chmod 600 .env
    # Les conteneurs tournent en non-root : prometheus = nobody (65534),
    # pve-exporter = user applicatif. Token PVEAuditor lecture seule et CT
    # mono-usage → lisible localement, acceptable.
    chown 65534:65534 secrets/gcp_scrape_password
    chmod 400 secrets/gcp_scrape_password
    chmod 644 secrets/pve.yml
"
unset GRAFANA_ADMIN_PASSWORD GRAFANA_ADMIN_PASSWORD2 SUPERVISION_WEBHOOK_SECRET \
      GCP_SCRAPE_PASSWORD PVE_TOKEN_VALUE

info "Démarrage (docker compose)..."
pct exec "$VMID" -- bash -c "cd '$APP_DIR' && docker compose up -d"

APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo
info "═══ Supervision déployée ═══"
info "  Prometheus : http://${APP_IP}:9090  (cibles : /targets)"
info "  Grafana    : http://${APP_IP}:3000  (admin / mot de passe saisi)"
info "  Logs       : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && docker compose logs -f'"
echo
info "Post-install (voir homelab/supervision/README.md) :"
info "  1. Vhost grafana.ts.tlagrange.pro → ${APP_IP}:3000 (Caddy interne CT 100 + extra-records headscale)"
info "  2. L5 : PROMETHEUS_URL=http://${APP_IP}:9090 et GRAFANA_URL=https://grafana.ts.tlagrange.pro dans /opt/l5/.env"
info "  3. Importer les dashboards Grafana : 1860 (node), 10347 (Proxmox), 7587 (blackbox)"
info "  4. Réserver l'IP ${APP_IP} dans la box (bail DHCP statique)"
