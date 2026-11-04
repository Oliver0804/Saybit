// Saybit Desktop Rust Core
mod apple_speech;
mod audio_duck;
mod eventkit;
mod file_transcribe;
mod injection;
mod local_stt;
mod platform;
mod secure_store;
mod sherpa_stt;
mod streaming_stt;

use tauri::{AppHandle, Emitter, Manager};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use tauri_plugin_deep_link::DeepLinkExt;
use enigo::{Enigo, Keyboard, Settings, Key, Direction};
use std::collections::{HashMap, HashSet};
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

fn log_startup(app: &AppHandle, msg: &str) {
    if let Ok(dir) = app.path().app_data_dir() {
        let _ = std::fs::create_dir_all(&dir);
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(dir.join("startup.log")) {
            let _ = writeln!(f, "[{}] {}", chrono_like_ts(), msg);
        }
    }
}

fn chrono_like_ts() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs().to_string()).unwrap_or_else(|_| "?".into())
}

fn build_tray(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let tray_menu = Menu::with_items(app, &[
        &MenuItem::with_id(app, "show_settings", "設定 (Settings)", true, None::<&str>)?,
        &MenuItem::with_id(app, "quit", "結束 (Quit)", true, None::<&str>)?,
    ])?;

    let icon = app.default_window_icon()
        .ok_or("default_window_icon not available")?
        .clone();

    // id "main"：前端用 TrayIcon.getById('main') 換成完整選單（錄音、語音模式…）；
    // 這份只有兩項的選單是前端還沒載入／失敗時的後備。前端選單沿用
    // show_settings / quit 這兩個 id 時，下面的處理照樣生效。
    let _tray = TrayIconBuilder::with_id("main")
        .icon(icon)
        .menu(&tray_menu)
        .on_menu_event(|app, event| {
            match event.id.as_ref() {
                "show_settings" => {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
                "quit" => app.exit(0),
                _ => {}
            }
        })
        .build(app)?;

    Ok(())
}

// enigo 在 macOS 會呼叫 Text Input Source API（TSM/HIToolbox），這些 API 斷言
// 必須在主執行緒執行。Tauri command 預設跑在 tokio worker 執行緒，直接呼叫會
// 觸發 dispatch_assert_queue 崩潰，因此一律用 run_on_main_thread 派到主執行緒。
#[tauri::command]
fn simulate_paste(app: AppHandle) -> Result<(), String> {
    app.run_on_main_thread(|| {
        if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
            #[cfg(target_os = "macos")]
            let modifier = Key::Meta;
            #[cfg(not(target_os = "macos"))]
            let modifier = Key::Control;
            let _ = enigo.key(modifier, Direction::Press);
            let _ = enigo.key(Key::Unicode('v'), Direction::Click);
            let _ = enigo.key(modifier, Direction::Release);
        }
    })
    .map_err(|e| e.to_string())
}

/// Smart Send 的 Enter。有給 expected_bundle_id 時先比對前景 App，
/// 換了就回 Err("foreground-changed")、不送任何按鍵（避免在別的 App 按下送出）。
#[tauri::command(async)]
fn simulate_enter(app: AppHandle, expected_bundle_id: Option<String>) -> Result<(), String> {
    platform::ensure_foreground(&app, expected_bundle_id.as_deref())?;
    app.run_on_main_thread(|| {
        if let Ok(mut enigo) = Enigo::new(&Settings::default()) {
            let _ = enigo.key(Key::Return, Direction::Click);
        }
    })
    .map_err(|e| e.to_string())
}

#[tauri::command]
fn apply_vibrancy(app: AppHandle, label: String) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(&label) {
        #[cfg(target_os = "windows")]
        {
            window_vibrancy::apply_acrylic(&window, Some((0, 0, 0, 0)))
                .map_err(|e| e.to_string())?;
        }
        #[cfg(target_os = "macos")]
        {
            use window_vibrancy::{NSVisualEffectMaterial, NSVisualEffectState};
            window_vibrancy::apply_vibrancy(
                &window,
                NSVisualEffectMaterial::HudWindow,
                Some(NSVisualEffectState::Active),
                None
            ).map_err(|e| e.to_string())?;
        }
        #[cfg(target_os = "linux")]
        {
            let _ = &window; // Linux 不支援原生磨砂玻璃
        }
    }
    Ok(())
}

