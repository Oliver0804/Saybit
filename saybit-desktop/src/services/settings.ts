// Saybit 設定模型。對齊原生版 Storage/SettingsStore.swift 的欄位集合。
//
// 兩個儲存層：
//   - 一般設定 → localStorage（單一 JSON，key: saybit_settings_v2）
//   - API 金鑰 → 系統金鑰庫（Rust secret_* command）。先前是明文存在 localStorage。

import { invoke } from '@tauri-apps/api/core';
import type { LLMProvider } from './providers';
import { defaultModelFor } from './providers';
import type { ContextRule } from './contextRules';
import { DEFAULT_CONTEXT_RULES } from './contextRules';
import type { PromptStyle } from './systemPrompts';
import type { AppLanguage } from './l10n';
import type { StreamingProvider } from './streamingStt';

export type { AppLanguage };
export type ProcessingMode = 'dictation' | 'command' | 'edit';
export type ToneStyle = 'auto' | 'formal' | 'casual' | 'very_casual';
export type InjectionMode = 'paste' | 'keypress' | 'replace_selection';
export type HotkeyTriggerMode = 'toggle' | 'hold' | 'doubleTap';
/// cloud = Whisper 相容 API；local = whisper.cpp；apple = SFSpeechRecognizer（僅 macOS）；
/// streaming = WebSocket 串流辨識（阿里雲／訊飛），邊講邊辨識
export type SttEngine = 'cloud' | 'local' | 'apple' | 'streaming';

export interface AppSettings {
  // ---- LLM 服務商 ----
  selectedProviderId: string;
  customProviders: LLMProvider[];
  selectedModel: string;
  lmStudioBaseUrl: string;

  // ---- 進階 LLM 參數 ----
  useCustomLLMParams: boolean;
  llmMaxTokens: number;
  llmFrequencyPenalty: number;
  llmPresencePenalty: number;
  llmTopP: number;

  // ---- Prompt / 語言 / 語氣 ----
  promptStyle: PromptStyle;
  languagePreference: string;
  enableAutoLanguageDetection: boolean;
  toneStyle: ToneStyle;
  appLanguage: AppLanguage;

  // ---- 快捷鍵 ----
  hotkey: string;
  hotkeyTriggerMode: HotkeyTriggerMode;

  // ---- 音訊輸入 ----
  selectedInputDeviceId: string;
  micSensitivity: number;
  enableVoiceBandpass: boolean;
  enableEchoCancellation: boolean;
  preBufferSeconds: number;
  silenceTimeout: number;
  enableAutoStop: boolean;

  // ---- STT ----
  sttEngine: SttEngine;
  sttBaseUrl: string;
  sttModel: string;
  whisperLanguage: string;
  /// Apple Speech 的辨識語言（BCP-47，例如 zh-TW / en-US / ja-JP）
  appleSpeechLocale: string;
  /// 強制離線辨識：音訊不離開機器，但語言必須有本機模型
  appleSpeechOnDeviceOnly: boolean;
  /// 串流辨識設定（金鑰另外存在系統金鑰庫，不放這裡）
  streamingProvider: StreamingProvider;
  streamingEndpoint: string;
  streamingAppId: string;
  streamingModel: string;

  // ---- 處理行為 ----
  selectedMode: ProcessingMode;
  enableContextAwareness: boolean;
  enableSelectionCapture: boolean;
  enableWhisperMode: boolean;
  enableSoundFeedback: boolean;
  enableActionIntents: boolean;

  // ---- 注入 ----
  injectionMode: InjectionMode;
  enablePreviewBeforeInject: boolean;
  previewTimeout: number;
  enableSmartSend: boolean;
  smartSendDelay: number;

  // ---- 膠囊 ----
  capsuleScale: number;
  overlayPositionX: number;
  overlayPositionY: number;
  hasCustomOverlayPosition: boolean;

  // ---- 系統 ----
  launchAtLogin: boolean;
  historyRetentionDays: number;
  enableHistoryAutoCleanup: boolean;
  enableAutoUpdateCheck: boolean;
  lastUpdateCheckAt: number;
  availableUpdateTag: string;
  availableUpdateUrl: string;

  // ---- per-app 規則 ----
  contextRules: ContextRule[];

