//! 全域快捷鍵（global-hotkey）＋觸發模式狀態機（移植 GlobalHotKeyManager.swift）＋給 A2 的快捷鍵錄製器。
//!
//! - 主快捷鍵依 `hotkey_trigger_mode`：toggle（按一下切換）/ hold（按住說話）/ double-tap（0.3 秒內連按兩下）
//! - 每個語音模式可有自己的快捷鍵，按下 = `ToggleRecording { mode }`；跟主快捷鍵或其他模式重複的略過
//! - OS auto-repeat：按住期間重複的 Pressed 吃掉；X11 的 auto-repeat 會送 Released+Pressed 成對事件，
//!   hold 模式的放開因此延後 40 ms 確認

use global_hotkey::hotkey::HotKey;
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};
use saybit_core::{HotkeyTriggerMode, Settings};
use std::collections::HashMap;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

pub const DOUBLE_TAP_INTERVAL: Duration = Duration::from_millis(300);
/// 按住期間超過這麼久沒收到任何 Pressed，就當作漏掉了 Released（避免卡在「已按下」吃掉下一次真的按鍵）
pub const STALE_DOWN: Duration = Duration::from_millis(1500);
/// hold 模式放開後等這麼久沒有新的 Pressed 才算真的放開（X11 auto-repeat）
pub const RELEASE_SETTLE: Duration = Duration::from_millis(40);
pub const RECORDER_TIMEOUT: Duration = Duration::from_secs(10);

// ───────────────────────────── 字串 ─────────────────────────────

pub fn parse(s: &str) -> Result<HotKey, String> {
    HotKey::from_str(s.trim()).map_err(|e| e.to_string())
}

/// 給使用者看的快捷鍵文字。macOS："⌃ ⌥ Space"；其他平台："Ctrl+Alt+Space"
pub fn display_label(s: &str) -> String {
    let mut mods: Vec<&'static str> = Vec::new();
    let mut key = String::new();
    for raw in s.split('+') {
        let token = raw.trim();
        if token.is_empty() {
            continue;
        }
        match token.to_ascii_uppercase().as_str() {
            "CTRL" | "CONTROL" => mods.push(if cfg!(target_os = "macos") { "⌃" } else { "Ctrl" }),
            "ALT" | "OPTION" => mods.push(if cfg!(target_os = "macos") { "⌥" } else { "Alt" }),
            "SHIFT" => mods.push(if cfg!(target_os = "macos") { "⇧" } else { "Shift" }),
            "CMD" | "COMMAND" | "SUPER" | "META" => mods.push(if cfg!(target_os = "macos") {
                "⌘"
            } else if cfg!(target_os = "windows") {
                "Win"
            } else {
                "Super"
            }),
            "CMDORCTRL" | "COMMANDORCONTROL" | "COMMANDORCTRL" | "CMDORCONTROL" => {
                mods.push(if cfg!(target_os = "macos") { "⌘" } else { "Ctrl" })
            }
            other => key = key_display(other),
        }
    }
    // 固定順序：⌃ ⌥ ⇧ ⌘（Ctrl Alt Shift Win）
    let order = ["⌃", "Ctrl", "⌥", "Alt", "⇧", "Shift", "⌘", "Win", "Super"];
    mods.sort_by_key(|m| order.iter().position(|o| o == m).unwrap_or(99));
    mods.dedup();
    let mut parts: Vec<String> = mods.into_iter().map(String::from).collect();
    if !key.is_empty() {
        parts.push(key);
    }
    parts.join(if cfg!(target_os = "macos") { " " } else { "+" })
}