#[tauri::command]
fn show_window(app: AppHandle, label: String) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(&label) {
        window.show().map_err(|e| e.to_string())?;
        // 膠囊絕不能搶焦點：一旦 Saybit 變成前景 App，後續 Cmd+V 會貼進膠囊自己，
        // 而且前景 App 查詢也只會查到 Saybit。原生版是用 nonactivatingPanel 達成
        // 同樣效果。設定視窗則維持照常聚焦。
        if label != "overlay" {
            window.set_focus().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[tauri::command]
fn hide_window(app: AppHandle, label: String) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(&label) {
        window.hide().map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// sensitive=true（轉錄內容、LLM 結果等）只記長度，不把內容落地到日誌檔。
fn mask_log_message(msg: &str, sensitive: bool) -> String {
    if sensitive {
        format!("[內容已遮罩, {} 字]", msg.chars().count())
    } else {
        msg.to_string()
    }
}

#[tauri::command]
fn frontend_log(app: AppHandle, msg: String, sensitive: Option<bool>) {
    let line = mask_log_message(&msg, sensitive.unwrap_or(false));
    if let Ok(dir) = app.path().app_data_dir() {
        let _ = std::fs::create_dir_all(&dir);
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(dir.join("frontend.log")) {
            let _ = writeln!(f, "[{}] {}", chrono_like_ts(), line);
        }
    }
}

/// 讀取日誌檔尾端內容供設定畫面顯示。kind 只接受固定的兩個值，
/// 不讓前端傳任意路徑進來。
#[tauri::command]
fn read_log(app: AppHandle, kind: String, max_lines: Option<usize>) -> Result<String, String> {
    let filename = match kind.as_str() {
        "frontend" => "frontend.log",
        "startup" => "startup.log",
        _ => return Err(format!("未知的日誌類型：{kind}")),
    };
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let path = dir.join(filename);
    if !path.exists() {
        return Ok(String::new());
    }
    let content = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let limit = max_lines.unwrap_or(500);
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(limit);
    Ok(lines[start..].join("\n"))
}

#[tauri::command]
fn clear_log(app: AppHandle, kind: String) -> Result<(), String> {
    let filename = match kind.as_str() {
        "frontend" => "frontend.log",
        "startup" => "startup.log",
        _ => return Err(format!("未知的日誌類型：{kind}")),
    };
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let path = dir.join(filename);
    if path.exists() {
        std::fs::write(&path, "").map_err(|e| e.to_string())?;
    }
    Ok(())
}

// ---------------------------------------------------------------- 全域快捷鍵

/// 主快捷鍵的 binding id；其他 id 是 voiceMode.id
const MAIN_HOTKEY_ID: &str = "main";

#[derive(serde::Deserialize, Clone, Debug)]
struct HotkeyBinding {
    id: String,
    shortcut: String,
}

#[derive(serde::Serialize, Clone, Debug)]
struct HotkeyEventPayload {
    id: String,
}

/// 目前註冊的快捷鍵（Shortcut::id → binding id）與「按住中」集合。
/// 按住不放時 OS 會重複送 Pressed（auto-repeat），用 pressed 集合只放行第一次。
#[derive(Default)]
struct HotkeyState {
    ids: HashMap<u32, String>,
    pressed: HashSet<u32>,
}

fn hotkey_state() -> &'static Mutex<HotkeyState> {
    static STATE: OnceLock<Mutex<HotkeyState>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(HotkeyState::default()))
}

#[derive(Debug, Default)]
struct HotkeyPlan {
    accepted: Vec<(String, Shortcut)>,
    /// 被略過的組合（與主快捷鍵或前面的模式重複）——只記 log，不算錯誤
    skipped: Vec<String>,
    /// 解析失敗
    errors: Vec<String>,
}

/// 決定要註冊哪些組合：主快捷鍵優先，同一組合只註冊一次。
fn plan_hotkeys(bindings: &[HotkeyBinding]) -> HotkeyPlan {
    let mut plan = HotkeyPlan::default();
    let mut ordered: Vec<&HotkeyBinding> = bindings.iter().filter(|b| b.id == MAIN_HOTKEY_ID).collect();
    ordered.extend(bindings.iter().filter(|b| b.id != MAIN_HOTKEY_ID));

    let mut owner: HashMap<u32, String> = HashMap::new();
    for b in ordered {
        let raw = b.shortcut.trim();
        if raw.is_empty() {
            continue;
        }
        let parsed: Shortcut = match raw.parse() {
            Ok(s) => s,
            Err(e) => {
                plan.errors.push(format!("{}: 無法解析快捷鍵 {raw}（{e:?}）", b.id));
                continue;
            }
        };
        if let Some(existing) = owner.get(&parsed.id()) {
            let reason = if existing == MAIN_HOTKEY_ID { "與主快捷鍵相同" } else { "與其他模式重複" };
            plan.skipped.push(format!("{}: {raw} {reason}（已被 {existing} 使用），略過", b.id));
            continue;
        }
        owner.insert(parsed.id(), b.id.clone());
        plan.accepted.push((b.id.clone(), parsed));
    }
    plan
}

fn apply_hotkeys(app: &AppHandle, bindings: &[HotkeyBinding]) -> Result<(), String> {
    let plan = plan_hotkeys(bindings);
    for msg in &plan.skipped {
        log_startup(app, &format!("hotkey: {msg}"));
    }

    // 先全部 unregister 再重註冊：重複呼叫（設定變更）時同一組合不會註冊兩次而失敗
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    {
        let mut state = hotkey_state().lock().unwrap_or_else(|e| e.into_inner());
        state.ids = plan.accepted.iter().map(|(id, s)| (s.id(), id.clone())).collect();
        state.pressed.clear();
    }

    let mut errors = plan.errors;
    for (id, shortcut) in plan.accepted {
        if let Err(e) = gs.register(shortcut) {
            hotkey_state()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .ids
                .remove(&shortcut.id());
            errors.push(format!("{id}: 註冊失敗（{e}）"));
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        let joined = errors.join("; ");
        log_startup(app, &format!("hotkey: {joined}"));
        Err(joined)
    }
}

/// 一次設定所有全域快捷鍵。id "main" 是主快捷鍵，其他是語音模式 id。
/// 事件 hotkey-pressed / hotkey-released 的 payload 為 { id }。
#[tauri::command]
fn set_hotkeys(app: AppHandle, bindings: Vec<HotkeyBinding>) -> Result<(), String> {
    apply_hotkeys(&app, &bindings)
}

/// 相容舊前端：等同 set_hotkeys([{ id: "main", shortcut }])，會清掉模式快捷鍵。
#[tauri::command]
fn set_hotkey(app: AppHandle, shortcut: String) -> Result<(), String> {
    apply_hotkeys(&app, &[HotkeyBinding { id: MAIN_HOTKEY_ID.into(), shortcut }])
}

fn handle_shortcut_event(app: &AppHandle, shortcut: &Shortcut, state: ShortcutState) {
    let key = shortcut.id();
    let (event, id) = {
        let mut hs = hotkey_state().lock().unwrap_or_else(|e| e.into_inner());
        let Some(id) = hs.ids.get(&key).cloned() else { return };
        match state {
            ShortcutState::Pressed => {
                if !hs.pressed.insert(key) {
                    return; // auto-repeat
                }
                ("hotkey-pressed", id)
            }
            ShortcutState::Released => {
                hs.pressed.remove(&key);
                ("hotkey-released", id)
            }
        }
    };
    let _ = app.emit(event, HotkeyEventPayload { id });
}

// ---------------------------------------------------------------- saybit:// URL scheme

const URL_COMMANDS: [&str; 5] = ["toggle", "start", "stop", "cancel", "settings"];
const URL_DEDUP_WINDOW: Duration = Duration::from_secs(1);
/// 冷啟動帶進來的 URL：webview 的 listen() 還沒掛上，事件會掉。啟動後這段時間內
/// 收到的指令先排進佇列由前端 take_pending_url_commands 取走；沒取走的到時才 emit。
const URL_COLD_START_GRACE: Duration = Duration::from_secs(3);

#[derive(serde::Serialize, Clone, Debug, PartialEq)]
struct UrlCommand {
    command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tab: Option<String>,
}

/// `saybit://toggle|start|stop|cancel|settings[?mode=Name][&tab=…]`，
/// 指令放 host 或 path 都接受（`saybit:toggle`、`saybit:///toggle`）。
fn parse_url_command(raw: &str) -> Option<UrlCommand> {
    let url = tauri::Url::parse(raw.trim()).ok()?;
    if !url.scheme().eq_ignore_ascii_case("saybit") {
        return None;
    }
    let host = url.host_str().unwrap_or("");
    let command = if host.is_empty() {
        url.path().trim_matches('/').split('/').next().unwrap_or("").to_string()
    } else {
        host.to_string()
    }
    .to_ascii_lowercase();
    if !URL_COMMANDS.contains(&command.as_str()) {
        return None;
    }
    let query = |name: &str| {
        url.query_pairs()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.trim().to_string())
            .filter(|v| !v.is_empty())
    };
    Some(UrlCommand { command, mode: query("mode"), tab: query("tab") })
}

/// 同一 URL 在 1 秒內重複就丟棄（launcher 重送、macOS 冷啟動 get_current 與 Opened 事件各送一次）。
#[derive(Default)]
struct UrlDeduper {
    last: HashMap<String, Instant>,
}

impl UrlDeduper {
    fn accept(&mut self, key: &str, now: Instant) -> bool {
        self.last.retain(|_, t| now.duration_since(*t) < Duration::from_secs(10));
        if let Some(t) = self.last.get(key) {
            if now.duration_since(*t) < URL_DEDUP_WINDOW {
                return false;
            }
        }
        self.last.insert(key.to_string(), now);
        true
    }
}

fn url_deduper() -> &'static Mutex<UrlDeduper> {
    static D: OnceLock<Mutex<UrlDeduper>> = OnceLock::new();
    D.get_or_init(|| Mutex::new(UrlDeduper::default()))
}

