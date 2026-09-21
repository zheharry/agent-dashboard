use std::{collections::BTreeMap, path::PathBuf, process::Stdio, time::Duration};

use chrono::{DateTime, Datelike, FixedOffset, NaiveDate, TimeZone, Utc};
use regex::Regex;
use serde::Deserialize;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Command,
    time::timeout,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveQuota {
    pub service_name: String,
    pub current: i64,
    pub max: i64,
    pub reset_at: DateTime<Utc>,
    pub plan: Option<String>,
    pub reset_window: Option<String>,
    pub disabled_reason: Option<String>,
    pub reset_note: Option<String>,
}

#[derive(Debug, Default)]
pub struct LiveUsageResult {
    pub updates: Vec<LiveQuota>,
    pub issues: Vec<String>,
    pub refreshed_apps: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveUsageError {
    ExecutableNotFound(String),
    ProcessFailed(String, String),
    TimedOut(String),
    InvalidResponse(String),
}

impl std::fmt::Display for LiveUsageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ExecutableNotFound(name) => write!(f, "{name} CLI not found"),
            Self::ProcessFailed(name, detail) => write!(f, "{name} failed: {detail}"),
            Self::TimedOut(name) => write!(f, "{name} timed out"),
            Self::InvalidResponse(name) => write!(f, "{name} returned an unexpected usage response"),
        }
    }
}

impl std::error::Error for LiveUsageError {}

pub async fn fetch_all() -> LiveUsageResult {
    let (claude, codex, agy, copilot, grok) = tokio::join!(
        fetch_claude(),
        fetch_codex(),
        fetch_agy(),
        fetch_copilot(),
        fetch_grok(),
    );

    let mut result = LiveUsageResult::default();

    match claude {
        Ok(updates) => {
            result.updates.extend(updates);
            result.refreshed_apps.push("claude".into());
        }
        Err(error) => result.issues.push(format!("Claude: {error}")),
    }
    match codex {
        Ok(updates) => {
            result.updates.extend(updates);
            result.refreshed_apps.push("codex".into());
        }
        Err(error) => result.issues.push(format!("Codex: {error}")),
    }
    match agy {
        Ok(updates) => {
            result.updates.extend(updates);
            result.refreshed_apps.push("agy claude/gpt".into());
            result.refreshed_apps.push("agy gemini".into());
        }
        Err(error) => result.issues.push(format!("Agy: {error}")),
    }
    match copilot {
        Ok(update) => {
            result.updates.push(update);
            result.refreshed_apps.push("copilot".into());
        }
        Err(error) => result.issues.push(format!("Copilot: {error}")),
    }
    match grok {
        Ok(update) => {
            result.updates.push(update);
            result.refreshed_apps.push("grok".into());
        }
        Err(error) => result.issues.push(format!("Grok: {error}")),
    }

    result
}

pub async fn fetch_claude() -> Result<Vec<LiveQuota>, LiveUsageError> {
    let output = run_simple(
        "claude",
        &["-p", "/usage", "--output-format", "json", "--no-session-persistence"],
    )
    .await?;
    parse_claude_response(&output, Utc::now())
}

pub async fn fetch_agy() -> Result<Vec<LiveQuota>, LiveUsageError> {
    let output = run_simple("agy", &["-p", "/usage", "--output-format", "json"]).await?;
    parse_agy_response(&output)
}

pub async fn fetch_codex() -> Result<Vec<LiveQuota>, LiveUsageError> {
    let response = run_codex_rate_limit_request().await?;
    parse_codex_response(&response)
}

pub async fn fetch_copilot() -> Result<LiveQuota, LiveUsageError> {
    let login = run_simple("gh", &["api", "user", "--jq", ".login"]) 
        .await?
        .trim()
        .to_string();
    if login.is_empty() {
        return Err(LiveUsageError::InvalidResponse("Copilot".into()));
    }

    let output = run_simple("gh", &["api", &format!("/users/{login}/settings/billing/usage")]).await?;
    parse_copilot_response(&output, Utc::now())
}

