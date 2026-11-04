// SenseVoice（sherpa-onnx）離線辨識的前端介面。模型、VAD、decode 都在 Rust
// （src-tauri/src/sherpa_stt.rs）；這裡負責：模型管理、把錄音中的 16k PCM 分包推過去、
// 收尾取結果、簡轉繁。
//
// 命令可能還沒註冊（舊版後端 / 非支援平台）：一律轉成可讀錯誤，不讓呼叫端炸掉。

import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { toTraditional, preloadTraditionalizer } from './traditionalize';
import { tr } from './settings';
import { CancelledError } from './llm';

function isCancelledString(e: unknown): boolean {
  return String((e as { message?: string })?.message ?? e).trim() === 'cancelled';
}

export interface SenseVoiceStatus {
  /// 此平台是否支援（Linux 目前可能是 false）；舊版後端沒有這欄時視為 true
  supported: boolean;
  installed: boolean;
  dir: string;
  total_bytes: number;
}

export type SenseVoiceLanguage = 'auto' | 'zh' | 'en' | 'ja' | 'ko' | 'yue';

/// 錯誤碼：UI 可依此引導（例如未安裝 → 去設定下載）
export class SenseVoiceError extends Error {
  constructor(
    public code: 'notInstalled' | 'unavailable' | 'failed',
    message: string
  ) {
    super(message);
    this.name = 'SenseVoiceError';
  }
}

function isMissingCommand(e: unknown): boolean {
  const s = String((e as { message?: string })?.message ?? e).toLowerCase();
  return s.includes('not found') || s.includes('unknown command') || s.includes('not allowed');
}

function wrap(e: unknown): SenseVoiceError {
  if (e instanceof SenseVoiceError) return e;
  if (isMissingCommand(e)) {
    return new SenseVoiceError(
      'unavailable',
      tr('errSenseVoiceUnavailable', '這個版本不支援 SenseVoice 離線辨識，請改用其他辨識引擎')
    );
  }
  const msg = String((e as { message?: string })?.message ?? e);
  return new SenseVoiceError('failed', `${tr('errSenseVoiceFailed', 'SenseVoice 辨識失敗')}：${msg}`);
}

// ---------------------------------------------------------------- 模型管理（F2 用）

export async function getSenseVoiceStatus(): Promise<SenseVoiceStatus> {
  try {
    const st = await invoke<Partial<SenseVoiceStatus>>('sensevoice_status');
    return {
      supported: st.supported !== false,
      installed: Boolean(st.installed),
      dir: st.dir ?? '',
      total_bytes: Number(st.total_bytes ?? 0),
    };
  } catch (e) {
    throw wrap(e);
  }
}

/// 下載模型；onProgress 收 0..1。完成後 resolve；被 cancelSenseVoiceDownload() 取消時丟 CancelledError。
export async function downloadSenseVoiceModel(
  onProgress?: (progress: number) => void
): Promise<void> {
  const unlisten = onProgress
    ? await listen<{ progress: number }>('sensevoice-model-progress', (ev) => {
        const p = Number(ev.payload?.progress);
        if (Number.isFinite(p)) onProgress(Math.max(0, Math.min(1, p)));
      }).catch(() => null)
    : null;
  try {
    await invoke('download_sensevoice_model');
  } catch (e) {
    if (isCancelledString(e)) throw new CancelledError();
    throw wrap(e);
  } finally {
    unlisten?.();
  }
}

export async function cancelSenseVoiceDownload(): Promise<void> {
  try {
    await invoke('cancel_sensevoice_download');
  } catch (e) {
    console.warn('[Saybit] cancel_sensevoice_download 失敗:', e);
  }
}

export async function deleteSenseVoiceModel(): Promise<void> {
  try {
    await invoke('delete_sensevoice_model');
  } catch (e) {
    throw wrap(e);
  }
}

/// whisperLanguage（zh / en / ja …）對應到 SenseVoice 的語言碼；其他一律 auto。
export function senseVoiceLanguageFor(whisperLanguage: string | null | undefined): SenseVoiceLanguage {
  const l = (whisperLanguage || '').toLowerCase();
  if (l.startsWith('yue') || l === 'zh-hk' || l === 'cantonese') return 'yue';
  if (l.startsWith('zh')) return 'zh';
  if (l.startsWith('en')) return 'en';
  if (l.startsWith('ja')) return 'ja';
  if (l.startsWith('ko')) return 'ko';
  return 'auto';
}

