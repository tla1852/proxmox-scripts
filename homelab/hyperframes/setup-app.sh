#!/usr/bin/env bash
#
# setup-app.sh — couche applicative HyperFrames (rendu HTML + GSAP → MP4 via
# Chrome headless + FFmpeg) + Studio web (prompt → Claude Code headless → MP4),
# appliquée à un CT existant (créé par create-lxc-hyperframes.sh, qui appelle
# ce script). Relançable tel quel :
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/hyperframes/setup-app.sh) <VMID>
#
# - Node 22 (NodeSource) + libs Chrome headless (liste de apps/recap/Dockerfile)
# - FFmpeg statique et chrome-headless-shell ÉPINGLÉS (mêmes builds que la prod
#   recap → rendu identique à Cloud Run)
# - CLI hyperframes + gsap épinglés dans /opt/hyperframes
# - hf-render : wrapper (1 rendu à la fois via flock, nice/ionice, log)
# - openssh-server (clés uniquement) + clés publiques autorisées pour thibault
# - Studio : utilisateur système "studio" (/srv/studio), Claude Code natif +
#   skills HyperFrames, service systemd hyperframes-studio (port 8080).
#   Auth Claude = jeton d'abonnement (`claude setup-token` sur un PC),
#   stocké dans /etc/hyperframes-studio.env (root, 600)
# - CPU weight réduit (cpuunits) : le CT cède la place aux autres guests
#   quand l'hôte est chargé
#
# Après coup : vhost Caddy interne hyperframes.ts.tlagrange.pro → <ip>:8080
# + extra_record Headscale (homelab/internal), et optionnellement l'enrôlement
# tailnet du CT pour le SSH hors LAN (homelab/tailnet/enroll-lxc.sh).

set -euo pipefail

