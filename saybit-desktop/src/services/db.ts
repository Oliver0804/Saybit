import Dexie, { type Table } from 'dexie';

export interface HistoryRecord {
  id?: number;
  rawTranscript: string;
  processedText: string;
  appContext: string;
  mode: 'dictation' | 'command' | 'edit';
  timestamp: number;
  duration: number; // 錄音時長（秒）
  modelName: string;
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
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
  }
}

export const db = new SaybitDatabase();

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
