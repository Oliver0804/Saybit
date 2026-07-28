import Dexie, { type Table } from 'dexie';

export interface HistoryRecord {
  id?: number;
  rawTranscript: string;
  processedText: string;
  /// 正規化後的 context identifier，例如 "slack"
  appContext: string;
  /// 使用者看得到的 App 名稱，例如 "Slack"
  appName?: string;
  mode: 'dictation' | 'command' | 'edit';
  /// 意圖分類結果：dictation / translate / rewrite / compose / skill / …
  intent?: string;
  /// 實際套用的語氣（含 per-app 規則覆寫後的結果）
  tone?: string | null;
  timestamp: number;
  duration: number; // 錄音時長（秒）
  modelName: string;
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  /// 粗估成本（USD）。未知模型為 null。
  costUsd?: number | null;
}

export interface DictionaryEntry {
  id?: number;
  word: string;
  replacement: string;
}

export interface SkillEntry {
  id?: number;
  triggerWord: string;
  prompt: string;
}

export class SaybitDatabase extends Dexie {
  history!: Table<HistoryRecord>;
  dictionary!: Table<DictionaryEntry>;
  skills!: Table<SkillEntry>;

  constructor() {
    super('SaybitDatabase');
    this.version(1).stores({
      history: '++id, timestamp, appContext, mode',
      dictionary: '++id, &word',
      skills: '++id, &triggerWord',
    });
    // v2：歷史紀錄新增 intent 索引（統計頁要按意圖分組）。
    // 新增的欄位本身是 schema-less 的，只有要建索引的欄位需要列出來。
    this.version(2).stores({
      history: '++id, timestamp, appContext, mode, intent',
      dictionary: '++id, &word',
      skills: '++id, &triggerWord',
    });
  }
}

export const db = new SaybitDatabase();

/// 依保留天數清理歷史紀錄。回傳刪除筆數。
export async function cleanupHistory(retentionDays: number): Promise<number> {
  if (retentionDays <= 0) return 0;
  const cutoff = Date.now() - retentionDays * 24 * 60 * 60 * 1000;
  return db.history.where('timestamp').below(cutoff).delete();
}

// 預填初始資料
export async function initDefaultData() {
  const dictCount = await db.dictionary.count();
  if (dictCount === 0) {
    await db.dictionary.bulkAdd([
      { word: 'openai', replacement: 'OpenAI' },
      { word: 'chatgpt', replacement: 'ChatGPT' },
      { word: 'github', replacement: 'GitHub' },
      { word: 'iphone', replacement: 'iPhone' },
      { word: 'macbook', replacement: 'MacBook' },
      { word: 'wifi', replacement: 'Wi-Fi' },
      { word: 'youtube', replacement: 'YouTube' },
      { word: 'line', replacement: 'LINE' },
    ]);
  }

  const skillsCount = await db.skills.count();
  if (skillsCount === 0) {
    await db.skills.bulkAdd([
      { triggerWord: '摘要', prompt: '壓縮至原文 1/3 長度，以重點條列呈現。' },
      { triggerWord: '條列', prompt: '以 `-` 前綴整理為條列式。' },
      { triggerWord: '代辦', prompt: '轉換為 `- [ ]` Markdown 待辦項目。' },
      { triggerWord: '修潤', prompt: '修正錯字、改善流暢度、保留原意。' },
      { triggerWord: '寫信', prompt: '正式商業書信格式，含問候語與結尾敬語。' },
    ]);
  }
}
