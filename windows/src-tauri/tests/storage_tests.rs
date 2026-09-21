use std::fs;

use windows_lib::{model::QuotaService, storage::{QuotaStorage, STORAGE_VERSION}};

#[test]
fn storage_round_trips_services() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("quota-store.json");
    let storage = QuotaStorage::new(path);
    let services = QuotaService::demo_services();

    storage.save_services(&services).unwrap();
    let loaded = storage.load_services().unwrap();

    assert_eq!(loaded, services);
}

#[test]
fn storage_version_mismatch_resets_to_demo_data() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("quota-store.json");
    let storage = QuotaStorage::new(path.clone());

    fs::write(
        &path,
        format!(
            "{{\"storageVersion\":{},\"services\":[]}}",
            STORAGE_VERSION - 1
        ),
    )
    .unwrap();

    let loaded = storage.load_services().unwrap();
    assert_eq!(loaded.len(), QuotaService::demo_services().len());
}
