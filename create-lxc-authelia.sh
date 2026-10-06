#!/usr/bin/env bash
#
# create-lxc-authelia.sh — LXC Ubuntu 24.04 + portail d'authentification Authelia (Docker)
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
# - Puis : déploie Authelia (https://www.authelia.com) — portail login + TOTP,
#          utilisateurs en fichier YAML, stockage SQLite, aucun autre service.
#
# Rôle : second facteur devant les services privés *.ts.tlagrange.pro quand ils
# sont atteints HORS tailnet, depuis l'IP du bureau, via l'edge Caddy (LXC 144).
# L'edge filtre l'IP source, puis interroge Authelia (forward_auth) avant de
# relayer vers le Caddy interne (LXC 100). Le chemin tailnet n'est pas concerné.
# Voir homelab/edge/{Caddyfile,144.fw,README.md}.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-authelia.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="8"
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts : authelia / 1 / 512)
read -rp "Nom du container (hostname) [authelia] : " CT_NAME; CT_NAME="${CT_NAME:-authelia}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [1] : " CT_CORES; CT_CORES="${CT_CORES:-1}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (Authelia + SQLite, 512 suffisent) [512] : " CT_RAM; CT_RAM="${CT_RAM:-512}"
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

# ═════════════════════════════════════════════════════════════════════════════
# COUCHE APPLICATIVE — AUTHELIA (le socle ci-dessus fournit Docker)
# ═════════════════════════════════════════════════════════════════════════════
APP_DIR="/opt/authelia"
AUTHELIA_IMAGE="ghcr.io/authelia/authelia:4.39"
BASE_DOMAIN="ts.tlagrange.pro"
AUTH_FQDN="auth.${BASE_DOMAIN}"
AUTH_USER="thibault"
AUTH_EMAIL="thibault@tlagrange.pro"

info "Déploiement d'Authelia (${AUTH_FQDN})..."

pct exec "$VMID" -- env APP_DIR="$APP_DIR" AUTHELIA_IMAGE="$AUTHELIA_IMAGE" \
    BASE_DOMAIN="$BASE_DOMAIN" AUTH_FQDN="$AUTH_FQDN" AUTH_USER="$AUTH_USER" \
    AUTH_EMAIL="$AUTH_EMAIL" bash -s <<'AUTHELIA'
set -euo pipefail
umask 077
mkdir -p "$APP_DIR/config" "$APP_DIR/secrets"

# Secrets générés ici, jamais en dur. Lus par Authelia via les variables *_FILE.
for s in session storage jwt; do
    [[ -s "$APP_DIR/secrets/$s" ]] || openssl rand -hex 48 > "$APP_DIR/secrets/$s"
done

docker pull -q "$AUTHELIA_IMAGE" >/dev/null

# Mot de passe initial aléatoire, haché argon2id par le binaire Authelia.
INIT_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
HASH=$(docker run --rm -e P="$INIT_PASS" --entrypoint sh "$AUTHELIA_IMAGE" \
    -c 'authelia crypto hash generate argon2 --password "$P"' | sed -n 's/^Digest: //p')
[[ "$HASH" == \$argon2id\$* ]] || { echo "Échec du hachage du mot de passe"; exit 1; }
printf '%s\n' "$INIT_PASS" > "$APP_DIR/initial-password.txt"

cat > "$APP_DIR/config/users.yml" <<USERS
users:
  ${AUTH_USER}:
    disabled: false
    displayname: 'Thibault'
    password: '${HASH}'
    email: '${AUTH_EMAIL}'
    groups:
      - 'admins'
USERS

cat > "$APP_DIR/config/configuration.yml" <<CONFIG
theme: 'auto'

server:
  address: 'tcp://:9091/'

log:
  level: 'info'

totp:
  issuer: '${BASE_DOMAIN}'

authentication_backend:
  password_reset:
    disable: true
  file:
    path: '/config/users.yml'
    watch: true
    password:
      algorithm: 'argon2'

# Tout ce qui passe par le portail exige mot de passe + TOTP.
access_control:
  default_policy: 'deny'
  rules:
    - domain: '*.${BASE_DOMAIN}'
      policy: 'two_factor'

session:
  cookies:
    - domain: '${BASE_DOMAIN}'
      authelia_url: 'https://${AUTH_FQDN}'
      default_redirection_url: 'https://telescope.${BASE_DOMAIN}'
      expiration: '8h'
      inactivity: '1h'

