#!/usr/bin/env bash
# Repère PHP dans les CT LXC du Proxmox (à lancer sur l'hôte, en root).
# Cherche : paquets php* installés dans le CT + binaire php dans chaque conteneur Docker.
# Usage : bash scan-php.sh

cx() { timeout 20 pct exec "$1" -- sh -c "$2" </dev/null 2>/dev/null; }

for id in $(pct list | awk 'NR>1 && $2=="running"{print $1}'); do
    name=$(pct config "$id" </dev/null | awk '/^hostname:/{print $2}')
    out=""

    # Paquets distro (Debian/Ubuntu) : version exacte du paquet pour comparer aux avis de sécurité
    pkgs=$(cx "$id" "dpkg-query -W -f='\${Status} \${Package} \${Version}\n' 'php*' 2>/dev/null | awk '/^install ok installed/ && \$4 ~ /^php[0-9][0-9.]*-(cli|fpm|common)\$|^libapache2-mod-php/ {print \"  paquet  \" \$4 \" \" \$5}'")
    [[ -n "$pkgs" ]] && out+="$pkgs"$'\n'

    # Binaire php hors paquet (compilé, /usr/local...)
    if [[ -z "$pkgs" ]]; then
        bin=$(cx "$id" "command -v php >/dev/null && php -r 'echo PHP_VERSION;'")
        [[ -n "$bin" ]] && out+="  binaire php $bin"$'\n'
    fi

    # Conteneurs Docker
    dock=$(cx "$id" 'command -v docker >/dev/null || exit 0
for c in $(docker ps --format "{{.Names}}"); do
  v=$(timeout 5 docker exec "$c" sh -c "command -v php >/dev/null && php -r \"echo PHP_VERSION;\"" 2>/dev/null)
  case "$v" in [0-9]*.[0-9]*) ;; *) continue ;; esac
  echo "  docker  $c ($(docker inspect -f "{{.Config.Image}}" "$c")) php $v"
done')
    [[ -n "$dock" ]] && out+="$dock"$'\n'

    [[ -n "$out" ]] && printf '%s | %s\n%s' "$id" "$name" "$out"
done

echo
echo "Fin du scan. Aucune ligne pour un CT = pas de PHP trouvé dedans."
echo "Versions corrigées upstream : 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 (CVE-2026-109618/109619)."
echo "Paquets Debian/Ubuntu : la version affichée est celle du paquet (correctif rétroporté), à comparer à l'avis Debian/Ubuntu."