fn key_display(upper: &str) -> String {
    if let Some(rest) = upper.strip_prefix("KEY") {
        if rest.len() == 1 {
            return rest.to_string();
        }
    }
    if let Some(rest) = upper.strip_prefix("DIGIT") {
        return rest.to_string();
    }
    match upper {
        "SPACE" => "Space".into(),
        "ENTER" => "Enter".into(),
        "TAB" => "Tab".into(),
        "BACKSPACE" => "⌫".into(),
        "COMMA" => ",".into(),
        "PERIOD" => ".".into(),
        "SLASH" => "/".into(),
        "BACKSLASH" => "\\".into(),
        "SEMICOLON" => ";".into(),
        "QUOTE" => "'".into(),
        "BRACKETLEFT" => "[".into(),
        "BRACKETRIGHT" => "]".into(),
        "MINUS" => "-".into(),
        "EQUAL" => "=".into(),
        "BACKQUOTE" => "`".into(),
        "ARROWUP" | "UP" => "↑".into(),
        "ARROWDOWN" | "DOWN" => "↓".into(),
        "ARROWLEFT" | "LEFT" => "←".into(),
        "ARROWRIGHT" | "RIGHT" => "→".into(),
        other => {
            // F1…F24 / 其他：首字大寫
            let mut c = other.chars();
            match c.next() {
                Some(f) => f.to_string() + &c.as_str().to_ascii_lowercase(),
                None => String::new(),
            }
        }
    }
}

// ───────────────────────────── 觸發模式狀態機 ─────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TriggerAction {
    Toggle,
    Start,
    Stop,
}

/// 主快捷鍵的狀態機（純邏輯，可測）
#[derive(Debug, Clone)]
pub struct TriggerMachine {
    pub mode: HotkeyTriggerMode,
    down: bool,
    last_press: Option<Instant>,
    last_tap: Option<Instant>,
    pending_release: Option<Instant>,
}

impl TriggerMachine {
    pub fn new(mode: HotkeyTriggerMode) -> Self {
        Self { mode, down: false, last_press: None, last_tap: None, pending_release: None }
    }

    pub fn set_mode(&mut self, mode: HotkeyTriggerMode) {
        if mode != self.mode {
            *self = Self::new(mode);
        }
    }

    pub fn on_pressed(&mut self, now: Instant) -> Option<TriggerAction> {
        if self.pending_release.take().is_some() {
            // X11：Released 後馬上又 Pressed = auto-repeat，不是真的放開
            self.down = true;
            self.last_press = Some(now);
            return None;
        }
        if self.down {
            let fresh_repeat = self.last_press.is_some_and(|t| now.duration_since(t) < STALE_DOWN);
            self.last_press = Some(now);
            if fresh_repeat {
                return None;
            }
            // 太久沒消息：當成漏掉 Released，這次算新的按下
        }
        self.down = true;
        self.last_press = Some(now);
        match self.mode {
            HotkeyTriggerMode::Toggle => Some(TriggerAction::Toggle),
            HotkeyTriggerMode::Hold => Some(TriggerAction::Start),
            HotkeyTriggerMode::DoubleTap => {
                if self.last_tap.is_some_and(|t| now.duration_since(t) <= DOUBLE_TAP_INTERVAL) {
                    self.last_tap = None;
                    Some(TriggerAction::Toggle)
                } else {
                    self.last_tap = Some(now);
                    None
                }
            }
        }
    }

    pub fn on_released(&mut self, now: Instant) -> Option<TriggerAction> {
        if !self.down {
            return None;
        }
        self.down = false;
        if self.mode == HotkeyTriggerMode::Hold {
            self.pending_release = Some(now);
        }
        None
    }

    /// 每幀呼叫：hold 模式放開確認後回 Stop
    pub fn tick(&mut self, now: Instant) -> Option<TriggerAction> {
        match self.pending_release {
            Some(t) if now.duration_since(t) >= RELEASE_SETTLE => {
                self.pending_release = None;
                Some(TriggerAction::Stop)
            }
            _ => None,
        }
    }

    pub fn needs_tick(&self) -> bool {
        self.pending_release.is_some()
    }
}

/// 語音模式快捷鍵的 auto-repeat 去重（只有 Pressed 會觸發）
#[derive(Debug, Default, Clone)]
pub struct RepeatFilter {
    down: HashMap<u32, Instant>,
}

