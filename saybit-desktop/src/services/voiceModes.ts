// 語音模式：每個模式有自己的指令（例如「寫成 email」「翻譯成英文」）與獨立快捷鍵。
// 用模式快捷鍵錄音時跳過意圖判斷，直接照模式指令處理。
// 移植自原生版 Models/VoiceMode.swift。

export interface VoiceMode {
  id: string;
  name: string;
  /// 給 AI 的指令；描述要把說的話變成什麼
  instructions: string;
  /// 快捷鍵（null = 沒設定，只能從 URL scheme / tray 觸發）
  hotkey: string | null;
}

/// 主快捷鍵在 set_hotkeys 裡的 id，語音模式的 id 不能跟它撞
export const MAIN_HOTKEY_ID = 'main';

export const DEFAULT_VOICE_MODES: VoiceMode[] = [
  {
    id: 'preset-email',
    name: 'Email',
    instructions:
      '把內容寫成一封完整、有禮貌的 email：開頭問候、分段清楚的正文、結尾致謝與署名留白。保留所有事實與數字，不要自行補充內容。',
    hotkey: null,
  },
  {
    id: 'preset-translate-en',
    name: '翻譯成英文',
    instructions: '把內容翻譯成自然、道地的英文。若有選取文字，則翻譯選取的文字。只輸出譯文。',
    hotkey: null,
  },
  {
    id: 'preset-bullet-notes',
    name: '條列筆記',
    instructions:
      '把內容整理成精簡的條列式筆記：先一行重點摘要，再用「- 」列出要點，有待辦事項時另外列在最後並加上「☐」。',
    hotkey: null,
  },
];

/// 依名稱找模式（不分大小寫，對齊原生 SettingsStore.voiceMode(named:)）。
export function findVoiceMode(
  settings: { voiceModes: VoiceMode[] },
  name: string | null | undefined
): VoiceMode | null {
  if (!name) return null;
  const target = name.trim().toLowerCase();
  if (!target) return null;
  return settings.voiceModes.find((m) => m.name.trim().toLowerCase() === target) ?? null;
}

export function findVoiceModeById(
  settings: { voiceModes: VoiceMode[] },
  id: string
): VoiceMode | null {
  return settings.voiceModes.find((m) => m.id === id) ?? null;
}

export function newVoiceModeId(): string {
  try {
    return crypto.randomUUID();
  } catch {
    return `mode-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  }
}

/// 從 localStorage 讀回的值做防呆：缺欄位補上、壞資料丟掉。
export function sanitizeVoiceModes(raw: unknown): VoiceMode[] {
  if (!Array.isArray(raw)) return DEFAULT_VOICE_MODES.map((m) => ({ ...m }));
  const out: VoiceMode[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;
    const m = item as Partial<VoiceMode>;
    if (typeof m.name !== 'string' || typeof m.instructions !== 'string') continue;
    let id = typeof m.id === 'string' && m.id ? m.id : newVoiceModeId();
    if (id === MAIN_HOTKEY_ID || seen.has(id)) id = newVoiceModeId();
    seen.add(id);
    out.push({
      id,
      name: m.name,
      instructions: m.instructions,
      hotkey: typeof m.hotkey === 'string' && m.hotkey ? m.hotkey : null,
    });
  }
  return out;
}

/// set_hotkeys 用的綁定清單：主快捷鍵 + 有設快捷鍵、且不與主快捷鍵相同的模式。
/// （原生 L12/L19：模式快捷鍵跟主快捷鍵相同時，主快捷鍵優先）
export function hotkeyBindings(
  mainHotkey: string,
  modes: VoiceMode[]
): Array<{ id: string; shortcut: string }> {
  const norm = (s: string) => s.replace(/\s+/g, '').toLowerCase();
  const bindings: Array<{ id: string; shortcut: string }> = [];
  const used = new Set<string>();
  if (mainHotkey) {
    bindings.push({ id: MAIN_HOTKEY_ID, shortcut: mainHotkey });
    used.add(norm(mainHotkey));
  }
  for (const m of modes) {
    if (!m.hotkey) continue;
    const key = norm(m.hotkey);
    if (used.has(key)) continue;
    used.add(key);
    bindings.push({ id: m.id, shortcut: m.hotkey });
  }
  return bindings;
}
