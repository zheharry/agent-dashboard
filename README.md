# Agent Quota

原生 macOS menu bar app。app 會常駐在桌面最上方的 menu bar，點擊圖示後顯示 quota popover，不開啟瀏覽器。

## 建置與開啟

在此目錄執行：

```bash
bash scripts/build-app.sh
open dist/AgentQuota.app
```

app 目前內建 Claude、Codex、Agy Claude/GPT、Agy Gemini、Copilot、Grok 範例資料，一組 quota 對應一張卡片。卡片內以 0–100% 半圓儀表並列各種 rate limit：Claude 與 Codex 顯示 5 小時／每週，Antigravity 拆成 Agy Claude/GPT 與 Agy Gemini 兩張卡，各自顯示該 group 的 5 小時／每週（這兩個 group 的額度本來就互相獨立），Copilot 顯示每月 AI Credits，Grok 顯示目前 billing period。點擊任一儀表即可編輯該 quota；資料會儲存在 macOS `UserDefaults`。

開啟後會透過本機已登入的 CLI 或官方 endpoint 自動同步 Claude (`claude -p /usage`)、Codex (`codex app-server account/rateLimits/read`)、Agy 兩張卡 (`agy -p /usage`)、Copilot (`gh api .../settings/billing/usage`) 與 Grok (`~/.grok/auth.json` + Grok billing endpoint) 的 live usage。Copilot 使用當月 AI Credits；目前以 Copilot Pro 的 1,500 credits allowance 顯示，若方案不同可在編輯器調整上限。Grok Free 有 weekly credit limit，但目前 billing API 只公開 reset period，不公開 cap、used 或 remaining，因此顯示 `N/A` 與 `Free limit · usage unavailable`；付費方案若提供 `creditUsagePercent`，則顯示實際百分比。
