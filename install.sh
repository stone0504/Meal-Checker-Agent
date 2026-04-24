#!/usr/bin/env bash
# install.sh — install meal-checker and tg-notify agents into ~/.claude/agents.
#
# Usage:
#   ./install.sh              # interactive: prompts for email / bot token / chat id
#   ./install.sh --no-prompt  # non-interactive: only copy files, edit env by hand
#
# At the prompts, press Enter to skip any value — the env file stays valid and
# you can fill it in later by editing ~/.config/claude-tools/env.
#
# The env file is sourced from ~/.zshrc / ~/.bashrc so new terminals pick the
# variables up permanently.
#
# Safe to re-run: existing agent files are overwritten in place, and
# existing env values become defaults at the prompts.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SRC="$HERE/agents"
AGENTS_DST="$HOME/.claude/agents"
SKILLS_SRC="$HERE/skills"
SKILLS_DST="$HOME/.claude/skills"
ENV_DIR="$HOME/.config/claude-tools"
ENV_FILE="$ENV_DIR/env"

NO_PROMPT=0
for arg in "$@"; do
  case "$arg" in
    --no-prompt) NO_PROMPT=1 ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
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

for rel in meal-checker.md meal-checker meal-order.md meal-order tg-notify.md tg-notify; do
  src="$AGENTS_SRC/$rel"
  dst="$AGENTS_DST/$rel"
  [[ -e "$src" ]] || die "bundle missing $src"
  rm -rf "$dst"
  cp -R "$src" "$dst"
done
chmod +x "$AGENTS_DST/tg-notify/send.sh"

# --- 3. meal-checker deps (shared with meal-order) ----------------------
log "Installing meal-checker dependencies (playwright)"
(
  cd "$AGENTS_DST/meal-checker"
  npm install --silent --no-audit --no-fund
  log "Downloading chromium for playwright (this can take a minute)"
  npx --yes playwright install chromium
)

# meal-order shares the same Playwright install via a relative symlink to
# avoid duplicating ~300MB of chromium.
log "Linking meal-order node_modules -> meal-checker/node_modules"
ln -sfn ../meal-checker/node_modules "$AGENTS_DST/meal-order/node_modules"

# --- 3b. Install skills --------------------------------------------------
if [[ -d "$SKILLS_SRC" ]]; then
  log "Installing skills into $SKILLS_DST"
  mkdir -p "$SKILLS_DST"
  for skill_dir in "$SKILLS_SRC"/*/; do
    [[ -d "$skill_dir" ]] || continue
    name="$(basename "$skill_dir")"
    dst="$SKILLS_DST/$name"
    rm -rf "$dst"
    cp -R "$skill_dir" "$dst"
    log "  installed skill: $name"
  done
fi

# --- 4. env file ---------------------------------------------------------
mkdir -p "$ENV_DIR"
chmod 700 "$ENV_DIR"

# Shell-escape a value so it survives inside single quotes in the env file.
# Any embedded single quote becomes '\'' (close, escaped quote, reopen).
sq_escape() {
  local s="$1"
  printf "%s" "${s//\'/\'\\\'\'}"
}

# Read existing values (if any) so we can offer them as defaults on re-run.
existing_email=""
existing_token=""
existing_chat=""
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  ( set +u; source "$ENV_FILE"; printf '%s\n%s\n%s\n' \
      "${MEAL_CHECKER_EMAIL:-}" "${TG_BOT_TOKEN:-}" "${TG_CHAT_ID:-}" ) \
      > /tmp/claude-tools-env.$$ 2>/dev/null || true
  { read -r existing_email; read -r existing_token; read -r existing_chat; } \
      < /tmp/claude-tools-env.$$ || true
  rm -f /tmp/claude-tools-env.$$
fi

email="$existing_email"
token="$existing_token"
chat="$existing_chat"

if [[ $NO_PROMPT -eq 0 ]]; then
  echo
  log "Setup shared env vars (press Enter to skip any value — you can edit $ENV_FILE later)"

  prompt_val() {
    # prompt_val "label" current_value → echoes new value (may be empty)
    local label="$1" current="$2" reply=""
    if [[ -n "$current" ]]; then
      read -r -p "$label [$current]: " reply
      printf '%s' "${reply:-$current}"
    else
      read -r -p "$label (blank to skip): " reply
      printf '%s' "$reply"
    fi
  }

  email="$(prompt_val "Meal-checker login email"   "$existing_email")"
  token="$(prompt_val "Telegram bot token"         "$existing_token")"
  chat="$(prompt_val  "Telegram chat id"           "$existing_chat")"
else
  log "--no-prompt given; keeping existing env values if any"
fi

# Write (or rewrite) the env file from the collected values. Missing values
# stay commented-out placeholders so the file is still valid to source.
{
  echo "# Claude agents shared env file. Sourced by both meal-checker and tg-notify."
  echo "# Location: $ENV_FILE"
  echo "# Edit anytime; new terminals pick up changes automatically via your shell rc."
  echo
  echo "# Amazon employee meal ordering login email (meal-checker)"
  if [[ -n "$email" ]]; then
    echo "export MEAL_CHECKER_EMAIL='$(sq_escape "$email")'"
  else
    echo "# export MEAL_CHECKER_EMAIL='you@amazon.com'"
  fi
  echo
  echo "# Telegram bot credentials (tg-notify)"
  echo "# Create a bot via @BotFather, send it /start, then look up your chat id"
  echo "# by sending any message and visiting"
  echo "#   https://api.telegram.org/bot<TOKEN>/getUpdates"
  if [[ -n "$token" ]]; then
    echo "export TG_BOT_TOKEN='$(sq_escape "$token")'"
  else
    echo "# export TG_BOT_TOKEN='123456:ABCDEF-your-bot-token'"
  fi
  if [[ -n "$chat" ]]; then
    echo "export TG_CHAT_ID='$(sq_escape "$chat")'"
  else
    echo "# export TG_CHAT_ID='123456789'"
  fi
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

filled=0; skipped=()
[[ -n "$email" ]] && filled=$((filled+1)) || skipped+=("MEAL_CHECKER_EMAIL")
[[ -n "$token" ]] && filled=$((filled+1)) || skipped+=("TG_BOT_TOKEN")
[[ -n "$chat"  ]] && filled=$((filled+1)) || skipped+=("TG_CHAT_ID")

log "Wrote env file: $ENV_FILE (${filled}/3 values set)"
if (( ${#skipped[@]} > 0 )); then
  warn "Skipped: ${skipped[*]} — edit $ENV_FILE and uncomment the matching line when ready"
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

log "Installation complete."
