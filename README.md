# Agent Quota

A native macOS menu bar app. It lives in the menu bar; clicking the icon opens a quota popover — no browser involved.

## Build and run

From this directory:

```bash
bash scripts/build-app.sh
open dist/AgentQuota.app
```

The app ships with sample data for Claude, Codex, Agy Claude/GPT, Agy Gemini, Copilot and Grok — one card per quota group. Each card stacks that group's rate limits as 0–100% rings: Claude and Codex show a 5-hour and a weekly window; Antigravity is split into two cards, Agy Claude/GPT and Agy Gemini, because those two groups have independent allowances; Copilot shows monthly AI Credits; Grok shows the current billing period. Click any ring to edit that quota. Everything is stored in macOS `UserDefaults`.

On launch the app syncs live usage through CLIs you are already signed in to, or the official endpoints: Claude (`claude -p /usage`), Codex (`codex app-server account/rateLimits/read`), both Agy cards (`agy -p /usage`), Copilot (`gh api .../settings/billing/usage`) and Grok (`~/.grok/auth.json` plus the Grok billing endpoint).

Copilot is reported as AI Credits for the current month, displayed against the Copilot Pro allowance of 1,500 credits; change the ceiling in the editor if you are on a different plan. Grok Free has a weekly credit limit, but the billing API currently exposes only the reset period — no cap, used or remaining — so it shows `N/A` and `Free limit · usage unavailable`. Paid plans that return `creditUsagePercent` show the real percentage.
