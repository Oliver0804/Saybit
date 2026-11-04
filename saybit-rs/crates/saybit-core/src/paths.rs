//! 資料夾位置（三平台）。directories crate 給的是 macOS：~/Library/Application Support/com.bashcat.Saybit；Windows：%APPDATA%\\bashcat\\Saybit\\data；Linux：~/.local/share/saybit。
//! 模型目錄在 macOS 例外，見 `models_dir`。

use std::path::PathBuf;

fn project_dirs() -> directories::ProjectDirs {
    directories::ProjectDirs::from("com", "bashcat", "Saybit").expect("home directory")
}

pub fn data_dir() -> PathBuf {
    let d = project_dirs().data_dir().to_path_buf();
    let _ = std::fs::create_dir_all(&d);
    d
}

pub fn config_dir() -> PathBuf {
    let d = project_dirs().config_dir().to_path_buf();
    let _ = std::fs::create_dir_all(&d);
    d
}

pub fn settings_file() -> PathBuf {
    config_dir().join("settings.json")
}

pub fn database_file() -> PathBuf {
    data_dir().join("saybit.sqlite")
}

pub fn logs_dir() -> PathBuf {
    let d = data_dir().join("logs");
    let _ = std::fs::create_dir_all(&d);
    d
}

/// 模型目錄。macOS 與原生 Swift 版共用 `~/Library/Application Support/Saybit/SherpaModels`
/// （子目錄名稱相同，原生版已下載的 SenseVoice 模型可直接重用）；其他平台放在 data_dir/models。
pub fn models_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    let d = {
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(data_dir);
        home.join("Library/Application Support/Saybit/SherpaModels")
    };
    #[cfg(not(target_os = "macos"))]
    let d = data_dir().join("models");
    let _ = std::fs::create_dir_all(&d);
    d
}
