// STT & LLM API Services
// 走 Tauri Rust HTTP client（tauri-plugin-http），繞開 WKWebView CORS：
// 錯誤回應（如 401 不帶 CORS header）才能以真實 status 呈現而非被遮蔽成 "Load failed"。
//
// 請求結構對齊原生版 Core/LLM/OpenRouterClient.swift：payload 以 JSON 當 user message、
// 帶 stream_options.include_usage 取回 token 用量、429/5xx 指數退避重試。

import { fetch } from '@tauri-apps/plugin-http';
import type { LLMProvider } from './providers';
import { buildIntentClassificationPrompt, type IntentResponse } from './systemPrompts';

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

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- STT

/// 語音轉文字：Whisper 相容 API（OpenAI / Groq / 其他 OpenAI 相容端點）
export async function transcribeAudio(
  audioBlob: Blob,
  apiKey: string,
  model = 'whisper-1',
  language = 'zh',
  baseUrl = 'https://api.openai.com/v1',
  prompt = ''
): Promise<string> {
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

  const response = await fetch(`${baseUrl.replace(/\/$/, '')}/audio/transcriptions`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}` },
    body: formData,
  });

  if (!response.ok) {
    const errText = await response.text();
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

/// 組出送給模型的 user message。有選取文字時用結構化格式，讓模型分得清
/// 「指令」與「被操作的文字」（對齊原生版）。
function buildUserMessage(payload: LLMPayload): string {
  const payloadString = JSON.stringify(payload);
  if (payload.existing_text) {
    return `## Voice Instruction
${payload.transcript}

## Selected Text
${payload.existing_text}

## Metadata
${payloadString}`;
  }
  return payloadString;
}

/// 本地服務（LM Studio / Ollama / 自訂端點）常常不吃 stream_options 與
/// response_format，帶了整個請求會 400 —— 對意圖分類來說等於永遠降級成聽寫，
/// 所以這兩個欄位都要按 provider 判斷。
function isLocalOrCustom(provider: LLMProvider): boolean {
  return (
    provider.id === 'lmstudio' ||
    provider.id === 'ollama' ||
    provider.id.startsWith('custom-')
  );
}

export async function refineTextStream(
  payload: LLMPayload,
  apiKey: string,
  provider: LLMProvider,
  model: string,
  systemPrompt: string,
  temperature: number,
  params: LLMParams,
  onChunk: (text: string) => void
): Promise<RefineResult> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...provider.extraHeaders,
  };
  if (apiKey) headers.Authorization = `Bearer ${apiKey}`;

  const body: Record<string, unknown> = {
    model,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: buildUserMessage(payload) },
    ],
    stream: true,
    temperature,
  };
  if (!isLocalOrCustom(provider)) {
    body.stream_options = { include_usage: true };
  }
  if (params.maxTokens != null) body.max_tokens = params.maxTokens;
  if (params.frequencyPenalty != null) body.frequency_penalty = params.frequencyPenalty;
  if (params.presencePenalty != null) body.presence_penalty = params.presencePenalty;
  if (params.topP != null) body.top_p = params.topP;

  let lastStatus = 0;

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    const response = await fetch(provider.baseUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      lastStatus = response.status;
      const errText = await response.text();
      if (RETRYABLE.has(response.status) && attempt < MAX_RETRIES) {
        await sleep(retryDelayMs(attempt));
        continue;
      }
      throw new Error(`${humanReadableStatus(response.status)}｜${errText.slice(0, 200)}`);
    }

    const reader = response.body?.getReader();
    if (!reader) throw new Error('無法取得串流讀取器');

    return await consumeSSE(reader, onChunk);
  }

  throw new Error(`重試 ${MAX_RETRIES} 次後仍失敗（${humanReadableStatus(lastStatus)}）`);
}

async function consumeSSE(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  onChunk: (text: string) => void
): Promise<RefineResult> {
  const decoder = new TextDecoder('utf-8');
  let accumulated = '';
  let buffer = '';
  let usage: LLMUsage | null = null;

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    // 保留最後一個可能未完的 line
    buffer = lines.pop() || '';

    for (const line of lines) {
      const clean = line.trim();
      if (!clean || !clean.startsWith('data: ')) continue;
      const jsonStr = clean.slice(6);
      if (jsonStr === '[DONE]') continue;

      try {
        const parsed = JSON.parse(jsonStr);
        const chunkText: string = parsed.choices?.[0]?.delta?.content || '';
        if (chunkText) {
          accumulated += chunkText;
          onChunk(chunkText);
        }
        // usage 通常在最後一個 chunk（choices 為空陣列）才出現
        if (parsed.usage) {
          usage = {
            promptTokens: parsed.usage.prompt_tokens ?? 0,
            completionTokens: parsed.usage.completion_tokens ?? 0,
            totalTokens: parsed.usage.total_tokens ?? 0,
          };
        }
      } catch {
        // 忽略無效的 JSON chunk
      }
    }
  }

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
  hasSelectedText: boolean
): Promise<IntentResponse> {
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
    // AbortController 讓逾時真的取消掉底層請求，而不是放著它繼續跑
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), INTENT_TIMEOUT_MS);

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
    }

    if (!response.ok) return degraded(humanReadableStatus(response.status));

    const data = await response.json();
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
    // AbortError 代表撞到 INTENT_TIMEOUT_MS，跟一般網路錯誤要分開講
    const reason =
      e?.name === 'AbortError'
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
  model: string
): Promise<T | null> {
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
    });
    if (!response.ok) return null;
    const data = await response.json();
    const content = data.choices?.[0]?.message?.content;
    if (!content) return null;
    const stripped = content
      .trim()
      .replace(/^```(?:json)?\s*/i, '')
      .replace(/```$/, '');
    return JSON.parse(stripped) as T;
  } catch {
    return null;
  }
}
