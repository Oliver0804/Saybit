// STT & LLM API Services
// 走 Tauri Rust HTTP client（tauri-plugin-http），繞開 WKWebView CORS：
// 錯誤回應（如 401 不帶 CORS header）才能以真實 status 呈現而非被遮蔽成 "Load failed"。
//
// 請求結構對齊原生版 Core/LLM/OpenRouterClient.swift：payload 以 JSON 當 user message、
// 帶 stream_options.include_usage 取回 token 用量、429/5xx 指數退避重試。

import { fetch } from '@tauri-apps/plugin-http';
import type { LLMProvider } from './providers';
import { buildIntentClassificationPrompt, type IntentResponse } from './systemPrompts';
import { assertSafeBaseUrl } from './settings';

/// 外部取消（使用者按取消 / 新的 session 作廢舊的）。與逾時、網路錯誤分開，
/// 呼叫端看到這個就靜默收工，不顯示成錯誤。
export class CancelledError extends Error {
  constructor() {
    super('cancelled');
    this.name = 'CancelledError';
  }
}

export function isCancelledError(e: unknown): boolean {
  return e instanceof CancelledError || (e as { name?: string } | null)?.name === 'CancelledError';
}

/// plugin-http 被 abort 時丟的是一般 Error("Request cancelled")，只能看 signal 判斷
function throwIfAborted(signal?: AbortSignal | null): void {
  if (signal?.aborted) throw new CancelledError();
}

/// 非 2xx 時讀 body 前 4KB，放進錯誤訊息（審查 M16）
async function readErrorBody(response: Response): Promise<string> {
  try {
    const text = await response.text();
    return text.slice(0, 4096);
  } catch {
    return '';
  }
}

/// 從錯誤 body / SSE error 物件取出人看得懂的訊息
function extractErrorMessage(obj: unknown): string | null {
  if (!obj || typeof obj !== 'object') return null;
  const err = (obj as { error?: unknown }).error;
  if (err == null) return null;
  if (typeof err === 'string') return err;
  if (typeof err === 'object') {
    const e = err as { message?: unknown; code?: unknown; metadata?: { raw?: unknown } };
    if (typeof e.message === 'string' && e.message) return e.message;
    if (e.code != null) return `error code ${String(e.code)}`;
  }
  return JSON.stringify(err).slice(0, 300);
}

function summarizeErrorBody(body: string): string {
  try {
    const msg = extractErrorMessage(JSON.parse(body));
    if (msg) return msg.slice(0, 300);
  } catch {
    /* 非 JSON 就截斷原文 */
  }
  return body.slice(0, 300);
}

export interface LLMPayload {
  transcript: string;
  context?: string | null;
  mode?: string | null;
  tone?: string | null;
  language_preference?: string | null;
  personal_dictionary?: Record<string, string> | null;
  snippets?: Record<string, string> | null;
  screen_context?: string | null;
  whisper_mode?: boolean | null;
  existing_text?: string | null;
}

export interface LLMUsage {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
}

export interface RefineResult {
  text: string;
  usage: LLMUsage | null;
}

export interface LLMParams {
  maxTokens?: number | null;
  frequencyPenalty?: number | null;
  presencePenalty?: number | null;
  topP?: number | null;
}

const MAX_RETRIES = 3;
const BASE_DELAY_MS = 1000; // 1s → 2s → 4s
const RETRYABLE = new Set([429, 500, 502, 503, 504]);

/// 把 HTTP status code 翻成使用者看得懂的訊息（對齊原生版）。
export function humanReadableStatus(code: number): string {
  switch (code) {
    case 400:
      return 'HTTP 400：請求格式錯誤（可能是模型名稱不正確或參數不被支援）';
    case 401:
      return 'HTTP 401：API Key 無效或已失效';
    case 402:
      return 'HTTP 402：餘額不足，請至服務商儲值';
    case 403:
      return 'HTTP 403：權限不足（可能是模型未授權）';
    case 404:
      return 'HTTP 404：模型不存在或端點錯誤';
    case 408:
      return 'HTTP 408：請求逾時';
    case 413:
      return 'HTTP 413：請求內容過大';
    case 429:
      return 'HTTP 429：超過速率限制，稍候再試';
    case 500:
      return 'HTTP 500：服務商內部錯誤';
    case 502:
      return 'HTTP 502：上游服務無回應';
    case 503:
      return 'HTTP 503：服務暫時不可用';
    case 504:
      return 'HTTP 504：上游逾時';
    default:
      return `HTTP ${code}：API 回應錯誤`;
  }
}