pub async fn fetch_grok() -> Result<LiveQuota, LiveUsageError> {
    let auth_path = home_dir()
        .join(".grok")
        .join("auth.json");
    let auth_data = tokio::fs::read_to_string(&auth_path)
        .await
        .map_err(|_| LiveUsageError::ProcessFailed("Grok".into(), "not signed in; run `grok login`".into()))?;
    let token = extract_grok_token(&auth_data)?;

    let client = reqwest::Client::builder()
        .user_agent("agent-quota/1.0 (personal research; local app)")
        .build()
        .map_err(|error| LiveUsageError::ProcessFailed("Grok".into(), error.to_string()))?;

    let response = timeout(
        Duration::from_secs(45),
        client
            .get("https://cli-chat-proxy.grok.com/v1/billing?format=credits")
            .bearer_auth(token)
            .header(reqwest::header::ACCEPT, "application/json")
            .send(),
    )
    .await
    .map_err(|_| LiveUsageError::TimedOut("Grok".into()))?
    .map_err(|error| LiveUsageError::ProcessFailed("Grok".into(), error.to_string()))?;

    if !response.status().is_success() {
        return Err(LiveUsageError::ProcessFailed(
            "Grok".into(),
            format!("HTTP {}", response.status()),
        ));
    }

    let output = response
        .text()
        .await
        .map_err(|error| LiveUsageError::ProcessFailed("Grok".into(), error.to_string()))?;
    parse_grok_billing_response(&output)
}

pub fn parse_claude_response(output: &str, now: DateTime<Utc>) -> Result<Vec<LiveQuota>, LiveUsageError> {
    let response: ClaudeResponse = decode_json_slice(output, "Claude")?;
    let usages = parse_claude_usage_text(&response.result, now);
    if usages.is_empty() {
        return Err(LiveUsageError::InvalidResponse("Claude".into()));
    }
    Ok(usages
        .into_iter()
        .map(|usage| LiveQuota {
            service_name: format!("Claude {}", usage.window),
            current: usage.used_percent,
            max: 100,
            reset_at: usage.reset_at.unwrap_or(now),
            plan: None,
            reset_window: Some(usage.window),
            disabled_reason: None,
            reset_note: usage.reset_at.is_none().then(|| "Reset time unavailable".into()),
        })
        .collect())
}

pub fn parse_agy_response(output: &str) -> Result<Vec<LiveQuota>, LiveUsageError> {
    let response: AgyResponse = decode_json_slice(output, "Agy")?;
    let groups = response.command.data.map(|data| data.groups).unwrap_or_default();

    let mut family_buckets: BTreeMap<String, Vec<AgyBucket>> = BTreeMap::new();
    for group in groups {
        let lower = group.name.to_lowercase();
        let family = if lower.contains("claude") {
            "Claude".to_string()
        } else if lower.contains("gemini") {
            "Gemini".to_string()
        } else {
            group.name
        };
        family_buckets.entry(family).or_default().extend(group.buckets);
    }

    let mut results = Vec::new();
    for (family, buckets) in family_buckets {
        let family_reset = buckets
            .iter()
            .filter_map(|bucket| bucket.reset_time.as_deref())
            .filter_map(parse_iso_datetime)
            .max()
            .unwrap_or_else(Utc::now);

        for bucket in buckets {
            if bucket.disabled != Some(true) && bucket.reset_time.is_none() {
                continue;
            }
            let reset_at = bucket
                .reset_time
                .as_deref()
                .and_then(parse_iso_datetime)
                .unwrap_or(family_reset);
            let window_label = if bucket.window == "5h" { "5h" } else { "weekly" };
            results.push(LiveQuota {
                service_name: format!("Agy {family} {window_label}"),
                current: ((1.0 - bucket.remaining_fraction) * 100.0).round() as i64,
                max: 100,
                reset_at,
                plan: Some("Pro".into()),
                reset_window: Some(window_label.into()),
                disabled_reason: bucket.disabled.filter(|flag| *flag).map(|_| "Weekly limit reached".into()),
                reset_note: None,
            });
        }
    }

    if results.is_empty() {
        return Err(LiveUsageError::InvalidResponse("Agy".into()));
    }

    Ok(results)
}

