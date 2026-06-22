#!/usr/bin/env bash
#
# create-lxc-ferroxide.sh — LXC Ubuntu 24.04 dédié à ferroxide (Proton CalDAV)
#
# Dérivé byte-pour-byte du socle tla1852/proxmox-scripts/create-lxc.sh.
# Socle inviolable : DHCP, unprivileged=1, nesting=1, Docker, user "thibault" (sudo+docker), root verrouillé.
# Couche applicative ajoutée APRÈS le verrouillage root (voir frontière plus bas) :
#   build de ferroxide (acheong08/ferroxide) en binaire Go, service systemd `ferroxide-caldav`
#   exposant l'agenda Proton en CalDAV (8081). Un poller (autre étape) upsert dans L5
#   via POST /webhooks/calendrier. Distinct du Proton Mail Bridge (qui ne fait que IMAP/SMTP).
#
# ⚠️ Le login Proton (compte + 2FA) NE PEUT PAS être scripté → étape `auth` manuelle, UNE fois.
#    Voir le runbook imprimé en fin de script.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-ferroxide.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="8"               # binaire Go + creds chiffrées : 8 Go largement suffisants
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions (défauts adaptés à ferroxide) -----
read -rp "Nom du container (hostname) [proton-caldav] : " CT_NAME
CT_NAME="${CT_NAME:-proton-caldav}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [1] : " CT_CORES
CT_CORES="${CT_CORES:-1}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (ex: 2048) [1024] : " CT_RAM
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

# ===================================================================================
# ============== FRONTIÈRE : fin du socle inviolable / couche applicative ============
# ===================================================================================
# ferroxide est un binaire Go (pas d'image Docker officielle) : on l'installe via la
# toolchain Go d'Ubuntu, puis on dépose un service systemd PRÊT mais NON démarré
# (l'auth Proton interactive doit précéder). Le login Proton (2FA) n'est pas scriptable.

info "Installation de la toolchain Go..."
pct exec "$VMID" -- bash -c "export DEBIAN_FRONTEND=noninteractive
    apt-get -y -qq install golang-go"

info "Build de ferroxide (acheong08/ferroxide -> /usr/local/bin/ferroxide)..."
pct exec "$VMID" -- bash -c "GOBIN=/usr/local/bin GOFLAGS=-buildvcs=false \
    go install github.com/acheong08/ferroxide/cmd/ferroxide@latest"
pct exec "$VMID" -- bash -c "test -x /usr/local/bin/ferroxide" \
    || err "Build ferroxide échoué (vérifier la version de Go / le réseau)."

# Service CalDAV — démarré APRÈS l'auth Proton (creds chiffrées sous /root/.config/ferroxide).
info "Dépôt du service systemd ferroxide-caldav (non démarré)..."
pct exec "$VMID" -- bash -c "cat > /etc/systemd/system/ferroxide-caldav.service <<'EOS'
[Unit]
Description=ferroxide CalDAV (miroir Proton)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/ferroxide caldav
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload"

# ----- Récap final -----
LXC_IP="$(pct exec "$VMID" -- hostname -I | awk '{print $1}')"
echo
info "Terminé ! Container ${VMID} (${CT_NAME}) prêt — ferroxide à finaliser à la main."
info "  IP LXC    : ${LXC_IP}"
info "  Accès     : pct enter ${VMID}   ou   ssh ${ADMIN_USER}@${LXC_IP}"
info "  ferroxide : $(pct exec "$VMID" -- /usr/local/bin/ferroxide --help 2>/dev/null | head -n1 || echo 'installé')"
echo
echo -e "\e[33m================ RUNBOOK : auth Proton + démarrage CalDAV (manuel, UNE fois) ================\e[0m"
cat <<RUNBOOK

  1. Entrer dans le container :
       pct enter ${VMID}

  2. Authentifier le compte Proton (login + 2FA) :
       ferroxide auth <adresse@proton.me>
     → IMPRIME un BRIDGE PASSWORD (32 car.) : À NOTER, non re-stocké, = mot de passe CalDAV.

  3. (Bind) Vérifier sur quelle adresse ferroxide écoute le CalDAV :
       ferroxide caldav --help        # chercher un flag d'adresse/port d'écoute
     - Si bind 127.0.0.1 uniquement ET poller dans un AUTRE LXC -> mettre un reverse
       proxy (Caddy/nginx) devant, ou faire tourner le poller DANS ce LXC.

  4. Démarrer + activer le service :
       systemctl enable --now ferroxide-caldav
       systemctl status  ferroxide-caldav --no-pager
       ss -ltnp | grep 8081           # confirmer l'écoute (127.0.0.1 vs 0.0.0.0)

  5. Vérifier le CalDAV :
       curl -u '<adresse@proton.me>:<bridge-password>' -X PROPFIND -H 'Depth: 0' \\
            http://127.0.0.1:8081/
     → doit renvoyer du XML <multistatus>.

  --- À reporter pour le poller calendrier (-> POST /webhooks/calendrier de L5) ---
    CalDAV host : ${LXC_IP}
    CalDAV port : 8081
    user        : <adresse Proton>
    pass        : <bridge password de l'étape 2>

  ⚠️ Tier isolé : à basculer sur le VLAN isolé du homelab (cf. homelab-secu).
     Réseau interne uniquement — ne PAS exposer le 8081 en public-facing.
RUNBOOK
echo -e "\e[33m=============================================================================================\e[0m"
