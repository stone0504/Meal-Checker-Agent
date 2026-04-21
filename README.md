# claude-tools-package

兩個搭配 Claude Code 使用的小工具，合併在同一個包：

| 工具 | 用途 |
|------|------|
| **tg-notify** | 從 CLI 送訊息到你自己的 Telegram（適合長任務跑完通知） |
| **meal-checker** | Claude Code subagent，登入員工訂餐平台查已確認的午餐 |

## 安裝

在新電腦上：

```bash
tar -xzf claude-tools-package.tar.gz
cd claude-tools-package
./install.sh              # 兩個都裝
./install.sh tg-notify    # 只裝 tg-notify
./install.sh meal-checker # 只裝 meal-checker
```

非互動式安裝（所有變數都可以預先帶入環境變數，略過提示）：

```bash
TG_BOT_TOKEN=xxx TG_CHAT_ID=yyy ./install.sh tg-notify
MEAL_CHECKER_EMAIL=you@mail.com ./install.sh meal-checker
TG_BOT_TOKEN=xxx TG_CHAT_ID=yyy MEAL_CHECKER_EMAIL=you@mail.com ./install.sh
```

安裝過程會：

1. 把 `TG_BOT_TOKEN` / `TG_CHAT_ID` / `MEAL_CHECKER_EMAIL` 寫進共用 env 檔 `~/.config/claude-tools/env` (mode 600)
2. 自動在你的 shell rc（zsh → `~/.zshrc`；bash → Linux 用 `~/.bashrc`、macOS 用 `~/.bash_profile`）加一段 `source` 指令，讓新開的 terminal 都能讀到這些變數
3. 裝完後 `source ~/.zshrc`（或 `source ~/.bashrc` / 開新 terminal）就能使用

## 前置需求

| 工具 | 需要 |
|------|------|
| tg-notify | `curl`（macOS/Linux 預設都有）、Telegram Bot Token、Chat ID |
| meal-checker | Node.js + npm（會用 `npm install` 裝 playwright，首次下載 chromium 約 150 MB） |

### 取得 Telegram 憑證

- **Bot Token**：Telegram 找 `@BotFather` → `/newbot`
- **Chat ID**：對 bot 按 Start 並傳一則訊息後，
  ```bash
  curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[0].message.chat.id'
  ```

## 安裝後位置

| 檔案 | 路徑 |
|------|------|
| tg-notify 執行檔 | `~/.local/bin/tg-notify` |
| 共用環境變數 | `~/.config/claude-tools/env` (mode 600) |
| meal-checker 定義 | `~/.claude/agents/meal-checker.md` |
| meal-checker 執行檔 + 依賴 | `~/.claude/agents/meal-checker/` |

## 用法

**tg-notify**

```bash
tg-notify "部署完成 ✅"
echo "支援 pipe" | tg-notify
```

在 Claude Code 裡：
> 幫我跑 `npm run build`，跑完用 tg-notify 通知我

**meal-checker**

在 Claude Code 裡直接問：
> 今天訂午餐了嗎？

Claude 會自動委派給 meal-checker 子代理人。

## 移除

```bash
# tg-notify
rm ~/.local/bin/tg-notify

# meal-checker
rm ~/.claude/agents/meal-checker.md
rm -rf ~/.claude/agents/meal-checker/

# 共用環境變數（兩個工具共用）
rm -rf ~/.config/claude-tools/
# 同時把 ~/.zshrc 或 ~/.bashrc 裡 `# >>> claude-tools env >>>` 到
# `# <<< claude-tools env <<<` 之間那段手動刪掉
```

## 安全提醒

- `~/.config/claude-tools/env` 已經設為 600 權限，不要 commit 進 git
- 如果 bot token 外洩，到 `@BotFather` → `/revoke` 重新產生
- meal-checker 只做讀取，不會下單或取消
