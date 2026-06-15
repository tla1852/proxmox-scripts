#!/usr/bin/env bash
#
# create-lxc-protonbridge.sh — LXC Ubuntu 24.04 dédié au Proton Mail Bridge (headless)
#
# Dérivé byte-pour-byte du socle tla1852/proxmox-scripts/create-lxc.sh.
# Socle inviolable : DHCP, unprivileged=1, nesting=1, Docker, user "thibault" (sudo+docker), root verrouillé.
# Couche applicative ajoutée APRÈS le verrouillage root (voir frontière plus bas) :
#   déploiement de l'image communautaire shenxn/protonmail-bridge, volume persistant,
#   IMAP (143) + SMTP (25) exposés sur l'IP LAN du LXC (n8n tourne dans un autre LXC).
#
# ⚠️ Le login Proton (compte + 2FA) NE PEUT PAS être scripté → étape `init` manuelle, UNE fois.
#    Voir le runbook imprimé en fin de script.
#
# Prérequis : plan Proton PAYANT (Mail Plus / Unlimited / Business). Bridge indisponible en Free.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-protonbridge.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="8"               # bridge léger : 8 Go suffisent largement
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions (défauts adaptés au bridge) -----
read -rp "Nom du container (hostname) [protonbridge] : " CT_NAME
CT_NAME="${CT_NAME:-protonbridge}"
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
# Le socle fournit déjà Docker + nesting. On prépare le Proton Mail Bridge headless.
# Image communautaire de référence (2026) : shenxn/protonmail-bridge.
#
# ⚠️ L'image brute crashe après l'init : le bridge s'auto-update vers une version
#    récente (v3.25+) qui dépend de libfido2, absente de l'image
#    (« libfido2.so.1: cannot open shared object file »). On build donc une image
#    dérivée qui ajoute libfido2-1.
#
# Le login Proton (2FA) ne peut pas être scripté → on ne démarre PAS encore le service ;
# on build l'image patchée, crée le volume persistant, et dépose un helper de démarrage.

BASE_IMAGE="shenxn/protonmail-bridge"
BRIDGE_IMAGE="protonmail-bridge:fido"   # image patchée (base + libfido2)
BRIDGE_VOLUME="protonmail"
LXC_IP="$(pct exec "$VMID" -- hostname -I | awk '{print $1}')"

info "Build de l'image patchée ${BRIDGE_IMAGE} (base ${BASE_IMAGE} + libfido2)..."
pct exec "$VMID" -- bash -c "mkdir -p /root/bridge-build
cat > /root/bridge-build/Dockerfile <<EOF
FROM ${BASE_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends libfido2-1 \\
    && rm -rf /var/lib/apt/lists/*
EOF
docker build -t ${BRIDGE_IMAGE} /root/bridge-build >/dev/null"

info "Création du volume persistant ${BRIDGE_VOLUME}..."
pct exec "$VMID" -- docker volume create "${BRIDGE_VOLUME}" >/dev/null

# Helper de démarrage du service (à lancer APRÈS le login init manuel).
# IMAP 143 publié sur l'IP LAN du LXC (n8n est dans un autre LXC).
# SMTP 25 NON publié : non utilisé (n8n lit seulement l'IMAP) et le port 25 est
# souvent déjà pris par un MTA local. Décommenter la ligne -p si l'envoi est requis
# (libérer 25 au préalable, ou remapper ex. -p 1025:25).
# ⚠️ Réseau interne uniquement — ne JAMAIS router ces ports via un reverse proxy.
info "Dépôt du helper /root/start-bridge.sh dans le container..."
pct exec "$VMID" -- bash -c "cat > /root/start-bridge.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
docker rm -f protonmail-bridge 2>/dev/null || true
docker run -d --name protonmail-bridge --restart=unless-stopped \\
    -v ${BRIDGE_VOLUME}:/root \\
    -p 143:143/tcp \\
    ${BRIDGE_IMAGE}
echo 'Bridge démarré. IMAP 143 exposé sur l'\\''IP LAN du LXC.'
EOS
chmod +x /root/start-bridge.sh"

# ----- Récap final -----
echo
info "Terminé ! Container ${VMID} (${CT_NAME}) prêt — Proton Bridge à finaliser à la main."
info "  IP LXC    : ${LXC_IP}"
info "  Accès     : pct enter ${VMID}   ou   ssh ${ADMIN_USER}@${LXC_IP}"
info "  Docker    : $(pct exec "$VMID" -- docker --version)"
echo
echo -e "\e[33m================ RUNBOOK : login Proton Bridge (manuel, UNE fois) ================\e[0m"
cat <<RUNBOOK

  1. Entrer dans le container :
       pct enter ${VMID}

  2. Lancer l'init interactif (login + 2FA) sur le volume persistant
     (image patchée ${BRIDGE_IMAGE}, sinon crash libfido2) :
       docker run --rm -it -v ${BRIDGE_VOLUME}:/root ${BRIDGE_IMAGE} init

     Dans le shell du bridge :
       > login        # identifiants Proton + code 2FA
       > info         # AFFICHE le mot de passe Bridge (≠ mot de passe Proton) — À NOTER
       > exit

  3. Démarrer le service persistant :
       /root/start-bridge.sh

  4. Vérifier :
       docker ps                       # protonmail-bridge = Up
       docker logs protonmail-bridge   # pas d'erreur de login

  --- À reporter pour la config n8n (credential IMAP) ---
    host   : ${LXC_IP}
    port   : 143  (STARTTLS, certificat auto-signé à accepter)
    user   : <adresse Proton>
    pass   : <mot de passe Bridge récupéré via 'info'>

  Prérequis rappel : plan Proton PAYANT (Bridge indispo en Free).
RUNBOOK
echo -e "\e[33m===================================================================================\e[0m"
