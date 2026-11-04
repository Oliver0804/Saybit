// 「一般」分頁：錄音 / 語音辨識 / AI 理解 / 輸出 / 介面 / 系統 / 權限。
// 分組與文案對齊原生 UI/Settings/GeneralSettingsView.swift。
import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { getVersion } from '@tauri-apps/api/app';
import { openUrl } from '@tauri-apps/plugin-opener';
import {
  enable as enableAutostart,
  disable as disableAutostart,
  isEnabled as isAutostartEnabled,
} from '@tauri-apps/plugin-autostart';
import {
  Mic,
  AudioWaveform,
  Sparkles,
  TextCursorInput,
  AppWindow,
  Settings2,
  ShieldCheck,
  Square,
  RotateCw,
  CheckCircle2,
  AlertTriangle,
  Accessibility,
} from 'lucide-react';

import { listInputDevices, AudioChain } from '../../services/audioChain';
import { getSenseVoiceStatus } from '../../services/sherpaStt';
import { APP_LANGUAGES } from '../../services/l10n';
import type { SttEngine } from '../../services/settings';
import { detectPlatform } from '../../components/platform';
import {
  GlassCard,
  Segmented,
  Select,
  Button,
  Badge,
  SettingRow,
  SettingToggle,
  SettingSlider,
  SettingIndent,
  SettingDivider,
  SettingDescription,
} from '../../components/ui';
import {
  AppleSpeechPanel,
  CloudSttPanel,
  ContextRulesEditor,
  LocalSttModelPanel,
  StreamingPanel,
  type SectionProps,
} from './sections';
import { SherpaModelPanel } from './SherpaModelPanel';

type MicPermission = 'granted' | 'denied' | 'prompt' | 'unknown';

/// webview 能不能查到麥克風授權看平台（WKWebView 不一定支援 permissions.query），查不到就回 unknown
async function queryMicPermission(): Promise<MicPermission> {
  try {
    const status = await navigator.permissions.query({ name: 'microphone' as PermissionName });
    return status.state as MicPermission;
  } catch {
    return 'unknown';
  }
}

