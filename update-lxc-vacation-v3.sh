#!/usr/bin/env bash
#
# update-lxc-vacation-v3.sh — Remet à niveau la surcouche compose d'un CT vacation-v3
#
# Pour un CT créé avant l'ajout des gabarits de mail en français (2026-11-14) :
# réécrit docker-compose.mailpit.yml comme le fait create-lxc-vacation-v3.sh
# (Mailpit + nginx qui sert les gabarits + variables GOTRUE_MAILER_* d'auth),
# crée /opt/vacation-v3/mail-templates (propriétaire thibault) puis relance compose.
#
# Préserve : .env (secrets), volumes Postgres/Storage, schéma et données.
# Idempotent : peut être relancé sans effet de bord.
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/update-lxc-vacation-v3.sh) <VMID>
# Puis, depuis claude-dev : pnpm mail:deploy (repo vacation-v3)

set -euo pipefail

APP_DIR="/opt/vacation-v3"
SUPABASE_DIR="${APP_DIR}/supabase"
MAILPIT_IMAGE="axllent/mailpit:v1.33.1"
MAILPIT_PORT="8025"
NGINX_IMAGE="nginx:1.29-alpine"
MAIL_TEMPLATES_DIR="${APP_DIR}/mail-templates"
ADMIN_USER="thibault"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

VMID="${1:-}"
[[ "$VMID" =~ ^[0-9]+$ ]] || err "Usage : $0 <VMID>"
pct exec "$VMID" -- test -f "${SUPABASE_DIR}/.env" || err "CT ${VMID} : ${SUPABASE_DIR}/.env introuvable, ce n'est pas un CT vacation-v3."

info "Réécriture de la surcouche compose (CT ${VMID})..."
pct exec "$VMID" -- env SUPABASE_DIR="$SUPABASE_DIR" MAILPIT_IMAGE="$MAILPIT_IMAGE" MAILPIT_PORT="$MAILPIT_PORT" \
    NGINX_IMAGE="$NGINX_IMAGE" MAIL_TEMPLATES_DIR="$MAIL_TEMPLATES_DIR" ADMIN_USER="$ADMIN_USER" bash -s <<'UPD'
set -euo pipefail
install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 755 "$MAIL_TEMPLATES_DIR"
cd "$SUPABASE_DIR"
cat > docker-compose.mailpit.yml <<YML
services:
  mailpit:
    container_name: supabase-mailpit
    image: ${MAILPIT_IMAGE}
    restart: unless-stopped
    ports:
      - "${MAILPIT_PORT}:8025"
    environment:
      MP_SMTP_AUTH_ACCEPT_ANY: "1"
      MP_SMTP_AUTH_ALLOW_INSECURE: "1"
      MP_UI_AUTH: "\${MAILPIT_UI_AUTH}"
      MP_MAX_MESSAGES: "500"

  # Gabarits de mail en français (code à 6 chiffres + lien). GoTrue ne lit que
  # des URL ; s'il n'obtient pas le fichier, il retombe sur son gabarit anglais.
  mail-templates:
    container_name: supabase-mail-templates
    image: ${NGINX_IMAGE}
    restart: unless-stopped
    volumes:
      - ${MAIL_TEMPLATES_DIR}:/usr/share/nginx/html:ro

  auth:
    environment:
      GOTRUE_MAILER_OTP_EXP: "3600"
      GOTRUE_MAILER_TEMPLATES_MAGIC_LINK: http://mail-templates/magic_link.html
      GOTRUE_MAILER_TEMPLATES_CONFIRMATION: http://mail-templates/confirmation.html
      GOTRUE_MAILER_TEMPLATES_INVITE: http://mail-templates/invite.html
      GOTRUE_MAILER_TEMPLATES_RECOVERY: http://mail-templates/recovery.html
      GOTRUE_MAILER_TEMPLATES_EMAIL_CHANGE: http://mail-templates/email_change.html
      GOTRUE_MAILER_SUBJECTS_MAGIC_LINK: "Ton code de connexion"
      GOTRUE_MAILER_SUBJECTS_CONFIRMATION: "Confirme ton adresse"
      GOTRUE_MAILER_SUBJECTS_INVITE: "Tu es invité·e à un voyage"
      GOTRUE_MAILER_SUBJECTS_RECOVERY: "Ton code de connexion"
      GOTRUE_MAILER_SUBJECTS_EMAIL_CHANGE: "Confirme ta nouvelle adresse"
YML
docker compose up -d
UPD

IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
info "Terminé. Depuis claude-dev, dans ~/vacation-v3 : LXC=${ADMIN_USER}@${IP} pnpm mail:deploy"
