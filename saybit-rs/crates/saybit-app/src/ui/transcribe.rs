//! 檔案轉錄分頁（移植 FileTranscriptionView.swift + FileTranscriptionModel.swift）
//! 狀態放在 UiState，切換分頁不會遺失進度或結果。
use super::l10n::{t, tf};
use super::widgets::{self, BgTask};
use crate::app::AppState;
use egui::{RichText, Ui};
use saybit_core::llm::client::LlmClient;
use saybit_core::llm::{providers, refiner};
use saybit_core::models::ModelManager;
use saybit_core::*;
use std::path::{Path, PathBuf};
use std::time::Instant;

const EXTENSIONS: &[&str] = &["wav", "mp3", "m4a", "aac", "flac", "ogg", "opus", "mp4", "mov", "m4v", "mkv", "webm", "caf", "aiff"];

const NOTES_PROMPT: &str = "You turn a raw speech transcript (with [mm:ss] timestamps, possibly containing recognition errors) into clean meeting / voice notes.
Write in the language indicated by language_preference (zh-TW means Traditional Chinese, Taiwan wording).
Output Markdown with these sections:
## 摘要 — 3–5 sentences
## 重點 — bullet points, each with the [mm:ss] timestamp where it was discussed
## 待辦事項 — action items with owner if mentioned (omit section if none)
Fix obvious recognition errors using context. Do not invent facts that are not in the transcript.";

pub enum TranscribeMsg {
    Segment(TranscriptSegment),
    Progress(f32),
    Done(Result<Vec<TranscriptSegment>, String>),
}

pub enum NotesMsg {
    Delta(String),
    Done(Result<(), String>),
}

pub struct TranscribeState {
    file: Option<PathBuf>,
    segments: Vec<TranscriptSegment>,
    progress: f32,
    task: Option<BgTask<TranscribeMsg>>,
    started: Option<Instant>,
    elapsed_secs: f32,
    error: Option<String>,
    show_timestamps: bool,
    cached_text: String,
    cached_key: (usize, bool),
    notes: String,
    notes_task: Option<BgTask<NotesMsg>>,
    model_installed: Option<bool>,
}

impl Default for TranscribeState {
    fn default() -> Self {
        Self {
            file: None,
            segments: Vec::new(),
            progress: 0.0,
            task: None,
            started: None,
            elapsed_secs: 0.0,
            error: None,
            show_timestamps: true,
            cached_text: String::new(),
            cached_key: (usize::MAX, true),
            notes: String::new(),
            notes_task: None,
            model_installed: None,
        }
    }
}

impl TranscribeState {
    fn text(&mut self) -> &str {
        let key = (self.segments.len(), self.show_timestamps);
        if self.cached_key != key {
            self.cached_text = file_transcribe::segments_to_text(&self.segments, self.show_timestamps);
            self.cached_key = key;
        }
        &self.cached_text
    }
}

pub fn is_supported_media(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| EXTENSIONS.iter().any(|x| x.eq_ignore_ascii_case(e)))
}

/// 存檔預設檔名：`<原檔名>-<後綴>.<ext>`
pub fn default_file_name(source: Option<&Path>, suffix: &str, ext: &str) -> String {
    let stem = source.and_then(|p| p.file_stem()).and_then(|s| s.to_str()).unwrap_or("saybit");
    format!("{stem}-{suffix}.{ext}")
}

fn start(ctx: &egui::Context, state: &mut AppState, path: PathBuf) {
    let tr = &mut state.ui.transcribe;
    if let Some(old) = &tr.task {
        old.cancel.cancel();
    }
    if let Some(old) = &tr.notes_task {
        old.cancel.cancel();
    }
    tr.notes_task = None;
    tr.notes.clear();
    tr.file = Some(path.clone());
    tr.segments.clear();
    tr.progress = 0.0;
    tr.error = None;
    tr.started = Some(Instant::now());
    tr.elapsed_secs = 0.0;
    let language = state.settings.language_preference.clone();
    log::info!("file transcription start: {}", path.display());
    tr.task = Some(BgTask::spawn(ctx, move |tx, cancel| {
        let r = file_transcribe::transcribe_file(
            &path,
            &language,
            &mut |seg| tx.send(TranscribeMsg::Segment(seg.clone())),
            &mut |p| tx.send(TranscribeMsg::Progress(p)),
            &cancel,
        );
        tx.send(TranscribeMsg::Done(r.map_err(|e| e.to_string())));
    }));
}

