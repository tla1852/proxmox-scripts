#!/usr/bin/env bash
#
# enroll-guests.sh — installe l'agent vulnwatch sur les invités (sur l'hôte Proxmox, en root).
#
#   enroll-guests.sh all                 tous les LXC Debian/Ubuntu démarrés
#   enroll-guests.sh 120 131 newsfeed    LXC choisis (CTID ou nom)
#   enroll-guests.sh --host              l'hôte Proxmox lui-même, en LECTURE SEULE
#   enroll-guests.sh --bundle            écrit /root/vulnwatch-agent-install.sh pour les VM
#                                        (à copier dans la VM puis : bash vulnwatch-agent-install.sh)
#
# Sur chaque invité :
# - utilisateur système `vulnwatch` sans mot de passe
# - authorized_keys : restrict,from="<IP vulnwatch>",command="/usr/local/sbin/vulnwatch-shim"
#   -> la clé ne sert QUE depuis vulnwatch, QUE pour l'agent, sans pty ni redirection
# - sudoers : vulnwatch ALL=(root) NOPASSWD: /usr/local/sbin/vulnwatch-agent (rien d'autre)
# - agent = liste fermée de verbes (inventory, apt-upgrade <pkg>, compose-update <projet>…)
# Prérequis installés si absents (avec confirmation) : openssh-server, sudo.
# Idempotent. Variables : VW_CT (CTID de vulnwatch, sinon trouvé par hostname « vulnwatch »).

