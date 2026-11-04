// 設定畫面的各個分區。共用一組 SectionProps，由 SettingsView 依分頁挑選渲染。
// 分頁結構對齊原生版：一般（GeneralSection.tsx）、AI 引擎、快捷鍵（含語音模式）、字典／技能。
import { useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { emit, listen } from '@tauri-apps/api/event';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  Key,
  Sparkles,
  Keyboard,
  SlidersHorizontal,
  BookOpen,
  Cpu,
  Trash2,
  Plus,
  ArrowRight,
  Eye,
  EyeOff,
  AlertTriangle,
  Link2,
} from 'lucide-react';

import { db } from '../../services/db';
import type { AppSettings, UrlSchemeDecision } from '../../services/settings';
import {
  llmKeyAccount,
  sttKeyAccount,
  streamingKeyAccount,
  saveSecret,
  loadSecret,
  validateBaseUrl,
} from '../../services/settings';
import {
  STREAMING_PROVIDERS,
  providerMeta,
  testStreaming,
  type StreamingProvider,
} from '../../services/streamingStt';
import type { Translator } from '../../services/l10n';
import {
  BUILT_IN_PROVIDERS,
  resolveProvider,
  fetchModelsForProvider,
  makeCustomProvider,
} from '../../services/providers';
import {
  AVAILABLE_TONES,
  toneDisplayName,
  DEFAULT_CONTEXT_RULES,
  type ContextRule,
  type ToneOverride,
} from '../../services/contextRules';
import { findConflict, isBareKey } from '../../services/hotkeyConflicts';
import { useHotkeyCapture } from '../../components/hotkeyCapture';
import { detectPlatform, displayHotkey } from '../../components/platform';
import {
  GlassCard,
  Row,
  Toggle,
  TextField,
  NumberField,
  Segmented,
  Select,
  Button,
  Hint,
  SettingRow,
  SettingToggle,
  SettingDescription,
  SettingDivider,
} from '../../components/ui';
import { VoiceModesSection } from './VoiceModesSection';

export interface SectionProps {
  settings: AppSettings;
  update: (patch: Partial<AppSettings>) => void;
  tr: Translator;
  secrets: { llmKey: string; sttKey: string };
  reloadSecrets: (settings: AppSettings) => Promise<void>;
  /// 跳到其他分頁（例如「一般 → 系統」的教學／關於按鈕）
  openTab?: (tab: string) => void;
}

/// http:// 端點的提示：非本機／區網的 http 會被 llm.ts 擋下，不送金鑰
function BaseUrlWarning({ url, tr }: { url: string; tr: Translator }) {
  if (!url.trim()) return null;
  const v = validateBaseUrl(url);
  if (v === 'ok') {
    return url.trim().toLowerCase().startsWith('http://') ? <Hint>🔓 {tr('baseUrlLocalHttpNote')}</Hint> : null;
  }
  return (
    <div className="flex items-start gap-2 text-[11px] text-amber-300 leading-relaxed">
      <AlertTriangle className="w-3.5 h-3.5 flex-shrink-0 mt-0.5" />
      <span>{v === 'invalid' ? tr('baseUrlInvalid') : tr('baseUrlInsecure')}</span>
    </div>
  );
}

// ---------------------------------------------------------------- API

