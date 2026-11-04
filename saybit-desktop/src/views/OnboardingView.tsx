// 第一次啟動的引導：語言 → 權限 → 選 AI 方式 → API Key（只有雲端才有）→ 完成。
// 對應原生 UI/Onboarding/OnboardingView.swift（最新流程）；桌面版沒有 Apple 本機模型選項。
//
// API Key 這一步要讓完全沒碰過 API 的人也能做完：說明 Key 是什麼、三步驟怎麼拿、
// 要不要儲值、貼上後立刻測試並把錯誤翻成可行動的提示。
import { useEffect, useRef, useState } from 'react';
import { emit } from '@tauri-apps/api/event';
import { openUrl } from '@tauri-apps/plugin-opener';
import { readText } from '@tauri-apps/plugin-clipboard-manager';
import { fetch } from '@tauri-apps/plugin-http';
import {
  Globe,
  Mic,
  Accessibility,
  Cloud,
  Server,
  Check,
  CheckCircle2,
  XCircle,
  AlertTriangle,
  Eye,
  EyeOff,
  ClipboardPaste,
  Keyboard,
  Settings as SettingsIcon,
  AudioWaveform,
  CreditCard,
  Loader2,
} from 'lucide-react';

import type { AppSettings } from '../services/settings';
import { llmKeyAccount, loadSecret, saveSecret, validateBaseUrl } from '../services/settings';
import { BUILT_IN_PROVIDERS, defaultModelFor, resolveProvider, type LLMProvider } from '../services/providers';
import { humanReadableStatus } from '../services/llm';
import { APP_LANGUAGES, type L10nKey, type Translator } from '../services/l10n';
import { detectPlatform, displayHotkey } from '../components/platform';
import { Button } from '../components/ui';

interface Props {
  settings: AppSettings;
  update: (patch: Partial<AppSettings>) => void;
  reloadSecrets: (settings: AppSettings) => Promise<void>;
  tr: Translator;
  /// startTutorial = 使用者按了「繼續教學」
  onFinish: (startTutorial: boolean) => void;
}

enum Step {
  Language = 0,
  Permissions = 1,
  AiChoice = 2,
  ApiKey = 3,
  Done = 4,
}
const TOTAL_STEPS = 5;

type AiChoice = 'cloud' | 'server';
type MicState = 'granted' | 'denied' | 'prompt' | 'unknown';

const ONBOARDING_PROVIDER_IDS = ['openrouter', 'openai', 'deepseek', 'groq'];

const KEY_PORTAL: Record<string, string> = {
  openrouter: 'https://openrouter.ai/keys',
  openai: 'https://platform.openai.com/api-keys',
  deepseek: 'https://platform.deepseek.com/api_keys',
  groq: 'https://console.groq.com/keys',
  together: 'https://api.together.xyz/settings/api-keys',
};
const NEEDS_PREPAID = new Set(['openrouter', 'openai', 'deepseek']);
const BLURB: Record<string, L10nKey> = {
  openrouter: 'obBlurbOpenRouter',
  openai: 'obBlurbOpenAI',
  deepseek: 'obBlurbDeepSeek',
  groq: 'obBlurbGroq',
};

type TestResult = { ok: true } | { ok: false; message: string; hint: string | null };

/// 送一個 max_tokens=1 的請求驗證 Key（對齊原生 OpenRouterClient.testConnection）
async function testProviderKey(provider: LLMProvider, model: string, apiKey: string, tr: Translator): Promise<TestResult> {
  const validation = validateBaseUrl(provider.baseUrl);
  if (validation !== 'ok') {
    return { ok: false, message: tr(validation === 'invalid' ? 'baseUrlInvalid' : 'baseUrlInsecure'), hint: null };
  }
  let response: Response;
  try {
    response = await fetch(provider.baseUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
        ...provider.extraHeaders,
      },
      body: JSON.stringify({
        model,
        messages: [{ role: 'user', content: 'Hi' }],
        max_tokens: 1,
        temperature: 0,
        stream: false,
      }),
    });
  } catch (e: any) {
    return { ok: false, message: String(e?.message || e), hint: tr('obTestHintNetwork') };
  }
  if (response.ok) return { ok: true };
  const code = response.status;
  const hint =
    code === 401 || code === 403
      ? tr('obTestHint401')
      : code === 402
        ? tr('obTestHint402', { provider: provider.name })
        : null;
  return { ok: false, message: humanReadableStatus(code), hint };
}