  // ---- 首次啟動 ----
  hasCompletedOnboarding: boolean;
}

export const DEFAULT_SETTINGS: AppSettings = {
  selectedProviderId: 'openrouter',
  customProviders: [],
  selectedModel: 'deepseek/deepseek-v4-flash',
  lmStudioBaseUrl: 'http://localhost:1234',

  useCustomLLMParams: false,
  llmMaxTokens: 4096,
  llmFrequencyPenalty: 0,
  llmPresencePenalty: 0,
  llmTopP: 1,

  promptStyle: 'typeless',
  languagePreference: 'zh-TW',
  enableAutoLanguageDetection: false,
  toneStyle: 'auto',
  appLanguage: 'zh-TW',

  hotkey: 'Ctrl+Alt+Space',
  hotkeyTriggerMode: 'toggle',

  selectedInputDeviceId: '',
  micSensitivity: 2.0,
  enableVoiceBandpass: true,
  enableEchoCancellation: false,
  preBufferSeconds: 1.0,
  silenceTimeout: 2.0,
  enableAutoStop: true,

  sttEngine: 'cloud',
  sttBaseUrl: 'https://api.openai.com/v1',
  sttModel: 'whisper-1',
  whisperLanguage: 'zh',
  appleSpeechLocale: 'zh-TW',
  appleSpeechOnDeviceOnly: true,
  streamingProvider: 'aliyun',
  streamingEndpoint: '',
  streamingAppId: '',
  streamingModel: 'fun-asr-realtime',

  selectedMode: 'dictation',
  enableContextAwareness: true,
  enableSelectionCapture: true,
  enableWhisperMode: false,
  enableSoundFeedback: true,
  enableActionIntents: false,

  injectionMode: 'paste',
  enablePreviewBeforeInject: false,
  previewTimeout: 3.0,
  enableSmartSend: false,
  smartSendDelay: 3.0,

  capsuleScale: 1.0,
  overlayPositionX: 0,
  overlayPositionY: 0,
  hasCustomOverlayPosition: false,

  launchAtLogin: false,
  historyRetentionDays: 30,
  enableHistoryAutoCleanup: false,
  enableAutoUpdateCheck: true,
  lastUpdateCheckAt: 0,
  availableUpdateTag: '',
  availableUpdateUrl: '',

  contextRules: DEFAULT_CONTEXT_RULES,

  hasCompletedOnboarding: false,
};

const STORAGE_KEY = 'saybit_settings_v2';

/// 從 localStorage 讀設定，缺欄位補預設值（版本升級時新增的欄位不會炸掉）。
export function loadSettings(): AppSettings {
  let stored: Partial<AppSettings> = {};
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) stored = JSON.parse(raw) as Partial<AppSettings>;
    else stored = migrateLegacySettings();
  } catch {
    stored = {};
  }

  const merged: AppSettings = { ...DEFAULT_SETTINGS, ...stored };

  // 陣列欄位若被存成非陣列（手改壞的設定檔）就回退預設，避免整個 UI 崩掉
  if (!Array.isArray(merged.customProviders)) merged.customProviders = [];
  if (!Array.isArray(merged.contextRules)) merged.contextRules = DEFAULT_CONTEXT_RULES;

  return merged;
}

export function persistSettings(settings: AppSettings): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
  } catch {
    /* 寫入失敗不阻擋主流程 */
  }
}

