pub mod model;
pub mod live_usage;
pub mod storage;

use std::{collections::HashSet, sync::Arc, time::Duration};

use chrono::{DateTime, Local, Utc};
use model::{DashboardState, QuotaService};
use tauri::{
    menu::MenuBuilder,
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, State,
};
use tauri_plugin_positioner::{Position, WindowExt};
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::{live_usage::LiveUsageResult, storage::QuotaStorage};

#[derive(Clone)]
struct AppState {
    store: Arc<Mutex<QuotaStore>>,
}

struct QuotaStore {
    storage: QuotaStorage,
    services: Vec<QuotaService>,
    refresh_issues: Vec<String>,
    last_refresh_at: Option<DateTime<Utc>>,
    live_service_keys: HashSet<String>,
    is_refreshing: bool,
}

impl AppState {
    fn new(storage: QuotaStorage) -> Result<Self, String> {
        let services = storage
            .load_services()
            .map_err(|error| format!("failed to load quota store: {error}"))?;
        Ok(Self {
            store: Arc::new(Mutex::new(QuotaStore {
                storage,
                services,
                refresh_issues: Vec::new(),
                last_refresh_at: None,
                live_service_keys: HashSet::new(),
                is_refreshing: false,
            })),
        })
    }
}

impl QuotaStore {
    fn snapshot(&self) -> DashboardState {
        DashboardState {
            services: self.active_services(),
            refresh_issues: self.refresh_issues.clone(),
            last_refresh_at: self.last_refresh_at,
            is_refreshing: self.is_refreshing,
            live_service_names: self.live_service_keys.iter().cloned().collect(),
            refresh_status_text: self.refresh_status_text(),
        }
    }

    fn refresh_status_text(&self) -> String {
        if self.is_refreshing {
            return "同步中…".into();
        }
        if let Some(last_refresh_at) = self.last_refresh_at {
            let synced_text = if self.live_service_keys.is_empty() {
                "尚未取得 live data".to_string()
            } else {
                format!("已同步 {} 個服務", self.live_service_keys.len())
            };
            return format!("{synced_text} · {}", last_refresh_at.with_timezone(&Local).format("%H:%M"));
        }
        "尚未同步".into()
    }

    fn active_services(&self) -> Vec<QuotaService> {
        let live_apps: HashSet<String> = self
            .services
            .iter()
            .filter_map(|service| {
                self.live_service_keys
                    .contains(&service.provider_key())
                    .then(|| service.app_name.clone())
            })
            .collect();
        self.services
            .iter()
            .filter(|service| {
                !live_apps.contains(&service.app_name)
                    || self.live_service_keys.contains(&service.provider_key())
            })
            .cloned()
            .collect()
    }

    fn persist(&self) -> Result<(), String> {
        self.storage
            .save_services(&self.services)
            .map_err(|error| format!("failed to save quota store: {error}"))
    }

    fn upsert(&mut self, service: QuotaService) -> Result<(), String> {
        if let Some(index) = self.services.iter().position(|candidate| candidate.id == service.id) {
            self.services[index] = service;
        } else {
            self.services.push(service);
        }
        self.persist()
    }

    fn delete(&mut self, id: Uuid) -> Result<(), String> {
        self.services.retain(|service| service.id != id);
        self.live_service_keys
            .retain(|service_key| self.services.iter().any(|service| service.provider_key() == *service_key));
        self.persist()
    }

    fn reset_demo_data(&mut self) -> Result<(), String> {
        self.services = QuotaService::demo_services();
        self.refresh_issues.clear();
        self.last_refresh_at = None;
        self.live_service_keys.clear();
        self.persist()
    }

    fn apply_live_result(&mut self, result: LiveUsageResult) -> Result<(), String> {
        for service in self
            .services
            .iter()
            .filter(|service| result.refreshed_apps.iter().any(|app| service.app_name.eq_ignore_ascii_case(app)))
        {
            self.live_service_keys.remove(&service.provider_key());
        }

        for update in result.updates {
            if let Some(index) = self
                .services
                .iter()
                .position(|service| {
                    service.app_name.eq_ignore_ascii_case(&update.app_name)
                        && service
                            .reset_window
                            .as_deref()
                            .unwrap_or_default()
                            .eq_ignore_ascii_case(update.reset_window.as_deref().unwrap_or_default())
                })
            {
                let service = &mut self.services[index];
                service.current = update.current;
                service.max = update.max;
                service.reset_at = update.reset_at;
                if let Some(plan) = update.plan {
                    service.plan = plan;
                }
                if let Some(reset_window) = update.reset_window {
                    service.reset_window = Some(reset_window);
                }
                service.disabled_reason = update.disabled_reason;
                service.reset_note = update.reset_note;
                self.live_service_keys.insert(service.provider_key());
            }
        }

        self.refresh_issues = result.issues;
        self.last_refresh_at = Some(Utc::now());
        self.is_refreshing = false;
        self.persist()
    }
}