fn app_started_at() -> Instant {
    static T: OnceLock<Instant> = OnceLock::new();
    *T.get_or_init(Instant::now)
}

fn handle_deep_links(app: &AppHandle, urls: Vec<tauri::Url>) {
    for url in urls {
        let raw = url.as_str().to_string();
        let accepted = url_deduper()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .accept(&raw.to_ascii_lowercase(), Instant::now());
        let Some(cmd) = parse_url_command(&raw) else {
            log_startup(app, "deep link: 不支援的指令，忽略");
            continue;
        };
        if !accepted {
            log_startup(app, &format!("deep link: {} 1 秒內重複，丟棄", cmd.command));
            continue;
        }
        log_startup(
            app,
            &format!(
                "deep link: {}{}",
                cmd.command,
                cmd.mode.as_deref().map(|m| format!(" mode={m}")).unwrap_or_default()
            ),
        );
        let wait = URL_COLD_START_GRACE.saturating_sub(app_started_at().elapsed());
        if cmd.command == "settings" {
            // 設定視窗先帶到前景，前端掛好 listener 後再取走指令
            let _ = show_window(app.clone(), "main".into());
        }
        let (direct, schedule_fallback) = {
            let mut q = pending_urls().lock().unwrap_or_else(|e| e.into_inner());
            let direct = q.offer(cmd, !wait.is_zero());
            let schedule = direct.is_none() && !q.fallback_scheduled;
            if schedule {
                q.fallback_scheduled = true;
            }
            (direct, schedule)
        };
        if let Some(cmd) = direct {
            dispatch_url_command(app, cmd);
        }
        if schedule_fallback {
            // 前端沒在寬限期內取走（舊前端、webview 載入失敗）→ 照舊直接 emit 剩下的
            let app = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(wait);
                let rest = pending_urls().lock().unwrap_or_else(|e| e.into_inner()).drain_remaining();
                for cmd in rest {
                    log_startup(&app, &format!("deep link: {} 未被前端取走，寬限期後直接送出", cmd.command));
                    dispatch_url_command(&app, cmd);
                }
            });
        }
    }
}

