#!/usr/bin/env bash
# =====================================================================
# changer-mdp.sh — change le mot de passe d'un compte Authelia (fichier)
#
# À lancer DANS le LXC Authelia, en root, depuis un terminal interactif :
#   pct exec <VMID> -- bash /root/changer-mdp.sh [utilisateur]
#
# Contourne le portail web : celui-ci exige un code envoyé par e-mail, or
# le notifier est un simple fichier. Le mot de passe est saisi au clavier
# (masqué), haché en argon2id par Authelia, puis écrit dans users.yml,
# qu'Authelia recharge seul (watch: true). TOTP et sessions inchangés.
# =====================================================================
set -euo pipefail

USERS="${USERS_FILE:-/opt/authelia/config/users.yml}"

info() { echo -e "\e[32m[+]\e[0m $*"; }
die()  { echo -e "\e[31m[x]\e[0m $*" >&2; exit 1; }

[[ -f "$USERS" ]] || die "$USERS introuvable : mauvais conteneur ?"
[[ -t 0 ]] || die "Terminal interactif requis (saisie du mot de passe)."

COMPTE="${1:-$(awk '/^  [^ #][^:]*:[[:space:]]*$/ { sub(/^  /, ""); sub(/:.*/, ""); print; exit }' "$USERS")}"
grep -q "^  ${COMPTE}:[[:space:]]*$" "$USERS" || die "Compte « ${COMPTE} » absent de $USERS."
info "Compte : ${COMPTE}"

read -r -s -p "Nouveau mot de passe : " P1; echo
read -r -s -p "Confirmation         : " P2; echo
[[ "$P1" == "$P2" ]] || die "Les deux saisies diffèrent."
(( ${#P1} >= 12 )) || die "12 caractères minimum."

HASH=$(docker exec -e P="$P1" authelia sh -c 'authelia crypto hash generate argon2 --password "$P"' \
    | sed -n 's/^Digest: //p')
unset P1 P2
[[ "$HASH" == \$argon2id\$* ]] || die "Échec du hachage."

cp -p "$USERS" "${USERS}.avant-mdp"
HASH="$HASH" awk -v compte="$COMPTE" '
    /^  [^ #][^:]*:[[:space:]]*$/ { courant = $0; sub(/^  /, "", courant); sub(/:.*/, "", courant) }
    courant == compte && /^    password:/ && !fait { print "    password: \047" ENVIRON["HASH"] "\047"; fait = 1; next }
    { print }
    END { exit fait ? 0 : 1 }
' "${USERS}.avant-mdp" > "${USERS}.nouveau" \
    || { rm -f "${USERS}.nouveau"; die "Ligne « password » du compte introuvable, rien modifié."; }

# Écriture en place : le fichier est monté dans le conteneur, son inode doit rester le même
cat "${USERS}.nouveau" > "$USERS"
rm -f "${USERS}.nouveau"

sleep 3
if docker logs --since 10s authelia 2>&1 | grep -qi 'level=error'; then
    cat "${USERS}.avant-mdp" > "$USERS"
    die "Authelia signale une erreur après rechargement : ancien fichier restauré. Voir : docker logs authelia"
fi
rm -f "${USERS}.avant-mdp"
info "Mot de passe changé pour ${COMPTE}. L'ancien ne fonctionne plus."