function retryDelayMs(attempt: number): number {
  return BASE_DELAY_MS * Math.pow(2, attempt) + Math.random() * 500;
}

/// 可被 signal 中斷的 sleep（重試退避期間取消要立刻生效）
const sleep = (ms: number, signal?: AbortSignal | null) =>
  new Promise<void>((resolve, reject) => {
    if (signal?.aborted) return reject(new CancelledError());
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new CancelledError());
    };
    signal?.addEventListener('abort', onAbort, { once: true });
  });

// ---------------------------------------------------------------- STT

/// 語音轉文字：Whisper 相容 API（OpenAI / Groq / 其他 OpenAI 相容端點）
export async function transcribeAudio(
  audioBlob: Blob,
  apiKey: string,
  model = 'whisper-1',
  language = 'zh',
  baseUrl = 'https://api.openai.com/v1',
  prompt = '',
  signal?: AbortSignal | null
): Promise<string> {
  assertSafeBaseUrl(baseUrl, Boolean(apiKey));
  throwIfAborted(signal);
  const formData = new FormData();
  // 副檔名/類型必須與實際編碼一致（MediaRecorder 錄的是 WebM/Opus），
  // 伺服器按副檔名選解碼器，標錯會讓解碼走 fallback、品質受損。
  const mime = audioBlob.type || 'audio/webm';
  const ext = mime.includes('webm') ? 'webm' : mime.includes('mp4') ? 'mp4' : 'wav';
  const file = new File([audioBlob], `recording.${ext}`, { type: mime });
  formData.append('file', file);
  formData.append('model', model);
  formData.append('language', language);
  // Whisper prompt 偏置：提示繁體中文語境 + 個人字典專有名詞，可大幅降低同音錯字
  if (prompt) formData.append('prompt', prompt);

  let response: Response;
  try {
    response = await fetch(`${baseUrl.replace(/\/$/, '')}/audio/transcriptions`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}` },
      body: formData,
      signal: signal ?? undefined,
    });
  } catch (e) {
    throwIfAborted(signal);
    throw e;
  }

  if (!response.ok) {
    const errText = await readErrorBody(response);
    if (response.status === 401) {
      throw new Error(
        'STT 401：key 與供應商不符（OpenAI 需 sk-...，Groq 需 gsk_...），請到設定確認。'
      );
    }
    if (response.status === 429) {
      throw new Error(
        'STT 429：該帳號額度不足。OpenAI 需綁卡儲值；或切換到 Groq 免費 STT（設定→STT 供應商）。'
      );
    }
    throw new Error(`STT API 錯誤: ${response.status} - ${errText.slice(0, 200)}`);
  }

  const data = (await response.json()) as { text?: string };
  return data.text || '';
}

// ---------------------------------------------------------------- LLM 串流

/// 內容中若出現同名標籤（可能是刻意注入），轉義後再包，避免提早閉合（對齊原生 taggedBlock）。
export function taggedBlock(tag: string, content: string): string {
  const escaped = content
    .split(`</${tag}>`)
    .join(`&lt;/${tag}&gt;`)
    .split(`<${tag}>`)
    .join(`&lt;${tag}&gt;`);
  return `<${tag}>\n${escaped}\n</${tag}>`;
}

/// 組出送給模型的 user message（審查 M11）。`existing_text` / `screen_context` 是資料，
/// 用專屬標籤包起來與指令（transcript）分開，也不再重複放進 JSON metadata。
export function buildUserMessage(payload: LLMPayload): string {
  const metadata: LLMPayload = { ...payload, existing_text: null, screen_context: null };
  const metadataJSON = JSON.stringify(metadata);
  const blocks: string[] = [];
  if (payload.existing_text) blocks.push(taggedBlock('existing_text', payload.existing_text));
  if (payload.screen_context) blocks.push(taggedBlock('screen_context', payload.screen_context));
  if (blocks.length === 0) return metadataJSON;
  return `## Voice Instruction
${payload.transcript}

## Metadata
${metadataJSON}

${blocks.join('\n\n')}`;
}

/// 本地服務（LM Studio / Ollama）常常不吃 stream_options 與 response_format，帶了整個
/// 請求會 400 —— 對意圖分類來說等於永遠降級成聽寫，所以這兩個欄位都要按 provider 判斷。
function isLocalOrCustom(provider: LLMProvider): boolean {
  return (
    provider.id === 'lmstudio' ||
    provider.id === 'ollama' ||
    provider.id.startsWith('custom-')
  );
}

function isCustomProvider(provider: LLMProvider): boolean {
  return provider.id.startsWith('custom-');
}

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface StreamChatOptions {
  apiKey: string;
  provider: LLMProvider;
  model: string;
  messages: ChatMessage[];
  temperature: number;
  params?: LLMParams;
  onChunk: (text: string) => void;
  signal?: AbortSignal | null;
}

/// 串流 chat completion 的共用核心：重試、取消、SSE error 處理都在這裡。
export async function streamChat(opts: StreamChatOptions): Promise<RefineResult> {
  const { apiKey, provider, model, messages, temperature, onChunk, signal } = opts;
  const params = opts.params ?? {};
  assertSafeBaseUrl(provider.baseUrl, Boolean(apiKey));

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...provider.extraHeaders,
  };
  if (apiKey) headers.Authorization = `Bearer ${apiKey}`;

  // 自訂端點先試著要 usage（審查 M16：不送 token 永遠是 0），回 400 就拿掉重試一次；
  // LM Studio / Ollama 已知不吃，直接不送。
  const custom = isCustomProvider(provider);
  let useStreamOptions = custom || !isLocalOrCustom(provider);

  const makeBody = () => {
    const body: Record<string, unknown> = { model, messages, stream: true, temperature };
    if (useStreamOptions) body.stream_options = { include_usage: true };
    if (params.maxTokens != null) body.max_tokens = params.maxTokens;
    if (params.frequencyPenalty != null) body.frequency_penalty = params.frequencyPenalty;
    if (params.presencePenalty != null) body.presence_penalty = params.presencePenalty;
    if (params.topP != null) body.top_p = params.topP;
    return JSON.stringify(body);
  };

  let lastStatus = 0;
  let lastBody = '';
  let skipNextDelay = false;

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0 && !skipNextDelay) await sleep(retryDelayMs(attempt - 1), signal);
    skipNextDelay = false;
    throwIfAborted(signal);

    let response: Response;
    try {
      response = await fetch(provider.baseUrl, {
        method: 'POST',
        headers,
        body: makeBody(),
        signal: signal ?? undefined,
      });
    } catch (e) {
      throwIfAborted(signal);
      throw e;
    }

    if (!response.ok) {
      lastStatus = response.status;
      lastBody = await readErrorBody(response);
      throwIfAborted(signal);
      if (response.status === 400 && custom && useStreamOptions && attempt < MAX_RETRIES) {
        useStreamOptions = false;
        skipNextDelay = true;
        continue;
      }
      if (RETRYABLE.has(response.status) && attempt < MAX_RETRIES) continue;
      const detail = lastBody ? `｜${summarizeErrorBody(lastBody)}` : '';
      if (RETRYABLE.has(response.status)) {
        throw new Error(
          `重試 ${MAX_RETRIES} 次後仍失敗（${humanReadableStatus(response.status)}）${detail}`
        );
      }
      throw new Error(`${humanReadableStatus(response.status)}${detail}`);
    }

    const reader = response.body?.getReader();
    if (!reader) throw new Error('無法取得串流讀取器');

    try {
      return await consumeSSE(reader, onChunk, signal);
    } catch (e) {
      throwIfAborted(signal);
      throw e;
    } finally {
      reader.cancel().catch(() => {});
    }
  }

  throw new Error(`重試 ${MAX_RETRIES} 次後仍失敗（${humanReadableStatus(lastStatus)}）`);
}

export async function refineTextStream(
  payload: LLMPayload,
  apiKey: string,
  provider: LLMProvider,
  model: string,
  systemPrompt: string,
  temperature: number,
  params: LLMParams,
  onChunk: (text: string) => void,
  signal?: AbortSignal | null
): Promise<RefineResult> {
  return streamChat({
    apiKey,
    provider,
    model,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: buildUserMessage(payload) },
    ],
    temperature,
    params,
    onChunk,
    signal,
  });
}

/// 解析一行 SSE / 非 SSE。回傳 'done' 代表收到 [DONE]。伺服器送 {"error":…} 直接丟錯（審查 M16）。
export function parseSSELine(
  line: string
): { kind: 'skip' } | { kind: 'done' } | { kind: 'chunk'; text: string; usage: LLMUsage | null } {
  const clean = line.trim();
  if (!clean) return { kind: 'skip' };

  let jsonStr: string;
  if (clean.startsWith('data:')) {
    jsonStr = clean.slice(5).trim();
    if (jsonStr === '[DONE]') return { kind: 'done' };
  } else if (clean.startsWith('{')) {
    // 非 SSE 格式的行 —— 可能是錯誤 JSON
    jsonStr = clean;
  } else {
    return { kind: 'skip' };
  }

  let parsed: any;
  try {
    parsed = JSON.parse(jsonStr);
  } catch {
    return { kind: 'skip' };
  }
  const errMsg = extractErrorMessage(parsed);
  if (errMsg) throw new Error(`LLM 串流錯誤：${errMsg.slice(0, 300)}`);

  const text: string = parsed?.choices?.[0]?.delta?.content || '';
  const usage: LLMUsage | null = parsed?.usage
    ? {
        promptTokens: parsed.usage.prompt_tokens ?? 0,
        completionTokens: parsed.usage.completion_tokens ?? 0,
        totalTokens: parsed.usage.total_tokens ?? 0,
      }
    : null;
  return { kind: 'chunk', text, usage };
}

async function consumeSSE(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  onChunk: (text: string) => void,
  signal?: AbortSignal | null
): Promise<RefineResult> {
  const decoder = new TextDecoder('utf-8');
  let accumulated = '';
  let buffer = '';
  let usage: LLMUsage | null = null;

  const handle = (line: string): boolean => {
    const r = parseSSELine(line);
    if (r.kind === 'done') return true;
    if (r.kind === 'chunk') {
      if (r.text) {
        accumulated += r.text;
        onChunk(r.text);
      }
      // usage 通常在最後一個 chunk（choices 為空陣列）才出現
      if (r.usage) usage = r.usage;
    }
    return false;
  };

  for (;;) {
    throwIfAborted(signal);
    const { done, value } = await reader.read();
    throwIfAborted(signal);
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    // 保留最後一個可能未完的 line
    buffer = lines.pop() || '';

    for (const line of lines) {
      if (handle(line)) return { text: accumulated, usage };
    }
  }
  if (buffer) handle(buffer);

  return { text: accumulated, usage };
}

// ---------------------------------------------------------------- 意圖分類

/// Stage 1 的逾時上限。對齊原生版 `classifyIntentWithTimeout` 的 8 秒。
/// 意圖分類只是錦上添花，卡住的話寧可當一般聽寫也不要讓使用者乾等。
const INTENT_TIMEOUT_MS = 8000;

/// 兩階段流程的 Stage 1。失敗或逾時一律降級成 dictation，不中斷 pipeline。
export async function classifyIntent(
  transcript: string,
  apiKey: string,
  provider: LLMProvider,
  model: string,
  skills: Record<string, string>,
  hasSelectedText: boolean,
  signal?: AbortSignal | null
): Promise<IntentResponse> {
  // 端點不安全不是「分類失敗」，要讓使用者看到 —— 不降級
  assertSafeBaseUrl(provider.baseUrl, Boolean(apiKey));
  throwIfAborted(signal);
  const degraded = (reason: string): IntentResponse => ({
    intent: 'dictation',
    content: transcript,
    degradedReason: reason,
  });

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...provider.extraHeaders,
  };
  if (apiKey) headers.Authorization = `Bearer ${apiKey}`;

  const body: Record<string, unknown> = {
    model,
    messages: [
      {
        role: 'system',
        content: buildIntentClassificationPrompt(skills, hasSelectedText),
      },
      { role: 'user', content: transcript },
    ],
    temperature: 0.1,
  };
  if (!isLocalOrCustom(provider)) {
    body.response_format = { type: 'json_object' };
  }

  try {
    // AbortController 讓逾時真的取消掉底層請求，而不是放著它繼續跑（審查 M13）；
    // 外部取消也接到同一個 controller，但事後要分辨是哪一種
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), INTENT_TIMEOUT_MS);
    const onExternalAbort = () => controller.abort();
    signal?.addEventListener('abort', onExternalAbort, { once: true });

    let response: Response;
    try {
      response = await fetch(provider.baseUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onExternalAbort);
    }
    throwIfAborted(signal);

    if (!response.ok) return degraded(humanReadableStatus(response.status));

    const data = await response.json();
    throwIfAborted(signal);
    const content = data.choices?.[0]?.message?.content;
    if (!content) return degraded('回應沒有 content 欄位');

    // 有些模型仍會用 ```json 包起來，先剝掉
    const stripped = content
      .trim()
      .replace(/^```(?:json)?\s*/i, '')
      .replace(/```$/, '');
    const parsed = JSON.parse(stripped) as IntentResponse;
    if (!parsed.intent) return degraded('JSON 缺少 intent 欄位');
    return parsed;
  } catch (e: any) {
    // 外部取消要往外丟，不能被當成「分類失敗 → 降級聽寫」繼續跑下去
    if (signal?.aborted || isCancelledError(e)) throw new CancelledError();
    // 被 controller abort 代表撞到 INTENT_TIMEOUT_MS，跟一般網路錯誤要分開講
    const reason =
      e?.name === 'AbortError' || /cancel/i.test(String(e?.message || e))
        ? `逾時 ${INTENT_TIMEOUT_MS / 1000}s`
        : String(e?.message || e);
    return degraded(reason);
  }
}

