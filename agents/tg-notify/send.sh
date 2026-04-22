#!/usr/bin/env bash
# tg-notify: send a message to a Telegram chat.
#
# Usage:
#   send.sh [--chat-id <id>] [--plain|--markdown|--html] [--silent] < message.txt
#   echo "hi" | send.sh
#   echo "hi" | send.sh --chat-id 123456789
#
# Reads message body from stdin.
# Credentials come from (in order of precedence):
#   1. --chat-id flag (overrides chat only, not token)
#   2. TG_BOT_TOKEN / TG_CHAT_ID environment variables
#   3. ~/.config/claude-tools/env

set -euo pipefail

ENV_FILE="${HOME}/.config/claude-tools/env"
# Only source the env file for values not already in the environment,
# so exported shell vars take precedence over the file.
if [[ -f "$ENV_FILE" ]]; then
  _existing_token="${TG_BOT_TOKEN:-}"
  _existing_chat="${TG_CHAT_ID:-}"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  [[ -n "$_existing_token" ]] && TG_BOT_TOKEN="$_existing_token"
  [[ -n "$_existing_chat" ]] && TG_CHAT_ID="$_existing_chat"
  unset _existing_token _existing_chat
fi

PARSE_MODE="Markdown"
DISABLE_NOTIFICATION="false"
CHAT_ID_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chat-id)
      [[ $# -ge 2 ]] || { echo "error: --chat-id needs a value" >&2; exit 2; }
      CHAT_ID_OVERRIDE="$2"; shift 2 ;;
    --chat-id=*)
      CHAT_ID_OVERRIDE="${1#--chat-id=}"; shift ;;
    --plain)    PARSE_MODE=""; shift ;;
    --markdown) PARSE_MODE="Markdown"; shift ;;
    --html)     PARSE_MODE="HTML"; shift ;;
    --silent)   DISABLE_NOTIFICATION="true"; shift ;;
    -h|--help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -n "$CHAT_ID_OVERRIDE" ]]; then
  TG_CHAT_ID="$CHAT_ID_OVERRIDE"
fi

: "${TG_BOT_TOKEN:?TG_BOT_TOKEN not set — export it or configure ~/.config/claude-tools/env}"
: "${TG_CHAT_ID:?TG_CHAT_ID not set — pass --chat-id, export the env var, or configure ~/.config/claude-tools/env}"

if ! [[ "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
  echo "error: TG_CHAT_ID must be a numeric Telegram chat id (got: $TG_CHAT_ID)" >&2
  exit 2
fi

MSG="$(cat)"
if [[ -z "$MSG" ]]; then
  echo "error: empty message on stdin" >&2
  exit 2
fi

# Telegram's sendMessage caps at 4096 chars.
if [[ ${#MSG} -gt 4096 ]]; then
  echo "error: message is ${#MSG} chars, exceeds Telegram's 4096 limit" >&2
  exit 2
fi

ARGS=(
  -s -S --fail-with-body
  -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
  -d "chat_id=${TG_CHAT_ID}"
  -d "disable_notification=${DISABLE_NOTIFICATION}"
  --data-urlencode "text=${MSG}"
)
if [[ -n "$PARSE_MODE" ]]; then
  ARGS+=(-d "parse_mode=${PARSE_MODE}")
fi

RESPONSE="$(curl "${ARGS[@]}")"
if ! grep -q '"ok":true' <<<"$RESPONSE"; then
  echo "telegram send failed: $RESPONSE" >&2
  exit 1
fi

MSG_ID="$(sed -n 's/.*"message_id":\([0-9]*\).*/\1/p' <<<"$RESPONSE" | head -1)"
echo "sent ok (message_id=${MSG_ID})"
