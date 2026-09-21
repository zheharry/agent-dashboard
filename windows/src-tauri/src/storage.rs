use std::{fs, io, path::PathBuf};

use serde::{Deserialize, Serialize};

use crate::model::QuotaService;

pub const STORAGE_VERSION: u32 = 8;

#[derive(Debug, Clone)]
pub struct QuotaStorage {
    path: PathBuf,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoreFile {
    storage_version: u32,
    services: Vec<QuotaService>,
}

impl QuotaStorage {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn path(&self) -> &PathBuf {
        &self.path
    }

    pub fn load_services(&self) -> io::Result<Vec<QuotaService>> {
        if !self.path.exists() {
            return Ok(QuotaService::demo_services());
        }

        let contents = fs::read_to_string(&self.path)?;
        let store: StoreFile = match serde_json::from_str(&contents) {
            Ok(store) => store,
            Err(_) => return Ok(QuotaService::demo_services()),
        };

        if store.storage_version != STORAGE_VERSION {
            return Ok(QuotaService::demo_services());
        }

        Ok(store.services)
    }

    pub fn save_services(&self, services: &[QuotaService]) -> io::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }

        let payload = StoreFile {
            storage_version: STORAGE_VERSION,
            services: services.to_vec(),
        };
        let encoded = serde_json::to_string_pretty(&payload)
            .map_err(|error| io::Error::other(error.to_string()))?;
        fs::write(&self.path, encoded)
    }
}

pub fn default_store_path() -> PathBuf {
    if cfg!(windows) {
        let base = std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        return base.join("AgentQuota").join("quota-store.json");
    }

    std::env::temp_dir()
        .join("AgentQuota")
        .join("quota-store.json")
}
