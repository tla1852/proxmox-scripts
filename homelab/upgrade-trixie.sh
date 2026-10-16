#!/usr/bin/env bash
# Montée de version Debian 12 (bookworm) -> 13 (trixie) d'un CT LXC, sur place.
# À lancer sur l'hôte Proxmox, en root :  bash upgrade-trixie.sh <VMID>
# Étapes : vérif OS -> snapshot -> maj bookworm -> sources trixie -> full-upgrade -> reboot -> contrôle.
# Retour arrière : pct rollback <VMID> <snapshot affiché>
set -euo pipefail

ID="${1:-}"
[[ "$ID" =~ ^[0-9]+$ ]] || { echo "Usage : bash $0 <VMID>"; exit 1; }

info() { echo -e "\e[1;34m[*]\e[0m $*"; }
ok()   { echo -e "\e[1;32m[ok]\e[0m $*"; }
err()  { echo -e "\e[1;31m[x]\e[0m $*"; exit 1; }

# </dev/null partout : pct exec lit stdin sinon
cx() { pct exec "$ID" -- bash -c "$1" </dev/null; }

pct status "$ID" </dev/null | grep -q running || err "CT $ID pas démarré."
NAME=$(pct config "$ID" </dev/null | awk '/^hostname:/{print $2}')
CODENAME=$(cx '. /etc/os-release; echo $VERSION_CODENAME')
[[ "$CODENAME" == "bookworm" ]] || err "CT $ID ($NAME) est en '$CODENAME', pas bookworm."

SNAP="pre_trixie_$(date +%Y%m%d_%H%M)"
info "Snapshot $SNAP de $ID ($NAME)..."
pct snapshot "$ID" "$SNAP" --description "avant upgrade Debian 13" </dev/null \
    || err "Snapshot impossible (stockage sans snapshot ?). Fais un vzdump avant : vzdump $ID --mode snapshot"
ok "Snapshot créé."

APT='DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'

info "Mise à jour bookworm complète d'abord..."
cx "apt-get update -q && $APT full-upgrade"

info "Dépôts tiers (vérifie qu'ils publient une version trixie) :"
cx "grep -rhE '^(deb |URIs:)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v debian.org || echo '  aucun'"

info "Bascule des sources bookworm -> trixie..."
cx "sed -i 's/bookworm/trixie/g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true"
cx "apt-get update -q" || err "apt update en échec (dépôt tiers sans trixie ?). Corrige ou : pct rollback $ID $SNAP"

info "Upgrade vers trixie (quelques minutes)..."
cx "$APT upgrade --without-new-pkgs && $APT full-upgrade && $APT autoremove --purge"

info "Redémarrage du CT..."
pct reboot "$ID" </dev/null
for _ in $(seq 1 30); do
    sleep 2
    cx 'true' 2>/dev/null && break
done
sleep 5

echo
ok "$(cx '. /etc/os-release; echo $PRETTY_NAME')"
info "Services en échec :"
cx "systemctl --failed --no-legend || true"
info "Ports en écoute :"
cx "ss -tlnH | awk '{print \$4}' | sort -u | tr '\n' ' '; echo"
echo
echo "Teste l'appli. Si cassée : pct rollback $ID $SNAP"
echo "Si OK après quelques jours : pct delsnapshot $ID $SNAP"
