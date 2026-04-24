#!/usr/bin/env bash
# install_for_kiro.sh — install meal-checker / meal-order / tg-notify agents
# into ~/.kiro/agents so they're usable from `kiro-cli` (Kiro CLI).
#
# Kiro CLI agents are JSON files, not Markdown+frontmatter, so this script
# converts each agents/<name>.md into ~/.kiro/agents/<name>.json and rewrites
# the path references inside the prompt (~/.claude/agents → ~/.kiro/agents).
#
# Usage:
#   ./install_for_kiro.sh              # interactive: prompts for email / bot token / chat id
#   ./install_for_kiro.sh --no-prompt  # non-interactive: only copy files, edit env by hand
#
# Press Enter at any prompt to skip — the env file stays valid and can be
# filled in later by editing ~/.config/claude-tools/env (shared with the
# Claude Code install).
#
# Safe to re-run: existing agent JSON / support dirs are overwritten in place,
# and existing env values become defaults at the prompts.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SRC="$HERE/agents"
AGENTS_DST="$HOME/.kiro/agents"
SKILLS_SRC="$HERE/skills"
SKILLS_DST="$HOME/.kiro/skills"
ENV_DIR="$HOME/.config/claude-tools"
ENV_FILE="$ENV_DIR/env"

NO_PROMPT=0
for arg in "$@"; do
  case "$arg" in
    --no-prompt) NO_PROMPT=1 ;;
    -h|--help)
      sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Preflight --------------------------------------------------------
log "Checking prerequisites"
command -v node    >/dev/null || die "node not found. Install Node.js 18+ first."
command -v npm     >/dev/null || die "npm not found."
command -v curl    >/dev/null || die "curl not found."
command -v python3 >/dev/null || die "python3 not found (needed to convert agent .md → .json)."
command -v kiro-cli >/dev/null || warn "kiro-cli not found on PATH — files will still install, but make sure Kiro CLI is set up."
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_MAJOR" -ge 18 ]] || die "node $NODE_MAJOR detected; need 18 or newer."

# --- 2. Convert .md agents → .json, and copy support dirs ----------------
log "Installing agents into $AGENTS_DST"
mkdir -p "$AGENTS_DST"

# Copy support directories (scripts, node_modules target, etc.)
for name in meal-checker meal-order tg-notify; do
  src_dir="$AGENTS_SRC/$name"
  dst_dir="$AGENTS_DST/$name"
  [[ -d "$src_dir" ]] || die "bundle missing $src_dir"
  rm -rf "$dst_dir"
  cp -R "$src_dir" "$dst_dir"
done
chmod +x "$AGENTS_DST/tg-notify/send.sh"

# Convert each .md (frontmatter + body) into a Kiro-style agent JSON and
# rewrite ~/.claude/agents/ → ~/.kiro/agents/ inside the prompt so the
# instructions point at the right scripts.
log "Converting agent .md files → Kiro JSON"
for name in meal-checker meal-order tg-notify; do
  src_md="$AGENTS_SRC/$name.md"
  dst_json="$AGENTS_DST/$name.json"
  [[ -f "$src_md" ]] || die "bundle missing $src_md"

  python3 - "$src_md" "$dst_json" <<'PY'
import json, re, sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

text = src.read_text(encoding="utf-8")
m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.DOTALL)
if not m:
    print(f"cannot parse frontmatter in {src}", file=sys.stderr)
    sys.exit(1)

fm_raw, body = m.group(1), m.group(2)
meta = {}
for line in fm_raw.splitlines():
    if ":" in line:
        k, _, v = line.partition(":")
        meta[k.strip()] = v.strip()

# Rewrite Claude-specific paths in the prompt so they point at the Kiro install.
body = body.replace("~/.claude/agents/", "~/.kiro/agents/")

# Claude tool names → Kiro built-in tool names.
tool_map = {
    "Bash":  "shell",
    "Read":  "read",
    "Write": "write",
    "Grep":  "grep",
    "Glob":  "glob",
}
raw_tools = [t.strip() for t in meta.get("tools", "").split(",") if t.strip()]
tools = [tool_map.get(t, t.lower()) for t in raw_tools]

# Claude model shortnames → Kiro model ids.
model_map = {
    "opus":   "claude-opus-4.6",
    "sonnet": "claude-sonnet-4.6",
    "haiku":  "claude-haiku-4.5",
}
model = model_map.get(meta.get("model", "").lower())

agent = {
    "name": meta.get("name", src.stem),
    "description": meta.get("description", ""),
    "prompt": body.strip(),
    "mcpServers": {},
    "tools": tools,
    "toolAliases": {},
    "allowedTools": tools,
    "resources": [],
    "hooks": {},
    "toolsSettings": {},
    "includeMcpJson": False,
}
if model:
    agent["model"] = model

dst.write_text(json.dumps(agent, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
  log "  installed agent: $name ($dst_json)"
done

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

# --- 4. env file (shared with Claude Code install) -----------------------
mkdir -p "$ENV_DIR"
chmod 700 "$ENV_DIR"

# Shell-escape a value so it survives inside single quotes in the env file.
sq_escape() {
  local s="$1"
  printf "%s" "${s//\'/\'\\\'\'}"
}

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

{
  echo "# Claude/Kiro agents shared env file. Sourced by meal-checker, meal-order, and tg-notify."
  echo "# Location: $ENV_FILE"
  echo "# Edit anytime; new terminals pick up changes automatically via your shell rc."
  echo
  echo "# Amazon employee meal ordering login email (meal-checker / meal-order)"
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
    echo "# claude/kiro agents: load shared env" >> "$rc"
    echo "$RC_LINE" >> "$rc"
    log "Added env-sourcing line to $rc"
  fi
done

# --- 6. Validate with kiro-cli if available ------------------------------
if command -v kiro-cli >/dev/null; then
  log "Validating installed agents with kiro-cli"
  for name in meal-checker meal-order tg-notify; do
    json="$AGENTS_DST/$name.json"
    if kiro-cli agent validate --path "$json" >/dev/null 2>&1; then
      log "  ✓ $name"
    else
      warn "  kiro-cli failed to validate $name — run: kiro-cli agent validate --path $json"
    fi
  done
fi

log "Installation complete. Try: kiro-cli chat --agent meal-checker"
