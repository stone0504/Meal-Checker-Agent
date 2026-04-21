#!/usr/bin/env bash
# Combined installer for tg-notify + meal-checker.
#
# Usage:
#   ./install.sh              # install both (default)
#   ./install.sh tg-notify    # only tg-notify
#   ./install.sh meal-checker # only meal-checker
#   ./install.sh both         # same as no args
#
# Non-interactive (all three can be pre-set):
#   TG_BOT_TOKEN=xxx TG_CHAT_ID=yyy MEAL_CHECKER_EMAIL=you@mail.com ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-both}"

case "$TARGET" in
  tg-notify|meal-checker|both) ;;
  *)
    echo "Usage: $0 [tg-notify|meal-checker|both]" >&2
    exit 2
    ;;
esac

# Env variables are written directly into the user's shell rc so that
# TG_BOT_TOKEN / TG_CHAT_ID / MEAL_CHECKER_EMAIL become permanent exports
# on macOS (zsh) and Linux (bash) alike. We maintain a marker-bracketed
# block inside the rc and upsert individual KEY=VALUE lines in place.
MARKER_BEGIN="# >>> claude-tools env >>>"
MARKER_END="# <<< claude-tools env <<<"

hr() { printf '\n%s\n' "------------------------------------------------------------"; }

# Pick which shell rc to patch. Honour $SHELL; fall back to whichever rc
# file already exists; otherwise default to ~/.zshrc on macOS, ~/.bashrc
# on Linux.
pick_shell_rc() {
  local shell_name
  shell_name="$(basename "${SHELL:-}")"
  case "$shell_name" in
    zsh)  echo "$HOME/.zshrc"  ; return ;;
    bash)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS bash only reads ~/.bash_profile for login shells.
        echo "$HOME/.bash_profile"
      else
        echo "$HOME/.bashrc"
      fi
      return ;;
  esac
  if [[ -f "$HOME/.zshrc"       ]]; then echo "$HOME/.zshrc";       return; fi
  if [[ -f "$HOME/.bashrc"      ]]; then echo "$HOME/.bashrc";      return; fi
  if [[ -f "$HOME/.bash_profile" ]]; then echo "$HOME/.bash_profile"; return; fi
  if [[ "$(uname -s)" == "Darwin" ]]; then echo "$HOME/.zshrc"; else echo "$HOME/.bashrc"; fi
}

# Cached rc path — set on first use.
SHELL_RC=""

ensure_rc_block() {
  [[ -n "$SHELL_RC" ]] || SHELL_RC="$(pick_shell_rc)"
  touch "$SHELL_RC"
  if ! grep -qF "$MARKER_BEGIN" "$SHELL_RC"; then
    {
      printf '\n%s\n' "$MARKER_BEGIN"
      printf '%s\n'   "$MARKER_END"
    } >>"$SHELL_RC"
    echo "✓ Added claude-tools env block to $SHELL_RC"
  fi
}

