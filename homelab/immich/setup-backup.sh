#!/usr/bin/env bash
#
# setup-backup.sh — sauvegarde nocturne CHIFFRÉE de la bibliothèque Immich vers
# Google Drive (rclone crypt), à lancer sur l'hôte Proxmox en root, après
# setup-app.sh. Relançable : la config rclone existante est conservée.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/immich/setup-backup.sh) <VMID>
#
# Ce qui part sur Drive (gdrive:immich-backup, chiffré noms + contenu) :
#   - data/   : /mnt/immich SAUF thumbs/ et encoded-video/ (régénérables) ;
#               inclut library/, upload/, profile/ et backups/ (dumps Postgres
#               faits par Immich chaque nuit à 02:00, 14 conservés)
#   - config/ : /opt/immich/.env et docker-compose.yml
#   - deleted/<date>/ : fichiers supprimés ou modifiés côté Immich, gardés 90 j
#                      (filet contre une suppression accidentelle)
# Timer systemd immich-backup.timer à 03:30. Quota Google : 750 Go envoyés par
# jour → le premier envoi s'étale sur plusieurs nuits (le service finit en
# échec ces nuits-là, c'est normal ; il reprend où il s'est arrêté).
#
# !! Les deux mots de passe crypt sont générés ici et affichés UNE fois.
# !! Sans eux, la sauvegarde est illisible : les ranger dans le gestionnaire
# !! de mots de passe AVANT de fermer le terminal.

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

VMID="${1:-}"
[[ -n "$VMID" ]] || err "Usage : setup-backup.sh <VMID du CT Immich>"
pct status "$VMID" 2>/dev/null | grep -q running || err "CT ${VMID} introuvable ou arrêté."
pct exec "$VMID" -- test -f /opt/immich/.env || err "Immich absent du CT ${VMID} : lancer setup-app.sh d'abord."
pct exec "$VMID" -- test -f /mnt/immich/upload/.immich || err "/mnt/immich vide dans le CT : NFS non monté ?"

info "Installation de rclone (CT ${VMID})..."
pct exec "$VMID" -- bash -c "command -v rclone >/dev/null || curl -fsSL https://rclone.org/install.sh | bash >/dev/null"

# ----- Remotes rclone -----
if pct exec "$VMID" -- bash -c "rclone listremotes | grep -qx 'gcrypt:'"; then
    info "Remotes gdrive:/gcrypt: déjà configurés, conservés."
else
    echo
    echo "Accès Google Drive. Facultatif mais conseillé : un client OAuth à toi"
    echo "(console.cloud.google.com > API Google Drive > identifiants « Application de bureau »),"
    echo "sinon rclone utilise son client partagé, souvent bridé. Laisser vide pour s'en passer."
    read -rp "client_id Google (vide = client rclone) : " GD_CLIENT_ID
    GD_CLIENT_SECRET=""
    [[ -n "$GD_CLIENT_ID" ]] && { read -rsp "client_secret Google : " GD_CLIENT_SECRET; echo; }
    echo
    echo "Sur un PC avec navigateur et rclone installé, lancer :"
    if [[ -n "$GD_CLIENT_ID" ]]; then
        echo "    rclone authorize \"drive\" \"${GD_CLIENT_ID}\" \"<client_secret>\""
    else
        echo "    rclone authorize \"drive\""
    fi
    echo "se connecter au compte Google (celui des 5 To), puis coller ici le JSON"
    echo "affiché entre les flèches (une seule ligne, {\"access_token\":...})."
    read -rsp "Jeton : " GD_TOKEN; echo
    [[ "$GD_TOKEN" =~ ^\{.*refresh_token.*\}$ ]] || err "Jeton invalide (JSON avec refresh_token attendu)."

    pct exec "$VMID" -- env GD_TOKEN="$GD_TOKEN" GD_CLIENT_ID="$GD_CLIENT_ID" GD_CLIENT_SECRET="$GD_CLIENT_SECRET" bash -s <<'RCLONE'
set -euo pipefail
# scope drive.file : rclone ne voit que les fichiers qu'il a lui-même créés
rclone config create gdrive drive scope=drive.file \
    client_id="$GD_CLIENT_ID" client_secret="$GD_CLIENT_SECRET" \
    token="$GD_TOKEN" --non-interactive >/dev/null
