#!/usr/bin/env bash
#
# create-lxc-boox-sync.sh — LXC Ubuntu 24.04 de base + SFTPGo
#
# Reprend le socle de create-lxc.sh (DHCP, onboot, unprivileged, nesting,
# user thibault, docker/curl/git/unzip/python3) puis installe SFTPGo :
# un point de dépôt WebDAV + SFTP servant de cible de synchro pour les
# notes manuscrites de la Boox Note Air 5C.
#
#   - WebDAV (port 8090) : dépôt natif depuis BOOX Notes (Settings > Comptes)
#   - SFTP   (port 2022) : lecture par N8N + repli FolderSync depuis la Boox
#   - Web UI (port 8080) : admin SFTPGo
#
# LOCAL ONLY : rien n'est exposé en externe (pas de reverse proxy, pas de
# port-forward). Les services écoutent sur l'IP LAN du conteneur. Tailscale
# pourra être ajouté plus tard sans rien changer ici.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-boox-sync.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="10"           # OS + SFTPGo + accumulation des PDF de notes
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"
GH_REPO="drakkan/sftpgo"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (defaults applicatifs autorisés via ${VAR:-default})
read -rp "Nom du container (hostname) [boox-sync] : " CT_NAME
CT_NAME="${CT_NAME:-boox-sync}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [1] : " CT_CORES
CT_CORES="${CT_CORES:-1}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo [1024] : " CT_RAM
CT_RAM="${CT_RAM:-1024}"
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

# ----- Création (base) -----
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

# ----- Base : maj + paquets + docker -----
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
pct exec "$VMID" -- passwd -l root >/dev/null

# ===== TOUT CE QUI EST AU-DESSUS = SOCLE INTOUCHABLE =====
# ===== CI-DESSOUS = COUCHE APPLICATIVE SPÉCIFIQUE     =====

# ----- Couche SFTPGo (point de dépôt WebDAV + SFTP, local only) -----
info "Installation de SFTPGo (peut durer quelques minutes)..."
pct exec "$VMID" -- env GH_REPO="$GH_REPO" bash -s <<'SFTPGO'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo ">> Dépendances"
apt-get update -qq
apt-get -y -qq install jq openssl

echo ">> Téléchargement de la dernière release SFTPGo (.deb amd64)"
DEB_URL=$(curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases/latest" \
    | jq -r '.assets[] | select(.name | test("_amd64\\.deb$")) | .browser_download_url' \
    | head -n1)
[ -n "$DEB_URL" ] || { echo "URL .deb introuvable" >&2; exit 1; }
curl -fsSL "$DEB_URL" -o /tmp/sftpgo.deb
apt-get -y -qq install /tmp/sftpgo.deb
rm -f /tmp/sftpgo.deb

systemctl stop sftpgo 2>/dev/null || true

echo ">> Arborescence de dépôt (inbox / processed)"
install -d -o sftpgo -g sftpgo \
    /srv/sftpgo/data/boox/inbox \
    /srv/sftpgo/data/boox/processed

echo ">> Activation SFTP (2022) + WebDAV (8090) dans la config"
python3 - <<'PY'
import json, os
p = "/etc/sftpgo/sftpgo.json"
try:
    with open(p) as f:
        c = json.load(f)
except Exception:
    c = {}
# SFTP pour N8N (lecture) et repli FolderSync
c.setdefault("sftpd", {})["bindings"] = [{"address": "", "port": 2022}]
# WebDAV pour le dépôt natif BOOX Notes
c.setdefault("webdavd", {})["bindings"] = [{"address": "", "port": 8090}]
# Web admin (ne pas écraser si déjà présent)
if "httpd" not in c or not c["httpd"].get("bindings"):
    c.setdefault("httpd", {})["bindings"] = [
        {"address": "", "port": 8080,
         "enable_web_admin": True, "enable_web_client": True}
    ]
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(p, "w") as f:
    json.dump(c, f, indent=2)
PY

echo ">> Comptes admin + boox (mots de passe générés dans le conteneur)"
ADMIN_PASS=$(openssl rand -hex 16)
BOOX_PASS=$(openssl rand -hex 16)
cat > /etc/sftpgo/initdata.json <<JSON
{
  "admins": [
    {"username": "admin", "password": "${ADMIN_PASS}", "status": 1, "permissions": ["*"]}
  ],
  "users": [
    {"username": "boox", "password": "${BOOX_PASS}", "status": 1,
     "home_dir": "/srv/sftpgo/data/boox", "permissions": {"/": ["*"]}}
  ]
}
JSON
chown sftpgo:sftpgo /etc/sftpgo/initdata.json
chmod 600 /etc/sftpgo/initdata.json

echo ">> Chargement initial des comptes au démarrage (loaddata, mode 1 = idempotent)"
install -d /etc/systemd/system/sftpgo.service.d
cat > /etc/systemd/system/sftpgo.service.d/override.conf <<'OVR'
[Service]
Environment=SFTPGO_LOADDATA_FROM=/etc/sftpgo/initdata.json
Environment=SFTPGO_LOADDATA_MODE=1
OVR

systemctl daemon-reload
systemctl enable --now sftpgo

cat > /root/sftpgo-credentials.txt <<CRED
SFTPGo — identifiants générés à l'installation
Admin Web UI : admin / ${ADMIN_PASS}
Compte dépôt : boox  / ${BOOX_PASS}
CRED
chmod 600 /root/sftpgo-credentials.txt

echo ">> SFTPGo installé"
SFTPGO

# ----- Récap -----
IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo
info "Terminé ! Container ${VMID} (${CT_NAME}) prêt — SFTPGo en LOCAL ONLY."
info "  Admin Web UI  : http://${IP}:8080"
info "  SFTP (N8N)    : sftp://${IP}:2022      (user boox)"
info "  WebDAV (Boox) : http://${IP}:8090      (user boox)"
info "  Dossiers      : /inbox  et  /processed  (relatifs au home du user boox)"
info "  Accès shell   : pct enter ${VMID}"
info "  Logs          : pct exec ${VMID} -- journalctl -u sftpgo -f"
echo
info "Identifiants générés :"
pct exec "$VMID" -- cat /root/sftpgo-credentials.txt
echo
info "Aucune exposition externe configurée."
info "Plus tard pour Tailscale : installer le client dans le CT — les ports 2022/8090/8080"
info "seront alors joignables via le tailnet, toujours sans rien forwarder sur Internet."
