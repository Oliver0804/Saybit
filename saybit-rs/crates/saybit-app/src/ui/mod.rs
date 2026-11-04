//! 設定視窗內容（批次 A2）。A1 只呼叫 `settings_panel`、`UiState`、`l10n`。
pub mod l10n;

mod about;
mod ai;
mod dictionary;
mod general;
mod history;
mod hotkey;
mod logs;
mod statistics;
mod transcribe;
pub mod widgets;

use crate::app::AppState;
use egui::{Color32, RichText};
use l10n::t;
use saybit_core::storage::Storage;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SettingsTab {
    #[default]
    General,
    Ai,
    Hotkey,
    Dictionary,
    Transcribe,
    History,
    Statistics,
    Logs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SidebarGroup {
    Settings,
    Tools,
    Data,
}

impl SidebarGroup {
    pub const ALL: [SidebarGroup; 3] = [Self::Settings, Self::Tools, Self::Data];
    pub fn title(self) -> String {
        t(match self {
            Self::Settings => "tabs.groupSettings",
            Self::Tools => "tabs.groupTools",
            Self::Data => "tabs.groupData",
        })
    }
}

#[allow(dead_code)] // from_slug / slug 給 A1（saybit://settings?tab=）用
impl SettingsTab {
    pub const ALL: [SettingsTab; 8] = [
        Self::General,
        Self::Ai,
        Self::Hotkey,
        Self::Dictionary,
        Self::Transcribe,
        Self::History,
        Self::Statistics,
        Self::Logs,
    ];

    /// saybit://settings?tab=… 的值
    pub fn from_slug(s: &str) -> Option<Self> {
        Some(match s {
            "general" => Self::General,
            "api" | "ai" => Self::Ai,
            "hotkey" => Self::Hotkey,
            "dictionary" => Self::Dictionary,
            "transcribe" => Self::Transcribe,
            "history" => Self::History,
            "statistics" => Self::Statistics,
            "logs" => Self::Logs,
            _ => return None,
        })
    }

    pub fn slug(self) -> &'static str {
        match self {
            Self::General => "general",
            Self::Ai => "api",
            Self::Hotkey => "hotkey",
            Self::Dictionary => "dictionary",
            Self::Transcribe => "transcribe",
            Self::History => "history",
            Self::Statistics => "statistics",
            Self::Logs => "logs",
        }
    }

    pub fn title(self) -> String {
        t(match self {
            Self::General => "tabs.general",
            Self::Ai => "tabs.ai",
            Self::Hotkey => "tabs.hotkey",
            Self::Dictionary => "tabs.dictionary",
            Self::Transcribe => "tabs.transcribe",
            Self::History => "tabs.history",
            Self::Statistics => "tabs.statistics",
            Self::Logs => "tabs.logs",
        })
    }

    pub fn icon(self) -> &'static str {
        match self {
            Self::General => "⚙",
            Self::Ai => "✨",
            Self::Hotkey => "⌨",
            Self::Dictionary => "📖",
            Self::Transcribe => "🎞",
            Self::History => "🕘",
            Self::Statistics => "📊",
            Self::Logs => "📄",
        }
    }

    pub fn icon_color(self) -> Color32 {
        match self {
            Self::General => Color32::GRAY,
            Self::Ai => Color32::from_rgb(175, 82, 222),
            Self::Hotkey => Color32::from_rgb(255, 149, 0),
            Self::Dictionary => Color32::from_rgb(0, 122, 255),
            Self::Transcribe => Color32::from_rgb(48, 176, 199),
            Self::History => Color32::from_rgb(52, 199, 89),
            Self::Statistics => Color32::from_rgb(255, 45, 85),
            Self::Logs => Color32::from_rgb(162, 132, 94),
        }
    }

    pub fn group(self) -> SidebarGroup {
        match self {
            Self::General | Self::Ai | Self::Hotkey | Self::Dictionary => SidebarGroup::Settings,
            Self::Transcribe => SidebarGroup::Tools,
            Self::History | Self::Statistics | Self::Logs => SidebarGroup::Data,
        }
    }

    /// 跨分頁搜尋用的關鍵字（分頁內各卡片仍各自過濾）
    pub fn search_keywords(self) -> Vec<&'static str> {
        match self {
            Self::General => general::all_keywords(),
            Self::Ai => vec![
                "AI", "API", "provider", "模型", "model", "服務商", "服务商", "OpenRouter", "Ollama", "LM Studio", "自訂",
                "custom", "key", "金鑰", "密钥", "連線", "connection", "測試", "prompt", "風格", "style", "提示詞", "語氣",
                "tone", "語調", "进阶", "進階", "advanced", "max_tokens", "參數", "本機", "離線",
            ],
            Self::Hotkey => vec![
                "快捷鍵", "hotkey", "shortcut", "快捷键", "鍵盤", "keyboard", "觸發", "trigger", "toggle", "hold", "按住",
                "雙擊", "double tap", "語音模式", "模式", "mode", "email", "翻譯", "url", "raycast", "捷徑", "說明",
            ],
            Self::Dictionary => vec![
                "字典", "dictionary", "詞彙", "词汇", "辞書", "詞條", "更正", "技能", "skill", "snippet", "觸發詞",
            ],
            Self::Transcribe => vec![
                "檔案", "转录", "轉錄", "transcribe", "file", "音檔", "影片", "會議", "逐字稿", "字幕", "srt",
            ],
            Self::History => vec!["歷史", "历史", "history", "紀錄", "記錄"],
            Self::Statistics => vec!["統計", "统计", "statistics", "stats", "用量", "費用", "cost"],
            Self::Logs => vec!["日誌", "日志", "logs", "log", "除錯", "debug"],
        }
    }

    pub fn matches(self, query: &str) -> bool {
        if query.trim().is_empty() {
            return true;
        }
        let title = self.title();
        let mut kw = self.search_keywords();
        kw.push(&title);
        widgets::matches_search(&kw, query)
    }
}