fn url_target(cmd: &UrlCommand) -> &'static str {
    if cmd.command == "settings" { "main" } else { "overlay" }
}

/// 冷啟動收到、還沒被前端取走的 URL 指令。main 取 settings，overlay 取其他；
/// 某個視窗取過一次之後，送給它的指令就直接 emit。
#[derive(Default)]
struct PendingUrlQueue {
    items: Vec<UrlCommand>,
    taken: HashSet<&'static str>,
    fallback_scheduled: bool,
}

impl PendingUrlQueue {
    /// 回傳 Some 代表要立刻送出；None 代表已排進佇列等前端取走。
    fn offer(&mut self, cmd: UrlCommand, in_grace: bool) -> Option<UrlCommand> {
        if in_grace && !self.taken.contains(url_target(&cmd)) {
            self.items.push(cmd);
            None
        } else {
            Some(cmd)
        }
    }

    fn take(&mut self, label: &str) -> Vec<UrlCommand> {
        let target = match label {
            "main" => "main",
            "overlay" => "overlay",
            _ => return Vec::new(),
        };
        self.taken.insert(target);
        let (mine, rest): (Vec<_>, Vec<_>) =
            std::mem::take(&mut self.items).into_iter().partition(|c| url_target(c) == target);
        self.items = rest;
        mine
    }

