//! 系統 CJK 字型：用 fontdb 找平台內建的中日文字型，加到 egui 的 fallback 鏈尾端。
//! 不內嵌字型檔（PingFang.ttc 近 80 MB），改 mmap 系統檔。

use std::sync::Arc;

/// 依平台偏好排序的候選字族（第一個找到的當主要 CJK fallback，第二個找到的日文字型再補）
fn candidates() -> &'static [&'static str] {
    #[cfg(target_os = "macos")]
    {
        &["PingFang TC", "PingFang SC", "Heiti TC", "Hiragino Sans GB", "STHeiti", "Hiragino Sans"]
    }
    #[cfg(target_os = "windows")]
    {
        &["Microsoft JhengHei UI", "Microsoft JhengHei", "Microsoft YaHei UI", "Microsoft YaHei", "Yu Gothic UI", "Meiryo", "MS Gothic"]
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        &[
            "Noto Sans CJK TC",
            "Noto Sans TC",
            "Source Han Sans TC",
            "Noto Sans CJK SC",
            "Noto Sans CJK JP",
            "Source Han Sans SC",
            "WenQuanYi Micro Hei",
            "WenQuanYi Zen Hei",
            "Droid Sans Fallback",
        ]
    }
}

/// 回傳 (字族名, 字型資料)。找不到回 None。
pub fn find_cjk_font(db: &mut fontdb::Database) -> Option<(String, egui::FontData)> {
    for name in candidates() {
        let query = fontdb::Query { families: &[fontdb::Family::Name(name)], ..Default::default() };
        let Some(id) = db.query(&query) else { continue };
        // SAFETY: mmap 系統字型檔；執行期間系統字型檔被改寫的機率可忽略（其他 GUI 框架也這樣做）。
        let shared = unsafe { db.make_shared_face_data(id) };
        let data = match shared {
            Some((blob, index)) => egui::FontData::from_blob(blob, index),
            None => {
                let owned = db.with_face_data(id, |bytes, index| (bytes.to_vec(), index))?;
                egui::FontData::from_blob(Arc::new(owned.0), owned.1)
            }
        };
        return Some(((*name).to_string(), data));
    }
    None
}

/// macOS：⌃ ⌥ ⇧ ⌘ 等鍵盤符號只有系統符號字型有
fn symbol_font(db: &mut fontdb::Database) -> Option<egui::FontData> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    for name in ["Apple Symbols", "Menlo"] {
        let query = fontdb::Query { families: &[fontdb::Family::Name(name)], ..Default::default() };
        let Some(id) = db.query(&query) else { continue };
        let owned = db.with_face_data(id, |bytes, index| (bytes.to_vec(), index))?;
        return Some(egui::FontData::from_blob(Arc::new(owned.0), owned.1));
    }
    None
}

/// 安裝字型。回傳找到的字族名（給日誌用）。
pub fn install(ctx: &egui::Context) -> Option<String> {
    let started = std::time::Instant::now();
    let mut db = fontdb::Database::new();
    db.load_system_fonts();
    let found = find_cjk_font(&mut db);
    let mut defs = egui::FontDefinitions::default();
    let name = found.map(|(name, data)| {
        defs.font_data.insert("cjk".into(), Arc::new(data));
        for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
            defs.families.entry(family).or_default().push("cjk".into());
        }
        name
    });
    // 符號字型排在 CJK 後面，只補前面都沒有的字元
    if let Some(sym) = symbol_font(&mut db) {
        defs.font_data.insert("symbols".into(), Arc::new(sym));
        for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
            defs.families.entry(family).or_default().push("symbols".into());
        }
    }
    ctx.set_fonts(defs);
    match &name {
        Some(n) => crate::applog::info("Fonts", format!("CJK 字型：{n}（{} ms）", started.elapsed().as_millis())),
        None => crate::applog::warn("Fonts", "找不到系統 CJK 字型，中日文會顯示成方塊；Linux 請安裝 fonts-noto-cjk".to_string()),
    }
    name
}
