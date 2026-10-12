#!/usr/bin/env bash
#
# create-lxc-guacamole.sh — LXC Ubuntu 24.04 + Apache Guacamole (Docker)
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
# - Puis : déploie Apache Guacamole (https://guacamole.apache.org) — passerelle
#          SSH / RDP / VNC dans le navigateur, avec liste de connexions :
#          guacd (moteur) + guacamole (appli web Tomcat) + PostgreSQL.
#
# Rôle : bastion du homelab, remplace mRemoteNG. Atteint en
# guac.ts.tlagrange.pro via le Caddy interne (tailnet) et, depuis le bureau,
# via l'edge (filtre IP + Authelia). Jamais exposé directement.
# Voir homelab/internal/{Caddyfile,extra-records.yaml} et homelab/edge/.
#
# Le compte admin par défaut (guacadmin/guacadmin) n'est jamais laissé tel
# quel : le script lui pose un mot de passe aléatoire. TOTP activé (extension
# intégrée) : enrôlement par QR code au premier login.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/create-lxc-guacamole.sh)

set -euo pipefail

# ----- Configuration -----
STORAGE="local-lvm"
DISK_GB="10"           # 3 images Docker (~1,5 Go) + base PostgreSQL
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE_PATTERN="ubuntu-24.04-standard"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

