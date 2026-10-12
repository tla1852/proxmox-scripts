#!/usr/bin/env bash
# =====================================================================
# theme-sombre.sh — thème sombre pour l'interface web de Guacamole
#
# À lancer DANS le LXC Guacamole (créé par create-lxc-guacamole.sh), en root :
#   pct exec <VMID> -- bash /root/theme-sombre.sh
#
# Guacamole n'a pas de mode sombre natif. Ce script fabrique une extension
# « branding » (un .jar ne contenant qu'un manifeste et une feuille CSS),
# la dépose dans /opt/guacamole/home/extensions et la fait charger par le
# conteneur (GUACAMOLE_HOME). Le thème est donc servi par le serveur :
# identique sur tous les postes, rien à installer côté navigateur.
#
# Idempotent : relancer le script après modification du CSS met à jour le
# thème. Retrait : supprimer le .jar puis
#   cd /opt/guacamole && docker compose up -d --force-recreate guacamole
#
# Sélecteurs établis d'après les sources de guacamole-client 1.6.0.
# =====================================================================
set -euo pipefail

APP_DIR="/opt/guacamole"
HOME_DIR="${APP_DIR}/home"
TPL="/etc/guacamole-tpl"
JAR="${HOME_DIR}/extensions/theme-sombre.jar"

info() { echo -e "\e[32m[+]\e[0m $*"; }
die()  { echo -e "\e[31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "À lancer en root."
[[ -f "${APP_DIR}/docker-compose.yml" ]] || die "${APP_DIR}/docker-compose.yml introuvable : mauvais conteneur ?"
cd "${APP_DIR}"

command -v zip >/dev/null || { info "Installation de zip"; apt-get update -qq; apt-get install -y -qq zip >/dev/null; }

# --- 1. Extension -----------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/guac-manifest.json" <<'JSON'
{
    "guacamoleVersion" : "*",
    "name"             : "Theme sombre",
    "namespace"        : "theme-sombre",
    "css"              : [ "sombre.css" ]
}
JSON

cat > "${WORK}/sombre.css" <<'CSS'
/* theme-sombre — interface sombre pour Guacamole 1.6.0 */

:root {
    color-scheme: dark;
    --ts-fond:     #1b1d21;
    --ts-surface:  #24272c;
    --ts-releve:   #2d3138;
    --ts-champ:    #15171a;
    --ts-texte:    #e3e5e8;
    --ts-attenue:  #9aa0a8;
    --ts-bord:     rgba(255, 255, 255, 0.12);
    --ts-voile:    rgba(255, 255, 255, 0.05);
    --ts-survol:   #33473a;
    --ts-choisi:   #2c5a3c;
    --ts-lien:     #7ab4ff;
}

/* --- Fond et texte ---------------------------------------------------- */

body,
div.login-ui,
.logged-out-modal guac-modal,
.automatic-login-rejected-modal guac-modal {
    background: var(--ts-fond);
    color: var(--ts-texte);
}

/* La vue session garde son fond noir d'origine */
body.client { background: black; }

a[href] { color: var(--ts-lien); }

.list-item .name,
.user a, .user a:hover, .user a:visited,
.user-group a, .user-group a:hover, .user-group a:visited,
.connection a, .connection a:hover, .connection a:visited,
.connection-group a, .connection-group a:hover, .connection-group a:visited,
.menu-dropdown .menu-contents li a,
.page-tabs .page-list li a[href],
.page-tabs .page-list li a[href]:visited,
.section-tabs li a,
.settings.connections .connection-list .new-connection a,
.settings.connections .connection-list .new-connection a:hover,
.settings.connections .connection-list .new-connection a:visited,
.settings.connections .connection-list .new-connection-group a,
.settings.connections .connection-list .new-connection-group a:hover,
.settings.connections .connection-list .new-connection-group a:visited,
.settings.connections .connection-list .new-sharing-profile a,
.settings.connections .connection-list .new-sharing-profile a:hover,
.settings.connections .connection-list .new-sharing-profile a:visited {
    color: var(--ts-texte);
}

.list-item .usage,
.settings.users table.user-list tr.user.disabled,
.settings.users table.user-list tr.user.disabled td.username a[href],
.settings.user-groups table.user-group-list tr.user-group.disabled,
.settings.user-groups table.user-group-list tr.user-group.disabled td.user-group-name a[href] {
    color: var(--ts-attenue);
}

.transfer.savable .filename,
.settings.connectionHistory a.history-session-recording,
.terminal-color-scheme-field .custom-color-scheme-hide-details,
.terminal-color-scheme-field .custom-color-scheme-show-details {
    color: var(--ts-lien);
}

/* --- En-têtes, onglets, sections -------------------------------------- */

.header,
.attributes .form h3,
.notification .title-bar,
#filesystem-menu .header.breadcrumbs {
    background: var(--ts-voile);
    border-bottom: 1px solid var(--ts-bord);
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.4);
}

