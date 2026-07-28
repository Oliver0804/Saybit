// LLM 服務商定義與模型清單查詢。移植自原生版 Core/LLM/LLMProvider.swift。
//
// baseUrl 一律存「完整的 chat/completions 端點」，與原生版一致 —— 因為各家路徑
// 不統一（DeepSeek 沒有 /v1、OpenRouter 是 /api/v1），用 origin 再自行拼接會出錯。

import { fetch } from '@tauri-apps/plugin-http';

export interface LLMProvider {
  id: string;
  name: string;
  /// 完整的 chat/completions 端點
  baseUrl: string;
  extraHeaders: Record<string, string>;
  keyPlaceholder: string;
  modelHint: string;
  isBuiltIn: boolean;
  requiresApiKey: boolean;
}

export const OPENROUTER: LLMProvider = {
  id: 'openrouter',
  name: 'OpenRouter',
  baseUrl: 'https://openrouter.ai/api/v1/chat/completions',
  extraHeaders: {
    'HTTP-Referer': 'https://saybit.bashcat.net',
    'X-Title': 'Saybit',
  },
  keyPlaceholder: 'sk-or-v1-...',
  modelHint:
    'deepseek/deepseek-v4-flash · deepseek/deepseek-v4-pro · openai/gpt-4.1-nano · google/gemini-2.5-flash',
  isBuiltIn: true,
  requiresApiKey: true,
};

export const OPENAI: LLMProvider = {
  id: 'openai',
  name: 'OpenAI',
  baseUrl: 'https://api.openai.com/v1/chat/completions',
  extraHeaders: {},
  keyPlaceholder: 'sk-...',
  modelHint: 'gpt-4.1-nano · gpt-4.1-mini · gpt-4o',
  isBuiltIn: true,
  requiresApiKey: true,
};

export const DEEPSEEK: LLMProvider = {
  id: 'deepseek',
  name: 'DeepSeek',
  baseUrl: 'https://api.deepseek.com/chat/completions',
  extraHeaders: {},
  keyPlaceholder: 'sk-...',
  modelHint: 'deepseek-chat · deepseek-reasoner',
  isBuiltIn: true,
  requiresApiKey: true,
};

export const GROQ: LLMProvider = {
  id: 'groq',
  name: 'Groq',
  baseUrl: 'https://api.groq.com/openai/v1/chat/completions',
  extraHeaders: {},
  keyPlaceholder: 'gsk_...',
  modelHint: 'llama-3.3-70b-versatile · gemma2-9b-it',
  isBuiltIn: true,
  requiresApiKey: true,
};

export const TOGETHER: LLMProvider = {
  id: 'together',
  name: 'Together AI',
  baseUrl: 'https://api.together.xyz/v1/chat/completions',
  extraHeaders: {},
  keyPlaceholder: '...',
  modelHint:
    'meta-llama/Llama-3.3-70B-Instruct-Turbo · Qwen/Qwen2.5-72B-Instruct-Turbo',
  isBuiltIn: true,
  requiresApiKey: true,
};

export const OLLAMA: LLMProvider = {
  id: 'ollama',
  name: 'Ollama (本地)',
  baseUrl: 'http://localhost:11434/v1/chat/completions',
  extraHeaders: {},
  keyPlaceholder: '',
  modelHint: 'llama3 · qwen2.5 · gemma2 · mistral',
  isBuiltIn: true,
  requiresApiKey: false,
};

export const LM_STUDIO: LLMProvider = {
  id: 'lmstudio',
  name: 'LM Studio (本地)',
  baseUrl: 'http://localhost:1234/v1/chat/completions',
  extraHeaders: {},
  keyPlaceholder: 'lm-studio-...',
  modelHint: '',
  isBuiltIn: true,
  requiresApiKey: false,
};

export const BUILT_IN_PROVIDERS: LLMProvider[] = [
  OPENROUTER,
  OPENAI,
  DEEPSEEK,
  GROQ,
  TOGETHER,
  OLLAMA,
  LM_STUDIO,
];

/// 切換 provider 後預先填入的常用模型。本地服務回 null，由抓回的清單決定。
export function defaultModelFor(providerId: string): string | null {
  switch (providerId) {
    case 'openrouter':
      return 'deepseek/deepseek-v4-flash';
    case 'openai':
      return 'gpt-4.1-nano';
    case 'deepseek':
      return 'deepseek-chat';
    case 'groq':
      return 'llama-3.3-70b-versatile';
    case 'together':
      return 'meta-llama/Llama-3.3-70B-Instruct-Turbo';
    default:
      return null;
  }
}