impl RepeatFilter {
    /// 回 true = 這是新的按下
    pub fn pressed(&mut self, id: u32, now: Instant) -> bool {
        let fresh = match self.down.get(&id) {
            Some(t) => now.duration_since(*t) >= STALE_DOWN,
            None => true,
        };
        self.down.insert(id, now);
        fresh
    }
    pub fn released(&mut self, id: u32) {
        self.down.remove(&id);
    }
}

// ───────────────────────────── 註冊服務 ─────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum HotkeyAction {
    Main(TriggerAction),
    /// 語音模式 id
    Mode(String),
}

/// 每組要註冊的快捷鍵（純資料，可測）
#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub main: Option<HotKey>,
    /// (hotkey, mode id)
    pub modes: Vec<(HotKey, String)>,
    /// 給使用者的警告（格式錯、重複）
    pub warnings: Vec<String>,
}

pub fn plan(settings: &Settings) -> Plan {
    use crate::ui::l10n::tf;
    let mut warnings = Vec::new();
    let main = match parse(&settings.hotkey) {
        Ok(h) => Some(h),
        Err(_) => {
            warnings.push(tf("hotkey.invalid", &[("hotkey", &settings.hotkey)]));
            None
        }
    };
    let mut taken: Vec<u32> = main.iter().map(|h| h.id()).collect();
    let mut modes = Vec::new();
    for mode in &settings.voice_modes {
        let Some(raw) = mode.hotkey.as_deref().filter(|s| !s.trim().is_empty()) else { continue };
        match parse(raw) {
            Ok(h) if taken.contains(&h.id()) => {
                warnings.push(tf("hotkey.modeDuplicate", &[("name", &mode.name)]));
            }
            Ok(h) => {
                taken.push(h.id());
                modes.push((h, mode.id.clone()));
            }
            Err(_) => warnings.push(tf("hotkey.invalid", &[("hotkey", raw)])),
        }
    }
    Plan { main, modes, warnings }
}

/// 快捷鍵錄製中：暫停所有全域快捷鍵，讓按鍵送進 egui 視窗
static RECORDER_ACTIVE: AtomicBool = AtomicBool::new(false);

pub fn recorder_active() -> bool {
    RECORDER_ACTIVE.load(Ordering::Relaxed)
}

pub struct HotkeyService {
    manager: Option<GlobalHotKeyManager>,
    registered: Vec<HotKey>,
    main_id: Option<u32>,
    mode_ids: HashMap<u32, String>,
    trigger: TriggerMachine,
    repeat: RepeatFilter,
    paused: bool,
}

impl HotkeyService {
    /// 必須在主執行緒建立（macOS Carbon / Windows 訊息迴圈）
    pub fn new() -> Self {
        let manager = match GlobalHotKeyManager::new() {
            Ok(m) => Some(m),
            Err(e) => {
                crate::applog::error("HotKey", format!("無法建立全域快捷鍵管理器：{e}"));
                None
            }
        };
        Self {
            manager,
            registered: Vec::new(),
            main_id: None,
            mode_ids: HashMap::new(),
            trigger: TriggerMachine::new(HotkeyTriggerMode::Toggle),
            repeat: RepeatFilter::default(),
            paused: false,
        }
    }

    pub fn unregister_all(&mut self) {
        if let Some(m) = &self.manager {
            if !self.registered.is_empty() {
                let _ = m.unregister_all(&self.registered);
            }
        }
        self.registered.clear();
        self.main_id = None;
        self.mode_ids.clear();
    }