export function ApiSection({ settings, update, tr, secrets, reloadSecrets }: SectionProps) {
  const [showKey, setShowKey] = useState(false);
  const [keyDraft, setKeyDraft] = useState(secrets.llmKey);
  const [models, setModels] = useState<string[]>([]);
  const [fetchState, setFetchState] = useState<'idle' | 'loading' | 'error'>('idle');
  const [fetchError, setFetchError] = useState('');

  const [newProviderName, setNewProviderName] = useState('');
  const [newProviderUrl, setNewProviderUrl] = useState('');

  useEffect(() => {
    setKeyDraft(secrets.llmKey);
  }, [secrets.llmKey]);

  const provider = resolveProvider(
    settings.selectedProviderId,
    settings.customProviders,
    settings.lmStudioBaseUrl
  );

  const commitKey = async (value: string) => {
    setKeyDraft(value);
    await saveSecret(llmKeyAccount(settings.selectedProviderId), value);
    await reloadSecrets(settings);
    // 金鑰不隨 settings 廣播（它不在設定物件裡），要另外通知 overlay 重新讀，
    // 否則設定視窗改完 key，實際在錄音的 overlay 還在用舊的。
    emit('secrets-updated', {}).catch(() => {});
  };

  const doFetchModels = async () => {
    setFetchState('loading');
    setFetchError('');
    try {
      const list = await fetchModelsForProvider(provider, keyDraft);
      setModels(list);
      setFetchState('idle');
      if (list.length === 0) setFetchError('端點沒有回傳任何模型');
    } catch (e: any) {
      setFetchState('error');
      setFetchError(String(e?.message || e));
    }
  };

  const addCustomProvider = () => {
    if (!newProviderName.trim() || !newProviderUrl.trim()) return;
    const id = `custom-${Date.now()}`;
    update({
      customProviders: [
        ...settings.customProviders,
        makeCustomProvider(id, newProviderName.trim(), newProviderUrl.trim()),
      ],
      selectedProviderId: id,
    });
    setNewProviderName('');
    setNewProviderUrl('');
  };

  const allProviders = [...BUILT_IN_PROVIDERS, ...settings.customProviders];

  return (
    <div className="max-w-2xl space-y-6">
      <GlassCard title={tr('tabAi')} icon={Key}>
        <div className="space-y-2">
          <label className="text-xs text-white/50 font-medium">{tr('provider')}</label>
          <Segmented
            value={settings.selectedProviderId}
            options={allProviders.map((p) => ({ value: p.id, label: p.name }))}
            onChange={(id) => {
              update({ selectedProviderId: id });
              setModels([]);
            }}
          />
          {provider.modelHint && <Hint>建議模型：{provider.modelHint}</Hint>}
        </div>

        {settings.selectedProviderId === 'lmstudio' && (
          <div className="space-y-1.5">
            <label className="text-xs text-white/50 font-medium">LM Studio Base URL</label>
            <TextField
              value={settings.lmStudioBaseUrl}
              onChange={(v) => update({ lmStudioBaseUrl: v })}
              placeholder="http://localhost:1234"
              className="w-full"
            />
            <Hint>可填 origin、/v1 或完整端點，會自動正規化成 {provider.baseUrl}</Hint>
            <BaseUrlWarning url={settings.lmStudioBaseUrl} tr={tr} />
          </div>
        )}
        {provider.id.startsWith('custom-') && <BaseUrlWarning url={provider.baseUrl} tr={tr} />}

        {provider.requiresApiKey && (
          <div className="space-y-1.5">
            <label className="text-xs text-white/50 font-medium">
              {tr('apiKey')}（{provider.keyPlaceholder || 'API Key'}）
            </label>
            <div className="relative">
              <input
                type={showKey ? 'text' : 'password'}
                value={keyDraft}
                onChange={(e) => setKeyDraft(e.target.value)}
                onBlur={(e) => commitKey(e.target.value)}
                placeholder={provider.keyPlaceholder}
                className="w-full bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2.5 text-sm font-mono text-emerald-400 focus:outline-none focus:border-emerald-500/50"
              />
              <button
                type="button"
                onClick={() => setShowKey(!showKey)}
                className="absolute right-3 top-3 text-white/40 hover:text-white cursor-pointer"
              >
                {showKey ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
              </button>
            </div>
            <Hint>🔒 {tr('apiKeyStoredSecurely')}</Hint>
          </div>
        )}

        <div className="space-y-1.5">
          <div className="flex items-center justify-between">
            <label className="text-xs text-white/50 font-medium">{tr('model')}</label>
            <Button onClick={doFetchModels} disabled={fetchState === 'loading'}>
              {fetchState === 'loading' ? '抓取中…' : tr('fetchModels')}
            </Button>
          </div>
          {models.length > 0 ? (
            <Select
              value={settings.selectedModel}
              options={models.map((m) => ({ value: m, label: m }))}
              onChange={(v) => update({ selectedModel: v })}
              className="w-full"
            />
          ) : (
            <TextField
              value={settings.selectedModel}
              onChange={(v) => update({ selectedModel: v })}
              className="w-full"
            />
          )}
          {fetchError && <Hint>⚠️ {fetchError}</Hint>}
        </div>
      </GlassCard>

      <PromptStyleCard settings={settings} update={update} tr={tr} />

      <GlassCard title={tr('advancedParams')} icon={SlidersHorizontal}>
        <Row label={tr('advancedParams')} description={tr('advancedParamsDesc')}>
          <Toggle
            checked={settings.useCustomLLMParams}
            onChange={(v) => update({ useCustomLLMParams: v })}
          />
        </Row>
        {settings.useCustomLLMParams && (
          <div className="space-y-3">
            <Row label="max_tokens">
              <NumberField
                value={settings.llmMaxTokens}
                min={64}
                max={128000}
                step={64}
                onChange={(v) => update({ llmMaxTokens: Math.round(v) })}
              />
            </Row>
            <Row label="top_p">
              <NumberField
                value={settings.llmTopP}
                min={0}
                max={1}
                step={0.05}
                onChange={(v) => update({ llmTopP: v })}
              />
            </Row>
            <Row label="frequency_penalty">
              <NumberField
                value={settings.llmFrequencyPenalty}
                min={-2}
                max={2}
                step={0.1}
                onChange={(v) => update({ llmFrequencyPenalty: v })}
              />
            </Row>
            <Row label="presence_penalty">
              <NumberField
                value={settings.llmPresencePenalty}
                min={-2}
                max={2}
                step={0.1}
                onChange={(v) => update({ llmPresencePenalty: v })}
              />
            </Row>
          </div>
        )}
      </GlassCard>

      <GlassCard title={tr('customProviders')} icon={Plus}>
        <div className="flex gap-2">
          <TextField
            value={newProviderName}
            onChange={setNewProviderName}
            placeholder="名稱（例如 My Proxy）"
            className="flex-1"
          />
          <TextField
            value={newProviderUrl}
            onChange={setNewProviderUrl}
            placeholder="https://.../v1/chat/completions"
            className="flex-[2]"
          />
          <Button variant="primary" onClick={addCustomProvider}>
            {tr('add')}
          </Button>
        </div>
        <BaseUrlWarning url={newProviderUrl} tr={tr} />
        {settings.customProviders.map((p) => (
          <div
            key={p.id}
            className="flex items-center justify-between p-3 bg-slate-950/60 border border-white/5 rounded-xl"
          >
            <div className="min-w-0">
              <div className="text-xs font-bold text-white/80">{p.name}</div>
              <div className="text-[10px] text-white/30 font-mono truncate">{p.baseUrl}</div>
            </div>
            <button
              type="button"
              onClick={() =>
                update({
                  customProviders: settings.customProviders.filter((x) => x.id !== p.id),
                  selectedProviderId:
                    settings.selectedProviderId === p.id
                      ? 'openrouter'
                      : settings.selectedProviderId,
                })
              }
              className="text-white/35 hover:text-red-400 p-1 cursor-pointer"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          </div>
        ))}
      </GlassCard>
    </div>
  );
}

// ---------------------------------------------------------------- 語音辨識子面板（一般 → 語音辨識）

export function AppleSpeechPanel({ settings, update, tr }: Pick<SectionProps, 'settings' | 'update' | 'tr'>) {
  const [appleAuthorized, setAppleAuthorized] = useState(false);
  const [appleError, setAppleError] = useState('');

  useEffect(() => {
    invoke<boolean>('apple_speech_authorized')
      .then(setAppleAuthorized)
      .catch(() => setAppleAuthorized(false));
  }, []);

  const requestAppleAuth = async () => {
    setAppleError('');
    try {
      await invoke('apple_speech_authorize');
      setAppleAuthorized(true);
    } catch (e: any) {
      setAppleError(String(e?.message || e));
      setAppleAuthorized(false);
    }
  };

  return (
    <div className="flex flex-col space-y-3 bg-slate-950/50 border border-white/10 rounded-xl p-4">
      <SettingDescription>{tr('sttAppleDesc')}</SettingDescription>
      <SettingRow title={tr('appleSpeechLocale')}>
        <Select
          value={settings.appleSpeechLocale}
          options={[
            { value: 'zh-TW', label: '中文（台灣）' },
            { value: 'zh-CN', label: '中文（中國）' },
            { value: 'zh-HK', label: '中文（香港）' },
            { value: 'en-US', label: 'English (US)' },
            { value: 'en-GB', label: 'English (UK)' },
            { value: 'ja-JP', label: '日本語' },
            { value: 'ko-KR', label: '한국어' },
          ]}
          onChange={(v) => update({ appleSpeechLocale: v })}
        />
      </SettingRow>
      <SettingToggle
        title={tr('appleOnDeviceOnly')}
        description={tr('appleOnDeviceOnlyDesc')}
        checked={settings.appleSpeechOnDeviceOnly}
        onChange={(v) => update({ appleSpeechOnDeviceOnly: v })}
      />
      <SettingRow title={tr('appleAuthorization')}>
        {appleAuthorized ? (
          <span className="text-xs font-semibold text-emerald-400">✓ {tr('authorized')}</span>
        ) : (
          <Button variant="primary" onClick={requestAppleAuth}>
            {tr('requestAccess')}
          </Button>
        )}
      </SettingRow>
      {appleError && <Hint>⚠️ {appleError}</Hint>}
    </div>
  );
}

export function CloudSttPanel({
  settings,
  update,
  tr,
  secrets,
  reloadSecrets,
}: Pick<SectionProps, 'settings' | 'update' | 'tr' | 'secrets' | 'reloadSecrets'>) {
  const [showKey, setShowKey] = useState(false);
  const [keyDraft, setKeyDraft] = useState(secrets.sttKey);

  useEffect(() => {
    setKeyDraft(secrets.sttKey);
  }, [secrets.sttKey]);

  const commitKey = async (value: string) => {
    setKeyDraft(value);
    await saveSecret(sttKeyAccount(settings.sttBaseUrl), value);
    await reloadSecrets(settings);
    emit('secrets-updated', {}).catch(() => {});
  };

  return (
    <div className="flex flex-col space-y-3 bg-slate-950/50 border border-white/10 rounded-xl p-4">
      <Segmented
        value={settings.sttBaseUrl}
        options={[
          { value: 'https://api.openai.com/v1', label: 'OpenAI whisper-1' },
          { value: 'https://api.groq.com/openai/v1', label: 'Groq whisper-large-v3' },
        ]}
        onChange={(v) =>
          update({
            sttBaseUrl: v,
            sttModel: v.includes('groq') ? 'whisper-large-v3' : 'whisper-1',
          })
        }
      />
      <div className="space-y-1.5">
        <label className="text-xs text-white/50 font-medium">
          STT {tr('apiKey')}（{settings.sttBaseUrl.includes('groq') ? 'gsk_...' : 'sk-...'}）
        </label>
        <div className="relative">
          <input
            type={showKey ? 'text' : 'password'}
            value={keyDraft}
            onChange={(e) => setKeyDraft(e.target.value)}
            onBlur={(e) => commitKey(e.target.value)}
            className="w-full bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2.5 text-sm font-mono text-emerald-400 focus:outline-none focus:border-emerald-500/50"
          />
          <button
            type="button"
            onClick={() => setShowKey(!showKey)}
            title={showKey ? tr('hide') : tr('show')}
            className="absolute right-3 top-3 text-white/40 hover:text-white cursor-pointer"
          >
            {showKey ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
          </button>
        </div>
        <Hint>🔒 {tr('apiKeyStoredSecurely')}</Hint>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- 精煉風格（AI 引擎分頁內）

function PromptStyleCard({ settings, update, tr }: Pick<SectionProps, 'settings' | 'update' | 'tr'>) {
  return (
    <GlassCard title={tr('promptStyle')} icon={Sparkles}>
      <Segmented
        value={settings.promptStyle}
        options={[
          { value: 'typeless', label: tr('styleTypeless') },
          { value: 'wispr-flow', label: tr('styleWispr') },
        ]}
        onChange={(v) => update({ promptStyle: v })}
      />
      <SettingDescription>
        {settings.promptStyle === 'typeless' ? tr('styleTypelessDesc') : tr('styleWisprDesc')}
      </SettingDescription>

      <SettingDivider />

      <SettingRow title={tr('processingMode')}>
        <Segmented
          value={settings.selectedMode}
          options={[
            { value: 'dictation', label: tr('modeDictation') },
            { value: 'command', label: tr('modeCommand') },
            { value: 'edit', label: tr('modeEdit') },
          ]}
          onChange={(v) => update({ selectedMode: v })}
        />
      </SettingRow>

      <SettingRow title={tr('toneStyle')} description={tr('toneAutoDesc')}>
        <Segmented
          value={settings.toneStyle}
          options={[
            { value: 'auto', label: tr('toneAuto') },
            { value: 'formal', label: tr('toneFormal') },
            { value: 'casual', label: tr('toneCasual') },
            { value: 'very_casual', label: tr('toneVeryCasual') },
          ]}
          onChange={(v) => update({ toneStyle: v })}
        />
      </SettingRow>
    </GlassCard>
  );
}

// ---------------------------------------------------------------- 快捷鍵（主快捷鍵 + 語音模式 + saybit://）

export function HotkeySection({ settings, update, tr }: SectionProps) {
  const platform = detectPlatform();
  const capture = useHotkeyCapture<'main'>((_target, accelerator) => update({ hotkey: accelerator }));
  const recording = capture.target === 'main';

  const conflict = findConflict(settings.hotkey, platform);
  const bare = isBareKey(settings.hotkey);

  const triggerDesc: Record<string, string> = {
    toggle: tr('triggerToggleDesc'),
    hold: tr('triggerHoldDesc'),
    doubleTap: tr('triggerDoubleTapDesc'),
  };

  return (
    <div className="max-w-2xl space-y-6">
      <GlassCard title={tr('navHotkey')} icon={Keyboard}>
        <button
          type="button"
          onClick={() => (recording ? capture.cancel() : capture.start('main'))}
          title={recording ? tr('vmCancelRecordingHelp') : tr('hotkeyRecord')}
          className={`w-full px-4 py-4 rounded-xl border text-center font-mono text-sm transition-all cursor-pointer ${
            recording
              ? 'bg-emerald-500/10 border-emerald-500/50 text-emerald-300 animate-pulse'
              : 'bg-slate-950/80 border-white/10 text-white hover:border-white/25'
          }`}
        >
          {recording
            ? tr('vmPressHotkey', { n: capture.remaining })
            : displayHotkey(settings.hotkey, platform) || tr('hotkeyRecord')}
        </button>
        <SettingDescription>{recording && capture.needsModifier ? tr('vmNeedsModifier') : tr('hotkeyRecordingHint')}</SettingDescription>

        {(conflict || bare) && (
          <div className="flex items-start gap-2 p-3 rounded-xl bg-amber-500/10 border border-amber-500/25">
            <AlertTriangle className="w-4 h-4 text-amber-400 flex-shrink-0 mt-0.5" />
            <div className="text-[11px] text-amber-200/90 leading-relaxed">
              {conflict && (
                <div>
                  {tr('hotkeyConflict')}：<b>{conflict.name}</b>
                </div>
              )}
              {bare && <div>{tr('hotkeyBareWarning')}</div>}
            </div>
          </div>
        )}

        <SettingDivider />

        <SettingRow title={tr('hotkeyTriggerMode')} description={triggerDesc[settings.hotkeyTriggerMode]}>
          <Select
            value={settings.hotkeyTriggerMode}
            options={[
              { value: 'toggle', label: tr('triggerToggle') },
              { value: 'hold', label: tr('triggerHold') },
              { value: 'doubleTap', label: tr('triggerDoubleTap') },
            ]}
            onChange={(v) => update({ hotkeyTriggerMode: v })}
            className="max-w-xs"
          />
        </SettingRow>
      </GlassCard>

      <VoiceModesSection settings={settings} update={update} tr={tr} />

      <GlassCard title={tr('vmExternalTrigger')} icon={Link2}>
        <pre className="text-xs font-mono text-white/60 leading-relaxed whitespace-pre-wrap select-text bg-slate-950/50 border border-white/5 rounded-xl p-3">
          {tr('vmUrlHelp')}
        </pre>
        <SettingRow title={tr('urlDecisionTitle')} description={tr('urlDecisionDesc')}>
          <Segmented<UrlSchemeDecision>
            value={settings.urlSchemeDecision}
            options={[
              { value: 'ask', label: tr('urlDecisionAsk') },
              { value: 'allow', label: tr('urlDecisionAllow') },
              { value: 'deny', label: tr('urlDecisionDeny') },
            ]}
            onChange={(v) => update({ urlSchemeDecision: v })}
          />
        </SettingRow>
      </GlassCard>
    </div>
  );
}

// ---------------------------------------------------------------- 情境規則

/// 嵌在「一般 → AI 理解」裡展開的規則編輯器（原生版是 sheet）
export function ContextRulesEditor({ settings, update, tr }: Pick<SectionProps, 'settings' | 'update' | 'tr'>) {
  const [newApp, setNewApp] = useState('');

  const updateRule = (id: string, patch: Partial<ContextRule>) => {
    update({
      contextRules: settings.contextRules.map((r) => (r.id === id ? { ...r, ...patch } : r)),
    });
  };

  const addRule = () => {
    const identifier = newApp.trim().toLowerCase();
    if (!identifier) return;
    if (settings.contextRules.some((r) => r.appIdentifier === identifier)) return;
    update({
      contextRules: [
        ...settings.contextRules,
        {
          id: `rule-${Date.now()}`,
          appIdentifier: identifier,
          toneOverride: 'auto',
          additionalPrompt: null,
          isEnabled: true,
        },
      ],
    });
    setNewApp('');
  };

  return (
    <div className="space-y-3">
        <SettingDescription>{tr('contextRulesDesc')}</SettingDescription>

        <div className="flex gap-2">
          <TextField
            value={newApp}
            onChange={setNewApp}
            placeholder={`${tr('appIdentifier')}（slack / cursor / gmail …）`}
            className="flex-1"
          />
          <Button variant="primary" onClick={addRule}>
            {tr('addRule')}
          </Button>
          <Button onClick={() => update({ contextRules: DEFAULT_CONTEXT_RULES })}>
            {tr('reset')}
          </Button>
        </div>

        <div className="space-y-2">
          {settings.contextRules.map((rule) => (
            <div
              key={rule.id}
              className="p-3 bg-slate-950/60 border border-white/5 rounded-xl space-y-2"
            >
              <div className="flex items-center gap-3">
                <Toggle
                  checked={rule.isEnabled}
                  onChange={(v) => updateRule(rule.id, { isEnabled: v })}
                />
                <span className="text-xs font-mono text-white/80 w-32 truncate">
                  {rule.appIdentifier}
                </span>
                <Select
                  value={(rule.toneOverride ?? 'auto') as ToneOverride}
                  options={AVAILABLE_TONES.map((tone) => ({
                    value: tone,
                    label: toneDisplayName(tone),
                  }))}
                  onChange={(v) => updateRule(rule.id, { toneOverride: v })}
                />
                <input
                  type="text"
                  value={rule.additionalPrompt ?? ''}
                  onChange={(e) =>
                    updateRule(rule.id, { additionalPrompt: e.target.value || null })
                  }
                  placeholder={tr('additionalPrompt')}
                  className="flex-1 bg-slate-950 border border-white/10 rounded-lg px-3 py-1.5 text-xs focus:outline-none focus:border-emerald-500/50"
                />
                <button
                  type="button"
                  onClick={() =>
                    update({
                      contextRules: settings.contextRules.filter((r) => r.id !== rule.id),
                    })
                  }
                  className="text-white/35 hover:text-red-400 p-1 cursor-pointer"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            </div>
          ))}
        </div>
        {settings.contextRules.length === 0 && <SettingDescription>{tr('contextRulesEmpty')}</SettingDescription>}
    </div>
  );
}

// ---------------------------------------------------------------- 字典

export function DictionarySection({ tr }: SectionProps) {
  const dictionary = useLiveQuery(() => db.dictionary.toArray()) || [];
  const [word, setWord] = useState('');
  const [replacement, setReplacement] = useState('');

  const add = async () => {
    if (!word.trim() || !replacement.trim()) return;
    await db.dictionary.add({ word: word.trim(), replacement: replacement.trim() });
    setWord('');
    setReplacement('');
  };

  return (
    <div className="max-w-2xl space-y-6">
      <GlassCard title={tr('navDictionary')} icon={BookOpen}>
        <SettingDescription>{tr('dictDesc')}</SettingDescription>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            add();
          }}
          className="flex gap-3 items-center"
        >
          <TextField value={word} onChange={setWord} placeholder={`${tr('dictOriginalTerm')}（wifi）`} className="flex-1" />
          <ArrowRight className="w-4 h-4 text-white/30 flex-shrink-0" />
          <TextField
            value={replacement}
            onChange={setReplacement}
            placeholder={`${tr('dictPreferredForm')}（Wi-Fi）`}
            className="flex-1"
          />
          <Button variant="primary" onClick={add}>
            {tr('add')}
          </Button>
        </form>

        <div className="grid grid-cols-2 gap-3">
          {dictionary.map((entry) => (
            <div
              key={entry.id}
              className="flex items-center justify-between p-3 bg-slate-950/60 border border-white/5 rounded-xl"
            >
              <div className="flex items-center space-x-2 text-xs min-w-0">
                <span className="text-white/40 truncate max-w-[80px] font-mono">{entry.word}</span>
                <ArrowRight className="w-3.5 h-3.5 text-emerald-400 flex-shrink-0" />
                <span className="text-white font-bold truncate max-w-[120px]">
                  {entry.replacement}
                </span>
              </div>
              <button
                type="button"
                onClick={() => db.dictionary.delete(entry.id!)}
                className="text-white/35 hover:text-red-400 p-1 cursor-pointer"
              >
                <Trash2 className="w-3.5 h-3.5" />
              </button>
            </div>
          ))}
        </div>
        {dictionary.length === 0 && <SettingDescription>{tr('dictEmpty')}</SettingDescription>}
      </GlassCard>
    </div>
  );
}

// ---------------------------------------------------------------- 技能

export function SkillsSection({ tr }: SectionProps) {
  const skills = useLiveQuery(() => db.skills.toArray()) || [];
  const [trigger, setTrigger] = useState('');
  const [prompt, setPrompt] = useState('');

  const add = async () => {
    if (!trigger.trim() || !prompt.trim()) return;
    await db.skills.add({ triggerWord: trigger.trim(), prompt: prompt.trim() });
    setTrigger('');
    setPrompt('');
  };

  return (
    <div className="max-w-2xl space-y-6">
      <GlassCard title={tr('navSkills')} icon={Cpu}>
        <SettingDescription>{tr('skillDesc')}</SettingDescription>
        <div className="flex flex-col gap-3">
          <div className="flex gap-3">
            <TextField
              value={trigger}
              onChange={setTrigger}
              placeholder={tr('skillTriggerWord')}
              className="w-1/3"
            />
            <TextField
              value={prompt}
              onChange={setPrompt}
              placeholder={tr('skillPromptInstruction')}
              className="flex-1"
            />
          </div>
          <Button variant="primary" onClick={add}>
            {tr('add')}
          </Button>
        </div>

        <div className="space-y-3">
          {skills.map((skill) => (
            <div
              key={skill.id}
              className="flex items-start justify-between p-4 bg-slate-950/60 border border-white/5 rounded-xl"
            >
              <div className="space-y-1.5 max-w-[90%]">
                <span className="px-2 py-0.5 bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 text-[10px] font-bold rounded-full">
                  {skill.triggerWord}
                </span>
                <p className="text-xs text-white/70 leading-relaxed">{skill.prompt}</p>
              </div>
              <button
                type="button"
                onClick={() => db.skills.delete(skill.id!)}
                className="text-white/35 hover:text-red-400 p-1 cursor-pointer self-center"
              >
                <Trash2 className="w-4 h-4" />
              </button>
            </div>
          ))}
        </div>
        {skills.length === 0 && <SettingDescription>{tr('skillEmpty')}</SettingDescription>}
      </GlassCard>
    </div>
  );
}

// ---------------------------------------------------------------- 字典／技能分頁

export function DictionarySkillsSection(props: SectionProps) {
  return (
    <div className="max-w-2xl space-y-6">
      <DictionarySection {...props} />
      <SkillsSection {...props} />
    </div>
  );
}

// ---------------------------------------------------------------- 本地模型面板

export function LocalSttModelPanel() {
  const [status, setStatus] = useState<{ present: boolean; sizeBytes: number } | null>(null);
  const [downloading, setDownloading] = useState(false);
  const [progress, setProgress] = useState<{ downloaded: number; total: number } | null>(null);
  const [error, setError] = useState('');

  const refresh = () => {
    invoke<{ present: boolean; sizeBytes: number }>('local_stt_status')
      .then(setStatus)
      .catch((e) => setError(String(e)));
  };

  useEffect(() => {
    refresh();
    const unlisten = listen<{ downloaded: number; total: number; done?: boolean }>(
      'stt-model-progress',
      (event) => {
        setProgress(event.payload);
        if (event.payload.done) {
          setDownloading(false);
          refresh();
        }
      }
    );
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const startDownload = async () => {
    setError('');
    setDownloading(true);
    try {
      await invoke('download_stt_model');
      refresh();
    } catch (e) {
      setError(String(e));
    } finally {
      setDownloading(false);
    }
  };

  const fmtMB = (b: number) => `${Math.round(b / 1024 / 1024)}MB`;
  const pct =
    progress && progress.total > 0
      ? Math.round((progress.downloaded / progress.total) * 100)
      : 0;

  return (
    <div className="flex flex-col space-y-2 bg-slate-950/50 border border-white/10 rounded-xl p-4">
      <div className="flex items-center justify-between">
        <span className="text-xs font-medium text-white/70">
          whisper large-v3-turbo (q5_0)・約 574MB・完全離線
        </span>
        {status?.present ? (
          <span className="text-xs font-semibold text-emerald-400">
            ✓ 已就緒（{fmtMB(status.sizeBytes)}）
          </span>
        ) : downloading ? (
          <span className="text-xs text-amber-300">下載中 {pct}%</span>
        ) : (
          <Button variant="primary" onClick={startDownload}>
            下載模型
          </Button>
        )}
      </div>
      {downloading && progress && (
        <div className="w-full h-1.5 bg-white/5 rounded-full overflow-hidden">
          <div
            className="h-full bg-emerald-500 transition-all duration-200"
            style={{ width: `${pct}%` }}
          />
        </div>
      )}
      {error && <p className="text-[11px] text-red-400">{error}</p>}
      <Hint>首次轉錄會載入模型（幾秒），之後常駐記憶體。無需 API key、資料不出機器。</Hint>
    </div>
  );
}


// ---------------------------------------------------------------- 串流辨識設定

export function StreamingPanel({
  settings,
  update,
  tr,
}: Pick<SectionProps, 'settings' | 'update' | 'tr'>) {
  const [keyDraft, setKeyDraft] = useState('');
  const [showKey, setShowKey] = useState(false);
  const [testState, setTestState] = useState<'idle' | 'testing'>('idle');
  const [testResult, setTestResult] = useState('');

  const meta = providerMeta(settings.streamingProvider);
  const account = streamingKeyAccount(settings.streamingProvider);

  // 換服務商就換一把金鑰
  useEffect(() => {
    loadSecret(account).then(setKeyDraft);
  }, [account]);

  const commitKey = async (value: string) => {
    setKeyDraft(value);
    await saveSecret(account, value);
    emit('secrets-updated', {}).catch(() => {});
  };

  const runTest = async () => {
    setTestState('testing');
    setTestResult('');
    try {
      const message = await testStreaming({
        provider: settings.streamingProvider,
        endpoint: settings.streamingEndpoint,
        apiKey: keyDraft,
        appId: settings.streamingAppId,
        model: settings.streamingModel,
      });
      setTestResult(`✓ ${message}`);
    } catch (e: any) {
      setTestResult(`✗ ${String(e?.message || e)}`);
    } finally {
      setTestState('idle');
    }
  };

  return (
    <div className="flex flex-col space-y-3 bg-slate-950/50 border border-white/10 rounded-xl p-4">
      <Hint>{tr('sttStreamingDesc')}</Hint>
      <Hint>{tr('streamingUntested')}</Hint>

      <Row label={tr('streamingProvider')}>
        <Select
          value={settings.streamingProvider}
          options={STREAMING_PROVIDERS.map((p) => ({ value: p.id, label: p.name }))}
          onChange={(v) =>
            update({
              streamingProvider: v as StreamingProvider,
              // 換家就把端點與模型帶回該家的預設，避免沿用上一家的值
              streamingEndpoint: '',
              streamingModel: providerMeta(v as StreamingProvider).defaultModel,
            })
          }
          className="max-w-sm"
        />
      </Row>

      <Hint>{meta.hint}</Hint>

      <div className="space-y-1.5">
        <label className="text-xs text-white/50 font-medium">{tr('streamingEndpoint')}</label>
        <TextField
          value={settings.streamingEndpoint}
          onChange={(v) => update({ streamingEndpoint: v })}
          placeholder={meta.defaultEndpoint}
          className="w-full"
        />
        <Hint>留空即使用預設：{meta.defaultEndpoint}</Hint>
      </div>

      {meta.needsAppId && (
        <div className="space-y-1.5">
          <label className="text-xs text-white/50 font-medium">appId</label>
          <TextField
            value={settings.streamingAppId}
            onChange={(v) => update({ streamingAppId: v })}
            className="w-full"
          />
        </div>
      )}

      {meta.needsModel && (
        <div className="space-y-1.5">
          <label className="text-xs text-white/50 font-medium">{tr('model')}</label>
          <TextField
            value={settings.streamingModel}
            onChange={(v) => update({ streamingModel: v })}
            placeholder={meta.defaultModel}
            className="w-full"
          />
        </div>
      )}

      <div className="space-y-1.5">
        <label className="text-xs text-white/50 font-medium">{tr('apiKey')}</label>
        <div className="relative">
          <input
            type={showKey ? 'text' : 'password'}
            value={keyDraft}
            onChange={(e) => setKeyDraft(e.target.value)}
            onBlur={(e) => commitKey(e.target.value)}
            className="w-full bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2.5 text-sm font-mono text-emerald-400 focus:outline-none focus:border-emerald-500/50"
          />
          <button
            type="button"
            onClick={() => setShowKey(!showKey)}
            className="absolute right-3 top-3 text-white/40 hover:text-white cursor-pointer"
          >
            {showKey ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
          </button>
        </div>
        <Hint>🔒 {tr('apiKeyStoredSecurely')}</Hint>
      </div>

      <div className="flex items-center gap-3">
        <Button variant="primary" onClick={runTest} disabled={testState === 'testing'}>
          {testState === 'testing' ? '連線中…' : tr('testConnection')}
        </Button>
        {testResult && (
          <span
            className={`text-xs font-medium ${
              testResult.startsWith('✓') ? 'text-emerald-400' : 'text-red-400'
            }`}
          >
            {testResult}
          </span>
        )}
      </div>
    </div>
  );
}