fn poll(state: &mut AppState) {
    let tr = &mut state.ui.transcribe;
    if let Some(task) = &tr.task {
        let cancelled = task.cancel.is_cancelled();
        let mut done = None;
        for msg in task.poll() {
            match msg {
                TranscribeMsg::Segment(s) => tr.segments.push(s),
                TranscribeMsg::Progress(p) => tr.progress = p,
                TranscribeMsg::Done(r) => done = Some(r),
            }
        }
        if let Some(started) = tr.started {
            tr.elapsed_secs = started.elapsed().as_secs_f32();
        }
        if let Some(r) = done {
            match r {
                Ok(segs) => {
                    tr.segments = segs;
                    tr.progress = 1.0;
                }
                Err(e) => tr.error = Some(if cancelled { t("transcribe.stopped") } else { e }),
            }
            tr.task = None;
            tr.cached_key = (usize::MAX, true);
        }
    }
    if let Some(task) = &tr.notes_task {
        for msg in task.poll() {
            match msg {
                NotesMsg::Delta(d) => tr.notes.push_str(&d),
                NotesMsg::Done(Ok(())) => tr.notes_task = None,
                NotesMsg::Done(Err(e)) => {
                    tr.notes = tf("transcribe.summarizeFailed", &[("msg", &e)]);
                    tr.notes_task = None;
                }
            }
            if tr.notes_task.is_none() {
                break;
            }
        }
    }
}

fn summarize(ctx: &egui::Context, state: &mut AppState) {
    let s = &state.settings;
    let Some(mut provider) = providers::find(s, &s.selected_provider_id) else { return };
    if provider.id == "lmstudio" && !s.lm_studio_base_url.trim().is_empty() {
        provider.base_url = providers::normalize_local_base_url(&s.lm_studio_base_url);
    }
    let key = secure_store::get(&secure_store::llm_account(&provider.id));
    let model = s.selected_model.clone();
    let transcript = file_transcribe::segments_to_text(&state.ui.transcribe.segments, true);
    let user = serde_json::json!({ "transcript": transcript, "language_preference": s.language_preference }).to_string();
    let tr = &mut state.ui.transcribe;
    if let Some(old) = &tr.notes_task {
        old.cancel.cancel();
    }
    tr.notes.clear();
    tr.notes_task = Some(BgTask::spawn(ctx, move |tx, cancel| {
        let opts = LlmRequestOptions { temperature: Some(0.3), ..Default::default() };
        let r = LlmClient::new().stream_chat(&provider, key.as_deref(), &model, NOTES_PROMPT, &user, &opts, &cancel, &mut |ev| {
            if let LlmStreamEvent::Delta(d) = ev {
                tx.send(NotesMsg::Delta(d));
            }
        });
        if !cancel.is_cancelled() {
            tx.send(NotesMsg::Done(r.map_err(|e| refiner::friendly_error(&e))));
        }
    }));
}

fn save_dialog(name: &str, ext: &str, content: &str) -> Result<(), String> {
    let Some(path) = rfd::FileDialog::new().set_file_name(name).add_filter(ext, &[ext]).save_file() else {
        return Ok(());
    };
    std::fs::write(path, content).map_err(|e| e.to_string())
}

pub fn show(ui: &mut Ui, state: &mut AppState) {
    poll(state);
    let ctx = ui.ctx().clone();

    if state.ui.transcribe.model_installed.is_none() {
        let installed = matches!(ModelManager::new().state(ModelKind::SenseVoice), ModelState::Installed);
        state.ui.transcribe.model_installed = Some(installed);
    }
    let installed = state.ui.transcribe.model_installed == Some(true);
    let busy = state.ui.transcribe.task.is_some();

    // 拖放
    let (hovering, dropped) = ctx.input(|i| {
        (!i.raw.hovered_files.is_empty(), i.raw.dropped_files.iter().map(|f| f.path().to_path_buf()).collect::<Vec<_>>())
    });
    if installed {
        if let Some(path) = dropped.into_iter().find(|p| is_supported_media(p)) {
            start(&ctx, state, path);
        }
    }

    super::scroll_page(ui, "transcribe", |ui| {
        widgets::card(ui, |ui| {
            widgets::section_header(ui, "🎞", &t("transcribe.title"));
            widgets::description(ui, &t("transcribe.subtitle"));
            if !installed {
                widgets::warn_label(ui, &t("transcribe.modelMissing"));
                ui.horizontal(|ui| {
                    if ui.button(t("tabs.general")).clicked() {
                        state.settings.stt_engine = SttEngineKind::SenseVoice;
                        state.ui.selected_tab = super::SettingsTab::General;
                    }
                    if ui.button(format!("⟳ {}", t("common.recheck"))).clicked() {
                        state.ui.transcribe.model_installed = None;
                    }
                });
                return;
            }

            // 拖放區
            let stroke_color = if hovering { ui.visuals().selection.bg_fill } else { ui.visuals().widgets.noninteractive.bg_stroke.color };
            egui::Frame::new()
                .stroke(egui::Stroke::new(if hovering { 2.0 } else { 1.0 }, stroke_color))
                .corner_radius(10)
                .inner_margin(24)
                .show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.vertical_centered(|ui| {
                        ui.label(RichText::new("⬇").size(28.0).color(ui.visuals().weak_text_color()));
                        ui.label(t("transcribe.dropHint"));
                        if ui.add_enabled(!busy, egui::Button::new(t("transcribe.chooseFile"))).clicked() {
                            if let Some(p) = rfd::FileDialog::new().add_filter("Audio / Video", EXTENSIONS).pick_file() {
                                start(&ctx, state, p);
                            }
                        }
                        if let Some(f) = &state.ui.transcribe.file {
                            let name = f.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                            ui.label(RichText::new(name).monospace().color(ui.visuals().weak_text_color()));
                        }
                    });
                });

            let tr = &mut state.ui.transcribe;
            if let Some(task) = &tr.task {
                ui.horizontal(|ui| {
                    ui.spinner();
                    let pct = (tr.progress * 100.0).round() as i32;
                    ui.label(tf(
                        "transcribe.progress",
                        &[("percent", &pct.to_string()), ("seconds", &(tr.elapsed_secs as i32).to_string())],
                    ));
                    if ui.button(t("transcribe.stop")).clicked() {
                        task.cancel.cancel();
                    }
                });
                ui.add(egui::ProgressBar::new(tr.progress));
                ctx.request_repaint_after(std::time::Duration::from_millis(250));
            } else if let Some(e) = &tr.error {
                widgets::warn_label(ui, e);
            } else if tr.file.is_some() && !tr.segments.is_empty() {
                widgets::status_label(
                    ui,
                    true,
                    &tf(
                        "transcribe.finished",
                        &[("count", &tr.segments.len().to_string()), ("seconds", &format!("{:.1}", tr.elapsed_secs))],
                    ),
                );
            }
        });

        if !installed || state.ui.transcribe.segments.is_empty() {
            return;
        }
        transcript_card(ui, state);
        notes_card(ui, state);
    });
}