# Anti-bruteforce : 3 échecs en 2 min -> compte bloqué 15 min.
regulation:
  max_retries: 3
  find_time: '2m'
  ban_time: '15m'

storage:
  local:
    path: '/config/db.sqlite3'

# Pas de SMTP : les codes de vérification (enrôlement TOTP) sont écrits dans ce
# fichier, lisible uniquement depuis le LXC.
notifier:
  filesystem:
    filename: '/config/notification.txt'

ntp:
  disable_failure: true
CONFIG

# Port 9091 publié sur le LAN : l'edge (LXC 144, DMZ) doit le joindre. HTTP en
# clair sur le LAN, TLS terminé par l'edge.
cat > "$APP_DIR/docker-compose.yml" <<COMPOSE
name: authelia

services:
  authelia:
    image: ${AUTHELIA_IMAGE}
    container_name: authelia
    restart: unless-stopped
    ports:
      - "0.0.0.0:9091:9091"
    environment:
      TZ: 'Europe/Paris'
      AUTHELIA_SESSION_SECRET_FILE: '/secrets/session'
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE: '/secrets/storage'
      AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE: '/secrets/jwt'
    volumes:
      - ./config:/config
      - ./secrets:/secrets:ro
COMPOSE

cd "$APP_DIR"
docker run --rm -v "$APP_DIR/config:/config" -v "$APP_DIR/secrets:/secrets:ro" \
    -e AUTHELIA_SESSION_SECRET_FILE=/secrets/session \
    -e AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/secrets/storage \
    -e AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/secrets/jwt \
    "$AUTHELIA_IMAGE" authelia config validate --config /config/configuration.yml
docker compose up -d

# Attente du healthcheck embarqué dans l'image
echo ">> Attente du démarrage d'Authelia..."
for i in $(seq 1 30); do
    STATUS=$(docker inspect --format '{{.State.Health.Status}}' authelia 2>/dev/null || echo starting)
    [[ "$STATUS" == "healthy" ]] && break
    [[ "$STATUS" == "unhealthy" ]] && { docker logs authelia | tail -20; echo "Authelia unhealthy"; exit 1; }
    [[ $i -eq 30 ]] && { docker logs authelia | tail -20; echo "Timeout démarrage (1 min)"; exit 1; }
    sleep 2
done
echo ">> Authelia démarré (healthy)"
AUTHELIA

# ----- Récap -----
APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
INIT_PASS=$(pct exec "$VMID" -- cat "$APP_DIR/initial-password.txt")
echo
info "═══ Authelia déployé ═══"
info "  CT            : ${VMID} (${CT_NAME}), IP ${APP_IP}"
info "  HTTP interne  : http://${APP_IP}:9091  (santé : /api/health)"
info "  Portail       : https://${AUTH_FQDN}  (une fois l'edge à jour)"
info "  Compte        : ${AUTH_USER}"
info "  Mot de passe  : ${INIT_PASS}"
info "                  (aussi dans ${APP_DIR}/initial-password.txt — à ranger"
info "                   dans Vaultwarden puis supprimer le fichier)"
info "  Config        : ${APP_DIR}/config/{configuration,users}.yml"
info "  Logs          : pct exec ${VMID} -- docker logs -f authelia"
unset INIT_PASS
echo
echo -e "\e[33m================ À FAIRE pour activer le service ================\e[0m"
cat <<RUNBOOK

  1. Réserver le bail DHCP de ${APP_IP} sur la box (l'edge et son firewall
     pointent sur cette IP).

  2. Edge (repo, homelab/edge/) — remplacer AUTHELIA_IP par ${APP_IP} dans
     Caddyfile et 144.fw, puis déployer selon homelab/edge/README.md
     (section « Accès bureau »).

  3. Enrôler le TOTP — depuis le bureau, ouvrir https://${AUTH_FQDN}, se
     connecter, « Enregistrer un appareil ». Authelia demande un code de
     vérification : il n'est pas envoyé par mail, le lire ici :

       pct exec ${VMID} -- cat ${APP_DIR}/config/notification.txt

  4. Changer le mot de passe (optionnel) : générer un hash puis remplacer la
     ligne password: de ${APP_DIR}/config/users.yml (rechargé à chaud) :

       pct exec ${VMID} -- docker exec -it authelia authelia crypto hash generate argon2

  5. Homarr (optionnel) : pct set ${VMID} -tags "homarr.securite"
     puis lancer homarr-sync.

RUNBOOK
echo -e "\e[33m=================================================================\e[0m"