P1=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-40)
P2=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-40)
# config create obscurcit lui-même les champs mot de passe
rclone config create gcrypt crypt remote=gdrive:immich-backup \
    filename_encryption=standard directory_name_encryption=true \
    password="$P1" password2="$P2" --non-interactive >/dev/null
umask 077
cat > /root/immich-backup-CLES.txt <<EOF
Sauvegarde Immich → Google Drive (dossier immich-backup, rclone crypt)
Sans ces deux valeurs, la sauvegarde est ILLISIBLE.

password  = $P1
password2 = $P2

Restauration depuis n'importe quelle machine :
  rclone config create gdrive drive scope=drive.file   (+ token via rclone authorize "drive")
  rclone config create gcrypt crypt remote=gdrive:immich-backup password=<password> password2=<password2>
  rclone copy gcrypt:data /mnt/immich --progress
EOF
rclone mkdir gcrypt:data
RCLONE
    unset GD_TOKEN GD_CLIENT_SECRET
    info "Remotes créés."
    echo
    pct exec "$VMID" -- cat /root/immich-backup-CLES.txt
    echo
    warn "Copier MAINTENANT password et password2 dans le gestionnaire de mots de passe."
    warn "Copie aussi dans le CT : /root/immich-backup-CLES.txt (perdue si le CT disparaît)."
    read -rp "Entrée une fois les clés rangées..." _
fi

# ----- Script + timer -----
info "Installation du service immich-backup..."
pct exec "$VMID" -- bash -s <<'TIMER'
set -euo pipefail
cat > /usr/local/bin/immich-backup <<'EOF'
#!/usr/bin/env bash
# Sauvegarde Immich → gcrypt: (cf. homelab/immich/setup-backup.sh)
set -euo pipefail
SRC=/mnt/immich
LOG=/var/log/immich-backup.log
exec 9>/run/immich-backup.lock
flock -n 9 || { echo "Sauvegarde déjà en cours."; exit 0; }
# Garde-fou : NFS absent = dossier vide = sync qui effacerait tout le distant
[[ -f "$SRC/upload/.immich" && -f "$SRC/library/.immich" ]] \
    || { echo "Fichiers témoins .immich absents dans $SRC : NFS non monté ? Abandon." >&2; exit 1; }
DAY=$(date +%F)
rclone copy /opt/immich gcrypt:config --include ".env" --include "docker-compose.yml" --log-file "$LOG"
rclone sync "$SRC" gcrypt:data \
    --exclude "/thumbs/**" --exclude "/encoded-video/**" --exclude "/.rw-test" \
    --backup-dir "gcrypt:deleted/$DAY" \
    --drive-stop-on-upload-limit \
    --transfers 4 --checkers 8 --fast-list \
    --log-level INFO --stats 10m --stats-one-line --log-file "$LOG"
rclone delete gcrypt:deleted --min-age 90d --log-file "$LOG"
rclone rmdirs gcrypt:deleted --leave-root --log-file "$LOG"
echo "$(date -Is) OK" >> "$LOG"
EOF
chmod 755 /usr/local/bin/immich-backup

cat > /etc/systemd/system/immich-backup.service <<'EOF'
[Unit]
Description=Sauvegarde Immich chiffrée vers Google Drive
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/immich-backup
Nice=10
IOSchedulingClass=idle
EOF

cat > /etc/systemd/system/immich-backup.timer <<'EOF'
[Unit]
Description=Sauvegarde Immich chaque nuit (après les dumps Postgres d'Immich à 02:00)

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/logrotate.d/immich-backup <<'EOF'
/var/log/immich-backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
systemctl daemon-reload
systemctl enable --now immich-backup.timer >/dev/null
TIMER

info "Test d'accès au Drive..."
pct exec "$VMID" -- rclone lsd gcrypt: >/dev/null || err "gcrypt: injoignable (jeton Google ?)."

echo
info "Sauvegarde configurée (CT ${VMID})."
info "  Prochaine : $(pct exec "$VMID" -- systemctl show immich-backup.timer -p NextElapseUSecRealtime --value)"
info "  Lancer    : pct exec ${VMID} -- systemctl start --no-block immich-backup"
info "  Suivre    : pct exec ${VMID} -- tail -f /var/log/immich-backup.log"
info "  État      : pct exec ${VMID} -- systemctl status immich-backup"
info "  Contenu   : pct exec ${VMID} -- rclone size gcrypt:data"
