#!/usr/bin/env bash
#
# setup-app.sh — couche applicative Immich, appliquée à un CT existant (créé
# par create-lxc-immich.sh, qui appelle ce script). Relançable tel quel :
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/immich/setup-app.sh) <VMID>
#
# - Photos dans un dossier d'un stockage NFS Proxmox existant (défaut :
#   /mnt/pve/nas-partage/Immich, stockage « nas-partage » = 192.168.1.102:
#   /volume1/partage) passé au CT en bind mount (mp0 → /mnt/immich) : un CT non
#   privilégié ne peut pas monter de NFS lui-même. Le partage est en root squash :
#   pas de chown possible, mais le root du CT arrive en uid 100000 (non squashé)
#   et le dossier est en 777 → Immich écrit. Si le NAS manque au boot, le dossier
#   n'existe pas : le CT ne démarre pas (rien n'est écrit sur l'hôte), et Immich
#   refuse de toute façon de démarrer sans ses fichiers témoins .immich
# - Service hôte immich-nas-wait (avant pve-guests) : active le stockage et
#   attend son montage, pour que le démarrage auto du CT ne le devance pas
# - Immich IMMICH_VERSION épinglé, compose + example.env officiels de la
#   release, ML sur CPU, photos sur NFS, Postgres en LOCAL (/opt/immich/postgres :
#   Immich ne supporte pas la base sur un partage réseau)
# - Compte admin créé par l'API dès le démarrage (pas de fenêtre « premier
#   arrivé = admin »), domaine externe réglé pour les liens de partage
#
# Prérequis : le dossier existe déjà sur le stockage, inscriptible par tous
# (777) ou par l'uid 100000. Autre emplacement : HOST_DIR=/mnt/pve/<stockage>/<dossier>

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

VMID="${1:-}"
[[ -n "$VMID" ]] || err "Usage : setup-app.sh <VMID> (CT créé par create-lxc-immich.sh)"
pct status "$VMID" 2>/dev/null | grep -q running || err "CT ${VMID} introuvable ou arrêté (pct status ${VMID})."
pct exec "$VMID" -- id thibault >/dev/null 2>&1 || err "Utilisateur thibault absent dans le CT ${VMID} : socle incomplet."

IMMICH_VERSION="v3.3.5"
IMMICH_RELEASE="https://github.com/immich-app/immich/releases/download/${IMMICH_VERSION}"
IMMICH_PORT="2283"
PUBLIC_URL="https://photos.survivalmode.familyds.org"
MNT="/mnt/immich"                                     # chemin dans le CT
HOST_DIR="${HOST_DIR:-/mnt/pve/nas-partage/Immich}"   # chemin sur l'hôte
STORAGE_ID=$(echo "$HOST_DIR" | sed -nE 's|^/mnt/pve/([^/]+)/.*|\1|p')

info "Configuration d'Immich ${IMMICH_VERSION} (CT ${VMID})..."

