# Claude Agents Bundle

> ⚠️ **Warning**: Date/time logic (e.g. "today's order") relies on the local system timezone. Make sure your system is set to **Asia/Taipei (GMT+8)**, otherwise the tool may query the wrong date.

Three personal Claude Code sub-agents plus one routing skill:

- **meal-checker** (agent) — logs into the Amazon employee lunch ordering platform (read-only) and reports today's order plus upcoming confirmed orders.
- **meal-order** (agent) — browses available meals on any date, places new orders, and cancels existing ones (writes to the platform). Shares Playwright with meal-checker.
- **tg-notify** (agent) — sends a Telegram message to the user's personal chat via the Bot API.
- **meal** (skill) — thin router invoked via `/meal`. Delegates to `meal-checker` (read) or `meal-order` (list / order / cancel) based on intent.

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

1. Copy `meal-checker.md`, `meal-order.md`, `tg-notify.md`, and their supporting folders into `~/.claude/agents/`
2. Run `npm install` and `npx playwright install chromium` for meal-checker, then symlink `meal-order/node_modules` to share the same install
3. Copy any skills under `skills/` (e.g. `meal/`) into `~/.claude/skills/`
4. Create `~/.config/claude-tools/env` from the template and prompt for secrets
5. Add a one-liner to `~/.zshrc` / `~/.bashrc` so the env file is sourced on new shells

Re-running the installer is safe: existing agent/skill folders in `~/.claude/agents/` and `~/.claude/skills/` are removed and replaced in place, and existing env values become defaults at the prompts.

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

# meal-order — lists today's lunch menu as JSON (read-only smoke test)
node ~/.claude/agents/meal-order/list-menu.js LUNCH
```

## Uninstall

```bash
rm -rf ~/.claude/agents/meal-checker ~/.claude/agents/meal-checker.md
rm -rf ~/.claude/agents/meal-order   ~/.claude/agents/meal-order.md
rm -rf ~/.claude/agents/tg-notify    ~/.claude/agents/tg-notify.md
rm -rf ~/.claude/skills/meal
rm -rf ~/.config/claude-tools        # removes the env file — back up first if needed
```

Then remove the `claude-agents: load shared env` block from your shell rc.

## Layout

```
claude-agents-bundle/
├── install.sh
├── README.md
├── env.example
├── agents/
│   ├── meal-checker.md
│   ├── meal-checker/
│   │   ├── check.js
│   │   ├── package.json
│   │   └── package-lock.json
│   ├── meal-order.md
│   ├── meal-order/
│   │   ├── list-menu.js
│   │   ├── order.js
│   │   ├── cancel.js
│   │   └── package.json
│   ├── tg-notify.md
│   └── tg-notify/
│       └── send.sh
└── skills/
    └── meal/
        └── SKILL.md
```

`node_modules/` and the Playwright chromium cache are **not** shipped — the installer fetches them into `meal-checker/` and symlinks `meal-order/node_modules` to it so both agents share the same Playwright install.
