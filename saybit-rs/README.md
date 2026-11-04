# Saybit（Rust / egui 版）

跨平台（macOS / Windows / Linux）的 Saybit：系統匣常駐、全域快捷鍵錄音、LLM 整理後輸入到目前的 App。
與 `../speakertpyer/`（原生 macOS）、`../saybit-desktop/`（Tauri）沒有共用程式碼。

## 建置與執行

```bash
cd saybit-rs
cargo run -p saybit-app            # debug
cargo build --release -p saybit-app
cargo test --workspace
SAYBIT_SMOKE=1 cargo run -p saybit-app   # 只開視窗 30 秒：不建系統匣/快捷鍵、不錄音、不讀寫設定
```

Linux 需要：`libasound2-dev libxdo-dev libxkbcommon-dev libxcb1-dev libdbus-1-dev libgtk-3-dev cmake clang`，
中文字型建議裝 `fonts-noto-cjk`。全域快捷鍵只支援 X11。

打包：`cargo install cargo-packager`，再 `cargo packager --release --config packaging/Packager.toml`
（CI：推 `rs-v*` tag 觸發 `.github/workflows/release-rs.yml`）。

## 資料夾

| | 設定 `settings.json` | 資料（歷史 DB、日誌 `logs/`、模型 `models/`） |
|---|---|---|
| macOS | `~/Library/Application Support/com.bashcat.Saybit/` | 同左 |
| Windows | `%APPDATA%\bashcat\Saybit\config\` | `%APPDATA%\bashcat\Saybit\data\` |
| Linux | `~/.config/saybit/` | `~/.local/share/saybit/` |

（實際路徑以 `crates/saybit-core/src/paths.rs` 為準。macOS 的模型目錄例外：共用原生 Swift 版的
`~/Library/Application Support/Saybit/SherpaModels/`，已下載的 SenseVoice 模型兩邊都能用。）
