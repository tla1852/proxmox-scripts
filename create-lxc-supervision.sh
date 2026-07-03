#!/usr/bin/env bash
#
# create-lxc-supervision.sh — LXC Ubuntu 24.04 + stack de supervision
# (Prometheus + Grafana + pve-exporter + blackbox, Docker Compose)
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
# - Puis : node_exporter sur l'HÔTE PVE, user API monitoring@pve + token
#          PVEAuditor, clone du repo, secrets, docker compose up
#          (voir homelab/supervision/README.md)
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-supervision.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="16"           # TSDB Prometheus (rétention 90j) + Grafana (skill : variable)
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts skill : supervision / 2 / 2048)
read -rp "Nom du container (hostname) [supervision] : " CT_NAME; CT_NAME="${CT_NAME:-supervision}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [2] : " CT_CORES; CT_CORES="${CT_CORES:-2}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (ex: 2048) [2048] : " CT_RAM; CT_RAM="${CT_RAM:-2048}"
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
# COUCHE APPLICATIVE — SUPERVISION (le socle ci-dessus fournit Docker + nesting)
# ═════════════════════════════════════════════════════════════════════════════
REPO_URL="https://github.com/tla1852/proxmox-scripts.git"
CLONE_DIR="/opt/proxmox-scripts"
APP_DIR="${CLONE_DIR}/homelab/supervision"

info "Configuration de la stack de supervision..."

# Secrets d'exécution (voir homelab/supervision/README.md pour où les trouver)
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
if ! systemctl is-active --quiet prometheus-node-exporter 2>/dev/null; then
    info "Installation de prometheus-node-exporter sur l'hôte PVE..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get -y -qq install prometheus-node-exporter
    systemctl enable --now prometheus-node-exporter
else
    info "prometheus-node-exporter déjà actif sur l'hôte."
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
    chmod 600 .env secrets/pve.yml secrets/gcp_scrape_password
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