/// 從 0.2.x 的散裝 localStorage key 搬遷到單一 JSON。
/// 明文 API 金鑰另外由 migratePlaintextKeys() 搬進系統金鑰庫。
function migrateLegacySettings(): Partial<AppSettings> {
  const legacy: Partial<AppSettings> = {};
  const get = (k: string) => localStorage.getItem(k);

  const sttEngine = get('saybit_stt_engine');
  if (
    sttEngine === 'cloud' ||
    sttEngine === 'local' ||
    sttEngine === 'apple' ||
    sttEngine === 'streaming'
  ) {
    legacy.sttEngine = sttEngine;
  }

  const sttUrl = get('saybit_stt_url');
  if (sttUrl) legacy.sttBaseUrl = sttUrl;

  const sttModel = get('saybit_stt_model');
  if (sttModel) legacy.sttModel = sttModel;

  const llmModel = get('saybit_llm_model');
  if (llmModel) legacy.selectedModel = llmModel;

  // 舊版存的是 origin 形式的 base URL（例如 https://openrouter.ai/api/v1），
  // 新版改存完整 chat/completions 端點，所以要反推 provider。
  const llmUrl = get('saybit_llm_url');
  if (llmUrl) {
    if (llmUrl.includes('openrouter.ai')) legacy.selectedProviderId = 'openrouter';
    else if (llmUrl.includes('api.openai.com')) legacy.selectedProviderId = 'openai';
    else if (llmUrl.includes('deepseek.com')) legacy.selectedProviderId = 'deepseek';
    else if (llmUrl.includes('groq.com')) legacy.selectedProviderId = 'groq';
    else if (llmUrl.includes('together.xyz')) legacy.selectedProviderId = 'together';
    else if (llmUrl.includes('11434')) legacy.selectedProviderId = 'ollama';
    else if (llmUrl.includes('1234')) legacy.selectedProviderId = 'lmstudio';
  }

  const hotkey = get('saybit_hotkey');
  if (hotkey) legacy.hotkey = hotkey;

  const previewTimeout = get('saybit_preview_timeout');
  if (previewTimeout) legacy.previewTimeout = Number(previewTimeout);

  const smartSend = get('saybit_smart_send');
  if (smartSend !== null) legacy.enableSmartSend = smartSend === 'true';

  const contextRules = get('saybit_context_rules');
  if (contextRules) {
    try {
      const parsed = JSON.parse(contextRules);
      if (Array.isArray(parsed)) legacy.contextRules = parsed;
    } catch {
      /* 忽略壞掉的舊資料 */
    }
  }

  return legacy;
}

// ---------------------------------------------------------------- 金鑰

/// 金鑰庫帳號命名：llm.<providerId> / stt.<sttProviderId>
export function llmKeyAccount(providerId: string): string {
  return `llm.${providerId}`;
}

/// STT 供應商由 base URL 反推，讓 OpenAI 與 Groq 的 key 各自獨立保存。
export function sttProviderIdFor(baseUrl: string): string {
  if (baseUrl.includes('groq.com')) return 'groq';
  if (baseUrl.includes('api.openai.com')) return 'openai';
  return 'custom';
}

export function sttKeyAccount(baseUrl: string): string {
  return `stt.${sttProviderIdFor(baseUrl)}`;
}

/// 串流辨識的金鑰帳號，每家服務商各自獨立。
export function streamingKeyAccount(provider: string): string {
  return `streaming.${provider}`;
}

export async function loadSecret(account: string): Promise<string> {
  try {
    return await invoke<string>('secret_get', { account });
  } catch {
    return '';
  }
}

export async function saveSecret(account: string, value: string): Promise<void> {
  try {
    await invoke('secret_set', { account, value });
  } catch {
    /* 金鑰庫不可用時靜默失敗，避免擋住設定 UI */
  }
}

const MIGRATION_FLAG = 'saybit_keys_migrated_v2';

/// 把 0.2.x 明文存在 localStorage 的金鑰搬進系統金鑰庫，搬完清除明文。
export async function migratePlaintextKeys(settings: AppSettings): Promise<void> {
  if (localStorage.getItem(MIGRATION_FLAG) === 'done') return;

  const legacyStt = localStorage.getItem('saybit_stt_key');
  if (legacyStt) {
    await saveSecret(sttKeyAccount(settings.sttBaseUrl), legacyStt);
    localStorage.removeItem('saybit_stt_key');
  }

  const legacyLlm = localStorage.getItem('saybit_llm_key');
  if (legacyLlm) {
    await saveSecret(llmKeyAccount(settings.selectedProviderId), legacyLlm);
    localStorage.removeItem('saybit_llm_key');
  }

  localStorage.setItem(MIGRATION_FLAG, 'done');
}

// ---------------------------------------------------------------- 衍生值

/// 切換 provider 時預先填入的模型（本地服務回原值不動）。
export function modelAfterProviderSwitch(
  providerId: string,
  currentModel: string
): string {
  return defaultModelFor(providerId) ?? currentModel;
}
