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
fn parses_claude_alternative_windows_report_lines() {
    let now = Utc.with_ymd_and_hms(2026, 9, 21, 12, 0, 0).unwrap();
    let payload = r#"{
      "content": "5-hour usage: 18% · resets Sep 22 at 4pm (UTC)\nWeekly usage: 63% · reset Sep 27 at 11:30pm (UTC)"
    }"#;
    let quotas = parse_claude_response(payload, now).unwrap();

    assert_eq!(quotas.len(), 2);
    assert!(quotas.iter().any(|quota| quota.service_name == "Claude 5h" && quota.current == 18));
    assert!(quotas.iter().any(|quota| quota.service_name == "Claude weekly" && quota.current == 63));
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
fn parses_agy_usage_without_remaining_fraction() {
    let payload = r#"{
      "command": {
        "data": {
          "groups": [
            {
              "name": "Claude / GPT",
              "buckets": [
                {
                  "window": "5h",
                  "usedPercent": 28,
                  "resetTime": "2026-09-21T18:00:00Z"
                }
              ]
            }
          ]
        }
      }
    }"#;

    let quotas = parse_agy_response(payload).unwrap();
    assert_eq!(quotas.len(), 1);
    assert_eq!(quotas[0].service_name, "Agy Claude 5h");
    assert_eq!(quotas[0].current, 28);
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
