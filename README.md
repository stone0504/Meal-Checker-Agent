# Claude Agents Bundle

> ⚠️ **Warning**: Date/time logic (e.g. "today's order") relies on the local system timezone. Make sure your system is set to **Asia/Taipei (GMT+8)**, otherwise the tool may query the wrong date.

Two personal Claude Code sub-agents:

- **meal-checker** — logs into the Amazon employee lunch ordering platform (read-only) and reports today's order plus upcoming confirmed orders.
- **tg-notify** — sends a Telegram message to the user's personal chat via the Bot API.

## Requirements

- macOS or Linux
- Claude Code already installed (this installs into `~/.claude/agents/`)
- Node.js 18 or newer
- `curl`

## Install

```bash
tar -xzf claude-agents-bundle.tar.gz
cd claude-agents-bundle
./install.sh
```

The installer will:

1. Copy `meal-checker.md`, `tg-notify.md`, and their supporting folders into `~/.claude/agents/`
2. Run `npm install` and `npx playwright install chromium` for meal-checker
3. Create `~/.config/claude-tools/env` from the template and prompt for secrets
4. Add a one-liner to `~/.zshrc` / `~/.bashrc` so the env file is sourced on new shells

Existing files in `~/.claude/agents/` are backed up to `*.bak.<timestamp>` before being overwritten. Re-running the installer is safe.

If you prefer to fill in secrets manually, pass `--no-prompt`:

```bash
./install.sh --no-prompt
# then edit ~/.config/claude-tools/env
```

## Configuration

`~/.config/claude-tools/env` (permissions `600`):

```bash
export MEAL_CHECKER_EMAIL='you@amazon.com'
export TG_BOT_TOKEN='<bot token from @BotFather>'
export TG_CHAT_ID='<your numeric chat id>'
```

To find your Telegram chat id: create a bot via [@BotFather](https://t.me/BotFather), send it any message, then visit `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy the `chat.id` from the JSON response.

## Smoke tests

```bash
# tg-notify — you should receive the message on your phone
echo "install smoke test" | ~/.claude/agents/tg-notify/send.sh

# meal-checker — prints JSON to stdout
node ~/.claude/agents/meal-checker/check.js
```

## Uninstall

```bash
rm -rf ~/.claude/agents/meal-checker ~/.claude/agents/meal-checker.md
rm -rf ~/.claude/agents/tg-notify    ~/.claude/agents/tg-notify.md
rm -rf ~/.config/claude-tools        # removes the env file — back up first if needed
```

Then remove the `claude-agents: load shared env` block from your shell rc.

## Layout

```
claude-agents-bundle/
├── install.sh
├── README.md
├── env.example
└── agents/
    ├── meal-checker.md
    ├── meal-checker/
    │   ├── check.js
    │   ├── package.json
    │   └── package-lock.json
    ├── tg-notify.md
    └── tg-notify/
        └── send.sh
```

`node_modules/` and the Playwright chromium cache are **not** shipped — the installer fetches them on each machine.