// ---------------------------------------------------------------- 結構化意圖

export interface EventPayload {
  title: string;
  date: string;
  duration_minutes?: number | null;
  location?: string | null;
  notes?: string | null;
  confirmation_text?: string | null;
}

export interface ReminderPayload {
  title: string;
  due_date?: string | null;
  notes?: string | null;
  confirmation_text?: string | null;
}

/// 非串流的單次呼叫，用在 create_event / create_reminder 這種要回 JSON 的意圖。
export async function completeJSON<T>(
  systemPrompt: string,
  userContent: string,
  apiKey: string,
  provider: LLMProvider,
  model: string,
  signal?: AbortSignal | null
): Promise<T | null> {
  assertSafeBaseUrl(provider.baseUrl, Boolean(apiKey));
  throwIfAborted(signal);
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...provider.extraHeaders,
  };
  if (apiKey) headers.Authorization = `Bearer ${apiKey}`;

  const body: Record<string, unknown> = {
    model,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userContent },
    ],
    temperature: 0.1,
  };
  if (!isLocalOrCustom(provider)) {
    body.response_format = { type: 'json_object' };
  }

  try {
    const response = await fetch(provider.baseUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: signal ?? undefined,
    });
    throwIfAborted(signal);
    if (!response.ok) return null;
    const data = await response.json();
    const content = data.choices?.[0]?.message?.content;
    if (!content) return null;
    const stripped = content
      .trim()
      .replace(/^```(?:json)?\s*/i, '')
      .replace(/```$/, '');
    return JSON.parse(stripped) as T;
  } catch (e) {
    if (signal?.aborted || isCancelledError(e)) throw new CancelledError();
    return null;
  }
}