export function makeCustomProvider(
  id: string,
  name: string,
  baseUrl: string
): LLMProvider {
  return {
    id,
    name,
    baseUrl,
    extraHeaders: {},
    keyPlaceholder: '...',
    modelHint: '',
    isBuiltIn: false,
    requiresApiKey: true,
  };
}

/// 把使用者隨意輸入的 LM Studio URL 統一轉成 `<origin>/v1/chat/completions`。
/// 容忍尾巴 `/`、已含 `/v1`、已含 `/v1/chat/completions` 的情況。
export function normalizeLMStudioURL(raw: string): string {
  let s = raw.trim();
  while (s.endsWith('/')) s = s.slice(0, -1);
  if (s.endsWith('/chat/completions')) return s;
  if (s.endsWith('/v1')) return s + '/chat/completions';
  return s + '/v1/chat/completions';
}

/// 解析出目前生效的 provider（LM Studio 會套用使用者自訂 base URL）。
export function resolveProvider(
  providerId: string,
  customProviders: LLMProvider[],
  lmStudioBaseUrl: string
): LLMProvider {
  const all = [...BUILT_IN_PROVIDERS, ...customProviders];
  const provider = all.find((p) => p.id === providerId) ?? OPENROUTER;
  if (provider.id === 'lmstudio' && lmStudioBaseUrl.trim()) {
    return { ...provider, baseUrl: normalizeLMStudioURL(lmStudioBaseUrl) };
  }
  return provider;
}

/// 從 chat/completions 端點推導 /models 端點。
/// ".../v1/chat/completions" → ".../v1/models"；".../chat/completions" → ".../models"
export function modelsEndpoint(baseUrl: string): string | null {
  try {
    const url = new URL(baseUrl);
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts[parts.length - 1] === 'completions') parts.pop();
    if (parts[parts.length - 1] === 'chat') parts.pop();
    parts.push('models');
    return `${url.origin}/${parts.join('/')}`;
  } catch {
    return null;
  }
}

interface OpenAIModelsResponse {
  data?: Array<{ id: string }>;
}

interface LMStudioModelsResponse {
  models?: Array<{ type: string; key: string }>;
}

interface OllamaTagsResponse {
  models?: Array<{ name: string }>;
}

/// 從任何 OpenAI 相容的 /models 端點抓可用模型清單。
export async function fetchOpenAIModels(
  provider: LLMProvider,
  apiKey: string
): Promise<string[]> {
  const endpoint = modelsEndpoint(provider.baseUrl);
  if (!endpoint) throw new Error(`無法解析 models 端點：${provider.baseUrl}`);

  const headers: Record<string, string> = { ...provider.extraHeaders };
  if (apiKey) headers.Authorization = `Bearer ${apiKey}`;

  const response = await fetch(endpoint, { method: 'GET', headers });
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`HTTP ${response.status}：${body.slice(0, 200)}`);
  }
  const decoded = (await response.json()) as OpenAIModelsResponse;
  return (decoded.data ?? []).map((m) => m.id).sort();
}

/// LM Studio 專用端點（GET /api/v1/models），會過濾掉 embedding 模型。
export async function fetchLMStudioModels(
  baseOrigin = 'http://localhost:1234',
  apiKey = ''
): Promise<string[]> {
  try {
    const headers: Record<string, string> = {};
    if (apiKey) headers.Authorization = `Bearer ${apiKey}`;
    const response = await fetch(`${baseOrigin}/api/v1/models`, {
      method: 'GET',
      headers,
    });
    if (!response.ok) return [];
    const decoded = (await response.json()) as LMStudioModelsResponse;
    return (decoded.models ?? []).filter((m) => m.type === 'llm').map((m) => m.key);
  } catch {
    return [];
  }
}

/// Ollama 專用端點（GET /api/tags）。
export async function fetchOllamaModels(
  baseOrigin = 'http://localhost:11434'
): Promise<string[]> {
  try {
    const response = await fetch(`${baseOrigin}/api/tags`, { method: 'GET' });
    if (!response.ok) return [];
    const decoded = (await response.json()) as OllamaTagsResponse;
    return (decoded.models ?? []).map((m) => m.name);
  } catch {
    return [];
  }
}

/// 依 provider 類型挑對的模型清單來源。
export async function fetchModelsForProvider(
  provider: LLMProvider,
  apiKey: string
): Promise<string[]> {
  if (provider.id === 'lmstudio') {
    const origin = new URL(provider.baseUrl).origin;
    return fetchLMStudioModels(origin, apiKey);
  }
  if (provider.id === 'ollama') {
    const origin = new URL(provider.baseUrl).origin;
    return fetchOllamaModels(origin);
  }
  return fetchOpenAIModels(provider, apiKey);
}