export function GeneralSection(props: SectionProps) {
  const { settings, update, tr, openTab } = props;
  const platform = detectPlatform();

  // ---- 系統 ----
  const [autostartError, setAutostartError] = useState('');
  const [version, setVersion] = useState('');
  useEffect(() => {
    // 開機自啟的真實狀態在 OS 那邊，掛載時對齊一次，避免設定檔跟系統不同步
    isAutostartEnabled()
      .then((enabled) => {
        if (enabled !== settings.launchAtLogin) update({ launchAtLogin: enabled });
      })
      .catch(() => {});
    getVersion().then(setVersion).catch(() => {});
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

  // ---- 錄音：裝置清單與麥克風測試 ----
  const [devices, setDevices] = useState<MediaDeviceInfo[]>([]);
  const [micTesting, setMicTesting] = useState(false);
  const [micLevel, setMicLevel] = useState(0);
  const [micTestError, setMicTestError] = useState(false);
  const testChainRef = useRef<AudioChain | null>(null);
  const rafRef = useRef<number | null>(null);

  useEffect(() => {
    listInputDevices().then(setDevices);
  }, []);

  const stopMicTest = () => {
    if (rafRef.current) cancelAnimationFrame(rafRef.current);
    rafRef.current = null;
    testChainRef.current?.stop();
    testChainRef.current = null;
    setMicTesting(false);
    setMicLevel(0);
  };

  const startMicTest = async () => {
    setMicTestError(false);
    const chain = new AudioChain();
    try {
      await chain.start({
        deviceId: settings.selectedInputDeviceId,
        echoCancellation: settings.enableEchoCancellation,
        bandpass: settings.enableVoiceBandpass,
        preBufferSeconds: 0,
      });
    } catch {
      chain.stop();
      setMicTestError(true);
      return;
    }
    testChainRef.current = chain;
    setMicTesting(true);
    setMicPermission('granted');
    const tick = () => {
      setMicLevel(Math.min(1, chain.currentLevel(settings.micSensitivity)));
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
  };

  // 離開頁面一定要關掉測試鏈，否則麥克風一直開著
  useEffect(() => stopMicTest, []);

  const deviceMissing =
    !!settings.selectedInputDeviceId &&
    devices.length > 0 &&
    !devices.some((d) => d.deviceId === settings.selectedInputDeviceId);

  // ---- 語音辨識 ----
  const [appleSupported, setAppleSupported] = useState(false);
  /// SenseVoice：查詢失敗（舊後端）時先當作支援，由模型面板顯示錯誤
  const [senseVoiceSupported, setSenseVoiceSupported] = useState(true);
  const [actionIntentsSupported, setActionIntentsSupported] = useState(false);
  useEffect(() => {
    invoke<boolean>('apple_speech_supported')
      .then(setAppleSupported)
      .catch(() => setAppleSupported(false));
    getSenseVoiceStatus()
      .then((st) => setSenseVoiceSupported(st.supported !== false))
      .catch(() => {});
    invoke<boolean>('action_intents_supported')
      .then(setActionIntentsSupported)
      .catch(() => setActionIntentsSupported(false));
  }, []);

  // ---- AI 理解 ----
  const [showRules, setShowRules] = useState(false);

  // ---- 權限 ----
  const [micPermission, setMicPermission] = useState<MicPermission>('unknown');
  const [openSettingsFailed, setOpenSettingsFailed] = useState(false);
  const refreshPermissions = () => {
    queryMicPermission().then(setMicPermission);
  };
  useEffect(() => {
    refreshPermissions();
    // 從系統設定授權回來時更新
    const onFocus = () => refreshPermissions();
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, []);

  const requestMic = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      stream.getTracks().forEach((t) => t.stop());
      setMicPermission('granted');
      listInputDevices().then(setDevices);
    } catch {
      setMicPermission('denied');
      if (platform === 'macos') openPrivacyPane('Privacy_Microphone');
    }
  };

  const openPrivacyPane = (anchor: string) => {
    setOpenSettingsFailed(false);
    openUrl(`x-apple.systempreferences:com.apple.preference.security?${anchor}`).catch(() =>
      setOpenSettingsFailed(true)
    );
  };

  const engineOptions: Array<{ value: SttEngine; label: string; disabled?: boolean }> = [
    {
      value: 'sensevoice',
      label: senseVoiceSupported ? tr('sttSenseVoice') : `${tr('sttSenseVoice')}（${tr('errSenseVoiceUnsupportedPlatform')}）`,
      disabled: !senseVoiceSupported,
    },
    {
      value: 'apple',
      label: appleSupported ? tr('sttApple') : `${tr('sttApple')}（${tr('unsupportedPlatform')}）`,
      disabled: !appleSupported,
    },
    { value: 'streaming', label: tr('sttStreaming') },
    { value: 'cloud', label: tr('sttCloud') },
    { value: 'local', label: tr('sttLocal') },
  ];

  const usesWhisperLanguage =
    settings.sttEngine === 'cloud' || settings.sttEngine === 'local' || settings.sttEngine === 'sensevoice';

  return (
    <div className="max-w-2xl space-y-6">
      {/* ---------------- 錄音 ---------------- */}
      <GlassCard title={tr('sectionRecording')} icon={Mic}>
        <SettingRow title={tr('inputDevice')} description={tr('selectMicDesc')}>
          <Select
            value={settings.selectedInputDeviceId}
            options={[
              { value: '', label: tr('systemDefault') },
              ...devices.map((d) => ({
                value: d.deviceId,
                label: d.label || `${tr('inputDevice')} ${d.deviceId.slice(0, 8)}`,
              })),
              // 已選的裝置拔掉後仍要有對應項目，否則選單會顯示空白
              ...(deviceMissing ? [{ value: settings.selectedInputDeviceId, label: tr('deviceUnavailable') }] : []),
            ]}
            onChange={(v) => update({ selectedInputDeviceId: v })}
            className="max-w-[240px]"
          />
        </SettingRow>

        <div className="flex items-center gap-3">
          <Button onClick={micTesting ? stopMicTest : startMicTest} variant={micTesting ? 'danger' : 'secondary'}>
            <span className="flex items-center gap-1.5">
              {micTesting ? <Square className="w-3 h-3" /> : <AudioWaveform className="w-3.5 h-3.5" />}
              {micTesting ? tr('stopTest') : tr('micTest')}
            </span>
          </Button>
          <div className={`flex-1 h-1.5 rounded-full bg-white/10 overflow-hidden ${micTesting ? '' : 'opacity-40'}`}>
            <div
              className={`h-full transition-[width] duration-75 ${micLevel > 0.85 ? 'bg-orange-400' : 'bg-emerald-500'}`}
              style={{ width: `${micLevel * 100}%` }}
            />
          </div>
          <span className="w-10 text-right text-xs font-mono tabular-nums text-white/50">
            {Math.round(micLevel * 100)}%
          </span>
        </div>
        {micTesting && <SettingDescription>{tr('micTestHint')}</SettingDescription>}
        {micTestError && <p className="text-[11px] text-red-400">{tr('micOpenFailed')}</p>}

        <SettingSlider
          title={tr('gainMultiplier')}
          valueText={`${settings.micSensitivity.toFixed(1)}×`}
          value={settings.micSensitivity}
          min={0.5}
          max={5}
          step={0.5}
          onChange={(v) => update({ micSensitivity: v })}
          description={tr('micSensitivityDesc')}
        />

        <SettingSlider
          title={tr('preBuffer')}
          valueText={tr('secondsValue', { v: settings.preBufferSeconds.toFixed(1) })}
          value={settings.preBufferSeconds}
          min={0}
          max={3}
          step={0.1}
          onChange={(v) => update({ preBufferSeconds: v })}
          description={tr('preBufferDesc')}
        />

        <SettingDivider />

        <SettingToggle
          title={tr('enableAutoStop')}
          description={tr('silenceAutoStopDesc')}
          checked={settings.enableAutoStop}
          onChange={(v) => update({ enableAutoStop: v })}
        />
        {settings.enableAutoStop && (
          <SettingIndent>
            <SettingSlider
              title={tr('silenceWait')}
              valueText={tr('secondsValue', { v: settings.silenceTimeout.toFixed(1) })}
              value={settings.silenceTimeout}
              min={0.5}
              max={5}
              step={0.5}
              onChange={(v) => update({ silenceTimeout: v })}
            />
          </SettingIndent>
        )}

        <SettingSlider
          title={tr('maxRecording')}
          valueText={tr('secondsValue', { v: settings.maxRecordingSeconds })}
          value={settings.maxRecordingSeconds}
          min={30}
          max={600}
          step={30}
          onChange={(v) => update({ maxRecordingSeconds: Math.round(v) })}
          description={tr('maxRecordingDesc')}
        />

        <SettingDivider />

        <SettingToggle
          title={tr('ducking')}
          description={tr('duckingDesc')}
          checked={settings.enableDucking}
          onChange={(v) => update({ enableDucking: v })}
        />

        <SettingDivider />

        <SettingToggle
          title={tr('soundFeedback')}
          checked={settings.enableSoundFeedback}
          onChange={(v) => update({ enableSoundFeedback: v })}
        />
      </GlassCard>

      {/* ---------------- 語音辨識 ---------------- */}
      <GlassCard title={tr('sectionRecognition')} icon={AudioWaveform}>
        <Segmented value={settings.sttEngine} options={engineOptions} onChange={(v) => update({ sttEngine: v })} />

        {settings.sttEngine === 'sensevoice' && <SherpaModelPanel tr={tr} />}
        {settings.sttEngine === 'apple' && <AppleSpeechPanel settings={settings} update={update} tr={tr} />}
        {settings.sttEngine === 'streaming' && <StreamingPanel settings={settings} update={update} tr={tr} />}
        {settings.sttEngine === 'cloud' && (
          <CloudSttPanel
            settings={settings}
            update={update}
            tr={tr}
            secrets={props.secrets}
            reloadSecrets={props.reloadSecrets}
          />
        )}
        {settings.sttEngine === 'local' && <LocalSttModelPanel />}

        {usesWhisperLanguage && (
          <SettingRow title={tr('sttLanguage')}>
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
          </SettingRow>
        )}

        <SettingDivider />

        <SettingToggle
          title={tr('voiceBandpass')}
          description={tr('voiceBandpassDesc')}
          checked={settings.enableVoiceBandpass}
          onChange={(v) => update({ enableVoiceBandpass: v })}
        />

        <SettingDivider />

        <SettingToggle
          title={tr('echoCancellation')}
          description={tr('echoCancellationDesc')}
          checked={settings.enableEchoCancellation}
          onChange={(v) => update({ enableEchoCancellation: v })}
        />
      </GlassCard>

      {/* ---------------- AI 理解 ---------------- */}
      <GlassCard title={tr('sectionAI')} icon={Sparkles}>
        <SettingToggle
          title={tr('contextAwareness')}
          description={tr('contextAwarenessDesc')}
          checked={settings.enableContextAwareness}
          onChange={(v) => update({ enableContextAwareness: v })}
        />
        {settings.enableContextAwareness && (
          <SettingIndent>
            <SettingRow title={tr('contextRulesTitle')} description={tr('contextRulesManageDesc')}>
              <Button onClick={() => setShowRules((v) => !v)}>{tr('contextRulesManage')}</Button>
            </SettingRow>
            {showRules && <ContextRulesEditor settings={settings} update={update} tr={tr} />}
            <SettingToggle
              title={tr('selectionCapture')}
              description={tr('selectionCaptureDesc')}
              checked={settings.enableSelectionCapture}
              onChange={(v) => update({ enableSelectionCapture: v })}
            />
          </SettingIndent>
        )}

        <SettingDivider />

        <SettingToggle
          title={tr('whisperMode')}
          description={tr('whisperModeDesc')}
          checked={settings.enableWhisperMode}
          onChange={(v) => update({ enableWhisperMode: v })}
        />

        <SettingDivider />

        <SettingToggle
          title={tr('actionIntents')}
          description={
            actionIntentsSupported
              ? tr('actionIntentsDesc')
              : `${tr('actionIntentsDesc')}（${tr('unsupportedPlatform')}）`
          }
          checked={settings.enableActionIntents && actionIntentsSupported}
          onChange={(v) => update({ enableActionIntents: v })}
          disabled={!actionIntentsSupported}
        />
      </GlassCard>

      {/* ---------------- 輸出 ---------------- */}
      <GlassCard title={tr('sectionOutput')} icon={TextCursorInput}>
        <SettingRow title={tr('injectionMode')} description={tr('injectionModeDesc')}>
          <Segmented
            value={settings.injectionMode}
            options={[
              { value: 'paste', label: tr('injectPaste') },
              { value: 'keypress', label: tr('injectKeypress') },
              { value: 'replace_selection', label: tr('injectReplaceSelection') },
            ]}
            onChange={(v) => update({ injectionMode: v })}
          />
        </SettingRow>

        <SettingDivider />

        <SettingToggle
          title={tr('enablePreview')}
          description={tr('previewDesc')}
          checked={settings.enablePreviewBeforeInject}
          onChange={(v) => update({ enablePreviewBeforeInject: v })}
        />
        {settings.enablePreviewBeforeInject && (
          <SettingIndent>
            <SettingSlider
              title={tr('previewTimeoutLabel')}
              valueText={tr('secondsValue', { v: settings.previewTimeout.toFixed(1) })}
              value={settings.previewTimeout}
              min={1}
              max={10}
              step={0.5}
              onChange={(v) => update({ previewTimeout: v })}
              description={tr('previewTimeoutDesc')}
            />
          </SettingIndent>
        )}

        <SettingDivider />

        <SettingToggle
          title={tr('smartSendTitle')}
          description={tr('smartSendDesc')}
          checked={settings.enableSmartSend}
          onChange={(v) => update({ enableSmartSend: v })}
        />
        {settings.enableSmartSend && (
          <SettingIndent>
            <SettingSlider
              title={tr('countdownSeconds')}
              valueText={tr('secondsValue', { v: settings.smartSendDelay })}
              value={settings.smartSendDelay}
              min={1}
              max={10}
              step={1}
              onChange={(v) => update({ smartSendDelay: Math.round(v) })}
              description={tr('smartSendCancelHint')}
            />
          </SettingIndent>
        )}
      </GlassCard>

      {/* ---------------- 介面 ---------------- */}
      <GlassCard title={tr('sectionInterface')} icon={AppWindow}>
        <SettingRow title={tr('appLanguage')}>
          <Select
            value={settings.appLanguage}
            options={APP_LANGUAGES.map((l) => ({ value: l.id, label: l.displayName }))}
            onChange={(value) => update({ appLanguage: value })}
          />
        </SettingRow>

        <SettingRow title={tr('outputLanguage')}>
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
            className={settings.sttEngine === 'cloud' && settings.enableAutoLanguageDetection ? 'opacity-40' : ''}
          />
        </SettingRow>

        {/* 自動語言偵測只對 Whisper API 有效，其他引擎不顯示 */}
        {settings.sttEngine === 'cloud' && (
          <SettingToggle
            title={tr('autoLanguageDetection')}
            description={tr('autoLanguageDetectionDesc')}
            checked={settings.enableAutoLanguageDetection}
            onChange={(v) => update({ enableAutoLanguageDetection: v })}
          />
        )}

        <SettingDivider />

        <SettingSlider
          title={tr('capsuleScale')}
          valueText={`${Math.round(settings.capsuleScale * 100)}%`}
          value={settings.capsuleScale}
          min={0.5}
          max={2}
          step={0.1}
          onChange={(v) => update({ capsuleScale: Math.round(v * 10) / 10 })}
          description={tr('capsuleSizeDesc')}
        />
      </GlassCard>

      {/* ---------------- 系統 ---------------- */}
      <GlassCard title={tr('sectionSystem')} icon={Settings2}>
        <SettingToggle
          title={tr('enableLaunchAtLogin')}
          description={tr('launchAtLoginDesc')}
          checked={settings.launchAtLogin}
          onChange={toggleAutostart}
        />
        {autostartError && <p className="text-[11px] text-amber-300">⚠️ {autostartError}</p>}

        <SettingDivider />

        <SettingToggle
          title={tr('enableAutoUpdateCheck')}
          description={tr('autoUpdateCheckDesc')}
          checked={settings.enableAutoUpdateCheck}
          onChange={(v) => update({ enableAutoUpdateCheck: v })}
        />
        {settings.availableUpdateTag && (
          <SettingIndent>
            <div className="flex items-center gap-2 text-xs text-white/80">
              <Sparkles className="w-3.5 h-3.5 text-emerald-400" />
              <span>{tr('updateNewer', { latest: settings.availableUpdateTag, current: version })}</span>
              {settings.availableUpdateUrl && (
                <button
                  type="button"
                  onClick={() => openUrl(settings.availableUpdateUrl).catch(() => {})}
                  className="text-emerald-300 underline cursor-pointer"
                >
                  {tr('viewRelease')}
                </button>
              )}
            </div>
          </SettingIndent>
        )}

        <SettingDivider />

        <SettingToggle
          title={tr('autoCleanup')}
          description={tr('historyCleanupDesc')}
          checked={settings.enableHistoryAutoCleanup}
          onChange={(v) => update({ enableHistoryAutoCleanup: v })}
        />
        {settings.enableHistoryAutoCleanup && (
          <SettingIndent>
            <SettingSlider
              title={tr('retentionDays')}
              valueText={tr('daysValue', { v: settings.historyRetentionDays })}
              value={Math.min(90, Math.max(7, settings.historyRetentionDays))}
              min={7}
              max={90}
              step={1}
              onChange={(v) => update({ historyRetentionDays: Math.round(v) })}
            />
          </SettingIndent>
        )}

        <SettingDivider />

        <SettingRow title={tr('tutorial')} description={tr('tutorialDesc')}>
          <div className="flex gap-2">
            <Button onClick={() => openTab?.('tutorial')}>{tr('replayTutorial')}</Button>
            <Button onClick={() => update({ hasCompletedOnboarding: false })}>{tr('replayOnboarding')}</Button>
          </div>
        </SettingRow>

        <SettingRow title={tr('aboutSaybit')} description={version ? `Saybit Desktop v${version}` : undefined}>
          <Button onClick={() => openTab?.('about')}>{tr('aboutSaybit')}</Button>
        </SettingRow>
      </GlassCard>

      {/* ---------------- 權限 ---------------- */}
      <GlassCard title={tr('permissionStatus')} icon={ShieldCheck}>
        <div className="flex justify-end -mt-2">
          <button
            type="button"
            onClick={refreshPermissions}
            className="flex items-center gap-1 text-xs text-white/50 hover:text-white cursor-pointer"
          >
            <RotateCw className="w-3 h-3" /> {tr('recheck')}
          </button>
        </div>

        {platform === 'macos' && (
          <>
            <SettingRow
              title={
                <span className="flex items-center gap-2">
                  <Accessibility className="w-4 h-4 text-white/50" /> {tr('accessibility')}
                  <Badge tone="warn">{tr('requiredBadge')}</Badge>
                </span>
              }
              description={tr('accessibilityManualDesc')}
            >
              <Button onClick={() => openPrivacyPane('Privacy_Accessibility')}>{tr('openSettings')}</Button>
            </SettingRow>
            <SettingDivider />
          </>
        )}

        <SettingRow
          title={
            <span className="flex items-center gap-2">
              <Mic className="w-4 h-4 text-white/50" /> {tr('microphone')}
              {micPermission !== 'granted' && <Badge tone="warn">{tr('requiredBadge')}</Badge>}
            </span>
          }
        >
          {micPermission === 'granted' ? (
            <span className="flex items-center gap-1 text-xs font-semibold text-emerald-400">
              <CheckCircle2 className="w-4 h-4" /> {tr('authorized')}
            </span>
          ) : (
            <div className="flex items-center gap-2">
              {micPermission === 'denied' && (
                <span className="flex items-center gap-1 text-xs text-amber-300">
                  <AlertTriangle className="w-3.5 h-3.5" /> {tr('notAuthorized')}
                </span>
              )}
              {micPermission === 'unknown' && <span className="text-xs text-white/40">{tr('permissionUnknown')}</span>}
              <Button onClick={requestMic}>{tr('requestAccess')}</Button>
            </div>
          )}
        </SettingRow>

        {openSettingsFailed && <SettingDescription>{tr('openSettingsFailed')}</SettingDescription>}
      </GlassCard>
    </div>
  );
}