#[tauri::command]
async fn get_services(state: State<'_, AppState>) -> Result<DashboardState, String> {
    Ok(state.store.lock().await.snapshot())
}

#[tauri::command]
async fn upsert_service(state: State<'_, AppState>, service: QuotaService) -> Result<DashboardState, String> {
    let mut store = state.store.lock().await;
    store.upsert(service)?;
    Ok(store.snapshot())
}

#[tauri::command]
async fn delete_service(state: State<'_, AppState>, id: String) -> Result<DashboardState, String> {
    let id = Uuid::parse_str(&id).map_err(|error| format!("invalid service id: {error}"))?;
    let mut store = state.store.lock().await;
    store.delete(id)?;
    Ok(store.snapshot())
}

#[tauri::command]
async fn reset_demo_data(state: State<'_, AppState>) -> Result<DashboardState, String> {
    let mut store = state.store.lock().await;
    store.reset_demo_data()?;
    Ok(store.snapshot())
}

#[tauri::command]
async fn refresh_live_data(app: AppHandle, state: State<'_, AppState>) -> Result<DashboardState, String> {
    refresh_and_emit(&app, state.inner().clone()).await
}

async fn refresh_and_emit(app: &AppHandle, state: AppState) -> Result<DashboardState, String> {
    {
        let mut store = state.store.lock().await;
        if store.is_refreshing {
            return Ok(store.snapshot());
        }
        store.is_refreshing = true;
        let snapshot = store.snapshot();
        let _ = app.emit("quota-state", &snapshot);
    }

    let result = live_usage::fetch_all().await;

    let snapshot = {
        let mut store = state.store.lock().await;
        store.apply_live_result(result)?;
        store.snapshot()
    };

    let _ = app.emit("quota-state", &snapshot);
    Ok(snapshot)
}

fn toggle_main_window(app: &AppHandle) -> tauri::Result<()> {
    let window = app
        .get_webview_window("main")
        .ok_or_else(|| tauri::Error::Io(std::io::Error::other("main window missing")))?;

    if window.is_visible()? {
        window.hide()?;
        return Ok(());
    }

    let _ = window.move_window_constrained(Position::TrayCenter);
    window.show()?;
    window.set_focus()?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_positioner::init())
        .setup(|app| {
            let main_window = app
                .get_webview_window("main")
                .ok_or_else(|| tauri::Error::Io(std::io::Error::other("main window missing")))?;
            main_window.hide()?;

            let state = AppState::new(QuotaStorage::new(storage::default_store_path()))
                .map_err(std::io::Error::other)
                .map_err(tauri::Error::Io)?;
            app.manage(state.clone());

            let menu = MenuBuilder::new(app).build()?;
            let icon = app
                .default_window_icon()
                .cloned()
                .ok_or_else(|| tauri::Error::Io(std::io::Error::other("tray icon missing")))?;

            TrayIconBuilder::with_id("agent-quota")
                .icon(icon)
                .menu(&menu)
                .tooltip("AgentQuota")
                .show_menu_on_left_click(false)
                .on_tray_icon_event(|tray, event| {
                    tauri_plugin_positioner::on_tray_event(tray.app_handle(), &event);
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let _ = toggle_main_window(tray.app_handle());
                    }
                })
                .build(app)?;

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let _ = refresh_and_emit(&handle, state.clone()).await;
                let mut interval = tokio::time::interval(Duration::from_secs(120));
                interval.tick().await;
                loop {
                    interval.tick().await;
                    let _ = refresh_and_emit(&handle, state.clone()).await;
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_services,
            upsert_service,
            delete_service,
            reset_demo_data,
            refresh_live_data
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
