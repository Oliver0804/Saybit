//! SQLite（rusqlite bundled）：history / dictionary / skills（批次 C2）。所有方法 &self，內部 Mutex<Connection>，Send + Sync。
use crate::types::*;
use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;

pub struct Storage {
    conn: Mutex<Connection>,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp_ms INTEGER NOT NULL,
    raw_transcript TEXT NOT NULL,
    processed_text TEXT NOT NULL,
    app_name TEXT NOT NULL DEFAULT '',
    mode TEXT NOT NULL DEFAULT 'dictation',
    model_name TEXT NOT NULL DEFAULT '',
    duration_secs REAL NOT NULL DEFAULT 0,
    prompt_tokens INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    total_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd REAL
);
CREATE INDEX IF NOT EXISTS history_ts ON history(timestamp_ms);
CREATE TABLE IF NOT EXISTS dictionary (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    term TEXT NOT NULL COLLATE NOCASE UNIQUE,
    preferred TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS skills (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    trigger TEXT NOT NULL UNIQUE,
    content TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
";

/// 預設字典（照 Persistence.swift）
const DEFAULT_DICTIONARY: &[(&str, &str)] = &[
    ("openai", "OpenAI"),
    ("chatgpt", "ChatGPT"),
    ("github", "GitHub"),
    ("iphone", "iPhone"),
    ("macbook", "MacBook"),
    ("wifi", "Wi-Fi"),
    ("youtube", "YouTube"),
    ("line", "LINE"),
];

/// 預設技能（Persistence.swift 的 v2 + v3）
const DEFAULT_SKILLS: &[(&str, &str)] = &[
    ("摘要", "將輸入內容濃縮為簡潔的摘要。保留關鍵資訊，去除冗餘內容。以條列式或短段落呈現，不超過原文的 1/3 長度。"),
    ("條列", "將輸入內容整理為條列式（bullet points）。每個要點簡潔明確，使用 - 作為項目符號。自動偵測並分組相關內容。"),
    ("代辦", "將輸入內容轉換為待辦事項清單。每個項目使用 - [ ] 格式（Markdown checkbox）。自動拆解複合任務為獨立項目，按邏輯順序排列。"),
    ("修潤", "潤飾輸入的文字，修正錯字、調整語句使其更通順自然。保留原意，不改變內容方向。"),
    ("寫信", "請用正式商業書信格式撰寫，包含問候語與結尾敬語。語氣專業有禮。"),
];

fn row_to_history(r: &rusqlite::Row) -> rusqlite::Result<HistoryRecord> {
    let ms: i64 = r.get(1)?;
    Ok(HistoryRecord {
        id: r.get(0)?,
        timestamp: chrono::DateTime::from_timestamp_millis(ms).unwrap_or_default(),
        raw_transcript: r.get(2)?,
        processed_text: r.get(3)?,
        app_name: r.get(4)?,
        mode: r.get(5)?,
        model_name: r.get(6)?,
        duration_secs: r.get::<_, f64>(7)? as f32,
        prompt_tokens: r.get::<_, i64>(8)?.max(0) as u32,
        completion_tokens: r.get::<_, i64>(9)?.max(0) as u32,
        total_tokens: r.get::<_, i64>(10)?.max(0) as u32,
        cost_usd: r.get(11)?,
    })
}

const HISTORY_COLS: &str = "id, timestamp_ms, raw_transcript, processed_text, app_name, mode, model_name, duration_secs, prompt_tokens, completion_tokens, total_tokens, cost_usd";

impl Storage {
    /// 開 `paths::database_file()`。開不起來（毀損）時把原檔搬到 `corrupt-<時間>/` 保留，再建新庫——絕不刪資料。
    pub fn open() -> anyhow::Result<Storage> {
        let path = crate::paths::database_file();
        match Self::open_path(&path) {
            Ok(s) => Ok(s),
            Err(e) if path.exists() => {
                let dir = crate::paths::data_dir().join(format!("corrupt-{}", chrono::Local::now().format("%Y%m%d-%H%M%S")));
                std::fs::create_dir_all(&dir)?;
                for suffix in ["", "-wal", "-shm"] {
                    let src = std::path::PathBuf::from(format!("{}{suffix}", path.display()));
                    if src.exists() {
                        let name = src.file_name().map(|n| n.to_owned()).unwrap_or_default();
                        std::fs::rename(&src, dir.join(name))?;
                    }
                }
                crate::logging::log(
                    LogLevel::Error,
                    "Storage",
                    format!("資料庫無法開啟（{e}），原檔已搬到 {} 並建立新資料庫", dir.display()),
                );
                Self::open_path(&path)
            }
            Err(e) => Err(e),
        }
    }

    pub fn open_path(path: &Path) -> anyhow::Result<Storage> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open(path)?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> anyhow::Result<Storage> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> anyhow::Result<Storage> {
        // 毀損的檔案在這裡（第一次真正讀頁面）才會報錯
        conn.execute_batch(SCHEMA)?;
        let s = Storage { conn: Mutex::new(conn) };
        s.seed_once("seeded_dictionary_v1", |c| {
            for (t, p) in DEFAULT_DICTIONARY {
                c.execute("INSERT OR IGNORE INTO dictionary(term, preferred) VALUES (?1, ?2)", params![t, p])?;
            }
            Ok(())
        })?;
        s.seed_once("seeded_skills_v3", |c| {
            for (t, p) in DEFAULT_SKILLS {
                c.execute("INSERT OR IGNORE INTO skills(trigger, content) VALUES (?1, ?2)", params![t, p])?;
            }
            Ok(())
        })?;
        Ok(s)
    }

    fn seed_once(&self, key: &str, f: impl FnOnce(&Connection) -> rusqlite::Result<()>) -> anyhow::Result<()> {
        let mut conn = self.conn.lock();
        let done: Option<String> = conn.query_row("SELECT value FROM meta WHERE key = ?1", [key], |r| r.get(0)).optional()?;
        if done.is_some() {
            return Ok(());
        }
        let tx = conn.transaction()?;
        f(&tx)?;
        tx.execute("INSERT INTO meta(key, value) VALUES (?1, '1')", [key])?;
        tx.commit()?;
        Ok(())
    }

    // history
    pub fn add_history(&self, rec: &HistoryRecord) -> anyhow::Result<i64> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO history(timestamp_ms, raw_transcript, processed_text, app_name, mode, model_name, duration_secs, prompt_tokens, completion_tokens, total_tokens, cost_usd)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                rec.timestamp.timestamp_millis(),
                rec.raw_transcript,
                rec.processed_text,
                rec.app_name,
                rec.mode,
                rec.model_name,
                rec.duration_secs as f64,
                rec.prompt_tokens,
                rec.completion_tokens,
                rec.total_tokens,
                rec.cost_usd,
            ],
        )?;
        Ok(conn.last_insert_rowid())
    }

    /// 新到舊
    pub fn list_history(&self, limit: usize, offset: usize) -> anyhow::Result<Vec<HistoryRecord>> {
        let conn = self.conn.lock();
        let mut st = conn.prepare(&format!("SELECT {HISTORY_COLS} FROM history ORDER BY timestamp_ms DESC, id DESC LIMIT ?1 OFFSET ?2"))?;
        let rows = st.query_map(params![limit as i64, offset as i64], row_to_history)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// 原文 / 結果 / App 名稱包含 query（不分大小寫），新到舊
    pub fn search_history(&self, query: &str, limit: usize) -> anyhow::Result<Vec<HistoryRecord>> {
        let q = query.trim();
        if q.is_empty() {
            return self.list_history(limit, 0);
        }
        let pattern = format!("%{}%", q.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_"));
        let conn = self.conn.lock();
        let mut st = conn.prepare(&format!(
            "SELECT {HISTORY_COLS} FROM history
             WHERE raw_transcript LIKE ?1 ESCAPE '\\' OR processed_text LIKE ?1 ESCAPE '\\' OR app_name LIKE ?1 ESCAPE '\\'
             ORDER BY timestamp_ms DESC, id DESC LIMIT ?2"
        ))?;
        let rows = st.query_map(params![pattern, limit as i64], row_to_history)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn all_history(&self) -> anyhow::Result<Vec<HistoryRecord>> {
        self.list_history(i64::MAX as usize, 0)
    }

    pub fn history_count(&self) -> anyhow::Result<usize> {
        let n: i64 = self.conn.lock().query_row("SELECT COUNT(*) FROM history", [], |r| r.get(0))?;
        Ok(n as usize)
    }

    pub fn delete_history(&self, id: i64) -> anyhow::Result<()> {
        self.conn.lock().execute("DELETE FROM history WHERE id = ?1", [id])?;
        Ok(())
    }

    /// days = 0 不刪；回刪除筆數
    pub fn delete_history_older_than(&self, days: u32) -> anyhow::Result<usize> {
        if days == 0 {
            return Ok(0);
        }
        let cutoff = (chrono::Utc::now() - chrono::Duration::days(days as i64)).timestamp_millis();
        Ok(self.conn.lock().execute("DELETE FROM history WHERE timestamp_ms < ?1", [cutoff])?)
    }

    pub fn delete_all_history(&self) -> anyhow::Result<()> {
        self.conn.lock().execute("DELETE FROM history", [])?;
        Ok(())
    }

    // dictionary（term 不分大小寫唯一；新增同名覆蓋 preferred）
    pub fn dictionary(&self) -> anyhow::Result<Vec<DictionaryEntry>> {
        let conn = self.conn.lock();
        let mut st = conn.prepare("SELECT id, term, preferred FROM dictionary ORDER BY id")?;
        let rows = st.query_map([], |r| Ok(DictionaryEntry { id: r.get(0)?, term: r.get(1)?, preferred: r.get(2)? }))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn upsert_dictionary(&self, term: &str, preferred: &str) -> anyhow::Result<()> {
        let (term, preferred) = (term.trim(), preferred.trim());
        anyhow::ensure!(!term.is_empty() && !preferred.is_empty(), "原始詞與偏好寫法都不能是空的");
        self.conn.lock().execute(
            "INSERT INTO dictionary(term, preferred) VALUES (?1, ?2)
             ON CONFLICT(term) DO UPDATE SET preferred = excluded.preferred",
            params![term, preferred],
        )?;
        Ok(())
    }

    pub fn delete_dictionary(&self, id: i64) -> anyhow::Result<()> {
        self.conn.lock().execute("DELETE FROM dictionary WHERE id = ?1", [id])?;
        Ok(())
    }

    // skills（語音技能：觸發詞 → prompt）
    pub fn skills(&self) -> anyhow::Result<Vec<Skill>> {
        let conn = self.conn.lock();
        let mut st = conn.prepare("SELECT id, trigger, content FROM skills ORDER BY id")?;
        let rows = st.query_map([], |r| Ok(Skill { id: r.get(0)?, trigger: r.get(1)?, content: r.get(2)? }))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// 同觸發詞已存在時更新內容
    pub fn add_skill(&self, trigger: &str, content: &str) -> anyhow::Result<()> {
        let (trigger, content) = (trigger.trim(), content.trim());
        anyhow::ensure!(!trigger.is_empty() && !content.is_empty(), "觸發詞與內容都不能是空的");
        self.conn.lock().execute(
            "INSERT INTO skills(trigger, content) VALUES (?1, ?2)
             ON CONFLICT(trigger) DO UPDATE SET content = excluded.content",
            params![trigger, content],
        )?;
        Ok(())
    }

    pub fn delete_skill(&self, id: i64) -> anyhow::Result<()> {
        self.conn.lock().execute("DELETE FROM skills WHERE id = ?1", [id])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(text: &str, days_ago: i64) -> HistoryRecord {
        HistoryRecord {
            id: 0,
            timestamp: chrono::Utc::now() - chrono::Duration::days(days_ago),
            raw_transcript: format!("raw {text}"),
            processed_text: text.into(),
            app_name: "Slack".into(),
            mode: "dictation".into(),
            model_name: "m".into(),
            duration_secs: 1.5,
            prompt_tokens: 10,
            completion_tokens: 5,
            total_tokens: 15,
            cost_usd: Some(0.001),
        }
    }

    #[test]
    fn storage_history_crud() {
        let s = Storage::open_in_memory().unwrap();
        let a = s.add_history(&rec("old 100%", 40)).unwrap();
        s.add_history(&rec("new", 0)).unwrap();
        s.add_history(&rec("mid", 5)).unwrap();
        assert_eq!(s.history_count().unwrap(), 3);
        let l = s.list_history(10, 0).unwrap();
        assert_eq!(l.iter().map(|r| r.processed_text.as_str()).collect::<Vec<_>>(), ["new", "mid", "old 100%"]);
        assert_eq!(l[0].cost_usd, Some(0.001));
        assert_eq!(l[0].total_tokens, 15);
        assert_eq!(s.list_history(1, 1).unwrap()[0].processed_text, "mid");
        assert_eq!(s.search_history("100%", 10).unwrap().len(), 1);
        assert_eq!(s.search_history("%", 10).unwrap().len(), 1);
        assert_eq!(s.search_history("zzz", 10).unwrap().len(), 0);
        assert_eq!(s.search_history("RAW", 10).unwrap().len(), 3);
        assert_eq!(s.delete_history_older_than(30).unwrap(), 1);
        assert!(s.all_history().unwrap().iter().all(|r| r.id != a));
        let id = s.list_history(1, 0).unwrap()[0].id;
        s.delete_history(id).unwrap();
        assert_eq!(s.history_count().unwrap(), 1);
        s.delete_all_history().unwrap();
        assert_eq!(s.history_count().unwrap(), 0);
    }

    #[test]
    fn storage_dictionary_and_skills() {
        let s = Storage::open_in_memory().unwrap();
        // 播種
        let d = s.dictionary().unwrap();
        assert_eq!(d.len(), DEFAULT_DICTIONARY.len());
        assert_eq!(s.skills().unwrap().len(), DEFAULT_SKILLS.len());
        // 不分大小寫覆蓋
        s.upsert_dictionary("OpenAI", "OPENAI").unwrap();
        let d = s.dictionary().unwrap();
        assert_eq!(d.len(), DEFAULT_DICTIONARY.len());
        assert_eq!(d.iter().find(|e| e.term == "openai").unwrap().preferred, "OPENAI");
        s.upsert_dictionary("賽比", "Saybit").unwrap();
        assert!(s.upsert_dictionary(" ", "x").is_err());
        let id = s.dictionary().unwrap().last().unwrap().id;
        s.delete_dictionary(id).unwrap();
        assert!(s.dictionary().unwrap().iter().all(|e| e.term != "賽比"));

        s.add_skill("翻譯", "translate").unwrap();
        s.add_skill("翻譯", "translate v2").unwrap();
        let sk = s.skills().unwrap();
        assert_eq!(sk.iter().filter(|x| x.trigger == "翻譯").count(), 1);
        assert_eq!(sk.iter().find(|x| x.trigger == "翻譯").unwrap().content, "translate v2");
        s.delete_skill(sk[0].id).unwrap();
        assert_eq!(s.skills().unwrap().len(), DEFAULT_SKILLS.len());
    }

    #[test]
    fn storage_file_seed_once_and_reopen() {
        let dir = std::env::temp_dir().join(format!("saybit-db-test-{}", uuid::Uuid::new_v4()));
        let path = dir.join("t.sqlite");
        {
            let s = Storage::open_path(&path).unwrap();
            for e in s.dictionary().unwrap() {
                s.delete_dictionary(e.id).unwrap();
            }
        }
        // 使用者刪光預設字典後重開，不會再播種
        let s = Storage::open_path(&path).unwrap();
        assert!(s.dictionary().unwrap().is_empty());
        drop(s);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
