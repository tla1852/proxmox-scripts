#!/usr/bin/env bash
#
# setup-anytype-cli.sh — active le client headless anytype-cli dans le CT any-sync
#
# Le compose upstream (anyproto/any-sync-dockercompose) livre les services
# anytype-cli_bootstrap + anytype-cli commentés. Plutôt que de décommenter le
# fichier upstream (perdu au prochain git pull), on pose un
# docker-compose.override.yml reprenant ces blocs à l'identique, avec une seule
# différence : seul le port HTTP API (31012) est publié hors du CT — les ports
# gRPC restent internes (n8n/MCP ne parlent que HTTP).
#
# - Crée le compte bot (défaut "anytype-bot") sur le réseau self-hosted au
#   premier démarrage (bootstrap), puis lance le serveur headless.
# - Génère une clé API ("homelab") et l'affiche — à stocker pour n8n / MCP.
# - Affiche la commande de jointure du space (invite à générer dans l'app).
#
# Usage (sur le noeud Proxmox, en root) :
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/setup-anytype-cli.sh) [VMID]
#   (VMID par défaut : 118)

set -euo pipefail

VMID="${1:-118}"
APP_DIR="/opt/any-sync-dockercompose"

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."
pct status "$VMID" 2>/dev/null | grep -q running || err "CT ${VMID} absent ou arrêté."
pct exec "$VMID" -- test -f "${APP_DIR}/.env" || err "${APP_DIR}/.env introuvable dans le CT ${VMID} : pas un CT any-sync ?"

# ----- Override compose (blocs upstream décommentés, ports gRPC non publiés) -----
OVERRIDE_TMP="$(mktemp)"
cat > "$OVERRIDE_TMP" <<'EOF'
# Généré par tla1852/proxmox-scripts/setup-anytype-cli.sh — ne pas éditer le
# docker-compose.yml upstream : ce fichier est fusionné automatiquement.
services:

  # anytype-cli bootstrap - create bot account on first run
  anytype-cli_bootstrap:
    image: "ghcr.io/anyproto/anytype-cli:${ANYTYPE_CLI_VERSION}"
    restart: "no"
    depends_on:
      netcheck:
        condition: service_healthy
    volumes:
      - ./etc/client.yml:/etc/anytype/network.yml:ro
      - "${STORAGE_DIR}/anytype-cli:/root/.anytype:Z"
    environment:
      - ANYTYPE_CLI_ACCOUNT_NAME=${ANYTYPE_CLI_ACCOUNT_NAME:-anytype-bot}
    entrypoint: >
      /bin/sh -c "
      if [ ! -f /root/.anytype/config.json ]; then
        echo 'Creating bot account...';
        anytype serve &
        SERVER_PID=$$!;
        sleep 2;
        anytype auth create $${ANYTYPE_CLI_ACCOUNT_NAME} --network-config /etc/anytype/network.yml || true;
        echo 'Waiting for account initialization...';
        sleep 2;
        kill $$SERVER_PID 2>/dev/null || true;
        wait $$SERVER_PID 2>/dev/null || true;
      else
        echo 'Bot account already exists, skipping bootstrap';
      fi;
      exit 0;
      "

  # anytype-cli server (seul le port HTTP API est publié)
  # serve bind 127.0.0.1 par défaut dans le conteneur -> le mapping Docker
  # tombe dans le vide ; on force l'écoute API sur 0.0.0.0.
  anytype-cli:
    image: "ghcr.io/anyproto/anytype-cli:${ANYTYPE_CLI_VERSION}"
    entrypoint: ["anytype"]
    command: ["serve", "--listen-address", "0.0.0.0:31012"]
    restart: unless-stopped
    depends_on:
      anytype-cli_bootstrap:
        condition: service_completed_successfully
    ports:
      - "${ANYTYPE_CLI_API_PORT}:31012"
    volumes:
      - ./etc/client.yml:/etc/anytype/network.yml:ro
      - "${STORAGE_DIR}/anytype-cli:/root/.anytype:Z"
    healthcheck:
      test: nc -z 127.0.0.1 31010 || exit 1
      interval: 30s
      timeout: 5s
      start_period: 15s
      retries: 3
EOF

info "Installation de l'override compose dans le CT ${VMID}..."
pct push "$VMID" "$OVERRIDE_TMP" "${APP_DIR}/docker-compose.override.yml"
rm -f "$OVERRIDE_TMP"

# Variables anytype-cli attendues par l'override : présentes dans .env dérivé de
# .env.example ; on ajoute des défauts si un .env plus ancien ne les a pas.
pct exec "$VMID" -- bash -c "
    set -e
    cd '$APP_DIR'
    grep -q '^ANYTYPE_CLI_VERSION='      .env || echo 'ANYTYPE_CLI_VERSION=latest'          >> .env
    grep -q '^ANYTYPE_CLI_API_PORT='     .env || echo 'ANYTYPE_CLI_API_PORT=31012'          >> .env
    grep -q '^ANYTYPE_CLI_ACCOUNT_NAME=' .env || echo 'ANYTYPE_CLI_ACCOUNT_NAME=anytype-bot' >> .env
"

info "Démarrage du headless (bootstrap compte bot + serveur)..."
pct exec "$VMID" -- bash -c "cd '$APP_DIR' && docker compose up -d anytype-cli"

info "Attente du healthcheck..."
for i in $(seq 1 30); do
    STATUS=$(pct exec "$VMID" -- bash -c "cd '$APP_DIR' && docker inspect -f '{{.State.Health.Status}}' \$(docker compose ps -q anytype-cli)" 2>/dev/null || echo starting)
    [[ "$STATUS" == "healthy" ]] && break
    [[ $i -eq 30 ]] && err "anytype-cli toujours pas healthy après 5 min — logs : pct exec ${VMID} -- bash -c 'cd ${APP_DIR} && docker compose logs anytype-cli anytype-cli_bootstrap'"
    sleep 10
done
info "anytype-cli healthy."

info "Génération de la clé API 'homelab'..."
# Après (re)démarrage, l'auto-login du compte bot prend quelques secondes :
# « API error: application is not running » tant que le compte n'est pas chargé.
APIKEY_OUT=""
for i in $(seq 1 6); do
    APIKEY_OUT=$(pct exec "$VMID" -- bash -c "cd '$APP_DIR' && docker compose exec -T anytype-cli anytype auth apikey create homelab" 2>&1) && break
    [[ $i -eq 6 ]] && err "Création de clé API impossible après 1 min : $APIKEY_OUT"
    sleep 10
done

APP_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo
info "═══ anytype-cli headless actif (CT ${VMID}) ═══"
info "  API HTTP  : http://${APP_IP}:31012 (auth par clé API ci-dessous)"
echo
echo "----- CLÉ API (à stocker : n8n, MCP, scripts) -----"
echo "$APIKEY_OUT"
echo "---------------------------------------------------"
echo
info "Étapes suivantes :"
info "  1. App desktop : Space -> Settings -> Members -> générer un lien d'invitation"
info "  2. Sur le noeud : pct exec ${VMID} -- bash -c \\"
info "       'cd ${APP_DIR} && docker compose exec -T anytype-cli anytype space join \"<lien-invitation>\"'"
info "  3. App desktop : approuver la demande du bot (rôle Editor)"
info "  4. Vérif : docker compose exec -T anytype-cli anytype space list"
