#!/usr/bin/env bash
# Inventaire OS des CT LXC du Proxmox (à lancer sur l'hôte, en root).
# Usage : bash inventaire-os.sh            -> tableau trié par OS
#         bash inventaire-os.sh bullseye   -> uniquement les lignes qui matchent
# CT arrêtés : OS lu depuis le rootfs monté en lecture (pct mount), sans démarrer le CT.

FILTRE="${1:-}"

lire_os() {
    local id=$1 status=$2 v=""
    if [[ "$status" == "running" ]]; then
        # </dev/null : sinon pct exec avale stdin et la boucle se bloque
        v=$(timeout 10 pct exec "$id" -- sh -c '. /etc/os-release; echo "$PRETTY_NAME"' </dev/null 2>/dev/null)
        [[ -n "$v" ]] || v="? (exec sans réponse)"
    else
        local mp="/var/lib/lxc/$id/rootfs"
        pct mount "$id" >/dev/null 2>&1 </dev/null
        if [[ -r "$mp/etc/os-release" ]]; then
            v=$(. "$mp/etc/os-release"; echo "$PRETTY_NAME")
        else
            v="? (rootfs illisible)"
        fi
        pct unmount "$id" >/dev/null 2>&1 </dev/null
        v="$v [arrêté]"
    fi
    echo "$v"
}

{
    for id in $(pct list | awk 'NR>1{print $1}'); do
        name=$(pct config "$id" </dev/null | awk '/^hostname:/{print $2}')
        status=$(pct status "$id" </dev/null | awk '{print $2}')
        printf '%s | %s | %s\n' "$id" "$name" "$(lire_os "$id" "$status")"
    done
} | sort -t'|' -k3 | { [[ -n "$FILTRE" ]] && grep -i -- "$FILTRE" || cat; }

echo
echo "VM (non inspectées, OS à vérifier à la main) :"
qm list </dev/null | awk 'NR>1{print "  " $1 " | " $2 " | " $3}'
