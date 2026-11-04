// 讓個人字典直接作用在「辨識」這一層，而不只靠 LLM（移植自原生版
// Core/SpeechRecognition/DictionaryHints.swift）：
//   1. STT initial prompt：帶偏好寫法，提高專有名詞命中率
//   2. 所有引擎：辨識完先做「原始詞 → 偏好寫法」字面替換，LLM 收到的就已經是正確寫法
//
// 刻意不 import db / Tauri，保持純函式，方便用 node 直接測。

export interface DictionaryLike {
  word: string;
  replacement?: string | null;
}

type Entries = DictionaryLike[] | Record<string, string>;

function toPairs(entries: Entries): Array<[string, string]> {
  const pairs: Array<[string, string]> = Array.isArray(entries)
    ? entries.map((e) => [e.word ?? '', (e.replacement || e.word) ?? ''])
    : Object.entries(entries);
  return pairs
    .map(([k, v]) => [k.trim(), v] as [string, string])
    .filter(([k]) => k.length > 0);
}

const isAsciiAlnum = (ch: string | undefined) => !!ch && /^[A-Za-z0-9]$/.test(ch);

/// 單次掃描替換（不會連鎖替換）：長詞優先、不分大小寫；
/// 開頭／結尾是 ASCII 英數的詞要整字比對（line 不能吃掉 deadline / online 裡的 line）。
/// 不用 regex lookbehind：舊版 WKWebView（Safari < 16.4）不支援。
export function applyDictionary(text: string, entries: Entries): string {
  if (!text) return text;
  const pairs = toPairs(entries);
  if (pairs.length === 0) return text;

  // 同 key（不分大小寫）先出現者為準
  const seen = new Set<string>();
  const terms: Array<{ lower: string; len: number; lead: boolean; trail: boolean; value: string }> = [];
  for (const [k, v] of pairs) {
    const lower = k.toLowerCase();
    if (seen.has(lower)) continue;
    seen.add(lower);
    terms.push({
      lower,
      len: k.length,
      lead: isAsciiAlnum(k[0]),
      trail: isAsciiAlnum(k[k.length - 1]),
      value: v,
    });
  }
  terms.sort((a, b) => b.len - a.len);

  let out = '';
  let i = 0;
  while (i < text.length) {
    let matched = false;
    for (const term of terms) {
      if (i + term.len > text.length) continue;
      if (text.slice(i, i + term.len).toLowerCase() !== term.lower) continue;
      if (term.lead && isAsciiAlnum(text[i - 1])) continue;
      if (term.trail && isAsciiAlnum(text[i + term.len])) continue;
      out += term.value;
      i += term.len;
      matched = true;
      break;
    }
    if (!matched) {
      out += text[i];
      i += 1;
    }
  }
  return out;
}

/// 偏好寫法（去重、去空白），給 STT initial prompt 用。
export function preferredSpellings(entries: Entries, limit = 30): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const [, v] of toPairs(entries)) {
    const s = v.trim();
    if (!s || seen.has(s)) continue;
    seen.add(s);
    out.push(s);
    if (out.length >= limit) break;
  }
  return out;
}

/// word → replacement 的 map（給 LLM payload 的 personal_dictionary）
export function toPersonalDictionary(entries: DictionaryLike[]): Record<string, string> {
  const dict: Record<string, string> = {};
  for (const e of entries) {
    if (e.word) dict[e.word] = e.replacement || e.word;
  }
  return dict;
}
