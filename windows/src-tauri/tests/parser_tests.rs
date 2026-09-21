use chrono::{TimeZone, Utc};
use windows_lib::live_usage::{
    extract_grok_token, parse_agy_response, parse_claude_response, parse_codex_response,
    parse_copilot_response, parse_grok_billing_response,
};

#[test]
fn parses_claude_fixture() {
    let now = Utc.with_ymd_and_hms(2026, 9, 21, 12, 0, 0).unwrap();
    let quotas = parse_claude_response(include_str!("fixtures/claude_usage.json"), now).unwrap();

    assert_eq!(quotas.len(), 2);
    assert_eq!(quotas[0].service_name, "Claude 5h");
    assert_eq!(quotas[0].current, 42);
    assert_eq!(quotas[1].service_name, "Claude weekly");
    assert_eq!(quotas[1].current, 73);
}

#[test]
fn parses_agy_fixture() {
    let quotas = parse_agy_response(include_str!("fixtures/agy_usage.json")).unwrap();

    assert_eq!(quotas.len(), 3);
    assert!(quotas.iter().any(|quota| quota.service_name == "Agy Claude 5h" && quota.current == 42));
    assert!(quotas.iter().any(|quota| quota.service_name == "Agy Claude weekly" && quota.disabled_reason.as_deref() == Some("Weekly limit reached")));
    assert!(quotas.iter().any(|quota| quota.service_name == "Agy Gemini weekly" && quota.current == 36));
}

#[test]
fn parses_codex_fixture() {
    let quotas = parse_codex_response(include_str!("fixtures/codex_response.jsonl")).unwrap();

    assert_eq!(quotas.len(), 2);
    assert_eq!(quotas[0].service_name, "Codex 5h");
    assert_eq!(quotas[0].plan.as_deref(), Some("Plus"));
    assert_eq!(quotas[1].service_name, "Codex weekly");
}

#[test]
fn parses_copilot_fixture() {
    let now = Utc.with_ymd_and_hms(2026, 9, 21, 12, 0, 0).unwrap();
    let quota = parse_copilot_response(include_str!("fixtures/copilot_usage.json"), now).unwrap();

    assert_eq!(quota.service_name, "Copilot");
    assert_eq!(quota.current, 99);
    assert_eq!(quota.max, 1_500);
}

#[test]
fn parses_grok_fixture() {
    let token = extract_grok_token(include_str!("fixtures/grok_auth.json")).unwrap();
    let quota = parse_grok_billing_response(include_str!("fixtures/grok_billing.json")).unwrap();

    assert_eq!(token, "token-123");
    assert_eq!(quota.service_name, "Grok");
    assert_eq!(quota.current, 35);
    assert_eq!(quota.plan.as_deref(), Some("SuperGrok Plus"));
    assert_eq!(quota.reset_window.as_deref(), Some("weekly"));
}