/// 設定視窗的 UI 狀態（各分頁的暫存輸入、背景任務、快取）
#[derive(Default)]
pub struct UiState {
    pub selected_tab: SettingsTab,
    pub search: String,
    general: general::GeneralState,
    ai: ai::AiState,
    hotkey: hotkey::HotkeyState,
    dictionary: dictionary::DictionaryState,
    transcribe: transcribe::TranscribeState,
    history: history::HistoryState,
    statistics: statistics::StatisticsState,
    logs: logs::LogsState,
    about: about::AboutState,
    /// 設定視窗自己的 SQLite 連線（歷史／字典／技能），第一次用到才開
    storage: Option<Result<Arc<Storage>, String>>,
    last_search: String,
}

#[allow(dead_code)] // open_about / on_settings_closed 給 A1（系統匣選單、關窗）呼叫
impl UiState {
    /// 開好的連線；開不起來回 Err(訊息)（給分頁顯示）
    fn storage(&mut self) -> Result<Arc<Storage>, String> {
        if self.storage.is_none() {
            self.storage = Some(Storage::open().map(Arc::new).map_err(|e| e.to_string()));
        }
        self.storage.clone().unwrap_or_else(|| Err(String::new()))
    }

    /// 顯示「關於」視窗
    pub fn open_about(&mut self) {
        self.about.open = true;
    }

    /// 設定視窗關閉時給 A1 呼叫：停掉麥克風測試、下次開啟重讀歷史／統計
    pub fn on_settings_closed(&mut self) {
        general::on_leave(&mut self.general);
        hotkey::on_leave(&mut self.hotkey);
        self.history = history::HistoryState::default();
        self.statistics = statistics::StatisticsState::default();
    }
}

/// API key 已改：A1 送 SecretsChanged 並更新系統匣的「缺 API Key」狀態。
/// 一般設定不用標 dirty：A1 每幀比對 `settings` 與已套用版本（打字中會等 400 ms 再存）。
fn mark_secrets_dirty(state: &mut AppState) {
    state.secrets_dirty = true;
}

/// 整個設定視窗（側欄 + 分頁內容）
pub fn settings_panel(ui: &mut egui::Ui, state: &mut AppState) {
    egui::Panel::left("saybit_settings_sidebar")
        .exact_size(200.0)
        .resizable(false)
        .show(ui, |ui| sidebar(ui, state));

    egui::CentralPanel::default().show(ui, |ui| {
        let tab = state.ui.selected_tab;
        match tab {
            SettingsTab::General => general::show(ui, state),
            SettingsTab::Ai => ai::show(ui, state),
            SettingsTab::Hotkey => hotkey::show(ui, state),
            SettingsTab::Dictionary => dictionary::show(ui, state),
            SettingsTab::Transcribe => transcribe::show(ui, state),
            SettingsTab::History => history::show(ui, state),
            SettingsTab::Statistics => statistics::show(ui, state),
            SettingsTab::Logs => logs::show(ui, state),
        }
    });

    if state.ui.selected_tab != SettingsTab::General {
        general::on_leave(&mut state.ui.general);
    }
    if state.ui.selected_tab != SettingsTab::Hotkey {
        hotkey::on_leave(&mut state.ui.hotkey);
    }
    about::show(ui.ctx(), state);

}