# ----- Questions -----
read -rp "E-mail du compte admin Immich : " IMMICH_ADMIN_EMAIL
[[ "$IMMICH_ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || err "E-mail invalide."
while true; do
    read -rsp "Mot de passe admin Immich (12 car. min) : " IMMICH_ADMIN_PASS; echo
    read -rsp "Confirmation : " IMMICH_ADMIN_PASS2; echo
    [[ ${#IMMICH_ADMIN_PASS} -ge 12 && "$IMMICH_ADMIN_PASS" == "$IMMICH_ADMIN_PASS2" ]] && break
    echo "Trop court ou différent, on recommence."
done
unset IMMICH_ADMIN_PASS2

# ----- Dossier photos sur l'hôte -----
[[ -n "$STORAGE_ID" ]] && { pvesm status --storage "$STORAGE_ID" >/dev/null 2>&1 || true; }
[[ -d "$HOST_DIR" ]] || err "${HOST_DIR} introuvable : stockage non monté ou dossier absent."
info "Photos : ${HOST_DIR} ($(df -h "$HOST_DIR" | awk 'NR==2 {print $4" libres sur "$2}'))"

# Au boot, les stockages NFS de Proxmox se montent sans ordre garanti vis-à-vis
# du démarrage auto des guests : on attend le montage avant pve-guests.
if [[ -n "$STORAGE_ID" && ! -f /etc/systemd/system/immich-nas-wait.service ]]; then
    cat > /etc/systemd/system/immich-nas-wait.service <<UNIT
[Unit]
Description=Attente du stockage ${STORAGE_ID} (photos Immich) avant les guests
After=network-online.target pve-cluster.service
Wants=network-online.target
Before=pve-guests.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in \$\$(seq 1 60); do pvesm status --storage ${STORAGE_ID} >/dev/null 2>&1; [ -d "${HOST_DIR}" ] && exit 0; sleep 2; done; exit 1'

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable immich-nas-wait.service >/dev/null 2>&1
    info "Service immich-nas-wait installé (avant pve-guests)."
fi

# ----- Bind mount dans le CT -----
if pct config "$VMID" | grep -q "^mp0:.*mp=${MNT}"; then
    info "mp0 déjà configuré."
else
    pct config "$VMID" | grep -q "^mp0:" && err "mp0 déjà utilisé par autre chose sur le CT ${VMID}."
    pct set "$VMID" -mp0 "${HOST_DIR},mp=${MNT}"
    info "Redémarrage du CT pour activer le montage..."
    pct reboot "$VMID"
    for i in $(seq 1 30); do
        pct exec "$VMID" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && break
        [[ $i -eq 30 ]] && err "Pas de réseau dans le CT après redémarrage."
        sleep 2
    done
fi
pct exec "$VMID" -- bash -c "touch ${MNT}/.rw-test && rm ${MNT}/.rw-test" \
    || err "Le CT ne peut pas écrire dans ${MNT}."

# ----- Immich -----
info "Installation d'Immich (téléchargement des images : plusieurs minutes)..."
pct exec "$VMID" -- env IMMICH_VERSION="$IMMICH_VERSION" IMMICH_RELEASE="$IMMICH_RELEASE" \
    MNT="$MNT" bash -s <<'APPLI'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
mkdir -p /opt/immich && cd /opt/immich
curl -fsSL -o docker-compose.yml "${IMMICH_RELEASE}/docker-compose.yml"
if [[ ! -f .env ]]; then
    curl -fsSL -o .env "${IMMICH_RELEASE}/example.env"
    # Mot de passe Postgres : A-Za-z0-9 uniquement (contrainte Immich)
    DB_PASS=$(openssl rand -hex 24)
    sed -i \
        -e "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${MNT}|" \
        -e "s|^DB_DATA_LOCATION=.*|DB_DATA_LOCATION=/opt/immich/postgres|" \
        -e "s|^# TZ=.*|TZ=Europe/Paris|" \
        -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
    unset DB_PASS
fi
sed -i "s|^IMMICH_VERSION=.*|IMMICH_VERSION=${IMMICH_VERSION}|" .env
chmod 600 .env
docker compose pull -q
docker compose up -d
APPLI

info "Attente du démarrage d'Immich..."
for i in $(seq 1 60); do
    pct exec "$VMID" -- curl -fsS -m3 "http://localhost:${IMMICH_PORT}/api/server/ping" >/dev/null 2>&1 && break
    [[ $i -eq 60 ]] && err "Immich ne répond pas après 5 min (pct exec ${VMID} -- docker logs immich_server)."
    sleep 5
done

# ----- Compte admin + domaine externe (API) -----
info "Création du compte admin et réglage du domaine externe..."
pct exec "$VMID" -- env API="http://localhost:${IMMICH_PORT}/api" PUBLIC_URL="$PUBLIC_URL" \
    EMAIL="$IMMICH_ADMIN_EMAIL" PASS="$IMMICH_ADMIN_PASS" python3 - <<'PY'
import json, os, urllib.request, urllib.error
api, email, pw = os.environ["API"], os.environ["EMAIL"], os.environ["PASS"]

def call(method, path, body=None, token=None):
    req = urllib.request.Request(api + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json",
                 **({"Authorization": "Bearer " + token} if token else {})})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
        return json.loads(raw) if raw else None

try:
    call("POST", "/auth/admin-sign-up", {"email": email, "password": pw, "name": "Admin"})
    print("  admin créé")
except urllib.error.HTTPError as e:
    print(f"  admin déjà existant ({e.code}), on continue")
token = call("POST", "/auth/login", {"email": email, "password": pw})["accessToken"]
cfg = call("GET", "/system-config", token=token)
cfg["server"]["externalDomain"] = os.environ["PUBLIC_URL"]
call("PUT", "/system-config", cfg, token=token)
print("  domaine externe :", os.environ["PUBLIC_URL"])
PY
unset IMMICH_ADMIN_PASS

CT_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo
info "Immich ${IMMICH_VERSION} prêt sur le CT ${VMID}."
info "  LAN       : http://${CT_IP}:${IMMICH_PORT}   (admin : ${IMMICH_ADMIN_EMAIL})"
info "  Photos    : ${HOST_DIR} (hôte) → ${MNT} (CT)"
info "  Logs      : pct exec ${VMID} -- docker compose -f /opt/immich/docker-compose.yml logs -f"
info "  Mise à jour : changer IMMICH_VERSION ici, relancer ce script (lire les notes de version avant)"
warn "Réserver le bail DHCP ${CT_IP} (CT ${VMID}) sur la box : l'edge pointe sur cette IP."
info "Étapes suivantes (hôte Proxmox, en root) :"
info "  bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/immich/expose.sh) ${VMID}"
info "  bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/immich/setup-backup.sh) ${VMID}"
