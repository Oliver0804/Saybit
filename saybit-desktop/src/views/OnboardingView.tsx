// 首次啟動導引：選服務商 → 填金鑰 → 設快捷鍵 → 測試麥克風。
// 對應原生版 UI/Onboarding/OnboardingView.swift。

import { useEffect, useState } from 'react';
import { emit } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';
import { Mic, Key, Keyboard, CheckCircle2 } from 'lucide-react';

import type { AppSettings } from '../services/settings';
import { llmKeyAccount, sttKeyAccount, saveSecret } from '../services/settings';
import { BUILT_IN_PROVIDERS, defaultModelFor } from '../services/providers';
import { AudioChain } from '../services/audioChain';
import { Button, Hint, Segmented, TextField } from '../components/ui';

interface Props {
  settings: AppSettings;
  update: (patch: Partial<AppSettings>) => void;
  reloadSecrets: (settings: AppSettings) => Promise<void>;
  onFinish: () => void;
}

const STEPS = ['歡迎', '選擇服務商', '語音辨識', '快捷鍵', '完成'];

export function OnboardingView({ settings, update, reloadSecrets, onFinish }: Props) {
  const [step, setStep] = useState(0);
  const [llmKey, setLlmKey] = useState('');
  const [sttKey, setSttKey] = useState('');
  const [micState, setMicState] = useState<'idle' | 'ok' | 'error'>('idle');
  const [appleSupported, setAppleSupported] = useState(false);

  useEffect(() => {
    invoke<boolean>('apple_speech_supported')
      .then(setAppleSupported)
      .catch(() => setAppleSupported(false));
  }, []);

  const next = () => setStep((s) => Math.min(s + 1, STEPS.length - 1));
  const back = () => setStep((s) => Math.max(s - 1, 0));

  const finish = async () => {
    if (llmKey.trim()) {
      await saveSecret(llmKeyAccount(settings.selectedProviderId), llmKey.trim());
    }
    if (sttKey.trim()) {
      await saveSecret(sttKeyAccount(settings.sttBaseUrl), sttKey.trim());
    }
    update({ hasCompletedOnboarding: true });
    await reloadSecrets({ ...settings, hasCompletedOnboarding: true });
    emit('secrets-updated', {}).catch(() => {});
    onFinish();
  };

  const testMic = async () => {
    const chain = new AudioChain();
    try {
      await chain.start({
        deviceId: '',
        echoCancellation: false,
        bandpass: true,
        preBufferSeconds: 0,
      });
      setMicState('ok');
    } catch {
      setMicState('error');
    } finally {
      setTimeout(() => chain.stop(), 300);
    }
  };

  return (
    <div className="flex flex-col w-full h-screen bg-slate-950 text-white items-center justify-center p-10">
      <div className="w-full max-w-lg space-y-8">
        {/* 進度指示 */}
        <div className="flex items-center gap-2">
          {STEPS.map((label, index) => (
            <div key={label} className="flex-1">
              <div
                className={`h-1 rounded-full transition-colors ${
                  index <= step ? 'bg-emerald-500' : 'bg-white/10'
                }`}
              />
            </div>
          ))}
        </div>

        {step === 0 && (
          <div className="space-y-4 text-center">
            <div className="flex items-center justify-center w-16 h-16 rounded-2xl bg-gradient-to-tr from-emerald-500 to-teal-400 mx-auto">
              <Mic className="w-8 h-8 text-slate-950" />
            </div>
            <h1 className="text-2xl font-bold">歡迎使用 Saybit</h1>
            <p className="text-sm text-white/50 leading-relaxed">
              用說的取代打字。Saybit 會把你的語音轉成乾淨的文字，
              自動去掉贅詞與補上標點，再直接打進你正在使用的任何應用程式。
            </p>
          </div>
        )}

        {step === 1 && (
          <div className="space-y-4">
            <div className="flex items-center gap-2">
              <Key className="w-5 h-5 text-emerald-400" />
              <h2 className="text-lg font-bold">選擇文字精煉服務商</h2>
            </div>
            <Segmented
              value={settings.selectedProviderId}
              options={BUILT_IN_PROVIDERS.map((p) => ({ value: p.id, label: p.name }))}
              onChange={(id) =>
                update({
                  selectedProviderId: id,
                  selectedModel: defaultModelFor(id) ?? settings.selectedModel,
                })
              }
            />
            <TextField
              value={llmKey}
              onChange={setLlmKey}
              placeholder="貼上 API Key"
              type="password"
              mono
              className="w-full"
            />
            <Hint>
              🔒 金鑰會存進系統金鑰庫，不會寫進設定檔。本地服務（Ollama / LM Studio）可留空。
            </Hint>
          </div>
        )}

        {step === 2 && (
          <div className="space-y-4">
            <div className="flex items-center gap-2">
              <Mic className="w-5 h-5 text-emerald-400" />
              <h2 className="text-lg font-bold">語音辨識方式</h2>
            </div>
            <Segmented
              value={settings.sttEngine}
              options={[
                { value: 'local', label: '本地 whisper（離線・免費）' },
                {
                  value: 'apple',
                  label: 'Apple 語音辨識（macOS）',
                  disabled: !appleSupported,
                },
                { value: 'cloud', label: '雲端 Whisper API' },
              ]}
              onChange={(v) => update({ sttEngine: v })}
            />
            {settings.sttEngine === 'apple' && (
              <Hint>
                使用 macOS 內建辨識，不用下載模型也不用金鑰。第一次使用會跳出語音辨識權限對話框；
                進設定的「語音輸入」頁可以改辨識語言與是否強制離線。
              </Hint>
            )}

            {settings.sttEngine === 'cloud' ? (
              <>
                <Segmented
                  value={settings.sttBaseUrl}
                  options={[
                    { value: 'https://api.openai.com/v1', label: 'OpenAI' },
                    { value: 'https://api.groq.com/openai/v1', label: 'Groq（有免費額度）' },
                  ]}
                  onChange={(v) =>
                    update({
                      sttBaseUrl: v,
                      sttModel: v.includes('groq') ? 'whisper-large-v3' : 'whisper-1',
                    })
                  }
                />
                <TextField
                  value={sttKey}
                  onChange={setSttKey}
                  placeholder={settings.sttBaseUrl.includes('groq') ? 'gsk_...' : 'sk-...'}
                  type="password"
                  mono
                  className="w-full"
                />
                <Hint>STT 與精煉可以用不同服務商，金鑰也各自獨立保存。</Hint>
              </>
            ) : settings.sttEngine === 'local' ? (
              <Hint>
                稍後可在「語音輸入」頁下載 whisper large-v3-turbo 模型（約 574MB），
                下載後完全離線、不需要金鑰。
              </Hint>
            ) : null}

            <div className="flex items-center gap-3">
              <Button onClick={testMic}>測試麥克風</Button>
              {micState === 'ok' && (
                <span className="text-xs text-emerald-400 flex items-center gap-1">
                  <CheckCircle2 className="w-4 h-4" /> 麥克風正常
                </span>
              )}
              {micState === 'error' && (
                <span className="text-xs text-red-400">無法存取麥克風，請檢查系統權限</span>
              )}
            </div>
          </div>
        )}

        {step === 3 && (
          <div className="space-y-4">
            <div className="flex items-center gap-2">
              <Keyboard className="w-5 h-5 text-emerald-400" />
              <h2 className="text-lg font-bold">快捷鍵</h2>
            </div>
            <TextField
              value={settings.hotkey}
              onChange={(v) => update({ hotkey: v })}
              placeholder="Ctrl+Alt+Space"
              mono
              className="w-full"
            />
            <Segmented
              value={settings.hotkeyTriggerMode}
              options={[
                { value: 'toggle', label: '按一下開始／再按結束' },
                { value: 'hold', label: '按住說話' },
                { value: 'doubleTap', label: '連按兩下' },
              ]}
              onChange={(v) => update({ hotkeyTriggerMode: v })}
            />
            <Hint>之後可以在設定裡用錄製的方式重新指定，並會提示是否撞到系統熱鍵。</Hint>
          </div>
        )}

        {step === 4 && (
          <div className="space-y-4 text-center">
            <CheckCircle2 className="w-14 h-14 text-emerald-400 mx-auto" />
            <h2 className="text-xl font-bold">設定完成</h2>
            <p className="text-sm text-white/50 leading-relaxed">
              按下 <code className="text-emerald-300">{settings.hotkey}</code> 開始說話。
              進階選項（語氣規則、個人字典、注入方式）都在設定畫面裡。
            </p>
          </div>
        )}

        <div className="flex items-center justify-between pt-4">
          <Button onClick={back} disabled={step === 0}>
            上一步
          </Button>
          <button
            type="button"
            onClick={finish}
            className="text-xs text-white/30 hover:text-white/60 cursor-pointer"
          >
            略過設定
          </button>
          {step < STEPS.length - 1 ? (
            <Button variant="primary" onClick={next}>
              下一步
            </Button>
          ) : (
            <Button variant="primary" onClick={finish}>
              開始使用
            </Button>
          )}
        </div>
      </div>
    </div>
  );
}
