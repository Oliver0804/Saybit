// 串流語音辨識的前端介面。實際的 WebSocket 在 Rust（src-tauri/src/streaming_stt.rs），
// 因為阿里雲的認證要在 handshake 帶 Authorization header，瀏覽器的 WebSocket API
// 做不到；順帶也讓金鑰不用進 webview。

import { invoke } from '@tauri-apps/api/core';

export type StreamingProvider = 'aliyun' | 'xunfei';

export interface StreamingConfig {
  provider: StreamingProvider;
  /// 留空則用該服務商的預設端點
  endpoint: string;
  apiKey: string;
  /// 訊飛專用
  appId: string;
  /// 阿里雲專用，例如 fun-asr-realtime
  model: string;
}

export const STREAMING_PROVIDERS: Array<{
  id: StreamingProvider;
  name: string;
  defaultEndpoint: string;
  defaultModel: string;
  /// 這家需要哪些欄位
  needsAppId: boolean;
  needsModel: boolean;
  hint: string;
}> = [
  {
    id: 'aliyun',
    name: '阿里雲百鍊（Fun-ASR / Qwen-ASR）',
    defaultEndpoint: 'wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference/',
    defaultModel: 'fun-asr-realtime',
    needsAppId: false,
    needsModel: true,
    hint: '預設是國際站（新加坡）端點。北京站或自建 workspace 請改成對應的 wss 位址；兩站的 API Key 不通用。',
  },
  {
    id: 'xunfei',
    name: '訊飛實時語音轉寫（RTASR）',
    defaultEndpoint: 'wss://rtasr.xfyun.cn/v1/ws',
    defaultModel: '',
    needsAppId: true,
    needsModel: false,
    hint: '需要開放平台的 appId 與 apiKey。簽章由 Saybit 端計算（MD5 + HmacSHA1），你只要填憑證。',
  },
];

export function providerMeta(id: StreamingProvider) {
  return STREAMING_PROVIDERS.find((p) => p.id === id) ?? STREAMING_PROVIDERS[0];
}

/// 開一條串流連線。連不上會直接丟錯，呼叫端要能回退到批次辨識。
export async function startStreaming(config: StreamingConfig): Promise<void> {
  await invoke('streaming_stt_start', { config });
}

/// 推一塊 16-bit PCM。刻意不 await 到底 —— 錄音的 audio callback 不能被網路拖住。
export async function pushStreamingAudio(bytes: Uint8Array): Promise<void> {
  await invoke('streaming_stt_push', bytes);
}

/// 送出結束訊號並取回完整逐字稿。
export async function finishStreaming(): Promise<string> {
  return invoke<string>('streaming_stt_finish');
}

/// 取消（錄音中止時用），不等結果。
export async function cancelStreaming(): Promise<void> {
  await invoke('streaming_stt_cancel').catch(() => {});
}

/// 設定畫面用：只連線再斷開，驗證憑證與端點是否正確。
export async function testStreaming(config: StreamingConfig): Promise<string> {
  return invoke<string>('streaming_stt_test', { config });
}