pub fn parse_codex_response(output: &str) -> Result<Vec<LiveQuota>, LiveUsageError> {
    let line = output
        .lines()
        .find(|candidate| {
            serde_json::from_str::<serde_json::Value>(candidate)
                .ok()
                .and_then(|value| value.get("id").and_then(|id| id.as_i64()))
                == Some(2)
        })
        .ok_or_else(|| LiveUsageError::InvalidResponse("Codex".into()))?;

    let response: CodexRpcResponse = serde_json::from_str(line)
        .map_err(|error| LiveUsageError::ProcessFailed("Codex".into(), error.to_string()))?;
    let result = response
        .result
        .ok_or_else(|| LiveUsageError::InvalidResponse("Codex".into()))?;

    let mut quotas = Vec::new();
    for (fallback_label, window) in [
        ("primary", result.rate_limits.primary),
        ("secondary", result.rate_limits.secondary),
    ] {
        let Some(window) = window else { continue };
        let Some(reset_timestamp) = window.resets_at else { continue };
        let window_label = match window.window_duration_mins {
            Some(300) => "5h",
            Some(10_080) => "weekly",
            _ => fallback_label,
        };
        quotas.push(LiveQuota {
            service_name: format!("Codex {window_label}"),
            current: window.used_percent,
            max: 100,
            reset_at: DateTime::<Utc>::from_timestamp(reset_timestamp, 0)
                .ok_or_else(|| LiveUsageError::InvalidResponse("Codex".into()))?,
            plan: result.rate_limits.plan_type.clone(),
            reset_window: Some(window_label.into()),
            disabled_reason: None,
            reset_note: None,
        });
    }

    if quotas.is_empty() {
        return Err(LiveUsageError::InvalidResponse("Codex".into()));
    }

    Ok(quotas)
}

pub fn parse_copilot_response(output: &str, now: DateTime<Utc>) -> Result<LiveQuota, LiveUsageError> {
    let response: GitHubUsageResponse = serde_json::from_str(output)
        .map_err(|error| LiveUsageError::ProcessFailed("Copilot".into(), error.to_string()))?;

    let month_prefix = format!("{:04}-{:02}", now.year(), now.month());
    let current_month_items: Vec<_> = response
        .usage_items
        .into_iter()
        .filter(|item| item.product.eq_ignore_ascii_case("copilot") && item.date.starts_with(&month_prefix))
        .collect();
    let credit_items: Vec<_> = current_month_items
        .iter()
        .filter(|item| item.sku.to_lowercase().contains("ai credit"))
        .cloned()
        .collect();
    let source_items = if credit_items.is_empty() { current_month_items } else { credit_items };
    let used_credits = source_items.iter().fold(0.0, |sum, item| sum + item.quantity);

    let month_start = Utc
        .with_ymd_and_hms(now.year(), now.month(), 1, 0, 0, 0)
        .single()
        .ok_or_else(|| LiveUsageError::InvalidResponse("Copilot".into()))?;
    let next_reset = if now.month() == 12 {
        Utc.with_ymd_and_hms(now.year() + 1, 1, 1, 0, 0, 0)
            .single()
            .ok_or_else(|| LiveUsageError::InvalidResponse("Copilot".into()))?
    } else {
        Utc.with_ymd_and_hms(now.year(), now.month() + 1, 1, 0, 0, 0)
            .single()
            .ok_or_else(|| LiveUsageError::InvalidResponse("Copilot".into()))?
    };
    let _ = month_start;

    Ok(LiveQuota {
        service_name: "Copilot".into(),
        current: used_credits.round().min(1_500.0) as i64,
        max: 1_500,
        reset_at: next_reset,
        plan: Some("Copilot Pro · AI credits".into()),
        reset_window: Some("month".into()),
        disabled_reason: None,
        reset_note: None,
    })
}

pub fn extract_grok_token(output: &str) -> Result<String, LiveUsageError> {
    let auth_records: BTreeMap<String, GrokAuthRecord> = serde_json::from_str(output)
        .map_err(|_| LiveUsageError::InvalidResponse("Grok auth".into()))?;
    auth_records
        .into_values()
        .find_map(|record| (!record.key.is_empty()).then_some(record.key))
        .ok_or_else(|| LiveUsageError::ProcessFailed("Grok".into(), "not signed in; run `grok login`".into()))
}

