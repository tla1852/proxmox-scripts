#!/usr/bin/env bash
#
# setup-app.sh — couche applicative Immich, appliquée à un CT existant (créé
# par create-lxc-immich.sh, qui appelle ce script). Relançable tel quel :
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/immich/setup-app.sh) <VMID>
#
# - Partage NFS du Synology monté SUR L'HÔTE (/mnt/immich, fstab, monté avant
#   le démarrage des guests) puis passé au CT en bind mount (mp0) : un CT non
#   privilégié ne peut pas monter de NFS lui-même. Le point de montage vide est
#   rendu immuable (chattr +i) : si le NAS manque, rien ne s'écrit sur le disque
#   de l'hôte, et Immich refuse de démarrer (fichiers témoins .immich absents)
# - Immich IMMICH_VERSION épinglé, compose + example.env officiels de la
#   release, ML sur CPU, photos sur NFS, Postgres en LOCAL (/opt/immich/postgres :
#   Immich ne supporte pas la base sur un partage réseau)
# - Compte admin créé par l'API dès le démarrage (pas de fenêtre « premier
#   arrivé = admin »), domaine externe réglé pour les liens de partage
#
# Prérequis DSM (Panneau de configuration) :
#   1. Dossier partagé « immich » (ex. /volume1/immich), sans corbeille
#   2. Services de fichiers > NFS : activé, NFSv4.1
#   3. Dossier « immich » > Autorisations NFS : IP de l'HÔTE Proxmox,
#      Lecture/Écriture, Squash « Pas de mappage », sécurité sys,
#      « Autoriser les connexions depuis des ports non privilégiés » coché

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
MNT="/mnt/immich"
# root d'un CT non privilégié = uid 100000 côté hôte (et donc côté NAS)
CT_ROOT_UID="100000"

info "Configuration d'Immich ${IMMICH_VERSION} (CT ${VMID})..."

# ----- Questions -----
read -rp "IP du NAS Synology : " NAS_IP
[[ "$NAS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "IP invalide."
read -rp "Chemin exporté [/volume1/immich] : " NAS_EXPORT; NAS_EXPORT="${NAS_EXPORT:-/volume1/immich}"
[[ "$NAS_EXPORT" =~ ^/[A-Za-z0-9/_.-]+$ ]] || err "Chemin invalide."

read -rp "E-mail du compte admin Immich : " IMMICH_ADMIN_EMAIL
[[ "$IMMICH_ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || err "E-mail invalide."
while true; do
    read -rsp "Mot de passe admin Immich (12 car. min) : " IMMICH_ADMIN_PASS; echo
    read -rsp "Confirmation : " IMMICH_ADMIN_PASS2; echo
    [[ ${#IMMICH_ADMIN_PASS} -ge 12 && "$IMMICH_ADMIN_PASS" == "$IMMICH_ADMIN_PASS2" ]] && break
    echo "Trop court ou différent, on recommence."
done
unset IMMICH_ADMIN_PASS2

# ----- NFS sur l'hôte -----
info "Montage NFS ${NAS_IP}:${NAS_EXPORT} → ${MNT} (hôte)..."
command -v mount.nfs >/dev/null || { apt-get update -qq; apt-get -y -qq install nfs-common >/dev/null; }
if ! mountpoint -q "$MNT"; then
    mkdir -p "$MNT"
    # Immuable tant que rien n'est monté dessus : NAS absent = écriture refusée
    chattr +i "$MNT"
fi
FSTAB_LINE="${NAS_IP}:${NAS_EXPORT} ${MNT} nfs defaults,hard,noatime,_netdev,nofail,x-systemd.before=pve-guests.service 0 0"
if grep -qE "[[:space:]]${MNT}[[:space:]]" /etc/fstab; then
    grep -qF "$FSTAB_LINE" /etc/fstab || warn "Entrée ${MNT} déjà dans /etc/fstab mais différente : conservée telle quelle."
else
    cp -p /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
    echo "$FSTAB_LINE" >> /etc/fstab
    systemctl daemon-reload
fi
mountpoint -q "$MNT" || mount "$MNT" || err "Montage NFS impossible : vérifier les autorisations NFS du dossier dans DSM (IP de l'hôte, Pas de mappage)."
chown "${CT_ROOT_UID}:${CT_ROOT_UID}" "$MNT" \
    || err "chown refusé par le NAS : régler le Squash du partage sur « Pas de mappage »."
info "NFS OK : $(df -h "$MNT" | awk 'NR==2 {print $2" au total, "$4" libres"}')"

# ----- Bind mount dans le CT -----
if pct config "$VMID" | grep -q "^mp0:.*mp=${MNT}"; then
    info "mp0 déjà configuré."
else
    pct config "$VMID" | grep -q "^mp0:" && err "mp0 déjà utilisé par autre chose sur le CT ${VMID}."
    pct set "$VMID" -mp0 "${MNT},mp=${MNT}"
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
info "  Photos    : ${NAS_IP}:${NAS_EXPORT} → ${MNT} (hôte) → ${MNT} (CT)"
info "  Logs      : pct exec ${VMID} -- docker compose -f /opt/immich/docker-compose.yml logs -f"
info "  Mise à jour : changer IMMICH_VERSION ici, relancer ce script (lire les notes de version avant)"
warn "Réserver le bail DHCP ${CT_IP} (CT ${VMID}) sur la box : l'edge pointe sur cette IP."
info "Étapes suivantes (hôte Proxmox, en root) :"
info "  bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/immich/expose.sh) ${VMID}"
info "  bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/immich/setup-backup.sh) ${VMID}"
