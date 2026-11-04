// 檔案轉錄（SenseVoice 離線）與「AI 整理成筆記」。
// 移植自原生版 UI/Transcribe/FileTranscriptionModel.swift + SherpaFileTranscriber.swift。
// 解碼、VAD、辨識都在 Rust（transcribe_file_sensevoice），這裡負責事件、取消、世代控管、簡轉繁。

import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import { toTraditional, preloadTraditionalizer } from './traditionalize';
import { streamChat, CancelledError } from './llm';
import { resolveProvider } from './providers';
import { loadSecret, llmKeyAccount, tr, type AppSettings } from './settings';
import type { SenseVoiceLanguage } from './sherpaStt';

export interface Segment {
  start: number;
  end: number;
  text: string;
}

export interface TranscribeFileOptions {
  onSegment?: (segment: Segment) => void;
  onProgress?: (progress: number) => void;
  signal?: AbortSignal;
}

/// 每次開始新檔案就 +1；舊任務的事件若世代不符就丟掉，避免段落混進新檔（原生 H12）。
let jobGeneration = 0;

export async function transcribeFile(
  path: string,
  language: SenseVoiceLanguage | string,
  opts: TranscribeFileOptions = {}
): Promise<Segment[]> {
  const { onSegment, onProgress, signal } = opts;
  if (signal?.aborted) throw new CancelledError();

  // 新任務開始：舊任務若還在跑，Rust 端只有一個 job，先叫它停
  if (jobGeneration > 0) {
    await invoke('cancel_file_transcription').catch(() => {});
  }
  const gen = ++jobGeneration;
  const isCurrent = () => gen === jobGeneration && !signal?.aborted;
  preloadTraditionalizer();

  const unlisteners: UnlistenFn[] = [];
  const safeListen = async <T>(event: string, cb: (payload: T) => void) => {
    try {
      unlisteners.push(await listen<T>(event, (ev) => cb(ev.payload)));
    } catch {
      /* 事件系統不可用時只是沒有進度 */
    }
  };

  await safeListen<{ progress: number }>('file-transcribe-progress', (p) => {
    if (!isCurrent()) return;
    const v = Number(p?.progress);
    if (Number.isFinite(v)) onProgress?.(Math.max(0, Math.min(1, v)));
  });
  await safeListen<Segment>('file-transcribe-segment', (seg) => {
    if (!isCurrent() || !seg || typeof seg.text !== 'string') return;
    // toTraditional 只在第一次需要等字典載入，之後 promise 依序 resolve，段落順序不變
    toTraditional(seg.text.trim()).then((text) => {
      if (isCurrent() && text) onSegment?.({ start: seg.start, end: seg.end, text });
    });
  });

  const onAbort = () => {
    invoke('cancel_file_transcription').catch(() => {});
  };
  signal?.addEventListener('abort', onAbort, { once: true });

  try {
    let raw: Segment[];
    try {
      raw = await invoke<Segment[]>('transcribe_file_sensevoice', { path, language });
    } catch (e) {
      const msg = String((e as { message?: string })?.message ?? e);
      // Rust 取消（含被新任務中止）回 Err("cancelled")
      if (signal?.aborted || gen !== jobGeneration || msg.trim() === 'cancelled') {
        throw new CancelledError();
      }
      if (/not found|unknown command|not allowed/i.test(msg)) {
        throw new Error(
          tr('errSenseVoiceUnavailable', '這個版本不支援 SenseVoice 離線辨識，請改用其他辨識引擎')
        );
      }
      throw new Error(`${tr('errFileTranscribeFailed', '檔案轉錄失敗')}：${msg}`);
    }
    if (signal?.aborted || gen !== jobGeneration) throw new CancelledError();

    const out: Segment[] = [];
    for (const seg of raw ?? []) {
      const text = await toTraditional((seg.text ?? '').trim());
      if (text) out.push({ start: seg.start, end: seg.end, text });
    }
    return out;
  } finally {
    signal?.removeEventListener('abort', onAbort);
    for (const u of unlisteners) u();
  }
}

/// [mm:ss]，超過一小時用 h:mm:ss（對齊原生 SherpaFileTranscriber.timestamp）
export function formatTimestamp(sec: number): string {
  const s = Math.max(0, Math.floor(Number.isFinite(sec) ? sec : 0));
  const pad = (n: number) => String(n).padStart(2, '0');
  if (s >= 3600) return `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`;
  return `${pad(Math.floor(s / 60))}:${pad(s % 60)}`;
}

/// 有時間戳：每段一行「[mm:ss] 文字」；沒有：直接接起來（對齊原生 plainText）
export function segmentsToText(segments: Segment[], withTimestamps: boolean): string {
  return segments
    .map((seg) => (withTimestamps ? `[${formatTimestamp(seg.start)}] ${seg.text}` : seg.text))
    .join(withTimestamps ? '\n' : '');
}

export const NOTES_SYSTEM_PROMPT = `You turn a raw speech transcript (with [mm:ss] timestamps, possibly containing recognition errors) into clean meeting / voice notes.
Write in the language indicated by language_preference (zh-TW means Traditional Chinese, Taiwan wording).
Output Markdown with these sections:
## 摘要 — 3–5 sentences
## 重點 — bullet points, each with the [mm:ss] timestamp where it was discussed
## 待辦事項 — action items with owner if mentioned (omit section if none)
Fix obvious recognition errors using context. Do not invent facts that are not in the transcript.`;

/// 把逐字稿整理成筆記，逐塊吐出 Markdown。text 建議傳 segmentsToText(segments, true)
/// （prompt 要求重點附時間戳）。中斷：傳 signal，或直接停止迭代（break 會中斷 HTTP）。
export async function* summarizeToNotes(
  text: string,
  settings: AppSettings,
  opts: { signal?: AbortSignal; apiKey?: string } = {}
): AsyncGenerator<string, void, void> {
  const provider = resolveProvider(
    settings.selectedProviderId,
    settings.customProviders,
    settings.lmStudioBaseUrl
  );
  const apiKey = opts.apiKey ?? (await loadSecret(llmKeyAccount(settings.selectedProviderId)));

  const controller = new AbortController();
  const outer = opts.signal;
  const onOuterAbort = () => controller.abort();
  if (outer?.aborted) controller.abort();
  outer?.addEventListener('abort', onOuterAbort, { once: true });

  // callback → async iterator 的小佇列
  const queue: string[] = [];
  let wake: (() => void) | null = null;
  let finished = false;
  let failure: unknown = null;

  const payload = {
    transcript: text,
    language_preference: settings.languagePreference,
  };

  const run = streamChat({
    apiKey,
    provider,
    model: settings.selectedModel,
    messages: [
      { role: 'system', content: NOTES_SYSTEM_PROMPT },
      { role: 'user', content: JSON.stringify(payload) },
    ],
    temperature: 0.3,
    onChunk: (chunk) => {
      queue.push(chunk);
      wake?.();
    },
    signal: controller.signal,
  })
    .catch((e) => {
      failure = e;
    })
    .finally(() => {
      finished = true;
      wake?.();
    });

  try {
    for (;;) {
      if (queue.length > 0) {
        yield queue.shift() as string;
        continue;
      }
      if (finished) break;
      await new Promise<void>((r) => (wake = r));
      wake = null;
    }
    await run;
    if (failure) throw failure;
  } finally {
    // 呼叫端提早 break / return 也會走到這裡 → 真的中斷請求
    if (!finished) controller.abort();
    outer?.removeEventListener('abort', onOuterAbort);
  }
}