set -euo pipefail
trap 'echo -e "\e[31m[ERREUR]\e[0m ligne ${LINENO} : ${BASH_COMMAND}" >&2' ERR

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."
[[ $# -ge 1 ]] || err "usage : $0 all | <CTID|nom>... | --host | --bundle"

# IP LAN d'un CT : 1re IPv4 hors bridges Docker (172.16/12) et tailnet (100.64/10),
# même règle que vulnwatch/proxmox.py:_usable_ip (hostname -I peut lister docker0 en 1er).
lan_ip() {
    pct exec "$1" -- hostname -I </dev/null | tr ' ' '\n' \
      | grep -E '^[0-9]+(\.[0-9]+){3}$' \
      | grep -vE '^(127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' \
      | head -n1 || true
}

VW_CT="${VW_CT:-$(pct list | awk '$3 == "vulnwatch" {print $1}')}"
[[ -n "$VW_CT" ]] || err "CT vulnwatch introuvable (VW_CT=<id> pour le préciser)."
VW_IP=$(lan_ip "$VW_CT")
PUBKEY=$(pct exec "$VW_CT" -- cat /var/lib/vulnwatch/.ssh/id_ed25519.pub)
[[ -n "$VW_IP" && "$PUBKEY" == ssh-ed25519* ]] || err "IP ou clé publique de vulnwatch illisible (CT ${VW_CT})."
info "vulnwatch : CT ${VW_CT}, ${VW_IP}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pct pull "$VW_CT" /opt/vulnwatch/app/agent/vulnwatch-agent "$TMP/agent"
pct pull "$VW_CT" /opt/vulnwatch/app/agent/vulnwatch-shim "$TMP/shim"

# ----- Bundle autonome (même installeur pour LXC, VM et hôte) -----
BUNDLE="$TMP/install.sh"
{
cat <<EOF
#!/usr/bin/env bash
# Installeur de l'agent vulnwatch (généré par enroll-guests.sh le $(date -I)).
# Usage dans l'invité, en root : bash vulnwatch-agent-install.sh [--readonly] [--yes]
set -euo pipefail
VW_IP='${VW_IP}'
PUBKEY='${PUBKEY}'
AGENT_B64='$(base64 -w0 "$TMP/agent")'
SHIM_B64='$(base64 -w0 "$TMP/shim")'
EOF
cat <<'EOF'
READONLY=0; YES=0
for a in "$@"; do case "$a" in --readonly) READONLY=1 ;; --yes) YES=1 ;; esac; done
[[ $EUID -eq 0 ]] || { echo "root requis" >&2; exit 1; }
command -v dpkg >/dev/null || { echo "NON_SUPPORTE: pas de dpkg (Debian/Ubuntu seulement)"; exit 3; }
missing=()
command -v sudo >/dev/null || missing+=(sudo)
command -v sshd >/dev/null || [[ -x /usr/sbin/sshd ]] || missing+=(openssh-server)
if [[ ${#missing[@]} -gt 0 ]]; then
    if [[ $YES -eq 1 ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y -qq "${missing[@]}" >/dev/null
    else
        echo "MANQUANT: ${missing[*]}"; exit 4
    fi
fi
id vulnwatch >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/vulnwatch-agent --shell /bin/sh vulnwatch
passwd -l vulnwatch >/dev/null 2>&1 || true
echo "$AGENT_B64" | base64 -d > /usr/local/sbin/vulnwatch-agent
echo "$SHIM_B64"  | base64 -d > /usr/local/sbin/vulnwatch-shim
chown root:root /usr/local/sbin/vulnwatch-agent /usr/local/sbin/vulnwatch-shim
chmod 0755 /usr/local/sbin/vulnwatch-agent /usr/local/sbin/vulnwatch-shim
H=$(getent passwd vulnwatch | cut -d: -f6)
install -d -o vulnwatch -g vulnwatch -m 0700 "$H/.ssh"
printf 'restrict,from="%s",command="/usr/local/sbin/vulnwatch-shim" %s\n' "$VW_IP" "$PUBKEY" > "$H/.ssh/authorized_keys"
chown vulnwatch:vulnwatch "$H/.ssh/authorized_keys"; chmod 0600 "$H/.ssh/authorized_keys"
cat > /etc/sudoers.d/vulnwatch.tmp <<'SUDO'
# vulnwatch : uniquement l'agent (verbes et arguments validés par l'agent lui-même)
Defaults:vulnwatch !requiretty
vulnwatch ALL=(root) NOPASSWD: /usr/local/sbin/vulnwatch-agent
SUDO
chmod 0440 /etc/sudoers.d/vulnwatch.tmp
visudo -cf /etc/sudoers.d/vulnwatch.tmp >/dev/null && mv /etc/sudoers.d/vulnwatch.tmp /etc/sudoers.d/vulnwatch
if [[ $READONLY -eq 1 ]]; then echo "READONLY=1" > /etc/vulnwatch-agent.conf; else rm -f /etc/vulnwatch-agent.conf; fi
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now ssh.socket >/dev/null 2>&1 || true
if sshd -T 2>/dev/null | grep -qiE '^(allowusers|allowgroups) '; then
    echo "ATTENTION: AllowUsers/AllowGroups dans sshd_config : ajouter vulnwatch"
fi
echo "AGENT_OK readonly=$READONLY"
EOF
} > "$BUNDLE"
chmod 0700 "$BUNDLE"

# Test de bout en bout depuis vulnwatch (enregistre aussi la clé d'hôte, TOFU)
test_from_vw() { # <ip>
    pct exec "$VW_CT" -- sudo -u vulnwatch ssh -i /var/lib/vulnwatch/.ssh/id_ed25519 \
        -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/var/lib/vulnwatch/.ssh/known_hosts -o LogLevel=ERROR \
        "vulnwatch@$1" ping 2>&1 </dev/null
}

case "$1" in
--bundle)
    install -m 0600 "$BUNDLE" /root/vulnwatch-agent-install.sh
    info "Écrit : /root/vulnwatch-agent-install.sh (contient la clé PUBLIQUE de vulnwatch, pas de secret)."
    info "Pour une VM : scp /root/vulnwatch-agent-install.sh root@<vm>: && ssh root@<vm> bash vulnwatch-agent-install.sh --yes"
    info "Si la VM n'a pas qemu-guest-agent : VW_HOST_OVERRIDES=<vmid>=<ip> dans /etc/vulnwatch/env du CT ${VW_CT}."
    exit 0 ;;
--host)
    warn "L'hôte Proxmox sera inventorié en LECTURE SEULE (aucune MAJ possible depuis vulnwatch)."
    bash "$BUNDLE" --readonly --yes
    HIP=$(ip -4 -o addr show vmbr0 | awk '{print $4}' | cut -d/ -f1 | head -n1)
    out=$(test_from_vw "$HIP") && info "hôte : ${out}" || warn "hôte : test KO : ${out}"
    exit 0 ;;
all)
    TARGETS=$(pct list | awk 'NR>1 && $2 == "running" {print $1}') ;;
*)
    TARGETS=""
    for t in "$@"; do
        if [[ "$t" =~ ^[0-9]+$ ]]; then TARGETS+=" $t"
        else id=$(pct list | awk -v n="$t" '$3 == n {print $1}'); [[ -n "$id" ]] || err "LXC '$t' introuvable"; TARGETS+=" $id"; fi
    done ;;
esac

OK=(); KO=(); SKIP=(); NEED=()
for id in $TARGETS; do
    name=$(pct config "$id" </dev/null | awk '/^hostname:/{print $2}')
    pct status "$id" </dev/null | grep -q running || { SKIP+=("$id/$name (arrêté)"); continue; }
    pct push "$id" "$BUNDLE" /root/.vulnwatch-agent-install.sh --perms 0700 </dev/null
    set +e
    res=$(pct exec "$id" -- bash /root/.vulnwatch-agent-install.sh </dev/null 2>&1); rc=$?
    set -e
    if [[ $rc -eq 4 ]]; then
        NEED+=("$id"); warn "${id}/${name} : ${res}"
    elif [[ $rc -eq 3 ]]; then
        SKIP+=("$id/$name (non Debian/Ubuntu)")
    elif [[ $rc -ne 0 ]]; then
        KO+=("$id/$name : install : ${res##*$'\n'}")
    fi
    pct exec "$id" -- rm -f /root/.vulnwatch-agent-install.sh </dev/null || true
    [[ $rc -eq 0 ]] || continue
    grep -q ATTENTION <<<"$res" && warn "${id}/${name} : $(grep ATTENTION <<<"$res")"
    ip=$(lan_ip "$id")
    [[ -n "$ip" ]] || { KO+=("$id/$name : aucune IP LAN (hostname -I : $(pct exec "$id" -- hostname -I </dev/null))"); continue; }
    if out=$(test_from_vw "$ip"); then OK+=("$id/$name"); else KO+=("$id/$name : ${out}"); fi
done

if [[ ${#NEED[@]} -gt 0 ]]; then
    echo
    warn "${#NEED[@]} LXC sans openssh-server et/ou sudo : ${NEED[*]}"
    read -rp "Les installer (openssh-server écoutera sur le LAN, clé vulnwatch seulement) ? [o/N] : " r
    if [[ "$r" =~ ^[oOyY]$ ]]; then
        for id in "${NEED[@]}"; do
            name=$(pct config "$id" </dev/null | awk '/^hostname:/{print $2}')
            pct push "$id" "$BUNDLE" /root/.vulnwatch-agent-install.sh --perms 0700 </dev/null
            if pct exec "$id" -- bash /root/.vulnwatch-agent-install.sh --yes </dev/null >/dev/null 2>&1; then
                ip=$(lan_ip "$id")
                if out=$(test_from_vw "$ip"); then OK+=("$id/$name"); else KO+=("$id/$name : ${out}"); fi
            else
                KO+=("$id/$name : install avec paquets échouée")
            fi
            pct exec "$id" -- rm -f /root/.vulnwatch-agent-install.sh </dev/null || true
        done
    else
        for id in "${NEED[@]}"; do SKIP+=("$id (prérequis refusés)"); done
    fi
fi

echo
info "Agents OK (${#OK[@]}) : ${OK[*]:-aucun}"
[[ ${#SKIP[@]} -eq 0 ]] || warn "Ignorés (${#SKIP[@]}) : ${SKIP[*]}"
for k in "${KO[@]}"; do warn "KO : $k"; done
info "VM : enroll-guests.sh --bundle ; hôte : enroll-guests.sh --host ; puis « Lancer un scan » dans l'UI."