.attributes .form h3,
.header:not(.ng-hide) ~ * .header,
.header:not(.ng-hide) ~ .header {
    border-top: 1px solid var(--ts-bord);
}

.page-tabs .page-list ul,
.section-tabs ul {
    background: var(--ts-voile);
    border-bottom: 1px solid var(--ts-bord);
}

.page-tabs .page-list li a[href].current,
.page-tabs .page-list li a[href].current:hover,
.section-tabs li a.current,
.section-tabs li a.current:hover {
    background: rgba(255, 255, 255, 0.16);
}

.connection-parameters .form .fields,
.preferences .form .fields {
    border-left: 3px solid var(--ts-bord);
}

/* --- Survol et sélection (remplace les verts clairs d'origine) -------- */

.page-tabs .page-list li a[href]:hover,
.section-tabs li a:hover,
.menu-dropdown .menu-contents li a:hover,
.recent-connections .connection:hover,
.list-item:not(.selected) .caption:hover,
.settings table.session-list tr.session:hover,
#filesystem-menu .header.breadcrumbs .breadcrumb:hover,
.client-zoom .client-zoom-out:hover,
.client-zoom .client-zoom-in:hover {
    background-color: var(--ts-survol);
}

.list-item.selected { background: var(--ts-choisi); }

.file-browser .list-item.focused .caption {
    border: 1px dotted rgba(255, 255, 255, 0.5);
    background: var(--ts-survol);
}

