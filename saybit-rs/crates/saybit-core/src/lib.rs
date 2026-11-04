//! Saybit core —— 與 GUI 無關的所有邏輯。
//!
//! 模組歸屬（各批次只能改自己的模組，共用型別在 `types.rs`，改型別要先在報告裡提出）：
//! - 批次 C1（音訊 / STT）：`audio/*`、`stt/*`、`models.rs`、`file_transcribe.rs`
//! - 批次 C2（LLM / pipeline / 儲存 / 設定）：`settings.rs`、`prompts.rs`、`llm/*`、`pipeline/*`、
//!   `storage/*`、`logging.rs`、`dictionary.rs`、`context_rules.rs`、`app_context.rs`、`update_checker.rs`
//! - 批次 C3（平台）：`inject/*`、`platform/*`、`ducking.rs`、`secure_store.rs`、`deeplink.rs`
//!
//! 所有阻塞式 I/O（HTTP、WebSocket、模型推論）都直接阻塞在呼叫執行緒上，沒有 tokio。
//! pipeline 跑在自己的執行緒；GUI 透過 `PipelineHandle` 下命令、讀快照、收事件。

pub mod types;

pub mod settings;
pub mod prompts;
pub mod llm;
pub mod pipeline;
pub mod storage;
pub mod logging;
pub mod dictionary;
pub mod context_rules;
pub mod app_context;
pub mod update_checker;

pub mod audio;
pub mod stt;
pub mod models;
pub mod file_transcribe;

pub mod inject;
pub mod platform;
pub mod ducking;
pub mod secure_store;
pub mod deeplink;

pub mod paths;

pub use types::*;