err()  { echo -e "\e[31m[ERREUR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

[[ $EUID -eq 0 ]] || err "Ce script doit être lancé en root sur le noeud Proxmox."
command -v pct >/dev/null || err "pct introuvable : ce script doit tourner sur un hôte Proxmox VE."

VMID="${1:-}"
[[ -n "$VMID" ]] || err "Usage : setup-app.sh <VMID> (CT créé par create-lxc-hyperframes.sh)"
pct status "$VMID" 2>/dev/null | grep -q running || err "CT ${VMID} introuvable ou arrêté (pct status ${VMID})."
pct exec "$VMID" -- id thibault >/dev/null 2>&1 || err "Utilisateur thibault absent dans le CT ${VMID} : socle incomplet."

# Versions alignées sur tla1852/blindtest apps/recap (package.json + Dockerfile)
HYPERFRAMES_VERSION="0.8.205"
GSAP_VERSION="3.14.2"
CHROME_VERSION="152.0.7977.30"
FFMPEG_RELEASE="https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-02-28-12-59"
FFMPEG_BUILD="ffmpeg-n8.0.1-66-g27b8d1a017"
FFMPEG_SHA256="26d2ecd0cefba99f9d1ea92252a3a4f743a58df4c1c3cf9f8bbaaa40b1fca5b0"
STUDIO_SRC="https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/hyperframes/studio"
STUDIO_PORT="8080"

info "Configuration de HyperFrames (CT ${VMID})..."

# ----- Priorité CPU basse (poids 50 vs 100 par défaut des autres guests) -----
pct set "$VMID" --cpuunits 50

# ----- Questions -----
echo "Colle les clés publiques SSH autorisées (claude-dev, PC...), une par ligne, ligne vide pour finir :"
KEYS=""
while IFS= read -r line; do
    [[ -z "$line" ]] && break
    [[ "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)[^\ ]*\ [A-Za-z0-9+/=]+ ]] || { echo "  ignorée (format inconnu)"; continue; }
    KEYS+="${line}"$'\n'
done

if pct exec "$VMID" -- test -s /etc/hyperframes-studio.env; then
    read -rsp "Jeton Claude (claude setup-token) — vide = garder l'actuel : " CLAUDE_TOKEN; echo
else
    read -rsp "Jeton Claude pour le Studio (lancer « claude setup-token » sur un PC) — vide = plus tard : " CLAUDE_TOKEN; echo
fi

# ----- Système : Node 22, libs Chrome, sshd -----
info "Installation de Node 22, des bibliothèques Chrome et de sshd..."
pct exec "$VMID" -- bash -s <<'SYS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! (command -v node >/dev/null && node -v | grep -q '^v22'); then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
    apt-get -y -qq install nodejs
fi
apt-get -y -qq install --no-install-recommends \
    xz-utils rsync jq openssh-server util-linux \
    libgbm1 libnss3 libatk-bridge2.0-0 libdrm2 libxcomposite1 libxdamage1 libxrandr2 \
    libcups2 libasound2t64 libpangocairo-1.0-0 libxshmfence1 libgtk-3-0 \
    fonts-liberation fonts-dejavu-core fonts-noto-color-emoji fontconfig >/dev/null
fc-cache -f >/dev/null
# SSH : clés uniquement
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-hyperframes.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
systemctl enable --now ssh >/dev/null 2>&1
systemctl restart ssh
SYS

# ----- FFmpeg + Chrome headless épinglés -----
info "Installation de FFmpeg et chrome-headless-shell (versions épinglées)..."
pct exec "$VMID" -- env FFMPEG_RELEASE="$FFMPEG_RELEASE" FFMPEG_BUILD="$FFMPEG_BUILD" \
    FFMPEG_SHA256="$FFMPEG_SHA256" CHROME_VERSION="$CHROME_VERSION" bash -s <<'BIN'
set -euo pipefail
if ! /usr/local/bin/ffmpeg -version 2>/dev/null | head -1 | grep -q "${FFMPEG_BUILD#ffmpeg-}"; then
    curl -fsSL -o /tmp/ffmpeg.tar.xz "$FFMPEG_RELEASE/$FFMPEG_BUILD-linux64-gpl-8.0.tar.xz"
    echo "$FFMPEG_SHA256  /tmp/ffmpeg.tar.xz" | sha256sum -c - >/dev/null
    tar --no-same-owner -xJf /tmp/ffmpeg.tar.xz -C /usr/local/bin --strip-components=2 --wildcards '*/bin/ffmpeg' '*/bin/ffprobe'
    rm /tmp/ffmpeg.tar.xz
fi
if ! /opt/chrome/chrome-headless-shell --version 2>/dev/null | grep -q "$CHROME_VERSION"; then
    npx --yes @puppeteer/browsers@2 install "chrome-headless-shell@${CHROME_VERSION}" --path /opt/puppeteer >/dev/null
    CHS="$(find /opt/puppeteer/chrome-headless-shell -path "*${CHROME_VERSION}*" -name chrome-headless-shell -type f | head -n1)"
    mkdir -p /opt/chrome && ln -sfn "$CHS" /opt/chrome/chrome-headless-shell
fi
BIN

# ----- CLI hyperframes + gsap, environnement, wrapper -----
info "Installation de hyperframes ${HYPERFRAMES_VERSION} et du wrapper hf-render..."
pct exec "$VMID" -- env HYPERFRAMES_VERSION="$HYPERFRAMES_VERSION" GSAP_VERSION="$GSAP_VERSION" bash -s <<'APPLI'
set -euo pipefail
mkdir -p /opt/hyperframes
cd /opt/hyperframes
[[ -f package.json ]] || echo '{"name":"hyperframes-runtime","private":true,"type":"module"}' > package.json
npm install --silent --no-fund --no-audit "hyperframes@${HYPERFRAMES_VERSION}" "gsap@${GSAP_VERSION}"
ln -sfn /opt/hyperframes/node_modules/.bin/hyperframes /usr/local/bin/hyperframes
# gsap à vendorer dans les projets : cp /opt/hyperframes/vendor/gsap.min.js assets/vendor/
mkdir -p vendor && cp node_modules/gsap/dist/gsap.min.js vendor/

cat > /etc/profile.d/hyperframes.sh <<'EOF'
export HYPERFRAMES_CHROME_PATH=/opt/chrome/chrome-headless-shell
export PRODUCER_HEADLESS_SHELL_PATH=/opt/chrome/chrome-headless-shell
export PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
export DO_NOT_TRACK=1
export HYPERFRAMES_NO_TELEMETRY=1
export HYPERFRAMES_SKIP_SKILLS=1
EOF
# Aussi pour les commandes SSH non interactives (ssh hyperframes 'hf-render ...')
grep -q profile.d/hyperframes /home/thibault/.bashrc 2>/dev/null \
    || sed -i '1i [ -f /etc/profile.d/hyperframes.sh ] && . /etc/profile.d/hyperframes.sh' /home/thibault/.bashrc

# Verrou partagé entre thibault (SSH) et studio (page web)
install -d -m 755 /var/lib/hf
[[ -f /var/lib/hf/render.lock ]] || install -m 644 /dev/null /var/lib/hf/render.lock

cat > /usr/local/bin/hf-render <<'EOF'
#!/usr/bin/env bash
# hf-render <dossier_projet> [sortie.mp4] [options hyperframes render...]
#   Rend un projet HyperFrames (index.html + hyperframes.json). Un seul rendu à
#   la fois (les suivants attendent), priorité CPU/IO basse. Défaut sortie :
#   <dossier_projet>/out.mp4 ; défaut qualité : --quality looks.
#   3 workers par défaut (mesuré sur 4 cœurs : 14,8 s vs 20,3 s en 1, 4 = pas mieux) ;
#   surchargeable : HF_RENDER_ARGS="--workers 2"
set -euo pipefail
. /etc/profile.d/hyperframes.sh
PROJ="${1:?usage: hf-render <dossier_projet> [sortie.mp4] [options...]}"; shift
OUT="$(realpath -m "${PROJ}/out.mp4")"
if [[ $# -gt 0 && "$1" != -* ]]; then OUT="$(realpath -m "$1")"; shift; fi
[[ -f "$PROJ/index.html" ]] || { echo "index.html absent dans $PROJ" >&2; exit 2; }
QUALITY=(--quality looks); [[ " $* " == *" --quality "* ]] && QUALITY=()
mkdir -p "$(dirname "$OUT")" "$HOME/.cache/hf"
LOG="$HOME/.cache/hf/render-$(date +%Y%m%d-%H%M%S).log"
echo "[hf-render] attente du verrou..." >&2
exec 9</var/lib/hf/render.lock
flock 9
echo "[hf-render] rendu $PROJ → $OUT (log $LOG)" >&2
cd "$PROJ"
START=$(date +%s)
# shellcheck disable=SC2086
nice -n 10 ionice -c3 hyperframes render --output "$OUT" "${QUALITY[@]}" ${HF_RENDER_ARGS:---workers 3} "$@" 2>&1 | tee "$LOG"
echo "[hf-render] OK en $(( $(date +%s) - START )) s : $OUT ($(du -h "$OUT" | cut -f1))" >&2
EOF
chmod 755 /usr/local/bin/hf-render

# Dossier de travail SSH + purge auto des jobs > 7 jours (pas la galerie du Studio)
install -d -o thibault -g thibault /home/thibault/jobs
cat > /etc/cron.daily/hf-purge <<'EOF'
#!/bin/sh
find /home/thibault/jobs -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} +
find /home/thibault/.cache/hf /srv/studio/.cache/hf -name 'render-*.log' -mtime +30 -delete 2>/dev/null || true
EOF
chmod 755 /etc/cron.daily/hf-purge
APPLI

# ----- Clés SSH -----
if [[ -n "$KEYS" ]]; then
    printf '%s' "$KEYS" | pct exec "$VMID" -- bash -c "install -d -m 700 -o thibault -g thibault /home/thibault/.ssh
        cat >> /home/thibault/.ssh/authorized_keys
        sort -u -o /home/thibault/.ssh/authorized_keys /home/thibault/.ssh/authorized_keys
        chown thibault:thibault /home/thibault/.ssh/authorized_keys; chmod 600 /home/thibault/.ssh/authorized_keys"
fi

# ----- Studio : utilisateur, Claude Code, skills, service -----
info "Installation du Studio (Claude Code + page web)..."
pct exec "$VMID" -- env STUDIO_SRC="$STUDIO_SRC" STUDIO_PORT="$STUDIO_PORT" bash -s <<'STUDIO'
set -euo pipefail
id studio >/dev/null 2>&1 || useradd --system --create-home --home-dir /srv/studio --shell /bin/bash studio
install -d -o studio -g studio /srv/studio/jobs

# Claude Code (installeur natif, dans ~studio/.local/bin, auto-update)
su - studio -c 'command -v ~/.local/bin/claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash >/dev/null'

# Skills HyperFrames + GSAP pour Claude (dans ~studio/.claude/skills)
su - studio -c 'cd /tmp && HYPERFRAMES_SKIP_SKILLS=0 DO_NOT_TRACK=1 HYPERFRAMES_NO_TELEMETRY=1 hyperframes skills </dev/null >/dev/null 2>&1' \
    || echo "[WARN] installation des skills HyperFrames en échec (le Studio marchera, en moins bien)"

# Code de la page
install -d /opt/hyperframes-studio
curl -fsSL -o /opt/hyperframes-studio/server.mjs "$STUDIO_SRC/server.mjs"
curl -fsSL -o /opt/hyperframes-studio/index.html "$STUDIO_SRC/index.html"

[[ -f /etc/hyperframes-studio.env ]] || install -m 600 /dev/null /etc/hyperframes-studio.env

cat > /etc/systemd/system/hyperframes-studio.service <<EOF
[Unit]
Description=HyperFrames Studio (prompt -> Claude Code -> MP4)
After=network-online.target
Wants=network-online.target

[Service]
User=studio
WorkingDirectory=/srv/studio
EnvironmentFile=/etc/hyperframes-studio.env
Environment=PORT=${STUDIO_PORT}
Environment=STUDIO_DATA=/srv/studio
Environment=HOME=/srv/studio
Environment=PATH=/srv/studio/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=HYPERFRAMES_CHROME_PATH=/opt/chrome/chrome-headless-shell
Environment=PRODUCER_HEADLESS_SHELL_PATH=/opt/chrome/chrome-headless-shell
Environment=PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
Environment=DO_NOT_TRACK=1
Environment=HYPERFRAMES_NO_TELEMETRY=1
Environment=HYPERFRAMES_SKIP_SKILLS=1
ExecStart=/usr/bin/node /opt/hyperframes-studio/server.mjs
Restart=on-failure
Nice=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hyperframes-studio >/dev/null 2>&1
STUDIO

if [[ -n "$CLAUDE_TOKEN" ]]; then
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$CLAUDE_TOKEN" | pct exec "$VMID" -- bash -c "cat > /etc/hyperframes-studio.env; chmod 600 /etc/hyperframes-studio.env"
fi
unset CLAUDE_TOKEN
pct exec "$VMID" -- systemctl restart hyperframes-studio

# ----- Test de fumée : rendu du projet vierge de « hyperframes init » -----
info "Test de rendu..."
pct exec "$VMID" -- su - thibault -c 'set -e
    D=$(mktemp -d ~/jobs/smoke-XXXX); cd "$D"
    hyperframes init project --non-interactive --example blank --resolution square --skip-skills >/dev/null
    hf-render "$D/project" >/dev/null && ls -la "$D/project/out.mp4" && rm -rf "$D"' \
    && info "Rendu de test OK." \
    || warn "Rendu de test en échec : voir ~/.cache/hf/*.log de thibault dans le CT."

sleep 2
pct exec "$VMID" -- curl -fsS -m5 "http://localhost:${STUDIO_PORT}/api/health" >/dev/null \
    || err "Le Studio ne répond pas : pct exec ${VMID} -- journalctl -u hyperframes-studio -n 30"
pct exec "$VMID" -- grep -q '^CLAUDE_CODE_OAUTH_TOKEN=.' /etc/hyperframes-studio.env \
    || warn "Pas de jeton Claude : le Studio répond mais les générations échoueront. Relancer ce script avec le jeton."

IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo
info "HyperFrames prêt dans le CT ${VMID}."
info "  Studio    : http://${IP}:${STUDIO_PORT}   (logs : pct exec ${VMID} -- journalctl -u hyperframes-studio -f)"
info "  Suite     : vhost Caddy interne  hyperframes.ts.tlagrange.pro → ${IP}:${STUDIO_PORT}  + extra_record (homelab/internal)"
info "  SSH       : ssh thibault@${IP}"
info "  Rendu SSH : rsync -a projet/ thibault@${IP}:jobs/x/ && ssh thibault@${IP} hf-render jobs/x && scp thibault@${IP}:jobs/x/out.mp4 ."
info "  Versions  : hyperframes ${HYPERFRAMES_VERSION}, $(pct exec "$VMID" -- /opt/chrome/chrome-headless-shell --version 2>/dev/null | head -1), $(pct exec "$VMID" -- /usr/local/bin/ffmpeg -version | head -1 | cut -d' ' -f1-3)"
info "  Tailnet   : bash /tmp/enroll-lxc.sh ${VMID}   (SSH hors LAN, cf. homelab/tailnet)"