async function queryMic(): Promise<MicState> {
  try {
    const status = await navigator.permissions.query({ name: 'microphone' as PermissionName });
    return status.state as MicState;
  } catch {
    return 'unknown';
  }
}

export function OnboardingView({ settings, update, reloadSecrets, tr, onFinish }: Props) {
  const platform = detectPlatform();
  const [step, setStep] = useState<Step>(Step.Language);

  // 權限
  const [micState, setMicState] = useState<MicState>('unknown');
  /// 桌面版查不到輔助使用授權，只能讓使用者自己確認
  const [accessibilityConfirmed, setAccessibilityConfirmed] = useState(false);
  const [openSettingsFailed, setOpenSettingsFailed] = useState(false);

  // AI 方式
  const [aiChoice, setAiChoice] = useState<AiChoice>(
    settings.selectedProviderId === 'ollama' || settings.selectedProviderId === 'lmstudio' ? 'server' : 'cloud'
  );

  // API Key
  const [apiKey, setApiKey] = useState('');
  const [showKey, setShowKey] = useState(false);
  const [apiKeySaved, setApiKeySaved] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<TestResult | null>(null);
  const testGenRef = useRef(0);

  const provider = resolveProvider(settings.selectedProviderId, settings.customProviders, settings.lmStudioBaseUrl);
  const onboardingProviders: LLMProvider[] = (() => {
    const list = BUILT_IN_PROVIDERS.filter((p) => ONBOARDING_PROVIDER_IDS.includes(p.id));
    // 使用者已選了其他雲端服務商（Together / 自訂）也一併列出
    if (provider.requiresApiKey && !list.some((p) => p.id === provider.id)) list.push(provider);
    return list;
  })();

  const refreshMic = () => {
    queryMic().then(setMicState);
  };

  useEffect(() => {
    refreshMic();
    const onFocus = () => refreshMic();
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, []);

  // 進到 API Key / 完成步驟時，讀回目前服務商已存的 Key
  useEffect(() => {
    if (step !== Step.ApiKey && step !== Step.Done) return;
    let cancelled = false;
    loadSecret(llmKeyAccount(settings.selectedProviderId)).then((key) => {
      if (cancelled) return;
      if (step === Step.ApiKey) setApiKey(key);
      setApiKeySaved(!!key);
    });
    return () => {
      cancelled = true;
    };
  }, [step, settings.selectedProviderId]);

  const requestMic = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      stream.getTracks().forEach((t) => t.stop());
      setMicState('granted');
    } catch {
      setMicState('denied');
      if (platform === 'macos') openPane('Privacy_Microphone');
    }
  };

  const openPane = (anchor: string) => {
    setOpenSettingsFailed(false);
    openUrl(`x-apple.systempreferences:com.apple.preference.security?${anchor}`).catch(() =>
      setOpenSettingsFailed(true)
    );
  };

  const selectProvider = (p: LLMProvider) => {
    testGenRef.current++;
    setTesting(false);
    setTestResult(null);
    // 換服務商就換成它的預設模型，否則會拿 OpenRouter 格式的模型名去打 OpenAI
    update({ selectedProviderId: p.id, selectedModel: defaultModelFor(p.id) ?? settings.selectedModel });
  };

  const selectChoice = (choice: AiChoice) => {
    setAiChoice(choice);
    if (choice === 'server') {
      if (!['ollama', 'lmstudio'].includes(settings.selectedProviderId)) {
        update({ selectedProviderId: 'ollama', selectedModel: defaultModelFor('ollama') ?? settings.selectedModel });
      }
    } else if (!onboardingProviders.some((p) => p.id === settings.selectedProviderId) || !provider.requiresApiKey) {
      const openRouter = BUILT_IN_PROVIDERS.find((p) => p.id === 'openrouter');
      if (openRouter) selectProvider(openRouter);
    }
  };

  const saveAndTest = async () => {
    const key = apiKey.trim();
    if (!key) return;
    const gen = ++testGenRef.current;
    try {
      await saveSecret(llmKeyAccount(provider.id), key);
    } catch {
      setTestResult({ ok: false, message: tr('saveFailed'), hint: null });
      return;
    }
    setApiKey(key);
    setApiKeySaved(true);
    await reloadSecrets(settings);
    emit('secrets-updated', {}).catch(() => {});

    const model = settings.selectedModel || defaultModelFor(provider.id) || '';
    if (!settings.selectedModel && model) update({ selectedModel: model });

    setTesting(true);
    setTestResult(null);
    const result = await testProviderKey(provider, model, key, tr);
    if (gen !== testGenRef.current) return; // 中途換了服務商或重按，舊結果作廢
    setTestResult(result);
    setTesting(false);
  };

  const pasteKey = async () => {
    try {
      const text = await readText();
      if (text) setApiKey(text.trim());
    } catch {
      /* 剪貼簿讀取失敗就讓使用者自己貼 */
    }
  };

  /// 自架伺服器不需要 API Key，跳過那一步
  const nextStep = () => setStep((s) => (s === Step.AiChoice && aiChoice !== 'cloud' ? Step.Done : Math.min(s + 1, Step.Done)));
  const previousStep = () => setStep((s) => (s === Step.Done && aiChoice !== 'cloud' ? Step.AiChoice : Math.max(s - 1, 0)));

  const finish = async (startTutorial: boolean) => {
    testGenRef.current++;
    const patch = { hasCompletedOnboarding: true };
    update(patch);
    await reloadSecrets({ ...settings, ...patch });
    emit('secrets-updated', {}).catch(() => {});
    onFinish(startTutorial);
  };

  return (
    <div className="flex flex-col w-full h-screen bg-slate-950 text-white">
      {/* Header */}
      <div className="flex items-center justify-between px-8 py-4 border-b border-white/5">
        <h1 className="text-lg font-semibold">{step === Step.Language ? 'Saybit' : tr('obTitle')}</h1>
        {step > Step.Language && (
          <span className="text-xs text-white/40">{tr('obStepOf', { c: step, t: TOTAL_STEPS - 1 })}</span>
        )}
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto px-8 py-6">
        <div className="max-w-xl mx-auto">
          {step === Step.Language && (
            <div className="flex flex-col items-center gap-6 pt-6">
              <Globe className="w-12 h-12 text-sky-400" />
              <p className="text-sm font-semibold text-center whitespace-pre-line">{tr('obChooseLanguage')}</p>
              <div className="w-72 space-y-2">
                {APP_LANGUAGES.map((lang) => {
                  const selected = settings.appLanguage === lang.id;
                  return (
                    <button
                      key={lang.id}
                      type="button"
                      onClick={() => update({ appLanguage: lang.id })}
                      className={`flex items-center justify-between w-full px-4 py-2.5 rounded-lg border text-sm cursor-pointer transition-colors ${
                        selected
                          ? 'bg-emerald-500/10 border-emerald-500/50'
                          : 'bg-white/[0.03] border-transparent hover:bg-white/5'
                      }`}
                    >
                      {lang.displayName}
                      {selected && <Check className="w-4 h-4 text-emerald-400" />}
                    </button>
                  );
                })}
              </div>
            </div>
          )}

          {step === Step.Permissions && (
            <div className="space-y-4">
              <h2 className="text-base font-semibold">{tr('obPermissionsTitle')}</h2>
              <p className="text-sm text-white/50 whitespace-pre-line">
                {platform === 'macos' ? tr('obPermissionsDesc') : tr('obPermissionsDescOther')}
              </p>

              <div className="space-y-3">
                <PermissionRow
                  icon={Mic}
                  title={tr('microphone')}
                  description={tr('obMicDesc')}
                  granted={micState === 'granted'}
                  actionLabel={tr('requestAccess')}
                  onAction={requestMic}
                />
                {platform === 'macos' && (
                  <PermissionRow
                    icon={Accessibility}
                    title={tr('accessibility')}
                    description={`${tr('obAccessibilityDesc')}。${tr('obAccessibilityManual')}`}
                    granted={accessibilityConfirmed}
                    actionLabel={tr('openSettings')}
                    onAction={() => openPane('Privacy_Accessibility')}
                    secondaryLabel={tr('obAccessibilityDone')}
                    onSecondary={() => setAccessibilityConfirmed(true)}
                  />
                )}
              </div>
              {openSettingsFailed && <p className="text-xs text-amber-300">{tr('openSettingsFailed')}</p>}

              <button
                type="button"
                onClick={refreshMic}
                className="text-xs text-emerald-400 hover:text-emerald-300 cursor-pointer"
              >
                {tr('obRecheckPermissions')}
              </button>
            </div>
          )}

          {step === Step.AiChoice && (
            <div className="space-y-3.5">
              <h2 className="text-base font-semibold">{tr('obAiChoiceTitle')}</h2>
              <p className="text-sm text-white/50 leading-relaxed">{tr('obAiChoiceDesc')}</p>
              <ChoiceCard
                icon={Cloud}
                title={tr('obChoiceCloudTitle')}
                description={tr('obChoiceCloudDesc')}
                selected={aiChoice === 'cloud'}
                onSelect={() => selectChoice('cloud')}
              />
              <ChoiceCard
                icon={Server}
                title={tr('obChoiceServerTitle')}
                description={tr('obChoiceServerDesc')}
                selected={aiChoice === 'server'}
                onSelect={() => selectChoice('server')}
              />
            </div>
          )}

          {step === Step.ApiKey && (
            <div className="space-y-3">
              <h2 className="text-base font-semibold">{tr('obApiKeyTitle')}</h2>
              <p className="text-sm text-white/50 leading-relaxed">{tr('obApiKeyIntro')}</p>

              <div className="text-xs text-white/40">{tr('obChooseProvider')}</div>
              <div className="flex flex-wrap gap-1.5">
                {onboardingProviders.map((p) => (
                  <button
                    key={p.id}
                    type="button"
                    onClick={() => selectProvider(p)}
                    className={`px-3 py-1 rounded-lg border text-xs cursor-pointer transition-colors ${
                      p.id === provider.id
                        ? 'bg-emerald-500/15 border-emerald-500/40 text-emerald-300'
                        : 'bg-slate-900 border-white/10 text-white/60 hover:text-white'
                    }`}
                  >
                    {p.name}
                  </button>
                ))}
              </div>
              {BLURB[provider.id] && <p className="text-xs text-white/50">{tr(BLURB[provider.id])}</p>}

              <div className="p-3 rounded-lg bg-white/[0.04] space-y-2 text-sm">
                <div className="flex items-center gap-2">
                  <StepBadge n={1} />
                  <span>{tr('obKeyStep1', { provider: provider.name })}</span>
                  {KEY_PORTAL[provider.id] && (
                    <Button onClick={() => openUrl(KEY_PORTAL[provider.id]).catch(() => {})} className="!px-2.5 !py-1">
                      {tr('obOpenKeyPage')}
                    </Button>
                  )}
                </div>
                <div className="flex items-center gap-2">
                  <StepBadge n={2} />
                  <span>{tr('obKeyStep2')}</span>
                </div>
                <div className="flex items-center gap-2">
                  <StepBadge n={3} />
                  <span>{tr('obKeyStep3')}</span>
                </div>
                {NEEDS_PREPAID.has(provider.id) && (
                  <div className="flex items-start gap-1.5 pt-1 text-xs text-white/50">
                    <CreditCard className="w-3.5 h-3.5 flex-shrink-0 mt-0.5" />
                    <span>{tr('obKeyNeedsCredit', { provider: provider.name })}</span>
                  </div>
                )}
              </div>

              <form
                className="flex items-center gap-2"
                onSubmit={(e) => {
                  e.preventDefault();
                  saveAndTest();
                }}
              >
                <input
                  type={showKey ? 'text' : 'password'}
                  value={apiKey}
                  placeholder={provider.keyPlaceholder}
                  onChange={(e) => setApiKey(e.target.value)}
                  className="flex-1 bg-slate-900 border border-white/10 rounded-lg px-3 py-2 text-sm font-mono text-emerald-400 focus:outline-none focus:border-emerald-500/50"
                />
                <IconButton label={showKey ? tr('hide') : tr('show')} onClick={() => setShowKey((v) => !v)}>
                  {showKey ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                </IconButton>
                <IconButton label={tr('obPasteFromClipboard')} onClick={pasteKey}>
                  <ClipboardPaste className="w-4 h-4" />
                </IconButton>
              </form>

              <div className="flex items-center gap-3">
                <Button variant="primary" onClick={saveAndTest} disabled={!apiKey.trim() || testing}>
                  {testing ? (
                    <span className="flex items-center gap-1.5">
                      <Loader2 className="w-3.5 h-3.5 animate-spin" /> {tr('obTesting')}
                    </span>
                  ) : (
                    tr('obSaveAndTest')
                  )}
                </Button>
                {apiKeySaved && !testResult && !testing && (
                  <span className="flex items-center gap-1 text-xs text-emerald-400">
                    <CheckCircle2 className="w-3.5 h-3.5" /> {tr('obApiKeySaved')}
                  </span>
                )}
              </div>

              {testResult && (
                <div
                  className={`p-2.5 rounded-lg space-y-1 ${testResult.ok ? 'bg-emerald-500/10' : 'bg-red-500/10'}`}
                >
                  <div
                    className={`flex items-start gap-1.5 text-sm select-text ${
                      testResult.ok ? 'text-emerald-400' : 'text-red-400'
                    }`}
                  >
                    {testResult.ok ? (
                      <CheckCircle2 className="w-4 h-4 flex-shrink-0 mt-0.5" />
                    ) : (
                      <XCircle className="w-4 h-4 flex-shrink-0 mt-0.5" />
                    )}
                    <span>{testResult.ok ? tr('obTestSuccess') : testResult.message}</span>
                  </div>
                  {!testResult.ok && testResult.hint && <p className="text-xs text-white/50">{testResult.hint}</p>}
                </div>
              )}

              <p className="text-xs text-white/40">{tr('obSkipKeyHint')}</p>
            </div>
          )}

          {step === Step.Done && (
            <div className="space-y-4">
              <h2 className="text-base font-semibold">{tr('obDoneTitle')}</h2>
              <DoneRow icon={Keyboard} text={tr('obDoneHotkey', { hotkey: displayHotkey(settings.hotkey, platform) })} />
              <DoneRow icon={SettingsIcon} text={tr('obDoneSettings')} />
              <DoneRow icon={AudioWaveform} text={tr('obDoneOffline')} />

              {aiChoice === 'cloud' && !apiKeySaved && <Warning text={tr('obDoneNoKeyWarning')} />}
              {aiChoice === 'server' && <Warning text={tr('obDoneServerHint')} />}
              {platform === 'macos' && !accessibilityConfirmed && (
                <Warning text={`${tr('accessibility')}：${tr('notSet')}`} />
              )}
              {micState === 'denied' && <Warning text={`${tr('microphone')}：${tr('notAuthorized')}`} />}
            </div>
          )}
        </div>
      </div>

      {/* Navigation */}
      <div className="flex items-center justify-between px-8 py-4 border-t border-white/5">
        <div>{step > Step.Language && <Button onClick={previousStep}>{tr('previous')}</Button>}</div>
        {step < Step.Done ? (
          <Button variant="primary" onClick={nextStep}>
            {tr('next')}
          </Button>
        ) : (
          <div className="flex gap-2.5">
            <Button variant="primary" onClick={() => finish(true)}>
              {tr('obContinueTutorial')}
            </Button>
            <Button onClick={() => finish(false)}>{tr('startUsing')}</Button>
          </div>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- 小元件

function PermissionRow({
  icon: Icon,
  title,
  description,
  granted,
  actionLabel,
  onAction,
  secondaryLabel,
  onSecondary,
}: {
  icon: React.ComponentType<{ className?: string }>;
  title: string;
  description: string;
  granted: boolean;
  actionLabel: string;
  onAction: () => void;
  secondaryLabel?: string;
  onSecondary?: () => void;
}) {
  return (
    <div className="flex items-center gap-3 p-3 rounded-lg bg-white/[0.03]">
      <Icon className="w-5 h-5 text-emerald-400 flex-shrink-0" />
      <div className="flex-1 min-w-0">
        <div className="text-sm">{title}</div>
        <div className="text-xs text-white/45 leading-relaxed">{description}</div>
      </div>
      {granted ? (
        <CheckCircle2 className="w-5 h-5 text-emerald-400 flex-shrink-0" />
      ) : (
        <div className="flex flex-col gap-1.5 flex-shrink-0">
          <Button onClick={onAction}>{actionLabel}</Button>
          {secondaryLabel && onSecondary && <Button onClick={onSecondary}>{secondaryLabel}</Button>}
        </div>
      )}
    </div>
  );
}

function ChoiceCard({
  icon: Icon,
  title,
  description,
  selected,
  onSelect,
}: {
  icon: React.ComponentType<{ className?: string }>;
  title: string;
  description: string;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      className={`flex items-start gap-3 w-full p-3 rounded-xl border text-left cursor-pointer transition-colors ${
        selected ? 'bg-emerald-500/[0.08] border-emerald-500/50' : 'bg-white/[0.03] border-transparent hover:bg-white/5'
      }`}
    >
      <Icon className={`w-5 h-5 flex-shrink-0 mt-0.5 ${selected ? 'text-emerald-400' : 'text-white/40'}`} />
      <div className="flex-1 space-y-0.5">
        <div className="text-sm font-medium">{title}</div>
        <div className="text-xs text-white/50 leading-relaxed">{description}</div>
      </div>
      <span
        className={`w-4 h-4 mt-0.5 rounded-full border-2 flex-shrink-0 ${
          selected ? 'border-emerald-400 bg-emerald-400 shadow-[inset_0_0_0_3px_rgb(2,6,23)]' : 'border-white/30'
        }`}
      />
    </button>
  );
}

function StepBadge({ n }: { n: number }) {
  return (
    <span className="flex items-center justify-center w-[18px] h-[18px] rounded-full bg-emerald-500/80 text-[11px] font-bold text-slate-950 flex-shrink-0">
      {n}
    </span>
  );
}

function IconButton({ label, onClick, children }: { label: string; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={label}
      aria-label={label}
      className="p-2 text-white/50 hover:text-white cursor-pointer"
    >
      {children}
    </button>
  );
}

function DoneRow({ icon: Icon, text }: { icon: React.ComponentType<{ className?: string }>; text: string }) {
  return (
    <div className="flex items-start gap-2.5">
      <Icon className="w-4 h-4 text-emerald-400 flex-shrink-0 mt-0.5" />
      <span className="text-sm leading-relaxed">{text}</span>
    </div>
  );
}

function Warning({ text }: { text: string }) {
  return (
    <div className="flex items-start gap-1.5 text-sm text-amber-300">
      <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" />
      <span>{text}</span>
    </div>
  );
}