.expandable.expanded > .children > .list-item:before { border-left-color: #555; }
.expandable.expanded > .children > .list-item:after  { border-bottom-color: #555; }

/* --- Champs de saisie ------------------------------------------------- */

div.location,
input[type=text],
input[type=email],
input[type=number],
input[type=password],
textarea,
select {
    background: var(--ts-champ);
    color: var(--ts-texte);
    border: 1px solid #555;
}

.header .filter input,
.connection-select-menu .menu-dropdown .menu-contents .filter input {
    background-color: transparent;
    border-color: var(--ts-bord);
}

.client-zoom .client-zoom-state input {
    background: transparent;
    border-color: var(--ts-bord);
}

.location-chooser .dropdown {
    background: var(--ts-surface);
    border: 1px solid #555;
}

.redirect-field-container,
.clipboard,
.clipboard-service-target {
    background: var(--ts-champ);
    color: var(--ts-texte);
}

.clipboard { border: 1px solid #555; }

.terminal-color-scheme-field .custom-color-scheme {
    background: var(--ts-surface);
    border: 1px solid #555;
}

/* --- Boutons ----------------------------------------------------------- */

input[type="submit"],
button,
a.button {
    background-color: #3d434c;
    border: 1px solid rgba(255, 255, 255, 0.15);
    color: white;
}

input[type="submit"]:hover, button:hover, a.button:hover    { background-color: #4f5763; }
input[type="submit"]:active, button:active, a.button:active { background-color: #2c3138; }

button.danger, a.button.danger               { background: #A43; }
button.danger:hover, a.button.danger:hover   { background: #C54; }
button.danger:active, a.button.danger:active { background: #932; }

input[type="submit"]:disabled,
button:disabled,
button.danger:disabled {
    background-color: #3d434c;
}

/* --- Menus déroulants -------------------------------------------------- */

.menu-dropdown {
    border-left: 1px solid var(--ts-bord);
    background: var(--ts-voile);
}

.menu-dropdown:hover { background: rgba(255, 255, 255, 0.09); }

.menu-dropdown.open,
.menu-dropdown.open:hover { background: rgba(255, 255, 255, 0.16); }

.menu-dropdown .menu-contents {
    background: var(--ts-releve);
    box-shadow: 0 2px 6px rgba(0, 0, 0, 0.5);
    border-left: 1px solid var(--ts-bord);
    border-bottom: 1px solid var(--ts-bord);
}

.menu-dropdown .menu-contents li a.current,
.menu-dropdown .menu-contents li a.current:hover { background-color: transparent; }

.menu-dropdown .menu-contents li a.danger       { color: white; background-color: #A43; }
.menu-dropdown .menu-contents li a.danger:hover { background-color: #C54; }

.user-menu .menu-dropdown .menu-contents .profile { border-bottom: 1px solid var(--ts-bord); }

/* --- Panneau latéral de session (Ctrl+Alt+Maj) ------------------------- */

.menu {
    background: var(--ts-surface);
    color: var(--ts-texte);
    box-shadow: 1px 0 4px black;
}

#guac-menu #devices .device,
#guac-menu #share-links {
    border: 1px solid var(--ts-bord);
    background: var(--ts-voile);
}

#guac-menu #devices .device:hover { border-color: white; }

.client-zoom .client-zoom-out,
.client-zoom .client-zoom-in {
    border: 1px solid rgba(255, 255, 255, 0.4);
    background: var(--ts-voile);
}

/* --- Tableaux ---------------------------------------------------------- */

table.sorted th { background: rgba(255, 255, 255, 0.08); }
table.sorted th, table.sorted td { border: 1px solid #4a4f57; }

.pager .set-page.current {
    background: rgba(255, 255, 255, 0.12);
    border: 1px solid rgba(255, 255, 255, 0.12);
}

.related-objects .abbreviated-related-objects ul li {
    border: 1px solid #555;
    background: var(--ts-surface);
}

.related-objects .all-related-objects { border-top: 1px solid #555; }

/* --- Notifications, transferts, avertissements ------------------------- */

.notification {
    border: 1px solid var(--ts-bord);
    box-shadow: 1px 1px 6px rgba(0, 0, 0, 0.6);
    background: var(--ts-releve);
    color: var(--ts-texte);
}

.notification.error,
.transfer.error { background: #5a2424; }

.notification .progress { background-color: #3a3f47; border-color: #555; }

.transfer-manager {
    background: var(--ts-surface);
    color: var(--ts-texte);
}

#file-transfer-dialog .transfer-manager { border: 1px solid #555; }

.transfer.in-progress .progress { background-color: #3a3f47; }

.manage-user .notice.read-only,
.manage-user-group .notice.read-only {
    background: #5a4520;
    border: 1px solid var(--ts-bord);
}

#connection-warning {
    background: #3d3520;
    color: var(--ts-texte);
}

.import.help pre { background-color: rgba(255, 255, 255, 0.08); }

.file-upload-container { border: 1px solid #555; }

.file-upload-container .drop-target {
    background: var(--ts-voile);
    border: 1px solid #777;
}

.file-upload-container .drop-target.file-present { background: rgba(255, 255, 255, 0.12); }

.import .errors .error-message,
.file-upload-container .file-error { color: #ff8a80; }

/* --- Page de connexion -------------------------------------------------- */

.login-ui .login-dialog th { text-shadow: none; }

.login-ui .login-dialog .login-fields input { border: 1px solid #555; }

.login-ui .login-fields .labeled-field.empty input { background: transparent; }
.login-ui .login-fields .labeled-field input:focus { background: var(--ts-champ); }

.login-ui.error p.login-error {
    background: #5a2424;
    border: 1px solid #c06060;
    color: #ffc9c9;
}

/* Le QR code d'enrôlement TOTP doit rester noir sur blanc pour être lisible */
.totp-qr-code img {
    background: white;
    border-color: #555;
}

.totp-hide-details,
.totp-show-details { color: var(--ts-lien); }

/* --- Icônes ------------------------------------------------------------- */

/* Icônes noires portées par un élément sans texte : simple inversion */
.icon,
.menu-dropdown .menu-indicator,
.loading::before,
table.sorted th.sort-primary:after,
.manage-user .page-tabs .page-list li a[href]:before,
.manage-user-group .page-tabs .page-list li a[href]:before,
.recent-connections .connection .remove-recent::after,
.file-upload-container .import-config .help::after,
.settings.connectionHistory a.history-session-recording::after,
img[src^="images/settings/"],
img[src^="images/arrows/"],
.fatal-page-error h1::before {
    filter: invert(1);
}

/* Icônes portées par un élément qui contient aussi du texte : variante
   blanche fournie par Guacamole, ou dessin intégré quand elle n'existe pas */
.user-menu .menu-dropdown .menu-title {
    background-image: url('images/user-icons/guac-user-white.svg');
}

.share-menu .menu-dropdown .menu-title {
    background-image: url('images/share-white.svg');
}

.user-menu .menu-dropdown .menu-contents li a {
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect x='10' y='14' width='44' height='30' rx='3' fill='none' stroke='%23ffffff' stroke-width='5'/%3E%3Cpath d='M24 54h16M32 44v10' stroke='%23ffffff' stroke-width='5' stroke-linecap='round'/%3E%3C/svg%3E");
}

.user-menu .menu-dropdown .menu-contents li a[href="#/"] {
    background-image: url('images/action-icons/guac-home.svg');
}

.user-menu .menu-dropdown .menu-contents li a[href="#/settings/users"],
.user-menu .menu-dropdown .menu-contents li a[href="#/settings/connections"],
.user-menu .menu-dropdown .menu-contents li a[href="#/settings/sessions"],
.user-menu .menu-dropdown .menu-contents li a[href="#/settings/preferences"] {
    background-image: url('images/action-icons/guac-config.svg');
}

.user-menu .menu-dropdown .menu-contents li a.logout {
    background-image: url('images/action-icons/guac-logout.svg');
}

.filter .search-string {
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Ccircle cx='27' cy='27' r='13' fill='none' stroke='%23b8bdc4' stroke-width='5'/%3E%3Cpath d='M37 37l14 14' stroke='%23b8bdc4' stroke-width='6' stroke-linecap='round'/%3E%3C/svg%3E");
}
CSS

mkdir -p "${HOME_DIR}/extensions"
# Lu par l'utilisateur non-root du conteneur
chmod 755 "${HOME_DIR}" "${HOME_DIR}/extensions"
rm -f "${JAR}"
( cd "${WORK}" && zip -q -X "${JAR}" guac-manifest.json sombre.css )
chmod 644 "${JAR}"
info "Extension : ${JAR}"

# --- 2. Faire charger l'extension par le conteneur ---------------------
# L'image copie le contenu de GUACAMOLE_HOME (ici ${TPL}, monté depuis
# ./home) dans son répertoire de travail au démarrage.
if ! grep -q "GUACAMOLE_HOME" docker-compose.yml; then
    cp docker-compose.yml docker-compose.yml.avant-theme
    awk -v tpl="${TPL}" '
        /^    ports:/               { print "    volumes:"; print "      - ./home:" tpl ":ro" }
                                    { print }
        /^      WEBAPP_CONTEXT:/    { print "      GUACAMOLE_HOME: " tpl }
    ' docker-compose.yml.avant-theme > docker-compose.yml
    grep -q "GUACAMOLE_HOME" docker-compose.yml && grep -q "./home:${TPL}:ro" docker-compose.yml \
        || { cp docker-compose.yml.avant-theme docker-compose.yml; die "docker-compose.yml : format inattendu, fichier restauré."; }
    docker compose config -q \
        || { cp docker-compose.yml.avant-theme docker-compose.yml; die "docker-compose.yml invalide après modification, fichier restauré."; }
    info "docker-compose.yml mis à jour (copie : docker-compose.yml.avant-theme)"
fi

# --- 3. Redémarrage (les extensions ne sont lues qu'au démarrage) ------
info "Redémarrage de Guacamole (sessions en cours coupées)"
docker compose up -d --force-recreate guacamole >/dev/null

for _ in $(seq 1 60); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)" == "200" ]] && break
    sleep 2
done
[[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)" == "200" ]] \
    || die "Guacamole ne répond pas. Logs : docker logs guacamole"

if curl -s http://127.0.0.1:8080/app.css | grep -q -- "--ts-fond"; then
    info "Thème sombre chargé. Recharger la page (Ctrl+F5)."
else
    die "Guacamole répond mais le thème n'est pas servi. Vérifier : docker logs guacamole | grep -i -E 'extension|theme'"
fi
