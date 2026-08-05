#!/usr/bin/env bash
# Enrôle un LXC Proxmox sur le tailnet Headscale.
#
# À lancer DEPUIS L'HÔTE PROXMOX (le LXC est redémarré : toute session ouverte
# à l'intérieur — ex. claude-dev — est coupée).
#
# Usage : ./enroll-lxc.sh <CTID|nom>
#   ex.  ./enroll-lxc.sh claude-dev
#
set -euo pipefail

HEADSCALE_CT=145
LOGIN_SERVER="https://headscale.survivalmode.familyds.org"
HS_USER="thibault"

die() { echo "ERREUR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ $# -eq 1 ]] || die "usage: $0 <CTID|nom>"
TARGET="$1"

command -v pct >/dev/null || die "pct introuvable : ce script se lance sur l'hôte Proxmox."

# --- Résolution CTID ---------------------------------------------------------
if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  CTID="$TARGET"
else
  CTID=$(pct list | awk -v n="$TARGET" '$3 == n {print $1}')
  [[ -n "$CTID" ]] || die "aucun LXC nommé '$TARGET' (voir: pct list)"
fi
CONF="/etc/pve/lxc/${CTID}.conf"
[[ -f "$CONF" ]] || die "$CONF introuvable"
NAME=$(pct config "$CTID" | awk '/^hostname:/ {print $2}')
echo "Cible : CTID=$CTID  hostname=$NAME"

# --- 1. /dev/net/tun ---------------------------------------------------------
if pct exec "$CTID" -- test -c /dev/net/tun 2>/dev/null; then
  step "1/5 /dev/net/tun déjà présent — pas de reboot"
else
  step "1/5 Ajout de /dev/net/tun dans $CONF puis reboot du LXC"
  grep -q 'dev/net/tun' "$CONF" || cat >> "$CONF" <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
  pct reboot "$CTID"
  for _ in $(seq 1 30); do
    sleep 2
    pct exec "$CTID" -- test -c /dev/net/tun 2>/dev/null && break
  done
  pct exec "$CTID" -- test -c /dev/net/tun \
    || die "/dev/net/tun toujours absent après reboot"
  echo "OK : /dev/net/tun disponible dans le LXC"
fi

# --- 2. Clé de pré-authentification -----------------------------------------
step "2/5 Génération d'une clé Headscale (réutilisable, 24 h)"
KEY=$(pct exec "$HEADSCALE_CT" -- docker exec headscale \
        headscale preauthkeys create --user "$HS_USER" --reusable --expiration 24h \
      | tr -d '\r' | tail -n1)
[[ -n "$KEY" ]] || die "clé vide (headscale CT $HEADSCALE_CT injoignable ?)"
echo "clé obtenue (${KEY:0:12}…)"

# --- 3. Installation Tailscale ----------------------------------------------
step "3/5 Installation de Tailscale dans le LXC"
if pct exec "$CTID" -- test -x /usr/bin/tailscale; then
  echo "déjà installé"
else
  pct exec "$CTID" -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
fi
pct exec "$CTID" -- systemctl enable --now tailscaled

# --- 4. Enrôlement -----------------------------------------------------------
step "4/5 Enrôlement sur $LOGIN_SERVER"
pct exec "$CTID" -- tailscale up \
  --login-server "$LOGIN_SERVER" \
  --authkey "$KEY" \
  --hostname "$NAME" \
  --accept-dns=false
TSIP=$(pct exec "$CTID" -- tailscale ip -4 | tr -d '\r')
[[ -n "$TSIP" ]] || die "pas d'IP tailnet attribuée"

# --- 5. Vérifications --------------------------------------------------------
step "5/5 Vérifications"
pct exec "$CTID" -- systemctl is-active ssh >/dev/null 2>&1 \
  || pct exec "$CTID" -- systemctl enable --now ssh || true
pct exec "$HEADSCALE_CT" -- docker exec headscale headscale nodes list

cat <<EOF

=========================================================
  $NAME (CT $CTID) enrôlé sur le tailnet
  IP tailnet : $TSIP
  Accès      : ssh thibault@$TSIP
  mRemoteNG  : utiliser $TSIP (pas l'IP 192.168.1.x)
=========================================================
EOF