    /// 依設定重新註冊；回傳要 toast 的訊息
    pub fn register(&mut self, settings: &Settings) -> Vec<String> {
        use crate::ui::l10n::tf;
        self.unregister_all();
        self.trigger.set_mode(settings.hotkey_trigger_mode);
        let plan = plan(settings);
        let mut messages = plan.warnings.clone();
        for w in &plan.warnings {
            crate::applog::warn("HotKey", w.clone());
        }
        let Some(manager) = &self.manager else { return messages };
        if let Some(main) = plan.main {
            match manager.register(main) {
                Ok(()) => {
                    self.registered.push(main);
                    self.main_id = Some(main.id());
                    crate::applog::info("HotKey", format!("主快捷鍵已註冊：{}（{:?}）", settings.hotkey, settings.hotkey_trigger_mode));
                }
                Err(e) => {
                    crate::applog::error("HotKey", format!("主快捷鍵註冊失敗 {}：{e}", settings.hotkey));
                    messages.push(tf("hotkey.registerFailed", &[("hotkey", &display_label(&settings.hotkey))]));
                }
            }
        }
        for (hk, mode_id) in plan.modes {
            match manager.register(hk) {
                Ok(()) => {
                    self.registered.push(hk);
                    self.mode_ids.insert(hk.id(), mode_id);
                }
                Err(e) => {
                    let label = hk.into_string();
                    crate::applog::error("HotKey", format!("語音模式快捷鍵註冊失敗 {label}：{e}"));
                    messages.push(tf("hotkey.registerFailed", &[("hotkey", &display_label(&label))]));
                }
            }
        }
        messages
    }

    /// 錄製快捷鍵期間暫停；回傳 Some(訊息) 表示恢復時重新註冊產生的提示
    pub fn sync_pause(&mut self, settings: &Settings) -> Vec<String> {
        let want = recorder_active();
        if want == self.paused {
            return Vec::new();
        }
        self.paused = want;
        if want {
            self.unregister_all();
            Vec::new()
        } else {
            self.register(settings)
        }
    }

    pub fn handle(&mut self, event: GlobalHotKeyEvent, now: Instant) -> Option<HotkeyAction> {
        let id = event.id();
        if Some(id) == self.main_id {
            let action = match event.state() {
                HotKeyState::Pressed => self.trigger.on_pressed(now),
                HotKeyState::Released => self.trigger.on_released(now),
            };
            return action.map(HotkeyAction::Main);
        }
        if let Some(mode_id) = self.mode_ids.get(&id) {
            match event.state() {
                HotKeyState::Pressed => {
                    if self.repeat.pressed(id, now) {
                        return Some(HotkeyAction::Mode(mode_id.clone()));
                    }
                }
                HotKeyState::Released => self.repeat.released(id),
            }
        }
        None
    }

    pub fn tick(&mut self, now: Instant) -> Option<HotkeyAction> {
        self.trigger.tick(now).map(HotkeyAction::Main)
    }

    pub fn needs_tick(&self) -> bool {
        self.trigger.needs_tick()
    }
}

// ───────────────────────────── 錄製器（給 A2）─────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecorderEvent {
    /// global-hotkey 可解析的字串，例如 "Ctrl+Alt+E"
    Captured(String),
    /// Esc / 逾時 / 呼叫 cancel()
    Cancelled,
}

/// 在 egui 視窗內錄一組快捷鍵。用法（A2）：
/// ```ignore
/// if ui.button("錄製").clicked() { state.hotkey_recorder.start(); }
/// if state.hotkey_recorder.is_active() { ui.label(state.hotkey_recorder.prompt()); }
/// match state.hotkey_recorder.poll(ui.ctx()) { Some(RecorderEvent::Captured(s)) => …, _ => {} }
/// ```
/// 錄製期間全域快捷鍵會暫停（A1 每幀處理），結束後自動恢復。
#[derive(Debug, Default)]
pub struct HotkeyRecorder {
    started: Option<Instant>,
    /// 目前按著的修飾鍵（即時顯示用）
    live: String,
    /// 上一次按鍵不合格的原因（沒修飾鍵）
    hint: Option<String>,
}

impl HotkeyRecorder {
    pub fn start(&mut self) {
        self.started = Some(Instant::now());
        self.live.clear();
        self.hint = None;
        RECORDER_ACTIVE.store(true, Ordering::Relaxed);
    }

    pub fn cancel(&mut self) {
        self.started = None;
        self.live.clear();
        self.hint = None;
        RECORDER_ACTIVE.store(false, Ordering::Relaxed);
    }

    pub fn is_active(&self) -> bool {
        self.started.is_some()
    }

