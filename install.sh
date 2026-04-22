#!/usr/bin/env bash
# install.sh — install meal-checker and tg-notify agents into ~/.claude/agents.
#
# Usage:
#   ./install.sh              # interactive
#   ./install.sh --no-prompt  # skip prompts, only copy files (you edit env by hand)
#
# Safe to re-run: existing files are backed up to *.bak before overwrite.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SRC="$HERE/agents"
AGENTS_DST="$HOME/.claude/agents"
ENV_DIR="$HOME/.config/claude-tools"
ENV_FILE="$ENV_DIR/env"

NO_PROMPT=0
for arg in "$@"; do
  case "$arg" in
    --no-prompt) NO_PROMPT=1 ;;
    -h|--help)
      sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Preflight --------------------------------------------------------
log "Checking prerequisites"
command -v node >/dev/null    || die "node not found. Install Node.js 18+ first."
command -v npm  >/dev/null    || die "npm not found."
command -v curl >/dev/null    || die "curl not found."
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_MAJOR" -ge 18 ]] || die "node $NODE_MAJOR detected; need 18 or newer."

# --- 2. Copy agent files -------------------------------------------------
log "Installing agents into $AGENTS_DST"
mkdir -p "$AGENTS_DST"

backup_if_exists() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
  mv "$f" "$bak"
  warn "existing $f moved to $bak"
}

for rel in meal-checker.md meal-checker tg-notify.md tg-notify; do
  src="$AGENTS_SRC/$rel"
  dst="$AGENTS_DST/$rel"
  [[ -e "$src" ]] || die "bundle missing $src"
  backup_if_exists "$dst"
  cp -R "$src" "$dst"
done
chmod +x "$AGENTS_DST/tg-notify/send.sh"

# --- 3. meal-checker deps ------------------------------------------------
log "Installing meal-checker dependencies (playwright)"
(
  cd "$AGENTS_DST/meal-checker"
  npm install --silent --no-audit --no-fund
  log "Downloading chromium for playwright (this can take a minute)"
  npx --yes playwright install chromium
)

# --- 4. env file ---------------------------------------------------------
mkdir -p "$ENV_DIR"
chmod 700 "$ENV_DIR"

if [[ -f "$ENV_FILE" ]]; then
  log "Existing env file detected: $ENV_FILE — leaving it untouched"
else
  cp "$HERE/env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "Wrote template env file: $ENV_FILE"

  if [[ $NO_PROMPT -eq 0 ]]; then
    echo
    read -r -p "Meal-checker login email (leave blank to edit later): " email
    read -r -p "Telegram bot token (leave blank to edit later): "        token
    read -r -p "Telegram chat id   (leave blank to edit later): "        chat

    # sed in-place — BSD (macOS) and GNU both accept -i with an empty suffix when given two args
    python3 - "$ENV_FILE" "$email" "$token" "$chat" <<'PY'
import pathlib, sys, re
path, email, token, chat = sys.argv[1], *sys.argv[2:5]
p = pathlib.Path(path)
content = p.read_text()
def sub(key, val):
    global content
    if not val: return
    content = re.sub(
        rf"^export {key}=.*$",
        f"export {key}='{val}'",
        content,
        flags=re.MULTILINE,
    )
sub("MEAL_CHECKER_EMAIL", email)
sub("TG_BOT_TOKEN", token)
sub("TG_CHAT_ID", chat)
p.write_text(content)
PY
    log "env file populated. Edit $ENV_FILE anytime to update."
  else
    warn "Edit $ENV_FILE to fill in MEAL_CHECKER_EMAIL / TG_BOT_TOKEN / TG_CHAT_ID"
  fi
fi

# --- 5. Shell rc hint ----------------------------------------------------
RC_LINE='[ -f ~/.config/claude-tools/env ] && . ~/.config/claude-tools/env'
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [[ -f "$rc" ]] || continue
  if ! grep -Fq "$RC_LINE" "$rc"; then
    echo "" >> "$rc"
    echo "# claude-agents: load shared env" >> "$rc"
    echo "$RC_LINE" >> "$rc"
    log "Added env-sourcing line to $rc"
  fi
done

# --- 6. Smoke test -------------------------------------------------------
log "Installation complete."
cat <<EOF

Next steps:
  1. Open a new shell (or run: source $ENV_FILE)
  2. Verify tg-notify:
       echo "install smoke test" | ~/.claude/agents/tg-notify/send.sh
  3. Verify meal-checker:
       node ~/.claude/agents/meal-checker/check.js

Both agents are now callable from Claude Code.
EOF