# ----- Questions ----- (défauts : guacamole / 2 / 2048)
read -rp "Nom du container (hostname) [guacamole] : " CT_NAME; CT_NAME="${CT_NAME:-guacamole}"
[[ "$CT_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || err "Nom invalide (lettres, chiffres, tirets)."

read -rp "Nombre de coeurs [2] : " CT_CORES; CT_CORES="${CT_CORES:-2}"
[[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || err "Nombre de coeurs invalide."

read -rp "RAM en Mo (Tomcat + guacd + PostgreSQL, conseillé >= 2048) [2048] : " CT_RAM; CT_RAM="${CT_RAM:-2048}"
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
# COUCHE APPLICATIVE — APACHE GUACAMOLE (le socle ci-dessus fournit Docker)
# ═════════════════════════════════════════════════════════════════════════════
APP_DIR="/opt/guacamole"
GUAC_VERSION="1.6.0"
POSTGRES_IMAGE="postgres:16"
FQDN="guac.ts.tlagrange.pro"

info "Déploiement de Guacamole ${GUAC_VERSION} (${FQDN})..."

pct exec "$VMID" -- env APP_DIR="$APP_DIR" GUAC_VERSION="$GUAC_VERSION" \
    POSTGRES_IMAGE="$POSTGRES_IMAGE" bash -s <<'GUACAMOLE'
set -euo pipefail
umask 077
mkdir -p "$APP_DIR/initdb" "$APP_DIR/home/extensions"
cd "$APP_DIR"

# Secret généré ici, jamais en dur.
[[ -s .env ]] || echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)" > .env

docker pull -q "guacamole/guacamole:${GUAC_VERSION}" >/dev/null
docker pull -q "guacamole/guacd:${GUAC_VERSION}" >/dev/null
docker pull -q "$POSTGRES_IMAGE" >/dev/null

# Schéma de la base, fourni par l'image Guacamole. Joué une seule fois par
# PostgreSQL, à la création du volume (docker-entrypoint-initdb.d).
docker run --rm "guacamole/guacamole:${GUAC_VERSION}" \
    /opt/guacamole/bin/initdb.sh --postgresql > initdb/001-schema.sql
grep -q 'CREATE TABLE guacamole_user' initdb/001-schema.sql \
    || { echo "Schéma Guacamole vide ou inattendu"; exit 1; }
chmod 755 initdb && chmod 644 initdb/001-schema.sql
# Gabarit GUACAMOLE_HOME (extensions, ex. homelab/guacamole/theme-sombre.sh) :
# lu par l'utilisateur non-root du conteneur.
chmod 755 home home/extensions

# Port 8080 publié sur le LAN : le Caddy interne (LXC 100) doit le joindre.
# HTTP en clair sur le LAN, TLS terminé par Caddy. WEBAPP_CONTEXT=ROOT sert
# l'appli à la racine (pas de /guacamole/). guacd et la base ne sont PAS publiés.
cat > docker-compose.yml <<COMPOSE
name: guacamole

services:
  db:
    image: ${POSTGRES_IMAGE}
    container_name: guac-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: guacamole
      POSTGRES_USER: guacamole
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - guac-db:/var/lib/postgresql/data
      - ./initdb:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U guacamole -d guacamole"]
      interval: 5s
      timeout: 3s
      retries: 20

  guacd:
    image: guacamole/guacd:${GUAC_VERSION}
    container_name: guacd
    restart: unless-stopped

  guacamole:
    image: guacamole/guacamole:${GUAC_VERSION}
    container_name: guacamole
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      guacd:
        condition: service_started
    volumes:
      - ./home:/etc/guacamole-tpl:ro
    ports:
      - "0.0.0.0:8080:8080"
    environment:
      WEBAPP_CONTEXT: ROOT
      GUACAMOLE_HOME: /etc/guacamole-tpl
      GUACD_HOSTNAME: guacd
      POSTGRESQL_ENABLED: "true"
      POSTGRESQL_HOSTNAME: db
      POSTGRESQL_DATABASE: guacamole
      POSTGRESQL_USERNAME: guacamole
      POSTGRESQL_PASSWORD: \${POSTGRES_PASSWORD}
      TOTP_ENABLED: "true"
      TOTP_ISSUER: "Guacamole homelab"

volumes:
  guac-db:
COMPOSE

docker compose up -d

echo ">> Attente du démarrage de Guacamole..."
for i in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)
    [[ "$CODE" == "200" ]] && break
    [[ $i -eq 60 ]] && { docker compose logs --tail 30 guacamole; echo "Timeout démarrage (2 min)"; exit 1; }
    sleep 2
done
echo ">> Guacamole démarré"

# Le schéma crée guacadmin/guacadmin : on remplace tout de suite ce mot de
# passe connu par un aléatoire. Format Guacamole : SHA-256(mot de passe +
# sel en hexadécimal MAJUSCULE), sel de 32 octets.
if [[ ! -s initial-password.txt ]]; then
    INIT_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
    SALT=$(openssl rand -hex 32)
    docker exec -i guac-db psql -q -v ON_ERROR_STOP=1 -U guacamole -d guacamole \
        -v pass="$INIT_PASS" -v salt="$SALT" <<'SQL'
UPDATE guacamole_user
   SET password_salt = decode(:'salt', 'hex'),
       password_hash = sha256(convert_to(:'pass' || upper(:'salt'), 'UTF8')),
       password_date = now()
 WHERE entity_id = (SELECT entity_id FROM guacamole_entity
                     WHERE name = 'guacadmin' AND type = 'USER');
SQL
    printf '%s\n' "$INIT_PASS" > initial-password.txt
fi

# Vérification. Avec le TOTP actif, un bon mot de passe ne donne pas encore de
# jeton : l'API répond INSUFFICIENT_CREDENTIALS (elle réclame le code TOTP) ;
# un mauvais mot de passe donne INVALID_CREDENTIALS.
api() { curl -s -X POST http://127.0.0.1:8080/api/tokens \
            --data-urlencode "username=guacadmin" --data-urlencode "password=$1"; }
if api guacadmin | grep -qE 'authToken|INSUFFICIENT_CREDENTIALS'; then
    echo "Le mot de passe par défaut guacadmin est encore actif"; exit 1
fi
api "$(cat initial-password.txt)" | grep -qE 'authToken|INSUFFICIENT_CREDENTIALS' \
    || echo ">> ATTENTION : nouveau mot de passe non confirmé par l'API, à tester au premier login"
echo ">> Mot de passe admin par défaut remplacé et vérifié"
GUACAMOLE

# ----- Récap -----
APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
INIT_PASS=$(pct exec "$VMID" -- cat "$APP_DIR/initial-password.txt")
echo
info "═══ Guacamole déployé ═══"
info "  CT            : ${VMID} (${CT_NAME}), IP ${APP_IP}"
info "  HTTP interne  : http://${APP_IP}:8080"
info "  URL           : https://${FQDN}  (une fois Caddy + DNS à jour)"
info "  Compte        : guacadmin"
info "  Mot de passe  : ${INIT_PASS}"
info "                  (aussi dans ${APP_DIR}/initial-password.txt — à ranger"
info "                   dans Vaultwarden puis supprimer le fichier)"
info "  TOTP          : QR code affiché au premier login"
info "  Config        : ${APP_DIR}/docker-compose.yml (+ .env)"
info "  Logs          : pct exec ${VMID} -- docker logs -f guacamole"
unset INIT_PASS
echo
echo -e "\e[33m================ À FAIRE pour activer le service ================\e[0m"
cat <<RUNBOOK

  1. Réserver le bail DHCP de ${APP_IP} sur la box.

  2. Caddy interne (repo, homelab/internal/Caddyfile) — ajouter puis déployer
     sur le LXC 100 :

       # Guacamole — bastion SSH/RDP/VNC (CT ${VMID})
       ${FQDN} {
           reverse_proxy ${APP_IP}:8080
       }

  3. MagicDNS (repo, homelab/internal/extra-records.yaml) — ajouter, puis
     reporter dans /opt/headscale/config/config.yaml (LXC 145) et redémarrer
     headscale :

       - { name: "${FQDN}", type: A, value: "100.64.0.2" }

  4. Accès bureau (repo, homelab/edge/) — ajouter ${FQDN} à la liste des
     vhosts privés du Caddyfile et « guac » à NAMES dans dns-bureau.sh
     (CNAME public). Aucune règle firewall à ajouter : l'edge passe par le
     Caddy interne.

  5. Premier login : guacadmin + mot de passe ci-dessus, scanner le QR TOTP,
     puis Paramètres > Utilisateurs : créer un compte personnel admin et
     changer le mot de passe.

  6. Homarr (optionnel) : pct set ${VMID} -tags "homarr.securite"
     puis lancer homarr-sync.

RUNBOOK
echo -e "\e[33m=================================================================\e[0m"