    /// 與 A2 暫用版（ui/widgets.rs）相同的介面
    #[allow(dead_code)]
    pub fn is_recording(&self) -> bool {
        self.is_active()
    }

    #[allow(dead_code)]
    pub fn remaining_secs(&self) -> u64 {
        self.started.map(|s| RECORDER_TIMEOUT.saturating_sub(s.elapsed()).as_secs()).unwrap_or(0)
    }

    /// Some(Ok(s)) 錄到、Some(Err(())) 取消或逾時、None 還在等（或沒在錄）
    #[allow(dead_code)]
    pub fn update(&mut self, ctx: &egui::Context) -> Option<Result<String, ()>> {
        self.poll(ctx).map(|e| match e {
            RecorderEvent::Captured(s) => Ok(s),
            RecorderEvent::Cancelled => Err(()),
        })
    }

    /// 提示文字：「請按下新的快捷鍵組合（Esc 取消）」＋目前按住的修飾鍵／錯誤提示
    pub fn prompt(&self) -> String {
        let mut s = crate::ui::l10n::t("hotkey.recordPrompt");
        if !self.live.is_empty() {
            s.push_str("  ");
            s.push_str(&display_label(&self.live));
        }
        if let Some(h) = &self.hint {
            s.push('\n');
            s.push_str(h);
        }
        s
    }