fn transcript_card(ui: &mut Ui, state: &mut AppState) {
    let busy = state.ui.transcribe.task.is_some();
    let mut do_summarize = false;
    widgets::card(ui, |ui| {
        let tr = &mut state.ui.transcribe;
        ui.horizontal(|ui| {
            widgets::section_header(ui, "📝", &t("transcribe.transcript"));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.checkbox(&mut tr.show_timestamps, t("transcribe.timestamps"));
            });
        });
        let mut text = tr.text().to_string();
        egui::ScrollArea::vertical().id_salt("transcript_text").max_height(320.0).show(ui, |ui| {
            ui.add(egui::TextEdit::multiline(&mut text).interactive(true).desired_width(f32::INFINITY).font(egui::TextStyle::Monospace));
        });
        ui.horizontal(|ui| {
            if ui.button(format!("⎘ {}", t("transcribe.copy"))).clicked() {
                ui.ctx().copy_text(text.clone());
            }
            if ui.add_enabled(!busy, egui::Button::new(t("transcribe.saveText"))).clicked() {
                let name = default_file_name(tr.file.as_deref(), &t("transcribe.transcriptSuffix"), "txt");
                if let Err(e) = save_dialog(&name, "txt", &text) {
                    tr.error = Some(e);
                }
            }
            let summarizing = tr.notes_task.is_some();
            if ui.add_enabled(!busy && !summarizing, egui::Button::new(format!("✨ {}", t("transcribe.summarize")))).clicked() {
                do_summarize = true;
            }
        });
    });
    if do_summarize {
        summarize(ui.ctx(), state);
    }
}

fn notes_card(ui: &mut Ui, state: &mut AppState) {
    let tr = &mut state.ui.transcribe;
    if tr.notes.is_empty() && tr.notes_task.is_none() {
        return;
    }
    widgets::card(ui, |ui| {
        ui.horizontal(|ui| {
            widgets::section_header(ui, "✨", &t("transcribe.notes"));
            if let Some(task) = &tr.notes_task {
                ui.spinner();
                if ui.button(t("transcribe.stop")).clicked() {
                    task.cancel.cancel();
                    tr.notes_task = None;
                }
            }
        });
        let mut notes = tr.notes.clone();
        egui::ScrollArea::vertical().id_salt("notes_text").max_height(360.0).show(ui, |ui| {
            ui.add(egui::TextEdit::multiline(&mut notes).desired_width(f32::INFINITY));
        });
        if tr.notes_task.is_none() {
            ui.horizontal(|ui| {
                if ui.button(format!("⎘ {}", t("transcribe.copy"))).clicked() {
                    ui.ctx().copy_text(tr.notes.clone());
                }
                if ui.button(t("transcribe.saveMarkdown")).clicked() {
                    let name = default_file_name(tr.file.as_deref(), &t("transcribe.notesSuffix"), "md");
                    if let Err(e) = save_dialog(&name, "md", &tr.notes) {
                        tr.error = Some(e);
                    }
                }
            });
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn media_extension_check() {
        assert!(is_supported_media(Path::new("/a/meeting.M4A")));
        assert!(is_supported_media(Path::new("clip.mp4")));
        assert!(!is_supported_media(Path::new("notes.txt")));
        assert!(!is_supported_media(Path::new("noext")));
    }

    #[test]
    fn default_names() {
        assert_eq!(default_file_name(Some(Path::new("/x/會議.m4a")), "逐字稿", "txt"), "會議-逐字稿.txt");
        assert_eq!(default_file_name(None, "notes", "md"), "saybit-notes.md");
    }
}