    fn drain_remaining(&mut self) -> Vec<UrlCommand> {
        std::mem::take(&mut self.items)
    }
}

fn pending_urls() -> &'static Mutex<PendingUrlQueue> {
    static Q: OnceLock<Mutex<PendingUrlQueue>> = OnceLock::new();
    Q.get_or_init(|| Mutex::new(PendingUrlQueue::default()))
}

/// 前端在 url-command listener 掛好後呼叫一次，取走冷啟動時收到的指令（取走即清空）。
/// main 視窗拿到 settings 指令，overlay 拿到其他指令。overlay 取到指令時若 Saybit
/// 是前景（macOS），會先把焦點還給最近的外部 App 再回傳。
#[tauri::command(async)]
fn take_pending_url_commands(app: AppHandle, window: tauri::WebviewWindow) -> Vec<UrlCommand> {
    let label = window.label().to_string();
    let taken = pending_urls().lock().unwrap_or_else(|e| e.into_inner()).take(&label);
    if label == "overlay" && !taken.is_empty() {
        platform::refocus_external_before_command(&app);
    }
    taken
}

fn dispatch_url_command(app: &AppHandle, cmd: UrlCommand) {
    if cmd.command == "settings" {
        let _ = app.emit_to("main", "url-command", cmd);
        let _ = show_window(app.clone(), "main".into());
    } else {
        // 開 URL 會把 Saybit 帶到前景：先把焦點還給原本的 App（macOS，等 250 ms），
        // 否則後續注入會貼進 Saybit 自己。不在呼叫端執行緒（可能是主執行緒）等待。
        let app = app.clone();
        std::thread::spawn(move || {
            platform::refocus_external_before_command(&app);
            let _ = app.emit_to("overlay", "url-command", cmd);
        });
    }
}

// ---------------------------------------------------------------- 存檔

#[derive(serde::Deserialize, Clone, Debug)]
struct SaveFilter {
    name: String,
    extensions: Vec<String>,
}

/// 使用者在存檔對話框選過的路徑。write_text_file 只接受這裡面的路徑，
/// 前端（或被注入的腳本）不能指定任意路徑寫檔。
fn save_allowlist() -> &'static Mutex<HashSet<std::path::PathBuf>> {
    static S: OnceLock<Mutex<HashSet<std::path::PathBuf>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashSet::new()))
}

/// 開系統存檔對話框，回傳選到的路徑（取消回 None），並把它加入可寫入清單。
/// 注意：前端直接用 @tauri-apps/plugin-dialog 的 save() 選到的路徑不會進清單
/// （plugin 只會放行 fs / asset scope，本 App 兩者都沒有），要寫檔請走這個命令。
#[tauri::command(async)]
fn save_text_file_dialog(
    app: AppHandle,
    default_name: Option<String>,
    filters: Option<Vec<SaveFilter>>,
) -> Option<String> {
    use tauri_plugin_dialog::DialogExt;
    let mut builder = app.dialog().file();
    if let Some(name) = default_name.filter(|n| !n.trim().is_empty()) {
        builder = builder.set_file_name(name);
    }
    for f in filters.unwrap_or_default() {
        let exts: Vec<&str> = f.extensions.iter().map(String::as_str).collect();
        builder = builder.add_filter(f.name, &exts);
    }
    let path = builder.blocking_save_file()?.into_path().ok()?;
    save_allowlist()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(path.clone());
    Some(path.to_string_lossy().into_owned())
}

fn is_save_path_allowed(allowed: &HashSet<std::path::PathBuf>, path: &std::path::Path) -> bool {
    allowed.contains(path)
}