/// 預載模型（第一次 sensevoice_start 約 1 秒）：start 後立刻 cancel。
/// 未安裝 / 不支援 / 命令不存在都靜默略過。
export async function preloadSenseVoice(): Promise<void> {
  try {
    const st = await getSenseVoiceStatus();
    if (!st.supported || !st.installed) return;
    preloadTraditionalizer();
    await invoke('sensevoice_start', { language: 'auto' });
    await invoke('sensevoice_cancel');
  } catch (e) {
    console.warn('[Saybit] SenseVoice 預載失敗（忽略）:', e);
  }
}

// ---------------------------------------------------------------- 錄音中的串流 session

/// 每包約 100 ms（16 kHz）
const PUSH_SAMPLES = 1600;

/// 一次錄音一個 session：start → push…（live tap）→ finish / cancel。
/// push 用 promise 串起來保證順序，finish 會等全部送完。
export class SenseVoiceSession {
  private pending: Float32Array[] = [];
  private pendingLength = 0;
  private queue: Promise<void> = Promise.resolve();
  private closed = false;
  private pushFailed = false;

  /// 模型沒裝 → notInstalled；命令不存在 → unavailable
  static async start(language: SenseVoiceLanguage): Promise<SenseVoiceSession> {
    const status = await getSenseVoiceStatus();
    if (!status.supported) {
      throw new SenseVoiceError(
        'unavailable',
        tr('errSenseVoiceUnsupportedPlatform', '此平台不支援 SenseVoice 離線辨識，請改用其他辨識引擎')
      );
    }
    if (!status.installed) {
      throw new SenseVoiceError(
        'notInstalled',
        tr(
          'errSenseVoiceNotInstalled',
          'SenseVoice 模型尚未下載，請到「設定 → 一般 → 語音辨識」下載模型（約 240 MB）'
        )
      );
    }
    preloadTraditionalizer();
    try {
      await invoke('sensevoice_start', { language });
    } catch (e) {
      throw wrap(e);
    }
    return new SenseVoiceSession();
  }

  /// live tap 呼叫：累積到 ~100 ms 才送一包。不能 throw（錄音 callback 不能被拖垮）。
  push(chunk: Float32Array): void {
    if (this.closed || this.pushFailed || chunk.length === 0) return;
    this.pending.push(chunk);
    this.pendingLength += chunk.length;
    if (this.pendingLength >= PUSH_SAMPLES) this.flush();
  }

  private flush(): void {
    if (this.pendingLength === 0) return;
    const merged = new Float32Array(this.pendingLength);
    let offset = 0;
    for (const c of this.pending) {
      merged.set(c, offset);
      offset += c.length;
    }
    this.pending = [];
    this.pendingLength = 0;
    const samples = Array.from(merged);
    this.queue = this.queue.then(() =>
      invoke('sensevoice_push', { samples }).then(
        () => {},
        (e) => {
          this.pushFailed = true;
          console.warn('[Saybit] sensevoice_push 失敗:', e);
        }
      )
    );
  }

  /// 送出剩餘音訊並取回整段結果（已轉繁體）。
  async finish(): Promise<string> {
    if (this.closed) return '';
    this.flush();
    this.closed = true;
    await this.queue;
    try {
      const text = await invoke<string>('sensevoice_finish');
      return await toTraditional((text || '').trim());
    } catch (e) {
      throw wrap(e);
    }
  }

  async cancel(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.pending = [];
    this.pendingLength = 0;
    await this.queue.catch(() => {});
    await invoke('sensevoice_cancel').catch((e) => {
      console.warn('[Saybit] sensevoice_cancel 失敗:', e);
    });
  }
}

/// stt-partial 事件的 payload：串流 STT 送字串，SenseVoice 送 { text }。
export function partialTextFromPayload(payload: unknown): string {
  if (typeof payload === 'string') return payload;
  if (payload && typeof payload === 'object' && typeof (payload as { text?: unknown }).text === 'string') {
    return (payload as { text: string }).text;
  }
  return '';
}

export { toTraditional };
