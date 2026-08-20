# Agent Quota

原生 macOS menu bar app。app 會常駐在桌面最上方的 menu bar，點擊圖示後顯示 quota popover，不開啟瀏覽器。

## 建置與開啟

在此目錄執行：

```bash
bash scripts/build-app.sh
open dist/AgentQuota.app
```

app 目前內建 Claude、Codex、Agy、Copilot、Other 範例資料。點擊 quota 卡片上的鉛筆可以修改方案、current/max 與 reset time；資料會儲存在 macOS `UserDefaults`。

開啟後會透過本機已登入的 CLI 自動同步 Claude (`claude -p /usage`)、Codex (`codex app-server account/rateLimits/read`) 與 Agy (`agy -p /usage`) 的 live usage。Copilot 個人帳號目前沒有可用的 GitHub quota endpoint，因此保留手動資料；組織/企業帳號可再接 Copilot metrics API。