/// 把文字寫到 save_text_file_dialog 選出的路徑（UTF-8，覆寫）。其他路徑一律拒絕。
#[tauri::command(async)]
fn write_text_file(path: String, content: String) -> Result<(), String> {
    let p = std::path::PathBuf::from(&path);
    let allowed = is_save_path_allowed(
        &save_allowlist().lock().unwrap_or_else(|e| e.into_inner()),
        &p,
    );
    if !allowed {
        return Err("path-not-allowed".into());
    }
    std::fs::write(&p, content).map_err(|e| e.to_string())
}

#[tauri::command]
fn show_overlay_menu(app: AppHandle) -> Result<(), String> {
    let overlay = app.get_webview_window("overlay").ok_or("overlay window not found")?;
    let menu = Menu::with_items(&app, &[
        &MenuItem::with_id(&app, "ov_open_settings", "設定 Settings", true, None::<&str>)
            .map_err(|e| e.to_string())?,
        &PredefinedMenuItem::separator(&app).map_err(|e| e.to_string())?,
        &MenuItem::with_id(&app, "ov_hide", "隱藏膠囊", true, None::<&str>)
            .map_err(|e| e.to_string())?,
        &MenuItem::with_id(&app, "ov_quit", "結束 Saybit", true, None::<&str>)
            .map_err(|e| e.to_string())?,
    ]).map_err(|e| e.to_string())?;
    overlay.popup_menu(&menu).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // 把 whisper.cpp / GGML 的 C 層 log 導向 Rust log crate；未啟用 log backend
    // 時等同關閉，避免每次轉錄在 stdout 噴大量 token 級除錯訊息。
    whisper_rs::install_logging_hooks();
    let _ = app_started_at();

    tauri::Builder::default()
        // single-instance 必須最先註冊：Windows/Linux 開 saybit:// 會啟動第二個程序，
        // 由它把 argv 轉給已開的實例（deep-link feature 會觸發 on_open_url）後結束。
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            let has_url = argv.iter().any(|a| a.to_ascii_lowercase().starts_with("saybit:"));
            if !has_url {
                // 使用者再次手動開 App：把設定視窗帶到前景
                let _ = show_window(app.clone(), "main".into());
            }
        }))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    // 按下與放開都要送出：hold（按住說話）與 doubleTap 觸發模式需要
                    // 完整的 press/release 時序，前端狀態機才判斷得出來。
                    // toggle 模式也是在前端由 hotkey-pressed 推動。payload { id }。
                    handle_shortcut_event(app, shortcut, event.state());
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            simulate_paste,
            simulate_enter,
            apply_vibrancy,
            show_window,
            hide_window,
            set_hotkey,
            set_hotkeys,
            take_pending_url_commands,
            platform::last_external_app,
            show_overlay_menu,
            save_text_file_dialog,
            write_text_file,
            frontend_log,
            read_log,
            clear_log,
            platform::foreground_app,
            platform::get_selected_text,
            injection::inject_text,
            injection::cancel_typing,
            apple_speech::apple_speech_supported,
            apple_speech::apple_speech_authorized,
            apple_speech::apple_speech_authorize,
            apple_speech::transcribe_apple,
            eventkit::action_intents_supported,
            eventkit::create_calendar_event,
            eventkit::create_reminder,
            streaming_stt::streaming_stt_start,
            streaming_stt::streaming_stt_push,
            streaming_stt::streaming_stt_finish,
            streaming_stt::streaming_stt_cancel,
            streaming_stt::streaming_stt_test,
            secure_store::secret_get,
            secure_store::secret_set,
            secure_store::secret_delete,
            local_stt::local_stt_status,
            local_stt::download_stt_model,
            local_stt::transcribe_local,
            sherpa_stt::sensevoice_status,
            sherpa_stt::download_sensevoice_model,
            sherpa_stt::cancel_sensevoice_download,
            sherpa_stt::delete_sensevoice_model,
            sherpa_stt::sensevoice_start,
            sherpa_stt::sensevoice_push,
            sherpa_stt::sensevoice_finish,
            sherpa_stt::sensevoice_cancel,
            file_transcribe::transcribe_file_sensevoice,
            file_transcribe::cancel_file_transcription,
            audio_duck::duck_system_volume,
            audio_duck::restore_system_volume,
            audio_duck::restore_pending_volume_if_needed
        ])
        .on_menu_event(|app, event| {
            match event.id.as_ref() {
                "ov_open_settings" => {
                    if let Some(w) = app.get_webview_window("main") {
                        let _ = w.show();
                        let _ = w.set_focus();
                    }
                }
                "ov_hide" => {
                    if let Some(w) = app.get_webview_window("overlay") {
                        let _ = w.hide();
                    }
                }
                "ov_quit" => app.exit(0),
                _ => {}
            }
        })
        .setup(|app| {
            let handle = app.handle().clone();
            log_startup(&handle, "setup: begin");

            // 1. 初始化系統托盤（任一步失敗都不阻擋 app 啟動）
            match build_tray(app) {
                Ok(_) => log_startup(&handle, "setup: tray ok"),
                Err(e) => log_startup(&handle, &format!("setup: tray FAILED: {e}")),
            }

            // 2. 註冊預設全域熱鍵 Ctrl + Alt + Space（前端載入設定後會用 set_hotkeys 覆蓋）
            let default_binding = HotkeyBinding { id: MAIN_HOTKEY_ID.into(), shortcut: "Ctrl+Alt+Space".into() };
            match apply_hotkeys(&handle, &[default_binding]) {
                Ok(_) => log_startup(&handle, "setup: hotkey ok"),
                Err(e) => log_startup(&handle, &format!("setup: hotkey FAILED: {e}")),
            }

            // 2b. saybit:// URL scheme。macOS 由 bundle Info.plist 註冊；Linux 與 Windows
            // 開發版要在執行期註冊（安裝版由安裝程式寫入）。
            #[cfg(any(target_os = "linux", all(debug_assertions, windows)))]
            if let Err(e) = app.deep_link().register_all() {
                log_startup(&handle, &format!("setup: deep link register FAILED: {e}"));
            }
            #[cfg(target_os = "macos")]
            platform::start_tracking_external_app();
            {
                let h = handle.clone();
                app.deep_link().on_open_url(move |event| handle_deep_links(&h, event.urls()));
            }
            // 冷啟動帶的 URL（Windows/Linux 是 argv；macOS 通常稍後才由 Opened 事件送到）
            if let Ok(Some(urls)) = app.deep_link().get_current() {
                handle_deep_links(&handle, urls);
            }

            // 3. 初始顯示主設定視窗（以利載入 Onboarding），置於主螢幕正中
            if let Some(main_window) = app.get_webview_window("main") {
                if let Ok(Some(primary)) = main_window.primary_monitor() {
                    let scale = primary.scale_factor();
                    let mon_w = (primary.size().width as f64) / scale;
                    let mon_h = (primary.size().height as f64) / scale;
                    let win_w = 900.0;
                    let win_h = 650.0;
                    let x = (mon_w - win_w) / 2.0;
                    let y = (mon_h - win_h) / 2.0;
                    let _ = main_window.set_position(tauri::LogicalPosition::new(x, y));
                }
                match main_window.show() {
                    Ok(_) => log_startup(&handle, "setup: main window shown"),
                    Err(e) => log_startup(&handle, &format!("setup: show main FAILED: {e}")),
                }
                let _ = main_window.set_focus();
            } else {
                log_startup(&handle, "setup: main window NOT FOUND");
            }

            log_startup(&handle, "setup: done");
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

// force-reload marker

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(command: &str, mode: Option<&str>, tab: Option<&str>) -> Option<UrlCommand> {
        Some(UrlCommand {
            command: command.into(),
            mode: mode.map(Into::into),
            tab: tab.map(Into::into),
        })
    }

    #[test]
    fn url_parse_host_and_path_forms() {
        assert_eq!(parse_url_command("saybit://toggle"), cmd("toggle", None, None));
        assert_eq!(parse_url_command("SAYBIT://Start"), cmd("start", None, None));
        assert_eq!(parse_url_command("saybit:stop"), cmd("stop", None, None));
        assert_eq!(parse_url_command("saybit:///cancel"), cmd("cancel", None, None));
        assert_eq!(parse_url_command("saybit://toggle/"), cmd("toggle", None, None));
    }

    #[test]
    fn url_parse_query() {
        assert_eq!(
            parse_url_command("saybit://start?mode=Email"),
            cmd("start", Some("Email"), None)
        );
        assert_eq!(
            parse_url_command("saybit://toggle?mode=%E7%BF%BB%E8%AD%AF%E6%88%90%E8%8B%B1%E6%96%87"),
            cmd("toggle", Some("翻譯成英文"), None)
        );
        assert_eq!(
            parse_url_command("saybit://settings?tab=hotkeys&mode="),
            cmd("settings", None, Some("hotkeys"))
        );
    }

    #[test]
    fn url_parse_rejects_unknown() {
        assert_eq!(parse_url_command("saybit://rm-rf"), None);
        assert_eq!(parse_url_command("https://toggle"), None);
        assert_eq!(parse_url_command("not a url"), None);
        assert_eq!(parse_url_command("saybit://"), None);
    }

    #[test]
    fn url_dedup_within_one_second() {
        let mut d = UrlDeduper::default();
        let t0 = Instant::now();
        assert!(d.accept("saybit://toggle", t0));
        assert!(!d.accept("saybit://toggle", t0 + Duration::from_millis(900)));
        assert!(d.accept("saybit://stop", t0 + Duration::from_millis(900)));
        // 視窗以最後一次「接受」為準
        assert!(d.accept("saybit://toggle", t0 + Duration::from_millis(1100)));
    }

    #[test]
    fn pending_url_queue_take_once() {
        let mut q = PendingUrlQueue::default();
        let start = cmd("start", Some("Email"), None).unwrap();
        let settings = cmd("settings", None, Some("hotkeys")).unwrap();
        assert_eq!(q.offer(start.clone(), true), None);
        assert_eq!(q.offer(settings.clone(), true), None);
        // 寬限期外直接送
        assert_eq!(q.offer(start.clone(), false), Some(start.clone()));
        assert!(q.take("other").is_empty());
        assert_eq!(q.take("overlay"), vec![start.clone()]);
        // overlay 取過了：之後給 overlay 的直接送，不再排隊；第二次取是空的
        assert_eq!(q.offer(start.clone(), true), Some(start.clone()));
        assert!(q.take("overlay").is_empty());
        // 取走過的不會出現在 fallback
        assert_eq!(q.drain_remaining(), vec![settings.clone()]);
        assert!(q.take("main").is_empty());
        assert_eq!(q.offer(settings.clone(), true), Some(settings));
    }

    #[test]
    fn write_text_file_rejects_unselected_paths() {
        let dir = std::env::temp_dir().join(format!("saybit-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let picked = dir.join("transcript.txt");
        save_allowlist().lock().unwrap().insert(picked.clone());

        assert!(write_text_file(picked.to_string_lossy().into(), "逐字稿".into()).is_ok());
        assert_eq!(std::fs::read_to_string(&picked).unwrap(), "逐字稿");
        let other = dir.join("other.txt");
        assert_eq!(
            write_text_file(other.to_string_lossy().into(), "x".into()),
            Err("path-not-allowed".into())
        );
        assert!(!other.exists());
        // 以 .. 繞路指到同一檔案也不接受（只認對話框回傳的原字串路徑）
        let sneaky = dir.join("sub").join("..").join("transcript.txt");
        assert!(!is_save_path_allowed(&save_allowlist().lock().unwrap(), &sneaky));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn mask_sensitive_log() {
        assert_eq!(mask_log_message("你好 abc", true), "[內容已遮罩, 6 字]");
        assert_eq!(mask_log_message("plain", false), "plain");
    }

    fn b(id: &str, s: &str) -> HotkeyBinding {
        HotkeyBinding { id: id.into(), shortcut: s.into() }
    }

    #[test]
    fn hotkey_plan_skips_duplicates_and_prefers_main() {
        let plan = plan_hotkeys(&[
            b("mode-a", "Ctrl+Alt+Space"),
            b("main", "Ctrl+Alt+Space"),
            b("mode-b", "Ctrl+Alt+KeyE"),
            b("mode-c", "ctrl+alt+KeyE"),
            b("mode-d", ""),
            b("mode-e", "NotAKey+++"),
        ]);
        let ids: Vec<&str> = plan.accepted.iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, vec!["main", "mode-b"]);
        assert_eq!(plan.skipped.len(), 2);
        assert!(plan.skipped[0].contains("主快捷鍵"));
        assert_eq!(plan.errors.len(), 1);
    }
}
