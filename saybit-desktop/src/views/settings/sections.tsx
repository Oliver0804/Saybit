// 設定畫面的各個分區。共用一組 SectionProps，由 SettingsView 依分頁挑選渲染。
import { useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { emit, listen } from '@tauri-apps/api/event';
import { enable as enableAutostart, disable as disableAutostart, isEnabled as isAutostartEnabled } from '@tauri-apps/plugin-autostart';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  Key,
  Volume2,
  Sparkles,
  Keyboard,
  ArrowRightLeft,
  SlidersHorizontal,
  Layers,
  BookOpen,
  Cpu,
  Trash2,
  Plus,
  ArrowRight,
  Eye,
  EyeOff,
  AlertTriangle,
} from 'lucide-react';

import { db } from '../../services/db';
import type { AppSettings } from '../../services/settings';
import {
  llmKeyAccount,
  sttKeyAccount,
  streamingKeyAccount,
  saveSecret,
  loadSecret,
} from '../../services/settings';
import {
  STREAMING_PROVIDERS,
  providerMeta,
  testStreaming,
  type StreamingProvider,
} from '../../services/streamingStt';
import type { L10nKey } from '../../services/l10n';
import { APP_LANGUAGES } from '../../services/l10n';
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
import { listInputDevices, AudioChain } from '../../services/audioChain';
import { findConflict, isBareKey } from '../../services/hotkeyConflicts';
import {
  GlassCard,
  Row,
  Toggle,
  TextField,
  NumberField,
  Segmented,
  Select,
  Slider,
  Button,
  Hint,
} from '../../components/ui';

export interface SectionProps {
  settings: AppSettings;
  update: (patch: Partial<AppSettings>) => void;
  tr: (key: L10nKey) => string;
  secrets: { llmKey: string; sttKey: string };
  reloadSecrets: (settings: AppSettings) => Promise<void>;
}

// ---------------------------------------------------------------- 一般