    /// 每幀呼叫（錄製中會吃掉鍵盤事件，避免觸發其他元件）
    pub fn poll(&mut self, ctx: &egui::Context) -> Option<RecorderEvent> {
        let started = self.started?;
        if started.elapsed() >= RECORDER_TIMEOUT {
            crate::applog::info("HotKey", "快捷鍵錄製逾時（10 秒），自動取消".to_string());
            self.cancel();
            return Some(RecorderEvent::Cancelled);
        }
        ctx.request_repaint_after(Duration::from_millis(200));
        let mut result = None;
        let mut live = None;
        ctx.input_mut(|i| {
            live = Some(modifiers_string(&i.modifiers));
            i.events.retain(|e| {
                let egui::Event::Key { key, pressed, repeat, modifiers, .. } = e else {
                    return !matches!(e, egui::Event::Text(_));
                };
                if !*pressed || *repeat || result.is_some() {
                    return false;
                }
                result = Some(match recorded_combo(*key, modifiers) {
                    Combo::Escape => Err(None),
                    Combo::NeedsModifier => Err(Some(crate::ui::l10n::t("hotkey.needModifier"))),
                    Combo::Unsupported => Err(Some(String::new())),
                    Combo::Ok(s) => Ok(s),
                });
                false
            });
        });
        self.live = live.unwrap_or_default();
        match result {
            Some(Ok(s)) => {
                self.cancel();
                Some(RecorderEvent::Captured(s))
            }
            Some(Err(None)) => {
                self.cancel();
                Some(RecorderEvent::Cancelled)
            }
            Some(Err(Some(hint))) => {
                self.hint = (!hint.is_empty()).then_some(hint);
                None
            }
            None => None,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Combo {
    Escape,
    NeedsModifier,
    Unsupported,
    Ok(String),
}

fn modifiers_string(m: &egui::Modifiers) -> String {
    let mut parts = Vec::new();
    // egui：ctrl 永遠是實體 Control 鍵；mac_cmd 只有 macOS 的 ⌘
    if m.ctrl {
        parts.push("Ctrl");
    }
    if m.alt {
        parts.push("Alt");
    }
    if m.shift {
        parts.push("Shift");
    }
    if m.mac_cmd {
        parts.push("Cmd");
    }
    parts.join("+")
}

/// egui 按鍵＋修飾鍵 → global-hotkey 字串（純邏輯，可測）
pub fn recorded_combo(key: egui::Key, m: &egui::Modifiers) -> Combo {
    if key == egui::Key::Escape {
        return Combo::Escape;
    }
    let Some(k) = key_token(key) else { return Combo::Unsupported };
    let mods = modifiers_string(m);
    if mods.is_empty() {
        return Combo::NeedsModifier;
    }
    Combo::Ok(format!("{mods}+{k}"))
}

fn key_token(key: egui::Key) -> Option<&'static str> {
    use egui::Key::*;
    Some(match key {
        A => "A", B => "B", C => "C", D => "D", E => "E", F => "F", G => "G", H => "H", I => "I",
        J => "J", K => "K", L => "L", M => "M", N => "N", O => "O", P => "P", Q => "Q", R => "R",
        S => "S", T => "T", U => "U", V => "V", W => "W", X => "X", Y => "Y", Z => "Z",
        Num0 => "0", Num1 => "1", Num2 => "2", Num3 => "3", Num4 => "4",
        Num5 => "5", Num6 => "6", Num7 => "7", Num8 => "8", Num9 => "9",
        F1 => "F1", F2 => "F2", F3 => "F3", F4 => "F4", F5 => "F5", F6 => "F6",
        F7 => "F7", F8 => "F8", F9 => "F9", F10 => "F10", F11 => "F11", F12 => "F12",
        Space => "Space",
        Enter => "Enter",
        Tab => "Tab",
        Backspace => "Backspace",
        Comma => "Comma",
        Period => "Period",
        Slash => "Slash",
        Backslash => "Backslash",
        Semicolon => "Semicolon",
        Quote => "Quote",
        OpenBracket => "BracketLeft",
        CloseBracket => "BracketRight",
        Minus => "Minus",
        Equals => "Equal",
        Backtick => "Backquote",
        ArrowUp => "ArrowUp",
        ArrowDown => "ArrowDown",
        ArrowLeft => "ArrowLeft",
        ArrowRight => "ArrowRight",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(base: Instant, n: u64) -> Instant {
        base + Duration::from_millis(n)
    }

    #[test]
    fn toggle_fires_once_and_eats_auto_repeat() {
        let t0 = Instant::now();
        let mut m = TriggerMachine::new(HotkeyTriggerMode::Toggle);
        assert_eq!(m.on_pressed(t0), Some(TriggerAction::Toggle));
        assert_eq!(m.on_pressed(ms(t0, 500)), None);
        assert_eq!(m.on_pressed(ms(t0, 530)), None);
        assert_eq!(m.on_released(ms(t0, 600)), None);
        assert_eq!(m.on_pressed(ms(t0, 900)), Some(TriggerAction::Toggle));
    }

    #[test]
    fn stale_down_recovers_from_missed_release() {
        let t0 = Instant::now();
        let mut m = TriggerMachine::new(HotkeyTriggerMode::Toggle);
        assert_eq!(m.on_pressed(t0), Some(TriggerAction::Toggle));
        // Released 沒來；2 秒後再按應該算新的一次
        assert_eq!(m.on_pressed(ms(t0, 2000)), Some(TriggerAction::Toggle));
    }

    #[test]
    fn hold_starts_and_stops_after_settle() {
        let t0 = Instant::now();
        let mut m = TriggerMachine::new(HotkeyTriggerMode::Hold);
        assert_eq!(m.on_pressed(t0), Some(TriggerAction::Start));
        assert_eq!(m.on_released(ms(t0, 1000)), None);
        assert!(m.needs_tick());
        assert_eq!(m.tick(ms(t0, 1010)), None);
        assert_eq!(m.tick(ms(t0, 1050)), Some(TriggerAction::Stop));
        assert!(!m.needs_tick());
    }

    #[test]
    fn hold_ignores_x11_release_press_pairs() {
        let t0 = Instant::now();
        let mut m = TriggerMachine::new(HotkeyTriggerMode::Hold);
        assert_eq!(m.on_pressed(t0), Some(TriggerAction::Start));
        for i in 0..10 {
            let t = 500 + i * 33;
            assert_eq!(m.on_released(ms(t0, t)), None);
            assert_eq!(m.on_pressed(ms(t0, t + 1)), None);
            assert_eq!(m.tick(ms(t0, t + 2)), None);
        }
        m.on_released(ms(t0, 2000));
        assert_eq!(m.tick(ms(t0, 2100)), Some(TriggerAction::Stop));
    }

    #[test]
    fn double_tap_requires_two_presses_within_window() {
        let t0 = Instant::now();
        let mut m = TriggerMachine::new(HotkeyTriggerMode::DoubleTap);
        assert_eq!(m.on_pressed(t0), None);
        m.on_released(ms(t0, 80));
        assert_eq!(m.on_pressed(ms(t0, 250)), Some(TriggerAction::Toggle));
        m.on_released(ms(t0, 300));
        // 太慢的第二下不算
        assert_eq!(m.on_pressed(ms(t0, 1000)), None);
        m.on_released(ms(t0, 1050));
        assert_eq!(m.on_pressed(ms(t0, 1500)), None);
        m.on_released(ms(t0, 1550));
        assert_eq!(m.on_pressed(ms(t0, 1700)), Some(TriggerAction::Toggle));
    }

    #[test]
    fn repeat_filter_dedupes_mode_hotkeys() {
        let t0 = Instant::now();
        let mut f = RepeatFilter::default();
        assert!(f.pressed(7, t0));
        assert!(!f.pressed(7, ms(t0, 40)));
        f.released(7);
        assert!(f.pressed(7, ms(t0, 100)));
        assert!(f.pressed(8, ms(t0, 100)));
    }

    #[test]
    fn hotkey_strings_parse_and_compare() {
        let a = parse("Ctrl+Alt+Space").unwrap();
        let b = parse("alt+ctrl+space").unwrap();
        assert_eq!(a.id(), b.id());
        assert!(parse("Ctrl+Alt+E").is_ok());
        assert!(parse("Shift+Cmd+Period").is_ok());
        assert!(parse("Ctrl+Nope").is_err());
        assert!(parse("Ctrl++").is_err());
    }

    #[test]
    fn recorder_combos() {
        let m = egui::Modifiers { ctrl: true, alt: true, ..Default::default() };
        assert_eq!(recorded_combo(egui::Key::E, &m), Combo::Ok("Ctrl+Alt+E".into()));
        assert!(parse("Ctrl+Alt+E").is_ok());
        assert_eq!(recorded_combo(egui::Key::E, &egui::Modifiers::NONE), Combo::NeedsModifier);
        assert_eq!(recorded_combo(egui::Key::Escape, &m), Combo::Escape);
        let cmd = egui::Modifiers { mac_cmd: true, command: true, shift: true, ..Default::default() };
        let Combo::Ok(s) = recorded_combo(egui::Key::Period, &cmd) else { panic!() };
        assert_eq!(s, "Shift+Cmd+Period");
        assert!(parse(&s).is_ok());
        for k in [egui::Key::OpenBracket, egui::Key::Backtick, egui::Key::F5, egui::Key::Num3, egui::Key::Equals] {
            let Combo::Ok(s) = recorded_combo(k, &m) else { panic!("{k:?}") };
            assert!(parse(&s).is_ok(), "{s}");
        }
    }

    #[test]
    fn display_labels() {
        let l = display_label("Ctrl+Alt+Space");
        if cfg!(target_os = "macos") {
            assert_eq!(l, "⌃ ⌥ Space");
            assert_eq!(display_label("shift+cmd+KeyE"), "⇧ ⌘ E");
        } else {
            assert_eq!(l, "Ctrl+Alt+Space");
        }
    }

    #[test]
    fn plan_skips_duplicates() {
        let mut s = Settings { hotkey: "Ctrl+Alt+Space".into(), ..Default::default() };
        s.voice_modes[0].hotkey = Some("Alt+Ctrl+Space".into()); // 跟主快捷鍵相同
        s.voice_modes[1].hotkey = Some("Ctrl+Alt+E".into());
        s.voice_modes[2].hotkey = Some("ctrl+alt+e".into()); // 跟上一個相同
        let p = plan(&s);
        assert!(p.main.is_some());
        assert_eq!(p.modes.len(), 1);
        assert_eq!(p.modes[0].1, s.voice_modes[1].id);
        assert_eq!(p.warnings.len(), 2);
    }
}