# Set or replace `export KEY='VALUE'` inside the managed block of the
# shell rc. Value is single-quoted; embedded single quotes are escaped
# the shell-safe way.
set_env_var() {
  local key="$1" value="$2"
  ensure_rc_block
  local escaped=${value//\'/\'\\\'\'}
  local line="export ${key}='${escaped}'"
  local tmp
  tmp="$(mktemp)"
  # Pass `line` via the environment — `awk -v` would interpret backslash
  # escapes in the value and mangle the shell-safe single-quote escape.
  LINE="$line" awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" \
      -v key="$key" '
    BEGIN { in_block=0; replaced=0; line=ENVIRON["LINE"] }
    {
      if ($0 == begin) { in_block=1; print; next }
      if ($0 == end) {
        if (in_block && !replaced) { print line }
        in_block=0; print; next
      }
      if (in_block && $0 ~ "^export " key "=") {
        if (!replaced) { print line; replaced=1 }
        next
      }
      print
    }
  ' "$SHELL_RC" >"$tmp"
  mv "$tmp" "$SHELL_RC"
}

prompt_if_missing() {
  # prompt_if_missing VAR_NAME "Prompt text: "
  local var_name="$1" prompt_text="$2"
  local current="${!var_name:-}"
  if [[ -z "$current" ]]; then
    read -r -p "$prompt_text" current
  fi
  printf '%s' "$current"
}

install_tg_notify() {
  hr
  echo "==> Installing tg-notify"

  local BIN_DIR="${TG_NOTIFY_BIN_DIR:-$HOME/.local/bin}"

  mkdir -p "$BIN_DIR"
  install -m 0755 "$SCRIPT_DIR/tg-notify/tg-notify" "$BIN_DIR/tg-notify"
  echo "✓ Installed tg-notify to $BIN_DIR"

  local TOKEN CHAT
  TOKEN="$(prompt_if_missing TG_BOT_TOKEN "Telegram Bot Token: ")"
  CHAT="$(prompt_if_missing  TG_CHAT_ID   "Telegram Chat ID:   ")"

  if [[ -z "$TOKEN" || -z "$CHAT" ]]; then
    echo "✗ TG_BOT_TOKEN / TG_CHAT_ID are required" >&2
    return 1
  fi

  set_env_var TG_BOT_TOKEN "$TOKEN"
  set_env_var TG_CHAT_ID   "$CHAT"
  echo "✓ Wrote TG_BOT_TOKEN / TG_CHAT_ID to $SHELL_RC"

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      echo
      echo "⚠️  $BIN_DIR is not on your PATH. Add to your shell rc:"
      echo "        export PATH=\"\$HOME/.local/bin:\$PATH\""
      ;;
  esac

  echo
  read -r -p "Send a tg-notify test message now? [Y/n] " ans
  ans="${ans:-Y}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    # Export inline so the test works in this shell even before rc is re-sourced.
    if TG_BOT_TOKEN="$TOKEN" TG_CHAT_ID="$CHAT" \
         "$BIN_DIR/tg-notify" "✅ tg-notify installed on $(hostname)"; then
      echo "✓ Test message sent — check Telegram"
    else
      echo "✗ Test failed — verify your token / chat id in $SHELL_RC" >&2
      return 1
    fi
  fi
}

install_meal_checker() {
  hr
  echo "==> Installing meal-checker agent"

  if ! command -v node >/dev/null 2>&1; then
    echo "✗ Node.js is required but not found on PATH." >&2
    echo "  Install Node first: https://nodejs.org/ (or via mise/nvm/brew)" >&2
    return 1
  fi
  if ! command -v npm >/dev/null 2>&1; then
    echo "✗ npm is required but not found on PATH." >&2
    return 1
  fi
  echo "✓ Node $(node --version) / npm $(npm --version)"

  local EMAIL
  EMAIL="$(prompt_if_missing MEAL_CHECKER_EMAIL "Meal platform login email (e.g. you@mail.com): ")"
  if [[ -z "$EMAIL" ]]; then
    echo "✗ MEAL_CHECKER_EMAIL is required" >&2
    return 1
  fi
  set_env_var MEAL_CHECKER_EMAIL "$EMAIL"
  echo "✓ Wrote MEAL_CHECKER_EMAIL to $SHELL_RC"

  local AGENTS_DIR="$HOME/.claude/agents"
  local AGENT_DIR="$AGENTS_DIR/meal-checker"
  local AGENT_DEF="$AGENTS_DIR/meal-checker.md"
  local SRC="$SCRIPT_DIR/meal-checker"

  mkdir -p "$AGENTS_DIR" "$AGENT_DIR"

  if [[ -f "$AGENT_DEF" ]]; then
    read -r -p "⚠️  $AGENT_DEF already exists. Overwrite? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      install -m 0644 "$SRC/meal-checker.md" "$AGENT_DEF"
      echo "✓ Overwrote $AGENT_DEF"
    else
      echo "  Keeping existing definition."
    fi
  else
    install -m 0644 "$SRC/meal-checker.md" "$AGENT_DEF"
    echo "✓ Wrote $AGENT_DEF"
  fi

  install -m 0644 "$SRC/check.js"     "$AGENT_DIR/check.js"
  install -m 0644 "$SRC/package.json" "$AGENT_DIR/package.json"
  echo "✓ Copied check.js + package.json to $AGENT_DIR"

  echo
  echo "==> npm install (playwright) in $AGENT_DIR"
  (cd "$AGENT_DIR" && npm install --omit=dev --no-audit --no-fund)
  echo "✓ npm install complete"

  echo
  echo "==> Downloading chromium (~150 MB, first run only)"
  (cd "$AGENT_DIR" && npx --yes playwright install chromium)
  echo "✓ chromium ready"

  echo
  read -r -p "Run a meal-checker smoke test now? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    if MEAL_CHECKER_EMAIL="$EMAIL" node "$AGENT_DIR/check.js"; then
      echo
      echo "✓ Smoke test passed"
    else
      echo
      echo "✗ Smoke test failed — see error above" >&2
      return 1
    fi
  fi
}

if [[ "$TARGET" == "tg-notify"    || "$TARGET" == "both" ]]; then install_tg_notify;    fi
if [[ "$TARGET" == "meal-checker" || "$TARGET" == "both" ]]; then install_meal_checker; fi

hr
echo "Done."
echo
if [[ "$TARGET" == "tg-notify" || "$TARGET" == "both" ]]; then
  echo "  tg-notify:    tg-notify \"訊息內容\""
fi
if [[ "$TARGET" == "meal-checker" || "$TARGET" == "both" ]]; then
  echo "  meal-checker: ask Claude Code \"今天訂午餐了嗎?\""
fi
echo
echo "Env written to: ${SHELL_RC:-<shell rc>}"
echo "Open a new terminal (or 'source' your shell rc) to pick up the new variables."