export function GeneralSection({ settings, update, tr }: SectionProps) {
  const [autostartError, setAutostartError] = useState('');

  // 開機自啟的真實狀態在 OS 那邊，掛載時對齊一次，避免設定檔跟系統不同步
  useEffect(() => {
    isAutostartEnabled()
      .then((enabled) => {
        if (enabled !== settings.launchAtLogin) update({ launchAtLogin: enabled });
      })
      .catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const toggleAutostart = async (value: boolean) => {
    setAutostartError('');
    try {
      if (value) await enableAutostart();
      else await disableAutostart();
      update({ launchAtLogin: value });
    } catch (e: any) {
      setAutostartError(String(e?.message || e));
    }
  };

  return (
    <div className="max-w-2xl space-y-6">
      <GlassCard title={tr('navGeneral')} icon={SlidersHorizontal}>
        <Row label={tr('appLanguage')}>
          <Select
            value={settings.appLanguage}
            options={APP_LANGUAGES.map((l) => ({ value: l.id, label: l.displayName }))}
            onChange={(value) => update({ appLanguage: value })}
          />
        </Row>

        <Row label={tr('launchAtLogin')} description={tr('launchAtLoginDesc')}>
          <Toggle checked={settings.launchAtLogin} onChange={toggleAutostart} />
        </Row>
        {autostartError && <Hint>⚠️ {autostartError}</Hint>}

        <Row label={tr('soundFeedback')} description={tr('soundFeedbackDesc')}>
          <Toggle
            checked={settings.enableSoundFeedback}
            onChange={(v) => update({ enableSoundFeedback: v })}
          />
        </Row>

        <Row label={tr('capsuleScale')}>
          <Slider
            value={settings.capsuleScale}
            min={0.6}
            max={2}
            step={0.1}
            suffix="×"
            onChange={(v) => update({ capsuleScale: v })}
          />
        </Row>
      </GlassCard>

      <GlassCard title={tr('historyRetention')} icon={Layers}>
        <Row label={tr('historyRetention')}>
          <Toggle
            checked={settings.enableHistoryAutoCleanup}
            onChange={(v) => update({ enableHistoryAutoCleanup: v })}
          />
        </Row>
        {settings.enableHistoryAutoCleanup && (
          <Row label={tr('historyRetentionDays')}>
            <NumberField
              value={settings.historyRetentionDays}
              min={1}
              max={3650}
              onChange={(v) => update({ historyRetentionDays: Math.round(v) })}
            />
          </Row>
        )}
        <Row label={tr('autoUpdateCheck')}>
          <Toggle
            checked={settings.enableAutoUpdateCheck}
            onChange={(v) => update({ enableAutoUpdateCheck: v })}
          />
        </Row>
        {settings.availableUpdateTag && (
          <Hint>
            🎉 {tr('updateAvailable')}：{settings.availableUpdateTag}
            <a
              href={settings.availableUpdateUrl}
              target="_blank"
              rel="noreferrer"
              className="text-emerald-300 underline"
            >
              Release Notes
            </a>
          </Hint>
        )}
      </GlassCard>
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
      <GlassCard title={tr('navApi')} icon={Key}>
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
          </div>
        )}

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

// ---------------------------------------------------------------- 語音輸入

export function SpeechSection({ settings, update, tr, secrets, reloadSecrets }: SectionProps) {
  const [devices, setDevices] = useState<MediaDeviceInfo[]>([]);
  const [showKey, setShowKey] = useState(false);
  const [keyDraft, setKeyDraft] = useState(secrets.sttKey);
  const [testLevel, setTestLevel] = useState<number | null>(null);
  const [appleSupported, setAppleSupported] = useState(false);
  const [appleAuthorized, setAppleAuthorized] = useState(false);
  const [appleError, setAppleError] = useState('');

  useEffect(() => {
    setKeyDraft(secrets.sttKey);
  }, [secrets.sttKey]);

  useEffect(() => {
    invoke<boolean>('apple_speech_supported')
      .then(setAppleSupported)
      .catch(() => setAppleSupported(false));
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

  useEffect(() => {
    listInputDevices().then(setDevices);
  }, []);

  const commitKey = async (value: string) => {
    setKeyDraft(value);
    await saveSecret(sttKeyAccount(settings.sttBaseUrl), value);
    await reloadSecrets(settings);
    emit('secrets-updated', {}).catch(() => {});
  };

  // 麥克風測試：開一條臨時鏈量 3 秒峰值，量完立刻釋放
  const runMicTest = async () => {
    const chain = new AudioChain();
    try {
      await chain.start({
        deviceId: settings.selectedInputDeviceId,
        echoCancellation: settings.enableEchoCancellation,
        bandpass: settings.enableVoiceBandpass,
        preBufferSeconds: 0,
      });
      let peak = 0;
      const started = Date.now();
      const tick = () => {
        peak = Math.max(peak, chain.currentLevel(settings.micSensitivity));
        setTestLevel(peak);
        if (Date.now() - started < 3000) requestAnimationFrame(tick);
        else chain.stop();
      };
      requestAnimationFrame(tick);
    } catch (e: any) {
      setTestLevel(-1);
      chain.stop();
    }
  };

  return (
    <div className="max-w-2xl space-y-6">
      <GlassCard title={tr('sttEngine')} icon={Volume2}>
        <Segmented
          value={settings.sttEngine}
          options={[
            { value: 'local', label: tr('sttLocal') },
            {
              value: 'apple',
              label: appleSupported ? tr('sttApple') : `${tr('sttApple')}（${tr('unsupportedPlatform')}）`,
              disabled: !appleSupported,
            },
            { value: 'streaming', label: tr('sttStreaming') },
            { value: 'cloud', label: tr('sttCloud') },
          ]}
          onChange={(v) => update({ sttEngine: v })}
        />

        {settings.sttEngine === 'local' && <LocalSttModelPanel />}

        {settings.sttEngine === 'apple' && (
          <div className="flex flex-col space-y-3 bg-slate-950/50 border border-white/10 rounded-xl p-4">
            <Hint>{tr('sttAppleDesc')}</Hint>

            <Row label={tr('appleSpeechLocale')}>
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
            </Row>

            <Row label={tr('appleOnDeviceOnly')} description={tr('appleOnDeviceOnlyDesc')}>
              <Toggle
                checked={settings.appleSpeechOnDeviceOnly}
                onChange={(v) => update({ appleSpeechOnDeviceOnly: v })}
              />
            </Row>

            <Row label={tr('appleAuthorization')}>
              {appleAuthorized ? (
                <span className="text-xs font-semibold text-emerald-400">✓ {tr('authorized')}</span>
              ) : (
                <Button variant="primary" onClick={requestAppleAuth}>
                  {tr('requestAccess')}
                </Button>
              )}
            </Row>
            {appleError && <Hint>⚠️ {appleError}</Hint>}
          </div>
        )}

        {settings.sttEngine === 'streaming' && (
          <StreamingPanel settings={settings} update={update} tr={tr} />
        )}

        {settings.sttEngine === 'cloud' && (
          <>
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
                  className="absolute right-3 top-3 text-white/40 hover:text-white cursor-pointer"
                >
                  {showKey ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                </button>
              </div>
              <Hint>🔒 {tr('apiKeyStoredSecurely')}</Hint>
            </div>
          </>
        )}
      </GlassCard>

      <GlassCard title={tr('inputDevice')} icon={Volume2}>
        <Row label={tr('inputDevice')}>
          <Select
            value={settings.selectedInputDeviceId}
            options={[
              { value: '', label: tr('systemDefault') },
              ...devices.map((d) => ({
                value: d.deviceId,
                label: d.label || `裝置 ${d.deviceId.slice(0, 8)}`,
              })),
            ]}
            onChange={(v) => update({ selectedInputDeviceId: v })}
            className="max-w-xs"
          />
        </Row>

        <Row label={tr('micSensitivity')}>
          <Slider
            value={settings.micSensitivity}
            min={0.5}
            max={5}
            step={0.1}
            suffix="×"
            onChange={(v) => update({ micSensitivity: v })}
          />
        </Row>

        <Row label={tr('micTest')}>
          <div className="flex items-center gap-3">
            {testLevel !== null && testLevel >= 0 && (
              <div className="w-24 h-2 bg-slate-950 rounded-full overflow-hidden border border-white/5">
                <div
                  className="h-full bg-emerald-500"
                  style={{ width: `${Math.min(100, testLevel * 100)}%` }}
                />
              </div>
            )}
            {testLevel === -1 && <span className="text-[11px] text-red-400">開啟失敗</span>}
            <Button onClick={runMicTest}>{tr('test')}</Button>
          </div>
        </Row>

        <Row label={tr('voiceBandpass')} description={tr('voiceBandpassDesc')}>
          <Toggle
            checked={settings.enableVoiceBandpass}
            onChange={(v) => update({ enableVoiceBandpass: v })}
          />
        </Row>

        <Row label={tr('echoCancellation')} description={tr('echoCancellationDesc')}>
          <Toggle
            checked={settings.enableEchoCancellation}
            onChange={(v) => update({ enableEchoCancellation: v })}
          />
        </Row>

        <Row label={tr('preBuffer')} description={tr('preBufferDesc')}>
          <Slider
            value={settings.preBufferSeconds}
            min={0}
            max={3}
            step={0.1}
            suffix="s"
            onChange={(v) => update({ preBufferSeconds: v })}
          />
        </Row>
      </GlassCard>

      <GlassCard title={tr('autoStop')} icon={Volume2}>
        <Row label={tr('autoStop')}>
          <Toggle
            checked={settings.enableAutoStop}
            onChange={(v) => update({ enableAutoStop: v })}
          />
        </Row>
        {settings.enableAutoStop && (
          <Row label={tr('silenceTimeout')}>
            <NumberField
              value={settings.silenceTimeout}
              min={0.5}
              max={10}
              step={0.5}
              onChange={(v) => update({ silenceTimeout: v })}
            />
          </Row>
        )}
      </GlassCard>
    </div>
  );
}

// ---------------------------------------------------------------- 精煉風格

export function PromptSection({ settings, update, tr }: SectionProps) {
  const [actionIntentsSupported, setActionIntentsSupported] = useState(false);

  useEffect(() => {
    invoke<boolean>('action_intents_supported')
      .then(setActionIntentsSupported)
      .catch(() => setActionIntentsSupported(false));
  }, []);

  return (
    <div className="max-w-2xl space-y-6">
      <GlassCard title={tr('promptStyle')} icon={Sparkles}>
        <Segmented
          value={settings.promptStyle}
          options={[
            { value: 'typeless', label: tr('styleTypeless') },
            { value: 'wispr-flow', label: tr('styleWispr') },
          ]}
          onChange={(v) => update({ promptStyle: v })}
        />
        <Hint>
          智慧模式偏重自然語意整理；工程師風格會辨識 camelCase／CLI 指令並自動修正技術名詞。
        </Hint>

        <Row label={tr('processingMode')}>
          <Segmented
            value={settings.selectedMode}
            options={[
              { value: 'dictation', label: tr('modeDictation') },
              { value: 'command', label: tr('modeCommand') },
              { value: 'edit', label: tr('modeEdit') },
            ]}
            onChange={(v) => update({ selectedMode: v })}
          />
        </Row>

        <Row label={tr('toneStyle')}>
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
        </Row>
      </GlassCard>

      <GlassCard title={tr('outputLanguage')} icon={Sparkles}>
        <Row label={tr('autoLanguageDetection')}>
          <Toggle
            checked={settings.enableAutoLanguageDetection}
            onChange={(v) => update({ enableAutoLanguageDetection: v })}
          />
        </Row>
        {!settings.enableAutoLanguageDetection && (
          <Row label={tr('outputLanguage')}>
            <Select
              value={settings.languagePreference}
              options={[
                { value: 'zh-TW', label: '繁體中文' },
                { value: 'zh-CN', label: '简体中文' },
                { value: 'en', label: 'English' },
                { value: 'ja', label: '日本語' },
                { value: 'ko', label: '한국어' },
              ]}
              onChange={(v) => update({ languagePreference: v })}
            />
          </Row>
        )}
        <Row label="Whisper 語言">
          <Select
            value={settings.whisperLanguage}
            options={[
              { value: 'zh', label: '中文' },
              { value: 'en', label: 'English' },
              { value: 'ja', label: '日本語' },
              { value: 'ko', label: '한국어' },
            ]}
            onChange={(v) => update({ whisperLanguage: v })}
          />
        </Row>
      </GlassCard>

      <GlassCard title={tr('contextAwareness')} icon={Layers}>
        <Row label={tr('contextAwareness')} description={tr('contextAwarenessDesc')}>
          <Toggle
            checked={settings.enableContextAwareness}
            onChange={(v) => update({ enableContextAwareness: v })}
          />
        </Row>
        <Row label={tr('selectionCapture')} description={tr('selectionCaptureDesc')}>
          <Toggle
            checked={settings.enableSelectionCapture}
            onChange={(v) => update({ enableSelectionCapture: v })}
            disabled={!settings.enableContextAwareness}
          />
        </Row>
        <Row label={tr('whisperMode')} description={tr('whisperModeDesc')}>
          <Toggle
            checked={settings.enableWhisperMode}
            onChange={(v) => update({ enableWhisperMode: v })}
          />
        </Row>
        <Row
          label={tr('actionIntents')}
          description={
            actionIntentsSupported
              ? tr('actionIntentsDesc')
              : `${tr('actionIntentsDesc')}（${tr('unsupportedPlatform')}）`
          }
        >
          <Toggle
            checked={settings.enableActionIntents && actionIntentsSupported}
            onChange={(v) => update({ enableActionIntents: v })}
            disabled={!actionIntentsSupported}
          />
        </Row>
      </GlassCard>
    </div>
  );
}

// ---------------------------------------------------------------- 快捷鍵

export function HotkeySection({ settings, update, tr }: SectionProps) {
  const [recording, setRecording] = useState(false);

  const platform: 'macos' | 'windows' | 'linux' = navigator.userAgent.includes('Mac')
    ? 'macos'
    : navigator.userAgent.includes('Win')
      ? 'windows'
      : 'linux';

  const conflict = findConflict(settings.hotkey, platform);
  const bare = isBareKey(settings.hotkey);

  // 錄製模式：攔截下一個按鍵組合，轉成 Tauri 加速器字串
  useEffect(() => {
    if (!recording) return;

    const onKeyDown = (event: KeyboardEvent) => {
      event.preventDefault();
      const key = event.key;
      // 只按修飾鍵不算完成，繼續等主鍵
      if (['Control', 'Alt', 'Shift', 'Meta'].includes(key)) return;

      const parts: string[] = [];
      if (event.ctrlKey) parts.push('Ctrl');
      if (event.altKey) parts.push('Alt');
      if (event.shiftKey) parts.push('Shift');
      if (event.metaKey) parts.push('Super');

      const mainKey =
        key === ' '
          ? 'Space'
          : key.length === 1
            ? key.toUpperCase()
            : key.charAt(0).toUpperCase() + key.slice(1);
      parts.push(mainKey);

      update({ hotkey: parts.join('+') });
      setRecording(false);
    };

    window.addEventListener('keydown', onKeyDown, true);
    return () => window.removeEventListener('keydown', onKeyDown, true);
  }, [recording, update]);

  return (
    <div className="max-w-2xl space-y-6">
      <GlassCard title={tr('navHotkey')} icon={Keyboard}>
        <button
          type="button"
          onClick={() => setRecording(true)}
          className={`w-full px-4 py-4 rounded-xl border text-center font-mono text-sm transition-all cursor-pointer ${
            recording
              ? 'bg-emerald-500/10 border-emerald-500/50 text-emerald-300 animate-pulse'
              : 'bg-slate-950/80 border-white/10 text-white hover:border-white/25'
          }`}
        >
          {recording ? tr('hotkeyRecording') : settings.hotkey || tr('hotkeyRecord')}
        </button>
        <Hint>{tr('hotkeyRecord')}</Hint>

        {(conflict || bare) && (
          <div className="flex items-start gap-2 p-3 rounded-xl bg-amber-500/10 border border-amber-500/25">
            <AlertTriangle className="w-4 h-4 text-amber-400 flex-shrink-0 mt-0.5" />
            <div className="text-[11px] text-amber-200/90 leading-relaxed">
              {conflict && (
                <div>
                  {tr('hotkeyConflict')}：<b>{conflict.name}</b>
                </div>
              )}
              {bare && <div>沒有修飾鍵的單鍵快捷鍵極易誤觸，建議至少加上一個修飾鍵。</div>}
            </div>
          </div>
        )}

        <Row label={tr('hotkeyTriggerMode')}>
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
        </Row>
      </GlassCard>
    </div>
  );
}

// ---------------------------------------------------------------- 輸出與注入

export function InjectionSection({ settings, update, tr }: SectionProps) {
  return (
    <div className="max-w-2xl space-y-6">
      <GlassCard title={tr('injectionMode')} icon={ArrowRightLeft}>
        <Select
          value={settings.injectionMode}
          options={[
            { value: 'paste', label: tr('injectPaste') },
            { value: 'keypress', label: tr('injectKeypress') },
            { value: 'replace_selection', label: tr('injectReplaceSelection') },
          ]}
          onChange={(v) => update({ injectionMode: v })}
          className="max-w-sm"
        />
        <Hint>
          貼上模式最快，會短暫借用剪貼簿並在 0.5 秒後自動還原原本的內容。
          逐字輸入用於不支援貼上的視窗，但長文字會比較慢。
        </Hint>
      </GlassCard>

      <GlassCard title={tr('previewBeforeInject')} icon={Sparkles}>
        <Row label={tr('previewBeforeInject')}>
          <Toggle
            checked={settings.enablePreviewBeforeInject}
            onChange={(v) => update({ enablePreviewBeforeInject: v })}
          />
        </Row>
        {settings.enablePreviewBeforeInject && (
          <Row label={tr('previewTimeout')}>
            <NumberField
              value={settings.previewTimeout}
              min={1}
              max={15}
              step={0.5}
              onChange={(v) => update({ previewTimeout: v })}
            />
          </Row>
        )}

        <Row label={tr('smartSend')}>
          <Toggle
            checked={settings.enableSmartSend}
            onChange={(v) => update({ enableSmartSend: v })}
          />
        </Row>
        {settings.enableSmartSend && (
          <Row label={tr('smartSendDelay')}>
            <NumberField
              value={settings.smartSendDelay}
              min={1}
              max={10}
              step={1}
              onChange={(v) => update({ smartSendDelay: Math.round(v) })}
            />
          </Row>
        )}
      </GlassCard>
    </div>
  );
}

// ---------------------------------------------------------------- 情境規則

export function ContextRulesSection({ settings, update, tr }: SectionProps) {
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
    <div className="max-w-3xl space-y-6">
      <GlassCard title={tr('navContextRules')} icon={Layers}>
        <Hint>{tr('contextRulesDesc')}</Hint>

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
      </GlassCard>
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
        <Hint>
          字典同時用在兩個地方：Whisper 的 prompt 偏置（降低同音錯字），
          以及精煉階段的 personal_dictionary（統一慣用寫法）。
        </Hint>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            add();
          }}
          className="flex gap-3 items-center"
        >
          <TextField value={word} onChange={setWord} placeholder="原始詞彙（wifi）" className="flex-1" />
          <ArrowRight className="w-4 h-4 text-white/30 flex-shrink-0" />
          <TextField
            value={replacement}
            onChange={setReplacement}
            placeholder="偏好寫法（Wi-Fi）"
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
        <Hint>
          技能會出現在意圖分類器的可用清單裡；說出觸發詞時，該技能的指令會被附加到精煉 prompt。
        </Hint>
        <div className="flex flex-col gap-3">
          <div className="flex gap-3">
            <TextField
              value={trigger}
              onChange={setTrigger}
              placeholder="觸發詞（翻譯）"
              className="w-1/3"
            />
            <TextField
              value={prompt}
              onChange={setPrompt}
              placeholder="自訂引導指令"
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
      </GlassCard>
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

function StreamingPanel({
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
