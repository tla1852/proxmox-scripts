#!/usr/bin/env bash
# Lit l'usage Claude Code (~/.claude via ccusage) et le POST sur L5.
# Tourne sous l'utilisateur propriétaire de ~/.claude (sur l'hôte Proxmox).
set -euo pipefail

# shellcheck disable=SC1091
source /etc/claude-usage.env   # L5_URL, L5_WEBHOOK_SECRET, [DAYS], [CCUSAGE_BIN], [NVM_DIR]

# nvm si présent (node n'est souvent pas dans le PATH système).
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true

CC="${CCUSAGE_BIN:-npx -y ccusage@latest}"

DAILY=$($CC daily --json 2>/dev/null)
BLOCK=$($CC blocks --active --json 2>/dev/null || echo '{"blocks":[]}')

DAILY_JSON="$DAILY" BLOCK_JSON="$BLOCK" \
  L5_URL="$L5_URL" L5_WEBHOOK_SECRET="${L5_WEBHOOK_SECRET:-}" DAYS="${DAYS:-35}" \
  python3 "$(dirname "$0")/post.py"
