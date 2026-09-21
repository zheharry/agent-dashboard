use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct QuotaService {
    pub id: Uuid,
    pub app_name: String,
    pub name: String,
    pub quota_label: String,
    pub plan: String,
    pub symbol: String,
    pub current: i64,
    pub max: i64,
    pub reset_at: DateTime<Utc>,
    pub accent_hex: String,
    pub reset_window: Option<String>,
    pub disabled_reason: Option<String>,
    pub reset_note: Option<String>,
}

impl QuotaService {
    pub fn percentage(&self) -> f64 {
        if self.max <= 0 {
            return 0.0;
        }
        (self.current as f64 / self.max as f64).clamp(0.0, 1.0)
    }

    pub fn percent_label(&self) -> String {
        if self.max <= 0 {
            return "N/A".to_string();
        }
        format!("{}%", (self.percentage() * 100.0).round() as i64)
    }

    pub fn reset_window_label(&self) -> String {
        match self.reset_window.as_deref() {
            Some("5h") | Some("5 hours") => "5 小時".to_string(),
            Some("5d") | Some("5 days") => "5 天".to_string(),
            Some("week") | Some("weekly") | Some("7d") => "每週".to_string(),
            Some("month") | Some("monthly") => "每月".to_string(),
            Some(other) => other.to_string(),
            None => String::new(),
        }
    }

    pub fn demo_services() -> Vec<Self> {
        let now = Utc::now();
        vec![
            Self {
                id: Uuid::new_v4(),
                app_name: "Claude".into(),
                name: "Claude 5h".into(),
                quota_label: "5 小時".into(),
                plan: "Pro".into(),
                symbol: "C".into(),
                current: 0,
                max: 100,
                reset_at: now + chrono::Duration::hours(29),
                accent_hex: "#D97757".into(),
                reset_window: Some("5h".into()),
                disabled_reason: None,
                reset_note: None,
            },
            Self {
                id: Uuid::new_v4(),
                app_name: "Claude".into(),
                name: "Claude weekly".into(),
                quota_label: "每週".into(),
                plan: "Pro".into(),
                symbol: "C".into(),
                current: 0,
                max: 100,
                reset_at: now + chrono::Duration::days(6),
                accent_hex: "#D97757".into(),
                reset_window: Some("week".into()),
                disabled_reason: None,
                reset_note: None,
            },
            Self {
                id: Uuid::new_v4(),
                app_name: "Codex".into(),
                name: "Codex 5h".into(),
                quota_label: "5 小時".into(),
                plan: "Plus".into(),
                symbol: "O".into(),
                current: 0,
                max: 100,
                reset_at: now + chrono::Duration::hours(8),
                accent_hex: "#10A37F".into(),
                reset_window: Some("5h".into()),
                disabled_reason: None,
                reset_note: None,
            },
            Self {
                id: Uuid::new_v4(),
                app_name: "Codex".into(),
                name: "Codex weekly".into(),
                quota_label: "每週".into(),
                plan: "Plus".into(),
                symbol: "O".into(),
                current: 0,
                max: 100,
                reset_at: now + chrono::Duration::days(6),
                accent_hex: "#10A37F".into(),
                reset_window: Some("week".into()),
                disabled_reason: None,
                reset_note: None,
            },
            Self {
                id: Uuid::new_v4(),
                app_name: "Agy Claude/GPT".into(),
                name: "Agy Claude 5h".into(),
                quota_label: "Claude/GPT · 5 小時".into(),
                plan: "Pro".into(),
                symbol: "A".into(),
                current: 0,
                max: 100,
                reset_at: now + chrono::Duration::hours(53),
                accent_hex: "#D97757".into(),
                reset_window: Some("5h".into()),
                disabled_reason: None,
                reset_note: None,
            },
            Self {
                id: Uuid::new_v4(),
                app_name: "Agy Claude/GPT".into(),
                name: "Agy Claude weekly".into(),
                quota_label: "Claude/GPT · 每週".into(),
                plan: "Pro".into(),
                symbol: "A".into(),
                current: 0,
                max: 100,
                reset_at: now + chrono::Duration::days(6),
                accent_hex: "#D97757".into(),
                reset_window: Some("week".into()),
                disabled_reason: None,
                reset_note: None,
            },
            Self {
                id: Uuid::new_v4(),
                app_name: "Agy Gemini".into(),
                name: "Agy Gemini 5h".into(),
                quota_label: "Gemini · 5 小時".into(),
                plan: "Pro".into(),
                symbol: "A".into(),
                current: 0,
                max: 100,
                reset_at: now + chrono::Duration::hours(5),
                accent_hex: "#4285F4".into(),
                reset_window: Some("5h".into()),
                disabled_reason: None,
                reset_note: None,
            },
            Self {
                id: Uuid::new_v4(),
                app_name: "Agy Gemini".into(),
                name: "Agy Gemini weekly".into(),
                quota_label: "Gemini · 每週".into(),
                plan: "Pro".into(),
                symbol: "A".into(),
                current: 0,
                max: 100,
                reset_at: now + chrono::Duration::days(6),
                accent_hex: "#4285F4".into(),
                reset_window: Some("week".into()),
                disabled_reason: None,
                reset_note: None,
            },
            Self {
                id: Uuid::new_v4(),
                app_name: "Copilot".into(),
                name: "Copilot".into(),
                quota_label: "每月 AI Credits".into(),
                plan: "Copilot Pro".into(),
                symbol: "C".into(),
                current: 0,
                max: 1_500,
                reset_at: now + chrono::Duration::days(12),
                accent_hex: "#0969DA".into(),
                reset_window: Some("month".into()),
                disabled_reason: None,
                reset_note: None,
            },
            Self {
                id: Uuid::new_v4(),
                app_name: "Grok".into(),
                name: "Grok".into(),
                quota_label: "每週 Credits".into(),
                plan: "Grok Build".into(),
                symbol: "G".into(),
                current: 0,
                max: 0,
                reset_at: now + chrono::Duration::days(7),
                accent_hex: "#6D5DFB".into(),
                reset_window: Some("week".into()),
                disabled_reason: None,
                reset_note: Some("Usage amount unavailable".into()),
            },
        ]
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DashboardState {
    pub services: Vec<QuotaService>,
    pub refresh_issues: Vec<String>,
    pub last_refresh_at: Option<DateTime<Utc>>,
    pub is_refreshing: bool,
    pub live_service_names: Vec<String>,
    pub refresh_status_text: String,
}
