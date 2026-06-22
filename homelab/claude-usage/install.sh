#!/usr/bin/env bash
# Installe le poller d'usage Claude Code sur l'hôte qui détient ~/.claude
# (= l'hôte Proxmox). Service systemd + timer (toutes les 15 min).
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/claude-usage/install.sh)
set -euo pipefail

DEST=/opt/claude-usage
ENVF=/etc/claude-usage.env
RAW=https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/claude-usage

# Utilisateur propriétaire de ~/.claude (logs Claude Code).
read -rp "Utilisateur Claude Code (propriétaire de ~/.claude) [thibault] : " CC_USER
CC_USER="${CC_USER:-thibault}"
CC_HOME=$(getent passwd "$CC_USER" | cut -d: -f6)
[ -d "$CC_HOME/.claude/projects" ] || { echo "⚠ $CC_HOME/.claude/projects introuvable — usage vide tant que Claude Code n'a pas tourné sous $CC_USER"; }

read -rp "URL L5 [http://192.168.1.43:3000] : " L5_URL
L5_URL="${L5_URL:-http://192.168.1.43:3000}"
read -rp "Secret webhook L5 (= N8N_WEBHOOK_SECRET de L5) : " L5_SECRET

echo "→ Fichiers dans $DEST"
sudo mkdir -p "$DEST"
sudo curl -fsSL "$RAW/poller.sh" -o "$DEST/poller.sh"
sudo curl -fsSL "$RAW/post.py"   -o "$DEST/post.py"
sudo chmod +x "$DEST/poller.sh"

echo "→ ccusage (npm global, sous $CC_USER/nvm)"
sudo -u "$CC_USER" bash -lc 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; npm i -g ccusage >/dev/null 2>&1 && echo "  ccusage installé ($(command -v ccusage))" || echo "  npm global KO — fallback npx au runtime"'

echo "→ $ENVF (chmod 600)"
sudo tee "$ENVF" >/dev/null <<EOF
L5_URL=$L5_URL
L5_WEBHOOK_SECRET=$L5_SECRET
DAYS=35
NVM_DIR=$CC_HOME/.nvm
# CCUSAGE_BIN=ccusage   # décommenter si ccusage est sur le PATH (npm -g)
EOF
sudo chmod 600 "$ENVF"

echo "→ systemd service + timer"
sudo tee /etc/systemd/system/claude-usage.service >/dev/null <<EOF
[Unit]
Description=Poll Claude Code usage (ccusage) -> L5
After=network-online.target
[Service]
Type=oneshot
User=$CC_USER
Environment=HOME=$CC_HOME
EnvironmentFile=$ENVF
ExecStart=$DEST/poller.sh
EOF
sudo tee /etc/systemd/system/claude-usage.timer >/dev/null <<EOF
[Unit]
Description=Run claude-usage poller every 15 min
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now claude-usage.timer
echo "→ Premier run :"
sudo systemctl start claude-usage.service && sudo journalctl -u claude-usage.service -n 8 --no-pager || true
echo "✓ Fait. Logs: journalctl -u claude-usage.service -f"