fn sidebar(ui: &mut egui::Ui, state: &mut AppState) {
    ui.add_space(12.0);
    ui.horizontal(|ui| {
        ui.label(RichText::new("🔍").color(ui.visuals().weak_text_color()));
        let w = ui.available_width() - if state.ui.search.is_empty() { 0.0 } else { 24.0 };
        ui.add(egui::TextEdit::singleline(&mut state.ui.search).hint_text(t("common.searchSettings")).desired_width(w));
        if !state.ui.search.is_empty() && ui.small_button("✖").on_hover_text(t("common.clearSearch")).clicked() {
            state.ui.search.clear();
        }
    });

    // 搜尋時若目前分頁沒有符合項目，自動跳到第一個有符合的分頁
    if state.ui.search != state.ui.last_search {
        state.ui.last_search = state.ui.search.clone();
        let q = state.ui.search.clone();
        if !q.trim().is_empty() && !state.ui.selected_tab.matches(&q) {
            if let Some(first) = SettingsTab::ALL.iter().find(|t| t.matches(&q)) {
                state.ui.selected_tab = *first;
            }
        }
    }

    ui.add_space(8.0);
    for group in SidebarGroup::ALL {
        ui.add_space(if group == SidebarGroup::Settings { 4.0 } else { 12.0 });
        ui.label(RichText::new(group.title()).small().color(ui.visuals().weak_text_color()));
        for tab in SettingsTab::ALL.into_iter().filter(|t| t.group() == group) {
            let selected = state.ui.selected_tab == tab;
            let dim = !tab.matches(&state.ui.search);
            let icon_color = if selected { tab.icon_color() } else { ui.visuals().weak_text_color() };
            let mut job = egui::text::LayoutJob::default();
            let fmt = |c: Color32| egui::TextFormat { color: c, font_id: egui::FontId::proportional(14.0), ..Default::default() };
            job.append(tab.icon(), 0.0, fmt(icon_color));
            let text_color = if selected { ui.visuals().strong_text_color() } else { ui.visuals().text_color() };
            job.append(&tab.title(), 10.0, fmt(text_color));
            let resp = ui
                .scope(|ui| {
                    if dim {
                        ui.set_opacity(0.35);
                    }
                    let w = ui.available_width();
                    ui.add(
                        egui::Button::selectable(selected, (egui::WidgetText::from(job), egui::Atom::grow()))
                            .frame_when_inactive(false)
                            .min_size(egui::vec2(w, 28.0)),
                    )
                })
                .inner;
            if resp.clicked() {
                state.ui.selected_tab = tab;
            }
        }
    }

    ui.with_layout(egui::Layout::bottom_up(egui::Align::Center), |ui| {
        ui.add_space(12.0);
        let v = format!("Saybit v{}", saybit_core::update_checker::current_version());
        if ui
            .add(egui::Label::new(RichText::new(v).small().color(ui.visuals().weak_text_color())).sense(egui::Sense::click()))
            .on_hover_text(t("common.about"))
            .clicked()
        {
            state.ui.about.open = true;
        }
    });
}

/// 分頁內的捲動容器（固定內距 20）
fn scroll_page(ui: &mut egui::Ui, id: &str, add: impl FnOnce(&mut egui::Ui)) {
    egui::ScrollArea::vertical().id_salt(id).auto_shrink([false, false]).show(ui, |ui| {
        egui::Frame::new().inner_margin(egui::Margin::same(20)).show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.spacing_mut().item_spacing.y = 16.0;
            add(ui);
        });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_roundtrip() {
        for tab in SettingsTab::ALL {
            assert_eq!(SettingsTab::from_slug(tab.slug()), Some(tab));
        }
        assert_eq!(SettingsTab::from_slug("ai"), Some(SettingsTab::Ai));
        assert_eq!(SettingsTab::from_slug("nope"), None);
    }

    #[test]
    fn cross_tab_search() {
        assert!(SettingsTab::Ai.matches("ollama"));
        assert!(!SettingsTab::Logs.matches("ollama"));
        assert!(SettingsTab::Hotkey.matches("Raycast"));
        assert!(SettingsTab::General.matches("麥克風"));
        assert!(SettingsTab::Logs.matches(""));
        let first = SettingsTab::ALL.iter().find(|t| t.matches("字典")).copied();
        assert_eq!(first, Some(SettingsTab::Dictionary));
    }
}
