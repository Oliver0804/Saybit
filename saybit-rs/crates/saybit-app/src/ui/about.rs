//! 「關於 Saybit」視窗（移植 AboutView.swift）；由側欄版本號開啟，或 A1 呼叫 `UiState::open_about()`
use super::l10n::{t, tf};
use super::widgets::{self, BgTask};
use crate::app::AppState;
use egui::RichText;
use saybit_core::update_checker;
use std::cmp::Ordering;

const REPO_URL: &str = "https://github.com/Oliver0804/Saybit";

/// check_latest 的結果：Some((tag, url)) 或 None（已是最新）
type CheckResult = Result<Option<(String, String)>, String>;

#[derive(Default)]
pub struct AboutState {
    pub open: bool,
    check: Option<BgTask<CheckResult>>,
    status: String,
    release_url: Option<String>,
}

/// check_latest 結果 → (狀態文字, 新版連結)
fn describe(result: CheckResult) -> (String, Option<String>) {
    let cur = update_checker::current_version();
    match result {
        Ok(None) => (tf("update.upToDate", &[("v", cur)]), None),
        Ok(Some((tag, url))) => {
            let remote = tag.trim_start_matches('v');
            match update_checker::compare_semver(remote, cur) {
                Ordering::Greater => (tf("update.newer", &[("latest", &tag), ("current", cur)]), Some(url)),
                Ordering::Less => (tf("update.ahead", &[("current", cur), ("remote", remote)]), None),
                Ordering::Equal => (tf("update.upToDate", &[("v", cur)]), None),
            }
        }
        Err(e) => (e, None),
    }
}

pub fn show(ctx: &egui::Context, state: &mut AppState) {
    let a = &mut state.ui.about;
    if !a.open {
        return;
    }
    if let Some(task) = &a.check {
        if let Some(r) = task.poll().into_iter().next() {
            let (status, url) = describe(r);
            a.status = status;
            a.release_url = url;
            a.check = None;
        }
    }
    let modal = egui::Modal::new(egui::Id::unique("about_saybit")).show(ctx, |ui| {
        ui.set_width(400.0);
        ui.vertical_centered(|ui| {
            ui.add_space(8.0);
            ui.label(RichText::new("Saybit").size(28.0).strong());
            ui.label(RichText::new(format!("v{}", update_checker::current_version())).weak());
            ui.horizontal(|ui| {
                let busy = a.check.is_some();
                if ui.add_enabled(!busy, egui::Button::new(format!("⬇ {}", t("update.checkButton")))).clicked() {
                    a.status.clear();
                    a.release_url = None;
                    a.check = Some(BgTask::spawn(ui.ctx(), |tx, _| {
                        tx.send(update_checker::check_latest().map_err(|e| e.to_string()));
                    }));
                }
                if busy {
                    ui.spinner();
                }
                if let Some(url) = &a.release_url {
                    widgets::link(ui, &t("update.viewRelease"), url);
                }
            });
            if !a.status.is_empty() {
                ui.label(RichText::new(&a.status).small().weak());
            }
            ui.add_space(8.0);
            ui.label(RichText::new(t("about.description")).weak());
        });
        egui::Frame::new()
            .fill(egui::Color32::from_rgba_unmultiplied(52, 199, 89, 20))
            .corner_radius(10)
            .inner_margin(12)
            .show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.label(RichText::new(format!("$ {}", t("about.priceTitle"))).strong());
                widgets::description(ui, &t("about.priceDesc"));
            });
        ui.separator();
        ui.vertical_centered(|ui| {
            ui.horizontal(|ui| {
                ui.label(RichText::new(t("common.developer")).weak());
                ui.label(RichText::new("bashcat").strong());
            });
            widgets::link(ui, &t("common.visitWebsite"), "https://bashcat.net");
            ui.horizontal(|ui| {
                widgets::link(ui, "GitHub", REPO_URL);
                widgets::link(ui, &t("about.reportIssue"), &format!("{REPO_URL}/issues/new"));
            });
            ui.label(RichText::new("© 2026 bashcat. All rights reserved.").small().weak());
            ui.add_space(6.0);
            if ui.button(t("common.close")).clicked() {
                a.open = false;
            }
        });
    });
    if modal.should_close() {
        a.open = false;
    }
}