pub fn parse_grok_billing_response(output: &str) -> Result<LiveQuota, LiveUsageError> {
    let response: GrokBillingResponse = serde_json::from_str(output)
        .map_err(|error| LiveUsageError::ProcessFailed("Grok".into(), format!("invalid billing response: {error}")))?;

    let latest_history = response
        .config
        .history
        .as_ref()
        .and_then(|history| history.last())
        .or_else(|| response.history.as_ref().and_then(|history| history.last()));
    let usage_percent = response
        .credit_usage_percent
        .or(response.config.credit_usage_percent)
        .or(latest_history.and_then(|history| history.credit_usage_percent));
    let period = response.config.current_period.as_ref();
    let reset_text = period
        .map(|period| period.end.as_str())
        .or(response.config.billing_period_end.as_deref())
        .or(latest_history.and_then(|history| history.end.as_deref()));
    let reset_at = reset_text
        .and_then(parse_iso_datetime)
        .ok_or_else(|| LiveUsageError::InvalidResponse("Grok".into()))?;

    let is_limited_free = usage_percent.is_none()
        && latest_history.is_none()
        && response.config.on_demand_cap.as_ref().map(|cap| cap.val).unwrap_or_default() == 0.0;
    let plan = if is_limited_free {
        "Free".to_string()
    } else {
        grok_plan(latest_history.and_then(|history| history.subscription_tier.as_deref()))
    };

    Ok(LiveQuota {
        service_name: "Grok".into(),
        current: usage_percent.unwrap_or(0.0).round() as i64,
        max: if usage_percent.is_none() { 0 } else { 100 },
        reset_at,
        plan: Some(plan),
        reset_window: Some(grok_window(period.and_then(|period| period.r#type.as_deref()))),
        disabled_reason: None,
        reset_note: usage_percent
            .is_none()
            .then(|| if is_limited_free { "Free limit · usage unavailable" } else { "Usage amount unavailable" }.to_string()),
    })
}

fn grok_window(raw_type: Option<&str>) -> String {
    match raw_type.map(|value| value.to_lowercase()) {
        Some(value) if value.contains("month") => "month".into(),
        Some(value) if value.contains("week") => "weekly".into(),
        _ => "period".into(),
    }
}

fn grok_plan(raw_tier: Option<&str>) -> String {
    let Some(raw_tier) = raw_tier else {
        return "Grok Build".into();
    };
    let tier = raw_tier.to_lowercase();
    if tier.contains("heavy") {
        "SuperGrok Heavy".into()
    } else if tier.contains("plus") {
        "SuperGrok Plus".into()
    } else if tier.contains("super") {
        "SuperGrok".into()
    } else if tier.contains("free") {
        "Free".into()
    } else {
        "Grok Build".into()
    }
}

fn parse_claude_usage_text(text: &str, now: DateTime<Utc>) -> Vec<ClaudeUsage> {
    text.lines()
        .filter_map(|line| {
            let window = if line.to_lowercase().contains("current session") || line.to_lowercase().contains("5 hour") {
                "5h"
            } else if line.to_lowercase().contains("current week") {
                "weekly"
            } else {
                return None;
            };
            let parts: Vec<_> = line.splitn(2, '·').map(str::trim).collect();
            let percent_text = parts.first()?.split(':').last()?.trim().trim_end_matches('%');
            let used_percent = percent_text.parse::<i64>().ok()?;
            let reset_at = parts
                .get(1)
                .map(|value| value.replace("resets ", ""))
                .and_then(|value| parse_claude_date(value.trim(), now));
            Some(ClaudeUsage {
                window: window.into(),
                used_percent,
                reset_at,
            })
        })
        .collect()
}

fn parse_claude_date(value: &str, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    let regex = Regex::new(r"^([A-Za-z]{3}) (\d{1,2}) at ([0-9:]+[ap]m) \(([^)]+)\)$").ok()?;
    let captures = regex.captures(value)?;
    let month = month_number(captures.get(1)?.as_str())?;
    let day = captures.get(2)?.as_str().parse::<u32>().ok()?;
    let (hour, minute) = parse_meridiem_time(captures.get(3)?.as_str())?;
    let timezone = timezone_offset(captures.get(4)?.as_str())?;

    let mut year = now.year();
    let mut date = FixedOffset::east_opt(timezone)?
        .from_local_datetime(&NaiveDate::from_ymd_opt(year, month, day)?.and_hms_opt(hour, minute, 0)?)
        .single()?
        .with_timezone(&Utc);
    if date < now - chrono::Duration::days(14) {
        year += 1;
        date = FixedOffset::east_opt(timezone)?
            .from_local_datetime(&NaiveDate::from_ymd_opt(year, month, day)?.and_hms_opt(hour, minute, 0)?)
            .single()?
            .with_timezone(&Utc);
    }
    Some(date)
}

fn month_number(value: &str) -> Option<u32> {
    Some(match value {
        "Jan" => 1,
        "Feb" => 2,
        "Mar" => 3,
        "Apr" => 4,
        "May" => 5,
        "Jun" => 6,
        "Jul" => 7,
        "Aug" => 8,
        "Sep" => 9,
        "Oct" => 10,
        "Nov" => 11,
        "Dec" => 12,
        _ => return None,
    })
}

fn parse_meridiem_time(value: &str) -> Option<(u32, u32)> {
    let lower = value.to_lowercase();
    let meridiem = if lower.ends_with("am") { "am" } else if lower.ends_with("pm") { "pm" } else { return None };
    let clock = lower.trim_end_matches(meridiem);
    let mut parts = clock.split(':');
    let hour = parts.next()?.parse::<u32>().ok()?;
    let minute = parts.next().map(|part| part.parse::<u32>().ok()).flatten().unwrap_or(0);
    let hour = match (hour % 12, meridiem) {
        (0, "am") => 0,
        (0, "pm") => 12,
        (value, "pm") => value + 12,
        (value, _) => value,
    };
    Some((hour, minute))
}

fn timezone_offset(value: &str) -> Option<i32> {
    Some(match value.to_uppercase().as_str() {
        "UTC" | "GMT" => 0,
        "PST" => -8 * 3600,
        "PDT" => -7 * 3600,
        "MST" => -7 * 3600,
        "MDT" => -6 * 3600,
        "CST" => -6 * 3600,
        "CDT" => -5 * 3600,
        "EST" => -5 * 3600,
        "EDT" => -4 * 3600,
        "BST" => 1 * 3600,
        "CET" => 1 * 3600,
        "CEST" => 2 * 3600,
        "JST" => 9 * 3600,
        "HKT" => 8 * 3600,
        _ => return None,
    })
}

fn parse_iso_datetime(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value).ok().map(|value| value.with_timezone(&Utc))
}

fn extract_json_object(output: &str, provider: &str) -> Result<&str, LiveUsageError> {
    let start = output
        .find('{')
        .ok_or_else(|| LiveUsageError::InvalidResponse(provider.into()))?;
    let end = output
        .rfind('}')
        .ok_or_else(|| LiveUsageError::InvalidResponse(provider.into()))?;
    Ok(&output[start..=end])
}

fn decode_json_slice<T>(output: &str, provider: &str) -> Result<T, LiveUsageError>
where
    T: for<'de> Deserialize<'de>,
{
    let slice = extract_json_object(output, provider)?;
    serde_json::from_str(slice)
        .map_err(|error| LiveUsageError::ProcessFailed(provider.into(), error.to_string()))
}

async fn run_simple(name: &str, arguments: &[&str]) -> Result<String, LiveUsageError> {
    let executable = executable_path(name).await.ok_or_else(|| LiveUsageError::ExecutableNotFound(name.into()))?;
    let home = home_dir();

    let output = timeout(Duration::from_secs(45), async {
        let mut command = Command::new(executable);
        command
            .args(arguments)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .current_dir(&home)
            .env("TERM", "dumb");
        command.output().await
    })
    .await
    .map_err(|_| LiveUsageError::TimedOut(name.into()))?
    .map_err(|error| LiveUsageError::ProcessFailed(name.into(), error.to_string()))?;

    if !output.status.success() {
        return Err(LiveUsageError::ProcessFailed(
            name.into(),
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
        ));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

async fn run_codex_rate_limit_request() -> Result<String, LiveUsageError> {
    let executable = executable_path("codex")
        .await
        .ok_or_else(|| LiveUsageError::ExecutableNotFound("codex".into()))?;
    let home = home_dir();

    let mut child = Command::new(executable)
        .args(["app-server", "--listen", "stdio://"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .current_dir(home)
        .env("TERM", "dumb")
        .spawn()
        .map_err(|error| LiveUsageError::ProcessFailed("Codex".into(), error.to_string()))?;

    let mut stdin = child.stdin.take().ok_or_else(|| LiveUsageError::InvalidResponse("Codex".into()))?;
    let stdout = child.stdout.take().ok_or_else(|| LiveUsageError::InvalidResponse("Codex".into()))?;
    let requests = concat!(
        "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"agent-quota\",\"version\":\"1.0.0\"}}}\n",
        "{\"method\":\"initialized\"}\n",
        "{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":null}\n"
    );
    stdin
        .write_all(requests.as_bytes())
        .await
        .map_err(|error| LiveUsageError::ProcessFailed("Codex".into(), error.to_string()))?;
    drop(stdin);

    let mut reader = BufReader::new(stdout).lines();
    let response = timeout(Duration::from_secs(45), async {
        while let Some(line) = reader.next_line().await? {
            let is_target = serde_json::from_str::<serde_json::Value>(&line)
                .ok()
                .and_then(|value| value.get("id").and_then(|id| id.as_i64()))
                == Some(2);
            if is_target {
                return Ok::<String, std::io::Error>(line);
            }
        }
        Ok(String::new())
    })
    .await
    .map_err(|_| LiveUsageError::TimedOut("Codex".into()))?
    .map_err(|error| LiveUsageError::ProcessFailed("Codex".into(), error.to_string()))?;

    let _ = child.kill().await;
    if response.is_empty() {
        return Err(LiveUsageError::InvalidResponse("Codex".into()));
    }
    Ok(response)
}

async fn executable_path(name: &str) -> Option<PathBuf> {
    let home = home_dir();
    let app_data = std::env::var_os("APPDATA").map(PathBuf::from);
    let extensions: &[&str] = if cfg!(windows) {
        &["", ".cmd", ".exe", ".bat"]
    } else {
        &[""]
    };

    let mut candidates = Vec::new();
    for extension in extensions {
        candidates.push(home.join(".local/bin").join(format!("{name}{extension}")));
        if let Some(base) = &app_data {
            candidates.push(base.join("npm").join(format!("{name}{extension}")));
        }
    }

    if let Some(path) = candidates.into_iter().find(|candidate| candidate.is_file()) {
        return Some(path);
    }

    let locator = if cfg!(windows) { "where" } else { "which" };
    let located = Command::new(locator).arg(name).output().await.ok()?;
    if !located.status.success() {
        return None;
    }

    String::from_utf8_lossy(&located.stdout)
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(PathBuf::from)
}

fn home_dir() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
}

#[derive(Debug)]
struct ClaudeUsage {
    window: String,
    used_percent: i64,
    reset_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
struct ClaudeResponse {
    result: String,
}

#[derive(Debug, Deserialize)]
struct AgyResponse {
    command: AgyCommand,
}

#[derive(Debug, Deserialize)]
struct AgyCommand {
    data: Option<AgyData>,
}

#[derive(Debug, Deserialize)]
struct AgyData {
    groups: Vec<AgyGroup>,
}

#[derive(Debug, Deserialize)]
struct AgyGroup {
    name: String,
    buckets: Vec<AgyBucket>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct AgyBucket {
    window: String,
    remaining_fraction: f64,
    reset_time: Option<String>,
    disabled: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct CodexRpcResponse {
    result: Option<CodexRateLimitResponse>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CodexRateLimitResponse {
    rate_limits: CodexRateLimitSnapshot,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CodexRateLimitSnapshot {
    plan_type: Option<String>,
    primary: Option<CodexRateLimitWindow>,
    secondary: Option<CodexRateLimitWindow>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CodexRateLimitWindow {
    used_percent: i64,
    window_duration_mins: Option<i64>,
    resets_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GitHubUsageResponse {
    usage_items: Vec<GitHubUsageItem>,
}

#[derive(Debug, Deserialize, Clone)]
struct GitHubUsageItem {
    date: String,
    product: String,
    quantity: f64,
    sku: String,
}

#[derive(Debug, Deserialize)]
struct GrokAuthRecord {
    key: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GrokBillingResponse {
    config: GrokBillingConfig,
    history: Option<Vec<GrokBillingHistory>>,
    credit_usage_percent: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GrokBillingConfig {
    current_period: Option<GrokBillingPeriod>,
    billing_period_end: Option<String>,
    credit_usage_percent: Option<f64>,
    history: Option<Vec<GrokBillingHistory>>,
    on_demand_cap: Option<GrokAmount>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GrokBillingHistory {
    end: Option<String>,
    credit_usage_percent: Option<f64>,
    subscription_tier: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GrokBillingPeriod {
    #[serde(rename = "type")]
    r#type: Option<String>,
    end: String,
}

#[derive(Debug, Deserialize)]
struct GrokAmount {
    val: f64,
}
