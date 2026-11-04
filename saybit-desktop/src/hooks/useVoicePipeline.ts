import { useState, useEffect, useRef, useMemo, useCallback } from 'react';
import { listen, emit, emitTo } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';
import { getCurrentWindow } from '@tauri-apps/api/window';

import { db, cleanupHistory } from '../services/db';
import {
  transcribeAudio,
  refineTextStream,
  classifyIntent,
  completeJSON,
  isCancelledError,
  type LLMPayload,
  type LLMUsage,
  type EventPayload,
  type ReminderPayload,
} from '../services/llm';
import {
  promptForStyle,
  promptForIntent,
  temperatureForStyle,
  forMode,
  type IntentResponse,
} from '../services/systemPrompts';
import { applyDictionary, preferredSpellings, toPersonalDictionary } from '../services/dictionaryHints';
import {
  findVoiceMode,
  findVoiceModeById,
  hotkeyBindings,
  MAIN_HOTKEY_ID,
  type VoiceMode,
} from '../services/voiceModes';
import {
  SenseVoiceSession,
  preloadSenseVoice,
  senseVoiceLanguageFor,
  partialTextFromPayload,
  toTraditional,
} from '../services/sherpaStt';
import {
  URL_COMMAND_EVENT,
  URL_COMMAND_ASK_EVENT,
  parseUrlCommand,
  routeUrlCommand,
  type UrlCommand,
} from '../services/urlCommands';
import { SessionGeneration } from '../services/sessionGeneration';
import {
  duckSystemVolume,
  restoreSystemVolume,
  restorePendingVolumeIfNeeded,
  DUCK_DELAY_MS,
} from '../services/ducking';
import {
  captureForegroundApp,
  captureSelectedText,
  isSelectionCaptureSafe,
  EMPTY_CONTEXT,
  isSelfApp,
  type AppContext,
} from '../services/appContext';
import { matchContextRule } from '../services/contextRules';
import {
  isLikelyHallucination,
  measureEnergy,
  hasAudibleSpeech,
} from '../services/sttArtifacts';
import { resolveProvider } from '../services/providers';
import { costFor } from '../services/pricing';
import {
  AudioChain,
  resampleTo16k,
  pcmToWavBlob,
  pcmToInt16Bytes,
} from '../services/audioChain';
import {
  startStreaming,
  pushStreamingAudio,
  finishStreaming,
  cancelStreaming,
} from '../services/streamingStt';
import {
  loadSettings,
  persistSettings,
  loadSecret,
  migratePlaintextKeys,
  llmKeyAccount,
  sttKeyAccount,
  streamingKeyAccount,
  tr,
  type AppSettings,
  type SttEngine,
} from '../services/settings';

export type PipelineState =
  | 'idle'
  | 'listening'
  | 'recording'
  | 'processing'
  | 'previewing'
  | 'done'
  | 'confirming'
  | 'error';

export interface Secrets {
  llmKey: string;
  sttKey: string;
}

/// 重試上次失敗所需的最小上下文（對應原生版 ErrorContext）
interface RetryContext {
  transcript: string;
  context: AppContext;
  /// 這次錄音用的語音模式（重新生成要沿用）
  mode: VoiceMode | null;
}

// 前端 log 落地到 app data dir 的 frontend.log。
// sensitive=true：內容含轉錄 / 選取文字 / LLM 結果，Rust 端落盤時改寫成「[內容已遮罩, N 字]」（審查 M14）。
function logToFile(msg: string, sensitive = false) {
  console.log(`[Saybit] ${msg}`);
  invoke('frontend_log', { msg, sensitive }).catch(() => {});
}

/// UI 可能把 onClick 事件物件直接傳進來，只認真的 VoiceMode
function asVoiceMode(x: unknown): VoiceMode | null {
  if (!x || typeof x !== 'object') return null;
  const m = x as Partial<VoiceMode>;
  return typeof m.id === 'string' && typeof m.name === 'string' && typeof m.instructions === 'string'
    ? (m as VoiceMode)
    : null;
}

function hotkeyIdFrom(payload: unknown): string {
  if (payload && typeof payload === 'object') {
    const id = (payload as { id?: unknown }).id;
    if (typeof id === 'string' && id) return id;
  }
  // 舊版 Rust 不帶 payload → 主快捷鍵
  return MAIN_HOTKEY_ID;
}

function isInjectCancelled(e: unknown): boolean {
  return String((e as { message?: string })?.message ?? e).trim() === 'cancelled';
}

function isForegroundChanged(e: unknown): boolean {
  return String((e as { message?: string })?.message ?? e).includes('foreground-changed');
}

/// 送 Rust 用的前景 App 識別：空的或是 Saybit 自己就不比對
function expectedBundleIdOf(ctx: AppContext): string | null {
  return ctx.bundleId && !ctx.isSelf ? ctx.bundleId : null;
}

/// 終端機：多行貼上 / Enter 會直接執行指令（審查 M26）
function isTerminalContext(ctx: AppContext): boolean {
  return ctx.identifier === 'terminal';
}

/// 提示音：用 WebAudio 合成，免帶音效檔。
function playFeedbackTone(kind: 'start' | 'stop' | 'error') {
  try {
    const ctx = new (window.AudioContext || (window as any).webkitAudioContext)();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    const freq = kind === 'start' ? 880 : kind === 'stop' ? 660 : 220;
    osc.frequency.value = freq;
    osc.type = 'sine';
    gain.gain.setValueAtTime(0.0001, ctx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.08, ctx.currentTime + 0.01);
    gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + 0.12);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start();
    osc.stop(ctx.currentTime + 0.13);
    osc.onended = () => ctx.close().catch(() => {});
  } catch {
    /* 提示音失敗不影響主流程 */
  }
}

export function useVoicePipeline() {
  const [state, setState] = useState<PipelineState>('idle');
  const [audioLevel, setAudioLevel] = useState(0);
  const [rawText, setRawText] = useState('');
  const [processedText, setProcessedText] = useState('');
  const [errorMsg, setErrorMsg] = useState('');
  const [countdown, setCountdown] = useState(0);
  const [recordingStartTime, setRecordingStartTime] = useState<number | null>(null);
  const [actionConfirmation, setActionConfirmation] = useState('');
  /// 串流辨識的即時逐字稿，錄音中就會持續更新
  const [partialText, setPartialText] = useState('');
  /// 這次錄音使用的語音模式名稱（膠囊顯示用），一般錄音為 null
  const [activeModeName, setActiveModeName] = useState<string | null>(null);
  /// main 視窗收到 saybit://settings?tab=… 時設定；UI 監看 at 變化去切分頁
  const [settingsTabRequest, setSettingsTabRequest] = useState<{ tab: string | null; at: number } | null>(null);

  const [settings, setSettings] = useState<AppSettings>(() => loadSettings());
  const [secrets, setSecretsState] = useState<Secrets>({ llmKey: '', sttKey: '' });

  const windowLabel = useMemo(() => {
    try {
      return getCurrentWindow().label;
    } catch {
      return 'unknown';
    }
  }, []);
  const isOverlay = windowLabel === 'overlay';

  // ---- refs：計時器與跨 callback 共用狀態 ----
  // 懶初始化：useRef 的參數每次 render 都會被求值，直接 new 會白做很多次
  const audioChainRef = useRef<AudioChain | null>(null);
  if (audioChainRef.current === null) audioChainRef.current = new AudioChain();
  const audioChain = audioChainRef.current;
  const silenceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const smartSendTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const previewTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const warmReleaseTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const hasDetectedSpeechRef = useRef(false);
  const recordingStartRef = useRef(0);
  const capturedContextRef = useRef<AppContext>({ ...EMPTY_CONTEXT });
  const retryContextRef = useRef<RetryContext | null>(null);
  const autoConfirmRef = useRef<() => void>(() => {});
  const hotkeyPressedAtRef = useRef(0);
  const lastHotkeyTapRef = useRef(0);
  /// 熱鍵目前是否還按著。用來濾掉作業系統的按鍵自動重複 —— 沒有這個的話，
  /// 按住不放會連續送出 hotkey-pressed，toggle 模式就會重複開錄。
  const hotkeyHeldRef = useRef<Set<string>>(new Set());
  /// startRecording 的 async 前置（查前景 App、開麥克風）期間 state 還是 idle，
  /// 這時再進來一次會開第二輪錄音並把第一輪錄到的音訊清掉。
  const isStartingRef = useRef(false);
  const monitorRafRef = useRef<number | null>(null);
  /// 這次錄音是否真的跑在串流模式（連線失敗會退回批次，要記住實際狀態）
  const streamingActiveRef = useRef(false);
  /// 這次錄音的 SenseVoice session（null = 沒用 SenseVoice）
  const senseVoiceRef = useRef<SenseVoiceSession | null>(null);
  /// 錄音開始時的引擎快照：錄音中改設定不能讓停止時換一個引擎去收（原生 H3）
  const recordingEngineRef = useRef<SttEngine>('cloud');
  /// session 世代（審查 C1）：每次開錄 / 取消都 +1，所有 await 之後比對，不符代表已被作廢
  /// bump() 同時 abort 處理中（STT / LLM）的請求，取消會真的中斷 HTTP
  const sessionGenRef = useRef<SessionGeneration | null>(null);
  if (sessionGenRef.current === null) sessionGenRef.current = new SessionGeneration();
  const sessionGen = sessionGenRef.current;
  /// 這次錄音的語音模式，只對這一次有效
  const activeModeRef = useRef<VoiceMode | null>(null);
  const maxRecordingTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const duckTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  /// 預覽是因為前景 App 變了才進來的：不自動確認、確認時不再比對、不 Smart Send
  const previewAfterForegroundChangeRef = useRef(false);
  /// 等使用者決定是否允許 saybit:// 的那一個指令
  const pendingUrlCommandRef = useRef<{ cmd: UrlCommand; at: number } | null>(null);
  /// 每次 render 指向最新的執行函式（事件監聽只註冊一次）
  const executeUrlCommandRef = useRef<(cmd: UrlCommand) => void>(() => {});
  /// URL 觸發但找不到外部目標 App：結果一律進預覽
  const forcePreviewRef = useRef(false);

  // 讓事件監聽器與計時器永遠讀得到最新的 state/settings，而不是被閉包鎖住舊值
  const stateRef = useRef(state);
  stateRef.current = state;

  /// 一律走這個函式改狀態：setState 要等 re-render 才會反映到 stateRef，
  /// 但 rAF 迴圈與熱鍵 handler 是「下一個 tick 就讀 stateRef」，兩者之間有空窗。
  /// 實測就是 startRecording 後 monitorAudioLevel 的第一幀讀到舊狀態直接退出，
  /// 波形與靜音偵測整個不會動。同步寫 ref 才能關掉這個競態。
  const transitionTo = useCallback((next: PipelineState) => {
    stateRef.current = next;
    setState(next);
  }, []);
  const settingsRef = useRef(settings);
  settingsRef.current = settings;
  const secretsRef = useRef(secrets);
  secretsRef.current = secrets;
  const processedTextRef = useRef(processedText);
  processedTextRef.current = processedText;

  /// 作廢目前所有在飛的回呼與請求，回傳新世代
  const bumpGeneration = () => {
    return sessionGen.bump();
  };

  // ---------------------------------------------------------------- 金鑰

  const reloadSecrets = useCallback(async (current: AppSettings) => {
    const [llmKey, sttKey] = await Promise.all([
      loadSecret(llmKeyAccount(current.selectedProviderId)),
      loadSecret(sttKeyAccount(current.sttBaseUrl)),
    ]);
    setSecretsState({ llmKey, sttKey });
  }, []);

  useEffect(() => {
    (async () => {
      const current = settingsRef.current;
      await migratePlaintextKeys(current);
      await reloadSecrets(current);
    })();
  }, [reloadSecrets]);

  // provider / STT 端點換了就要換一組金鑰
  useEffect(() => {
    reloadSecrets(settingsRef.current);
  }, [settings.selectedProviderId, settings.sttBaseUrl, reloadSecrets]);

  // 其他 webview 改了金鑰要同步過來
  useEffect(() => {
    const unlisten = listen('secrets-updated', () => {
      reloadSecrets(settingsRef.current);
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [reloadSecrets]);

  // 串流辨識的即時結果（只有 overlay 需要顯示）
  useEffect(() => {
    if (!isOverlay) return;
    // 串流 STT 送字串，SenseVoice 送 { text }（且可能是簡體）
    const unlisten = listen<unknown>('stt-partial', (event) => {
      const s = stateRef.current;
      if (s !== 'recording' && s !== 'processing') return;
      const text = partialTextFromPayload(event.payload);
      if (recordingEngineRef.current !== 'sensevoice') {
        setPartialText(text);
        return;
      }
      const gen = sessionGen.current;
      toTraditional(text).then((converted) => {
        if (gen === sessionGen.current) setPartialText(converted);
      });
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [isOverlay]);

  // ---------------------------------------------------------------- 設定同步

  useEffect(() => {
    const unlisten = listen<AppSettings>('settings-updated', (event) => {
      const incoming = event.payload;
      // 使用者剛在對話框決定了 saybit:// 是否允許 → 處理等待中的那個指令
      const pending = pendingUrlCommandRef.current;
      if (pending && incoming?.urlSchemeDecision && incoming.urlSchemeDecision !== 'ask') {
        pendingUrlCommandRef.current = null;
        const fresh = Date.now() - pending.at < 60_000;
        if (incoming.urlSchemeDecision === 'allow' && fresh) {
          settingsRef.current = incoming;
          executeUrlCommandRef.current(pending.cmd);
        } else {
          logToFile(`URL 指令 ${pending.cmd.command} 未執行（decision=${incoming.urlSchemeDecision}${fresh ? '' : '，已逾時'}）`);
        }
      }
      setSettings((prev) => {
        if (JSON.stringify(prev) === JSON.stringify(incoming)) return prev;
        return incoming;
      });
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const updateSettings = useCallback((patch: Partial<AppSettings>) => {
    setSettings((prev) => {
      const updated = { ...prev, ...patch };
      persistSettings(updated);
      emit('settings-updated', updated).catch(() => {});
      return updated;
    });
  }, []);

  // ---------------------------------------------------------------- 生命週期

  useEffect(() => {
    logToFile(`pipeline mounted, label=${windowLabel}`);
    const chain = audioChain;
    // 上次當掉時音量可能還壓著：只讓 overlay（唯一會 duck 的 webview）還原
    if (windowLabel === 'overlay') restorePendingVolumeIfNeeded();
    return () => {
      if (warmReleaseTimerRef.current) clearTimeout(warmReleaseTimerRef.current);
      if (monitorRafRef.current) cancelAnimationFrame(monitorRafRef.current);
      if (duckTimerRef.current) clearTimeout(duckTimerRef.current);
      if (maxRecordingTimerRef.current) clearTimeout(maxRecordingTimerRef.current);
      restoreSystemVolume();
      chain.stop();
    };
  }, [windowLabel]);

  // 歷史自動清理：只讓設定視窗跑，避免兩個 webview 同時刪
  useEffect(() => {
    if (isOverlay) return;
    if (!settings.enableHistoryAutoCleanup) return;
    cleanupHistory(settings.historyRetentionDays)
      .then((n) => {
        if (n > 0) logToFile(`history cleanup: 刪除 ${n} 筆超過 ${settings.historyRetentionDays} 天的紀錄`);
      })
      .catch(() => {});
  }, [isOverlay, settings.enableHistoryAutoCleanup, settings.historyRetentionDays]);

  // 依 state 顯示/隱藏膠囊（僅 overlay 執行）
  useEffect(() => {
    if (!isOverlay) return;
    if (state === 'idle') {
      invoke('hide_window', { label: 'overlay' }).catch(() => {});
    } else {
      invoke('show_window', { label: 'overlay' }).catch(() => {});
    }
  }, [state, isOverlay]);

  // SenseVoice 預載：只在 overlay（實際錄音的 webview）、閒置時做，避免跟正在錄的 session 打架
  useEffect(() => {
    if (!isOverlay || settings.sttEngine !== 'sensevoice') return;
    if (stateRef.current !== 'idle') return;
    preloadSenseVoice();
  }, [isOverlay, settings.sttEngine]);

  // 熱鍵註冊：只讓設定視窗負責，避免兩邊互相 unregister
  // 主快捷鍵 + 各語音模式的快捷鍵一起註冊。不要退回 set_hotkey：那個相容包裝會清掉模式快捷鍵
  const hotkeyBindingsKey = JSON.stringify(hotkeyBindings(settings.hotkey, settings.voiceModes));
  useEffect(() => {
    if (isOverlay) return;
    const bindings = JSON.parse(hotkeyBindingsKey) as Array<{ id: string; shortcut: string }>;
    if (bindings.length === 0) return;
    invoke('set_hotkeys', { bindings }).catch((e) => {
      logToFile(`set_hotkeys 失敗：${e}`);
    });
  }, [hotkeyBindingsKey, isOverlay]);

  // 預覽無操作自動確認（前景 App 變了才進預覽的不自動確認，免得又打進別的 App）
  useEffect(() => {
    if (state !== 'previewing') return;
    if (previewAfterForegroundChangeRef.current) return;
    const ms = Math.max(0.5, settings.previewTimeout) * 1000;
    previewTimerRef.current = setTimeout(() => {
      logToFile(`preview ${settings.previewTimeout}s 無操作，自動確認`);
      autoConfirmRef.current();
    }, ms);
    return () => {
      if (previewTimerRef.current) {
        clearTimeout(previewTimerRef.current);
        previewTimerRef.current = null;
      }
    };
  }, [state, settings.previewTimeout]);

  // ---------------------------------------------------------------- 熱鍵

  /// 切換錄音（審查 C1）：處理中 / 完成中再按一律忽略，不開新錄音。
  /// mode 只對這一次錄音有效。
  const toggleRecording = (modeArg?: VoiceMode | null, opts: { fromUrl?: boolean } = {}) => {
    const mode = asVoiceMode(modeArg);
    const s = stateRef.current;
    if (s === 'idle' || s === 'listening' || s === 'error') {
      startRecording({ mode, fromUrl: opts.fromUrl === true });
    }
    else if (s === 'recording') stopRecording();
    else if (s === 'confirming') cancelConfirming();
    else logToFile(`toggleRecording 在 ${s} 狀態下忽略`);
  };
  const toggleRecordingRef = useRef(toggleRecording);
  toggleRecordingRef.current = toggleRecording;

  const handleToggle = useCallback(() => {
    toggleRecordingRef.current(null);
  }, []);

  useEffect(() => {
    if (!isOverlay) return;

    const unlistenPressed = listen<unknown>('hotkey-pressed', (event) => {
      const id = hotkeyIdFrom(event.payload);
      // 自動重複濾除：上一次 press 還沒等到 release 就再進來，代表使用者只是
      // 按著沒放，不是新的一次觸發。doubleTap 不受影響 —— 兩次點按之間必然有 release。
      if (hotkeyHeldRef.current.has(id)) return;
      hotkeyHeldRef.current.add(id);

      // 語音模式快捷鍵：一律按一下切換，不吃 trigger mode
      if (id !== MAIN_HOTKEY_ID) {
        const voiceMode = findVoiceModeById(settingsRef.current, id);
        if (!voiceMode) {
          logToFile(`找不到快捷鍵對應的語音模式: ${id}`);
          return;
        }
        toggleRecordingRef.current(voiceMode);
        return;
      }

      const mode = settingsRef.current.hotkeyTriggerMode;
      hotkeyPressedAtRef.current = Date.now();

      if (mode === 'toggle') {
        handleToggle();
        return;
      }
      if (mode === 'hold') {
        // 按住說話：按下就開錄，放開才停
        const s = stateRef.current;
        if (s === 'idle' || s === 'listening' || s === 'error') startRecording();
        return;
      }
      if (mode === 'doubleTap') {
        const now = Date.now();
        const elapsed = now - lastHotkeyTapRef.current;
        lastHotkeyTapRef.current = now;
        // 300ms 內連按兩次才觸發，與原生版 doubleTapInterval 一致
        if (elapsed <= 300) {
          lastHotkeyTapRef.current = 0;
          handleToggle();
        }
      }
    });

    const unlistenReleased = listen<unknown>('hotkey-released', (event) => {
      const id = hotkeyIdFrom(event.payload);
      hotkeyHeldRef.current.delete(id);

      if (id !== MAIN_HOTKEY_ID) return;
      if (settingsRef.current.hotkeyTriggerMode !== 'hold') return;
      // 防手滑：按不到 200ms 視為誤觸，不送出
      const heldMs = Date.now() - hotkeyPressedAtRef.current;
      if (stateRef.current !== 'recording') return;
      if (heldMs < 200) {
        cancelRecording();
        return;
      }
      stopRecording();
    });

    return () => {
      unlistenPressed.then((fn) => fn());
      unlistenReleased.then((fn) => fn());
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOverlay, handleToggle]);

  // ---------------------------------------------------------------- saybit:// 指令

  /// 實際執行（已確認允許）。對齊原生 AppDelegate.handleURL。
  executeUrlCommandRef.current = (cmd: UrlCommand) => {
    const mode = cmd.mode ? findVoiceMode(settingsRef.current, cmd.mode) : null;
    if (cmd.mode && !mode) logToFile(`URL scheme 找不到語音模式: ${cmd.mode}`);
    logToFile(`URL scheme: ${cmd.command}${cmd.mode ? ` mode=${cmd.mode}` : ''}`);
    const s = stateRef.current;
    switch (cmd.command) {
      case 'toggle':
        toggleRecordingRef.current(mode, { fromUrl: true });
        break;
      case 'start':
        if (s !== 'recording') toggleRecordingRef.current(mode, { fromUrl: true });
        break;
      case 'stop':
        if (s === 'recording') stopRecording();
        break;
      case 'cancel':
        cancelRecording();
        break;
      case 'settings':
        // 由 main 視窗處理：透過 settingsTabRequest 交給 UI 開分頁
        if (!isOverlay) setSettingsTabRequest({ tab: cmd.tab ?? null, at: Date.now() });
        break;
    }
  };

  /// url-command 事件與冷啟動佇列共用的處理函式
  const handleUrlCommandPayload = (payload: unknown) => {
    const cmd = parseUrlCommand(payload);
    if (!cmd) {
      logToFile(`未知的 URL 指令: ${JSON.stringify(payload)}`);
      return;
    }
    if (cmd.command === 'settings') {
      if (!isOverlay) executeUrlCommandRef.current(cmd);
      return;
    }
    if (!isOverlay) return; // 錄音類指令只給 overlay
    const route = routeUrlCommand(cmd, settingsRef.current.urlSchemeDecision);
    if (route === 'ignore') {
      logToFile(`URL 指令 ${cmd.command} 被拒絕（使用者設定為不允許）`);
      return;
    }
    if (route === 'ask') {
      pendingUrlCommandRef.current = { cmd, at: Date.now() };
      emitTo('main', URL_COMMAND_ASK_EVENT, cmd).catch(() => {
        emit(URL_COMMAND_ASK_EVENT, cmd).catch(() => {});
      });
      invoke('show_window', { label: 'main' }).catch(() => {});
      return;
    }
    executeUrlCommandRef.current(cmd);
  };
  const handleUrlCommandRef = useRef(handleUrlCommandPayload);
  handleUrlCommandRef.current = handleUrlCommandPayload;

  // 兩個 webview 都掛：overlay 處理錄音類指令，main 處理 settings。
  // 掛好之後取一次冷啟動佇列（listener 還沒掛上時收到的 URL）。
  useEffect(() => {
    let disposed = false;
    const unlisten = listen<unknown>(URL_COMMAND_EVENT, (event) => {
      handleUrlCommandRef.current(event.payload);
    });
    unlisten
      .then(() => (disposed ? [] : invoke<unknown[]>('take_pending_url_commands')))
      .then((cmds) => {
        if (disposed || !Array.isArray(cmds)) return;
        for (const c of cmds) handleUrlCommandRef.current(c);
      })
      .catch((e) => logToFile(`take_pending_url_commands 失敗：${e}`));
    return () => {
      disposed = true;
      unlisten.then((fn) => fn());
    };
  }, []);

  // ---------------------------------------------------------------- 錄音

  const clearRecordingTimers = () => {
    if (maxRecordingTimerRef.current) {
      clearTimeout(maxRecordingTimerRef.current);
      maxRecordingTimerRef.current = null;
    }
    if (duckTimerRef.current) {
      clearTimeout(duckTimerRef.current);
      duckTimerRef.current = null;
    }
  };

  /// 錄音中的即時辨識 session 全部丟掉（取消、過短、無聲時用）
  const discardLiveSessions = () => {
    audioChain.setLiveTap(null);
    if (streamingActiveRef.current) {
      streamingActiveRef.current = false;
      cancelStreaming();
    }
    const sv = senseVoiceRef.current;
    if (sv) {
      senseVoiceRef.current = null;
      sv.cancel();
    }
  };

  const startRecording = async (opts?: { mode?: VoiceMode | null; fromUrl?: boolean }) => {
    const s0 = stateRef.current;
    if (s0 !== 'idle' && s0 !== 'listening' && s0 !== 'error') return;
    // 同步旗標，擋掉前置作業還沒跑完就再進來的第二次呼叫
    if (isStartingRef.current) {
      logToFile('startRecording 已在進行中，忽略重複觸發');
      return;
    }
    isStartingRef.current = true;

    if (warmReleaseTimerRef.current) {
      clearTimeout(warmReleaseTimerRef.current);
      warmReleaseTimerRef.current = null;
    }

    // 新 session：舊的回呼 / 計時器（例如錯誤畫面的自動重置）全部作廢
    const gen = bumpGeneration();
    const alive = () => gen === sessionGen.current;
    const voiceMode = asVoiceMode(opts?.mode);
    activeModeRef.current = voiceMode;
    setActiveModeName(voiceMode?.name ?? null);
    previewAfterForegroundChangeRef.current = false;
    forcePreviewRef.current = false;
    if (s0 === 'error') setErrorMsg('');

    const current = settingsRef.current;
    recordingEngineRef.current = current.sttEngine;

    // ⚠️ 順序很重要：必須在膠囊出現「之前」查前景 App 與選取文字，
    // 否則查到的會是 Saybit 自己。
    if (current.enableContextAwareness) {
      try {
        const ctx = await captureForegroundApp();
        if (current.enableSelectionCapture && isSelectionCaptureSafe(ctx.identifier)) {
          ctx.selectedText = await captureSelectedText();
        }
        capturedContextRef.current = ctx;
        logToFile(
          `context: app=${ctx.appName} id=${ctx.identifier} selectedLen=${ctx.selectedText.length}` +
            (ctx.isSelf ? ' ⚠️ 前景是 Saybit 自己，結果會貼回本視窗' : '')
        );
      } catch (e) {
        capturedContextRef.current = { ...EMPTY_CONTEXT };
        logToFile(`context capture failed: ${e}`);
      }
    } else {
      // 不做情境感知也要知道前景 App 是誰：注入前比對要用（審查 H6）
      const fg = await captureForegroundApp();
      capturedContextRef.current = {
        ...EMPTY_CONTEXT,
        appName: fg.appName,
        bundleId: fg.bundleId,
        isSelf: fg.isSelf,
      };
    }

    // URL 觸發：開 URL 會讓 Saybit 變前景，Rust 已把焦點還回去；以最近的外部 App 為注入目標
    if (opts?.fromUrl) {
      try {
        const ext = await invoke<Record<string, unknown>>('last_external_app');
        const bundleId = String(ext?.bundleId ?? ext?.bundle_id ?? '');
        const appName = String(ext?.appName ?? ext?.app_name ?? '');
        const self = !bundleId || isSelfApp(appName, bundleId);
        const ctx = capturedContextRef.current;
        capturedContextRef.current = {
          ...ctx,
          appName: appName || ctx.appName,
          bundleId: self ? '' : bundleId,
          isSelf: self,
        };
        if (self) {
          forcePreviewRef.current = true;
          logToFile('URL 觸發：找不到外部目標 App，結果改為預覽');
        }
      } catch (e) {
        forcePreviewRef.current = true;
        logToFile(`last_external_app 失敗，結果改為預覽：${e}`);
      }
    }

    if (!alive()) {
      isStartingRef.current = false;
      return;
    }

    try {
      invoke('show_window', { label: 'overlay' }).catch(() => {});

      await audioChain.start({
        deviceId: current.selectedInputDeviceId,
        echoCancellation: current.enableEchoCancellation,
        bandpass: current.enableVoiceBandpass,
        preBufferSeconds: current.preBufferSeconds,
      });
      if (!alive()) return;

      hasDetectedSpeechRef.current = false;
      recordingStartRef.current = Date.now();
      setPartialText('');

      // 串流模式：先把連線開起來再開始擷取，讓第一塊音訊就有地方送。
      // 連線失敗不中斷錄音 —— 退回批次辨識，使用者頂多是慢一點而不是整個用不了。
      streamingActiveRef.current = false;
      senseVoiceRef.current = null;
      let feedPrefixToTap = false;
      if (current.sttEngine === 'streaming') {
        try {
          const streamingKey = await loadSecret(
            streamingKeyAccount(current.streamingProvider)
          );
          await startStreaming({
            provider: current.streamingProvider,
            endpoint: current.streamingEndpoint,
            apiKey: streamingKey,
            appId: current.streamingAppId,
            model: current.streamingModel,
          });
          if (!alive()) {
            cancelStreaming();
            return;
          }
          streamingActiveRef.current = true;
          audioChain.setLiveTap((chunk) => {
            pushStreamingAudio(pcmToInt16Bytes(chunk)).catch(() => {});
          });
          logToFile(`串流辨識連線成功（${current.streamingProvider}）`);
        } catch (e: any) {
          logToFile(`串流辨識連線失敗，改用批次辨識：${e?.message || e}`);
          audioChain.setLiveTap(null);
        }
      } else if (current.sttEngine === 'sensevoice') {
        // SenseVoice 沒有備援：模型沒裝 / 後端不支援就直接告訴使用者去哪裡處理
        let session: SenseVoiceSession;
        try {
          session = await SenseVoiceSession.start(senseVoiceLanguageFor(current.whisperLanguage));
        } catch (e: any) {
          if (!alive()) return;
          audioChain.setLiveTap(null);
          showError(e?.message || String(e));
          return;
        }
        if (!alive()) {
          session.cancel();
          return;
        }
        senseVoiceRef.current = session;
        audioChain.setLiveTap((chunk) => session.push(chunk));
        feedPrefixToTap = true;
      } else {
        audioChain.setLiveTap(null);
      }

      audioChain.beginCapture({ feedPrefixToTap });

      if (current.enableSoundFeedback) playFeedbackTone('start');

      setRecordingStartTime(Date.now());
      transitionTo('recording');
      monitorAudioLevel();

      // Ducking：延遲 200 ms，讓開始提示音不被一起壓掉
      if (current.enableDucking) {
        duckTimerRef.current = setTimeout(() => {
          duckTimerRef.current = null;
          if (alive() && stateRef.current === 'recording') duckSystemVolume();
        }, DUCK_DELAY_MS);
      }
      // 單次錄音上限
      const maxSec = Math.max(5, current.maxRecordingSeconds || 300);
      maxRecordingTimerRef.current = setTimeout(() => {
        maxRecordingTimerRef.current = null;
        if (alive() && stateRef.current === 'recording') {
          logToFile(`錄音達上限 ${maxSec}s，自動停止`);
          stopRecording();
        }
      }, maxSec * 1000);
    } catch (err: any) {
      if (alive()) showError(`${tr('errMicOpenFailed', '麥克風開啟失敗')}: ${err?.message || err}`);
    } finally {
      isStartingRef.current = false;
      // 沒進到錄音（被取消 / SenseVoice 起不來）→ 麥克風照樣排程釋放
      if (stateRef.current !== 'recording') scheduleWarmRelease();
    }
  };

  /// 音量監控 + 靜音自動停止。audioLevel state 節流 ~15Hz，
  /// 波形本身是直接讀 analyser，不吃這個 state。
  const monitorAudioLevel = () => {
    let lastSetTs = 0;

    const tick = () => {
      if (stateRef.current !== 'recording') {
        monitorRafRef.current = null;
        return;
      }

      const current = settingsRef.current;
      const rms = audioChain.currentLevel(current.micSensitivity);

      const now = performance.now();
      if (now - lastSetTs > 66) {
        setAudioLevel(rms);
        lastSetTs = now;
      }

      if (current.enableAutoStop) {
        if (rms >= 0.15) {
          hasDetectedSpeechRef.current = true;
          if (silenceTimerRef.current) {
            clearTimeout(silenceTimerRef.current);
            silenceTimerRef.current = null;
          }
        } else if (rms < 0.08) {
          if (!silenceTimerRef.current) {
            // 說過話 → 用設定的語後靜音逾時；從沒說過話 → 固定 3 秒放棄
            const delay = hasDetectedSpeechRef.current ? current.silenceTimeout * 1000 : 3000;
            silenceTimerRef.current = setTimeout(() => stopRecording(), delay);
          }
        }
      }

      monitorRafRef.current = requestAnimationFrame(tick);
    };

    monitorRafRef.current = requestAnimationFrame(tick);
  };

  const clearSilenceTimer = () => {
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
    }
  };

  /// 排程釋放麥克風：留 60 秒暖機供連續錄音零遺失，兼顧隱私。
  const scheduleWarmRelease = () => {
    if (warmReleaseTimerRef.current) clearTimeout(warmReleaseTimerRef.current);
    warmReleaseTimerRef.current = setTimeout(() => {
      audioChain.stop();
      warmReleaseTimerRef.current = null;
    }, 60000);
  };

  const stopRecording = () => {
    if (stateRef.current !== 'recording') return;
    clearSilenceTimer();
    clearRecordingTimers();
    restoreSystemVolume();

    audioChain.setLiveTap(null);
    const captured = audioChain.endCapture();
    if (settingsRef.current.enableSoundFeedback) playFeedbackTone('stop');
    scheduleWarmRelease();

    processAudio(captured.pcm, captured.sampleRate, captured.durationSeconds, sessionGen.current);
  };

  /// 取消（誤觸 hold 模式、按取消鈕、URL cancel）。錄音中、處理中、預覽、倒數都能取消；
  /// 取消會中斷在飛的 STT / LLM 請求，且不顯示成錯誤。
  const cancelRecording = () => {
    const s = stateRef.current;
    bumpGeneration();
    clearSilenceTimer();
    clearRecordingTimers();
    discardLiveSessions();
    if (s === 'recording') {
      audioChain.endCapture();
      scheduleWarmRelease();
    }
    // 逐字輸入中（done）取消：叫 Rust 停止打字
    if (s === 'done') invoke('cancel_typing').catch(() => {});
    if (s !== 'idle') logToFile(`已取消（${s}）`);
    resetPipeline();
  };

  // ---------------------------------------------------------------- 主流程

  const processAudio = async (
    pcm: Float32Array,
    sampleRate: number,
    durationSeconds: number,
    gen: number
  ) => {
    const alive = () => gen === sessionGen.current;
    transitionTo('processing');
    setRawText('');
    setProcessedText('');
    setActionConfirmation('');

    const current = settingsRef.current;
    const keys = secretsRef.current;
    const context = capturedContextRef.current;
    const engine = recordingEngineRef.current;
    const voiceMode = activeModeRef.current;
    const controller = sessionGen.newController();
    const signal = controller.signal;

    try {
      const pcm16k = resampleTo16k(pcm, sampleRate);
      if (pcm16k.length < 16000 * 0.2) {
        // 少於 0.2 秒基本上是誤觸，直接收工
        logToFile(`錄音過短（${(pcm16k.length / 16000).toFixed(2)}s），略過`);
        discardLiveSessions();
        resetPipeline();
        return;
      }

      // 靜音閘：whisper 餵到無聲不會回空字串，而是吐出訓練資料裡的字幕檔殘留
      // （「字幕:CM 李宗盛」之類），那串會被當成真的轉錄貼進使用者的視窗。
      const energy = measureEnergy(pcm16k);
      if (!hasAudibleSpeech(energy)) {
        logToFile(
          `音量過低（peak=${energy.peak.toFixed(4)} rms=${energy.rms.toFixed(4)}），判定為無聲，略過辨識`
        );
        discardLiveSessions();
        resetPipeline();
        return;
      }

      // ---- 個人字典（STT 偏置、辨識後字面替換、LLM 精煉）----
      const dictEntries = await db.dictionary.toArray().catch(() => []);
      if (!alive()) return;
      const personalDictionary = toPersonalDictionary(dictEntries);

      let sttPrompt = '以下是繁體中文（台灣）的語音逐字稿。';
      const dictWords = preferredSpellings(dictEntries, 30);
      if (dictWords.length > 0) {
        sttPrompt += `常見詞彙：${dictWords.join('、')}。`;
      }

      // ---- Stage 0：STT ----
      const sttRaw = await runSTT(pcm16k, engine, current, keys.sttKey, sttPrompt, signal);
      if (!alive()) return;
      logToFile(`STT ok: "${sttRaw.slice(0, 80)}"`, true);

      if (!sttRaw.trim()) {
        resetPipeline();
        return;
      }

      // 第二道防線：音量閘放行了但模型還是吐出字幕檔殘留（例如背景音樂夠大聲）
      if (isLikelyHallucination(sttRaw)) {
        logToFile(`判定為 whisper 幻覺，丟棄："${sttRaw}"`, true);
        resetPipeline();
        return;
      }
      // 字典字面替換：LLM 收到的就已經是正確寫法（本機小模型也不會漏換）
      const transcript = applyDictionary(sttRaw, dictEntries);
      setRawText(transcript);
      retryContextRef.current = { transcript, context, mode: voiceMode };

      // ---- 自訂技能（snippets）----
      const skillEntries = await db.skills.toArray().catch(() => []);
      if (!alive()) return;
      const snippets: Record<string, string> = {};
      for (const skill of skillEntries) {
        if (skill.triggerWord) snippets[skill.triggerWord] = skill.prompt;
      }

      const provider = resolveProvider(
        current.selectedProviderId,
        current.customProviders,
        current.lmStudioBaseUrl
      );
      const llmKey = keys.llmKey || keys.sttKey;
      const hasSelection = Boolean(context.selectedText);

      // ---- 語氣：per-app 規則優先，其次全域設定 ----
      const rule = matchContextRule(current.contextRules, context.identifier);
      const ruleTone = rule?.toneOverride && rule.toneOverride !== 'auto' ? rule.toneOverride : null;
      const globalTone = current.toneStyle !== 'auto' ? current.toneStyle : null;

      let intent: IntentResponse;
      let systemPrompt: string;
      let temperature = temperatureForStyle(current.promptStyle);
      let tone: string | null;
      let payloadMode: string;

      if (voiceMode) {
        // ---- 語音模式：跳過意圖分類，直接照模式指令 ----
        intent = { intent: 'dictation', content: transcript };
        systemPrompt = forMode(voiceMode.instructions, hasSelection);
        temperature = 0.3;
        tone = ruleTone || globalTone;
        payloadMode = hasSelection ? 'edit' : 'dictation';
        logToFile(`voice mode: ${voiceMode.name}（略過意圖分類）`);
      } else {
        // ---- Stage 1：意圖分類 ----
        intent = await classifyIntent(
          transcript,
          llmKey,
          provider,
          current.selectedModel,
          snippets,
          hasSelection,
          signal
        );
        if (!alive()) return;
        logToFile(
          `intent=${intent.intent} lang=${intent.language ?? '-'} style=${intent.style ?? '-'}` +
            (intent.degradedReason ? ` ⚠️ 意圖分析未成功，降級為聽寫：${intent.degradedReason}` : '')
        );

        // ---- 行事曆 / 提醒事項（僅 macOS 有原生後端）----
        if (
          current.enableActionIntents &&
          (intent.intent === 'create_event' || intent.intent === 'create_reminder')
        ) {
          const handled = await handleActionIntent(intent, provider, llmKey, current, transcript, signal, alive);
          if (!alive()) return;
          if (handled) return;
          // 沒處理成功就往下走一般精煉流程，至少把話打出來
        }

        tone = intent.style || ruleTone || globalTone;

        // ---- system prompt：專用意圖優先，否則走風格 prompt ----
        systemPrompt = promptForIntent(intent, current.languagePreference);
        if (!systemPrompt) systemPrompt = promptForStyle(current.promptStyle);
        // 技能命中時把該技能的指令附上
        if (intent.intent === 'skill' && intent.skill_name && snippets[intent.skill_name]) {
          systemPrompt += `\n\n## Skill: ${intent.skill_name}\n${snippets[intent.skill_name]}`;
        }
        payloadMode = modeForIntent(intent, current.selectedMode, hasSelection);
      }
      if (rule?.additionalPrompt) {
        systemPrompt += `\n\n## App-Specific Instruction (${context.identifier})\n${rule.additionalPrompt}`;
      }

      const payload: LLMPayload = {
        transcript: voiceMode ? transcript : intent.content || transcript,
        context: context.identifier,
        mode: payloadMode,
        tone,
        language_preference: current.enableAutoLanguageDetection
          ? null
          : current.languagePreference,
        personal_dictionary: personalDictionary,
        snippets,
        whisper_mode: current.enableWhisperMode,
        existing_text: context.selectedText || null,
      };

      // ---- Stage 2：串流精煉 ----
      const result = await refineTextStream(
        payload,
        llmKey,
        provider,
        current.selectedModel,
        systemPrompt,
        temperature,
        current.useCustomLLMParams
          ? {
              maxTokens: current.llmMaxTokens,
              frequencyPenalty: current.llmFrequencyPenalty,
              presencePenalty: current.llmPresencePenalty,
              topP: current.llmTopP,
            }
          : {},
        (chunk) => {
          if (alive()) setProcessedText((prev) => prev + chunk);
        },
        signal
      );
      if (!alive()) return;

      let finalText = extractReplacementIfCommandJSON(result.text);
      const terminal = isTerminalContext(context);
      // 終端機：尾端換行會直接送出指令
      if (terminal) finalText = finalText.replace(/[\r\n]+$/, '');
      setProcessedText(finalText);
      logToFile(`refine ok: "${finalText.slice(0, 80)}" usage=${JSON.stringify(result.usage)}`, true);

      await saveHistory({
        transcript,
        finalText,
        context,
        intent,
        tone,
        durationSeconds,
        model: current.selectedModel,
        usage: result.usage,
        voiceModeName: voiceMode?.name ?? null,
      });
      if (!alive()) return;

      // 強制預覽：終端機（審查 M26）；帶選取文字又開 Smart Send（審查 M11，選取內容可能夾帶注入）
      const forcePreview =
        terminal || (hasSelection && current.enableSmartSend) || forcePreviewRef.current;
      if (current.enablePreviewBeforeInject || forcePreview) {
        if (forcePreview && !current.enablePreviewBeforeInject) {
          logToFile(
            terminal
              ? '終端機目標，強制預覽'
              : forcePreviewRef.current
                ? 'URL 觸發且無外部目標，強制預覽'
                : '帶選取文字且 Smart Send 開啟，強制預覽'
          );
        }
        transitionTo('previewing');
      } else {
        await injectResult(finalText);
      }
    } catch (err: any) {
      if (!alive() || signal.aborted || isCancelledError(err)) {
        logToFile('處理已取消');
        return;
      }
      showError(err?.message || String(err));
    } finally {
      sessionGen.release(controller);
    }
  };

  /// Command 模式下模型可能回 {"action":"replace","replacement":"..."}，
  /// 直接貼 JSON 出去會很醜，取出 replacement 欄位（對齊原生版）。
  const extractReplacementIfCommandJSON = (text: string): string => {
    const trimmed = text.trim();
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) return text;
    try {
      const parsed = JSON.parse(trimmed);
      if (parsed && typeof parsed.replacement === 'string') return parsed.replacement;
    } catch {
      /* 不是 JSON 就原樣輸出 */
    }
    return text;
  };

  const modeForIntent = (
    intent: IntentResponse,
    configured: AppSettings['selectedMode'],
    hasSelection: boolean
  ): string => {
    if (hasSelection) return 'edit';
    if (intent.intent === 'dictation') return configured;
    return 'command';
  };

  const runSTT = async (
    pcm16k: Float32Array,
    engine: SttEngine,
    current: AppSettings,
    sttKey: string,
    sttPrompt: string,
    signal: AbortSignal
  ): Promise<string> => {
    // 兩條本機路徑共用同一份 raw PCM body
    const rawPcm = () =>
      new Uint8Array(pcm16k.buffer, pcm16k.byteOffset, pcm16k.byteLength);

    if (engine === 'local' || engine === 'apple') {
      let peak = 0;
      for (let i = 0; i < pcm16k.length; i++) {
        const a = Math.abs(pcm16k[i]);
        if (a > peak) peak = a;
      }
      logToFile(
        `${engine} STT start: ${(pcm16k.length / 16000).toFixed(2)}s, peak=${peak.toFixed(3)}`
      );
    }

    // SenseVoice：音訊在錄音期間就推過去了，這裡只要收尾取結果（已簡轉繁）
    if (engine === 'sensevoice') {
      const session = senseVoiceRef.current;
      senseVoiceRef.current = null;
      if (!session) {
        throw new Error(tr('errSenseVoiceNoSession', 'SenseVoice 沒有啟動成功，請重新錄音'));
      }
      if (signal.aborted) {
        session.cancel();
        return '';
      }
      const text = await session.finish();
      logToFile(`SenseVoice 完成："${text.slice(0, 80)}"`, true);
      return text;
    }

    // 串流模式：音訊在錄音期間就一路推過去了，這裡只要送結束訊號收結果。
    // 連線當初沒建立成功（streamingActiveRef 為 false）就直接往下走批次路徑。
    if (engine === 'streaming' && streamingActiveRef.current) {
      streamingActiveRef.current = false;
      try {
        const streamed = await finishStreaming();
        logToFile(`串流辨識完成："${streamed.slice(0, 80)}"`, true);
        if (streamed.trim()) return streamed;
        logToFile('串流辨識回空結果，退回批次辨識');
      } catch (e: any) {
        logToFile(`串流辨識收尾失敗，退回批次辨識：${e?.message || e}`);
      }
      if (signal.aborted) return '';
      // 走到這裡代表串流沒給出東西 —— 整段音訊還在手上，用雲端 Whisper 補救
    }

    if (engine === 'apple') {
      try {
        return await invoke<string>('transcribe_apple', rawPcm(), {
          headers: {
            locale: current.appleSpeechLocale,
            'require-on-device': String(current.appleSpeechOnDeviceOnly),
          },
        });
      } catch (e: any) {
        logToFile(`apple STT FAILED: ${e?.message || e}`);
        throw new Error(`Apple 語音辨識失敗: ${e?.message || e}`);
      }
    }

    if (engine === 'local') {
      try {
        return await invoke<string>('transcribe_local', rawPcm());
      } catch (e: any) {
        logToFile(`local STT FAILED: ${e?.message || e}`);
        throw new Error(`本地 STT 失敗: ${e?.message || e}`);
      }
    }

    if (!sttKey) {
      throw new Error(
        engine === 'streaming'
          ? '串流辨識沒有結果，且未設定可用於備援的 STT API Key'
          : '未設定 STT API Key，請前往設定填入（或改用本地 whisper）'
      );
    }

    const wav = pcmToWavBlob(pcm16k);
    logToFile(
      `Whisper fetch start, wav=${wav.size}B, keyLen=${sttKey.length}, url=${current.sttBaseUrl}, model=${current.sttModel}`
    );
    try {
      return await transcribeAudio(
        wav,
        sttKey,
        current.sttModel,
        current.whisperLanguage,
        current.sttBaseUrl,
        sttPrompt,
        signal
      );
    } catch (e: any) {
      if (isCancelledError(e)) throw e;
      logToFile(`Whisper FAILED: ${e?.message || e}`);
      throw new Error(`${e?.message || e}`);
    }
  };

  const saveHistory = async (args: {
    transcript: string;
    finalText: string;
    context: AppContext;
    intent: IntentResponse;
    tone: string | null;
    durationSeconds: number;
    model: string;
    usage: LLMUsage | null;
    voiceModeName?: string | null;
  }) => {
    const usage = args.usage;
    const cost = usage
      ? costFor(args.model, usage.promptTokens, usage.completionTokens)
      : null;

    try {
      await db.history.add({
        rawTranscript: args.transcript,
        processedText: args.finalText,
        appContext: args.context.identifier || 'unknown',
        appName: args.context.appName,
        mode: args.intent.intent === 'dictation' ? 'dictation' : 'command',
        // 語音模式記成 voice_mode，統計頁才分得出來
        intent: args.voiceModeName ? 'voice_mode' : args.intent.intent,
        tone: args.tone,
        timestamp: Date.now(),
        duration: Math.round(args.durationSeconds),
        modelName: args.model,
        promptTokens: usage?.promptTokens ?? 0,
        completionTokens: usage?.completionTokens ?? 0,
        totalTokens: usage?.totalTokens ?? 0,
        costUsd: cost,
      });
    } catch (e) {
      logToFile(`history 寫入失敗: ${e}`);
    }
  };

  // ---------------------------------------------------------------- 行事曆 / 提醒

  /// 回傳 true 代表已處理完畢（不再往下走精煉流程）。
  const handleActionIntent = async (
    intent: IntentResponse,
    provider: ReturnType<typeof resolveProvider>,
    llmKey: string,
    current: AppSettings,
    transcript: string,
    signal: AbortSignal,
    alive: () => boolean
  ): Promise<boolean> => {
    const systemPrompt = promptForIntent(intent, current.languagePreference);
    const content = intent.content || transcript;

    try {
      if (intent.intent === 'create_event') {
        const parsed = await completeJSON<EventPayload>(
          systemPrompt,
          content,
          llmKey,
          provider,
          current.selectedModel,
          signal
        );
        if (!alive()) return true;
        if (!parsed?.title || !parsed.date) return false;
        await invoke('create_calendar_event', {
          title: parsed.title,
          startIso: parsed.date,
          durationMinutes: parsed.duration_minutes ?? 60,
          location: parsed.location ?? null,
          notes: parsed.notes ?? null,
        });
        finishWithConfirmation(parsed.confirmation_text || `已建立行程：${parsed.title}`);
        return true;
      }

      const parsed = await completeJSON<ReminderPayload>(
        systemPrompt,
        content,
        llmKey,
        provider,
        current.selectedModel,
        signal
      );
      if (!alive()) return true;
      if (!parsed?.title) return false;
      await invoke('create_reminder', {
        title: parsed.title,
        dueIso: parsed.due_date ?? null,
        notes: parsed.notes ?? null,
      });
      finishWithConfirmation(parsed.confirmation_text || `已建立提醒：${parsed.title}`);
      return true;
    } catch (e: any) {
      if (isCancelledError(e) || !alive()) throw e;
      // 非 macOS 平台沒有這兩個 command，或使用者拒絕授權 → 降級成一般聽寫
      logToFile(`action intent 失敗，降級為聽寫: ${e?.message || e}`);
      return false;
    }
  };

  const finishWithConfirmation = (text: string) => {
    setActionConfirmation(text);
    setProcessedText(text);
    transitionTo('done');
    scheduleReset(2500, 'done');
  };

  // ---------------------------------------------------------------- 注入

  /// 只在 session 沒換過、且還停在預期狀態時才重置（避免舊計時器把新錄音收掉）
  const scheduleReset = (ms: number, expected: PipelineState) => {
    const gen = sessionGen.current;
    setTimeout(() => {
      if (gen === sessionGen.current && stateRef.current === expected) resetPipeline();
    }, ms);
  };

  /// 注入（審查 H6）：帶錄音開始時的前景 App，Rust 端不一致回 foreground-changed → 改進預覽。
  /// skipForegroundCheck：使用者在預覽中手動確認，目標就是他現在所在的 App。
  const injectResult = async (text: string, opts: { skipForegroundCheck?: boolean } = {}) => {
    const current = settingsRef.current;
    const context = capturedContextRef.current;
    const gen = sessionGen.current;
    const alive = () => gen === sessionGen.current;
    const expectedBundleId = opts.skipForegroundCheck ? null : expectedBundleIdOf(context);
    const terminal = isTerminalContext(context);
    // 前景換過才進預覽的那次，或終端機：一律不 Smart Send
    const smartSend =
      current.enableSmartSend && !terminal && !previewAfterForegroundChangeRef.current;
    try {
      logToFile(
        `inject start: mode=${current.injectionMode} smartSend=${smartSend} len=${text.length} expected=${expectedBundleId ?? '-'}`
      );
      transitionTo('done');

      // 剪貼簿備份/還原、逐字輸入、取代選取都在 Rust 端處理
      try {
        await invoke('inject_text', {
          text,
          mode: current.injectionMode,
          // Wayland 等拿不到 bundle_id 時是空字串 → 不傳，略過比對
          expectedBundleId: expectedBundleId || undefined,
          // 逐字輸入時，聊天類 App 的換行要 Shift+Enter，否則每行都會被送出
          newlineWithShift: context.category === 'chat_messaging',
        });
      } catch (e) {
        if (isInjectCancelled(e)) {
          // 逐字輸入被取消或被新的注入取代：當作取消，不是錯誤
          logToFile('注入已取消');
          if (alive()) resetPipeline();
          return;
        }
        if (!isForegroundChanged(e)) throw e;
        if (!alive()) return;
        logToFile('前景 App 已切換，改為預覽，不自動注入');
        previewAfterForegroundChangeRef.current = true;
        setProcessedText(text);
        transitionTo('previewing');
        return;
      }
      if (!alive()) return;
      logToFile('inject invoked');

      if (smartSend) {
        transitionTo('confirming');
        let remaining = Math.round(current.smartSendDelay);
        setCountdown(remaining);

        smartSendTimerRef.current = setInterval(async () => {
          if (!alive() || stateRef.current !== 'confirming') {
            if (smartSendTimerRef.current) clearInterval(smartSendTimerRef.current);
            smartSendTimerRef.current = null;
            return;
          }
          remaining -= 1;
          setCountdown(remaining);
          if (remaining <= 0) {
            if (smartSendTimerRef.current) clearInterval(smartSendTimerRef.current);
            smartSendTimerRef.current = null;
            logToFile('smart send: invoking Enter');
            // 送 Enter 前再比對一次前景，不一致就取消（Discord 誤送出事故的根因）
            try {
              await invoke('simulate_enter', {
                expectedBundleId: expectedBundleIdOf(context) || undefined,
              });
            } catch (e) {
              logToFile(
                isForegroundChanged(e)
                  ? 'smart send 取消：前景 App 已切換'
                  : `smart send 失敗：${(e as { message?: string })?.message ?? e}`
              );
            }
            if (alive()) resetPipeline();
          }
        }, 1000);
      } else {
        scheduleReset(2000, 'done');
      }
    } catch (err: any) {
      if (alive()) showError(`${tr('errInjectFailed', '注入失敗')}: ${err?.message || err}`);
    }
  };

  const confirmInject = async () => {
    if (stateRef.current !== 'previewing') return;
    // 使用者手動確認 = 目標就是他現在的前景 App
    await injectResult(processedTextRef.current, { skipForegroundCheck: true });
  };

  autoConfirmRef.current = () => {
    if (stateRef.current === 'previewing' && !previewAfterForegroundChangeRef.current) {
      injectResult(processedTextRef.current);
    }
  };

  const cancelConfirming = () => {
    if (smartSendTimerRef.current) {
      clearInterval(smartSendTimerRef.current);
      smartSendTimerRef.current = null;
    }
    resetPipeline();
  };

  /// 重新生成：沿用原本的 context 與意圖判斷，不再退化成 dictation。
  const regenerateResult = async () => {
    if (stateRef.current !== 'previewing') return;
    const retry = retryContextRef.current;
    if (!retry) return;

    if (previewTimerRef.current) {
      clearTimeout(previewTimerRef.current);
      previewTimerRef.current = null;
    }
    // 重新生成是新的一輪請求：作廢舊的，取消鈕也要能中斷它
    const gen = bumpGeneration();
    const alive = () => gen === sessionGen.current;
    const controller = sessionGen.newController();
    const signal = controller.signal;
    capturedContextRef.current = retry.context;
    previewAfterForegroundChangeRef.current = false;
    transitionTo('processing');
    setProcessedText('');

    const current = settingsRef.current;
    const keys = secretsRef.current;
    const provider = resolveProvider(
      current.selectedProviderId,
      current.customProviders,
      current.lmStudioBaseUrl
    );
    const llmKey = keys.llmKey || keys.sttKey;

    try {
      const dictEntries = await db.dictionary.toArray().catch(() => []);
      if (!alive()) return;
      const personalDictionary = toPersonalDictionary(dictEntries);
      const hasSelection = Boolean(retry.context.selectedText);

      const rule = matchContextRule(current.contextRules, retry.context.identifier);
      const ruleTone =
        rule?.toneOverride && rule.toneOverride !== 'auto' ? rule.toneOverride : null;
      const globalTone = current.toneStyle !== 'auto' ? current.toneStyle : null;

      let systemPrompt = retry.mode
        ? forMode(retry.mode.instructions, hasSelection)
        : promptForStyle(current.promptStyle);
      if (rule?.additionalPrompt) {
        systemPrompt += `\n\n## App-Specific Instruction (${retry.context.identifier})\n${rule.additionalPrompt}`;
      }

      const result = await refineTextStream(
        {
          transcript: retry.transcript,
          context: retry.context.identifier,
          mode: hasSelection ? 'edit' : retry.mode ? 'dictation' : current.selectedMode,
          tone: ruleTone || globalTone,
          language_preference: current.languagePreference,
          personal_dictionary: personalDictionary,
          whisper_mode: current.enableWhisperMode,
          existing_text: retry.context.selectedText || null,
        },
        llmKey,
        provider,
        current.selectedModel,
        systemPrompt,
        retry.mode ? 0.3 : temperatureForStyle(current.promptStyle),
        {},
        (chunk) => {
          if (alive()) setProcessedText((prev) => prev + chunk);
        },
        signal
      );
      if (!alive()) return;

      let text = extractReplacementIfCommandJSON(result.text);
      if (isTerminalContext(retry.context)) text = text.replace(/[\r\n]+$/, '');
      setProcessedText(text);
      transitionTo('previewing');
    } catch (err: any) {
      if (!alive() || signal.aborted || isCancelledError(err)) return;
      showError(err?.message || String(err));
    } finally {
      sessionGen.release(controller);
    }
  };

  /// 失敗後重跑一次（不用重講）。對應原生版 retryLastAction。
  const retryLastAction = () => {
    const retry = retryContextRef.current;
    if (!retry) return;
    transitionTo('previewing');
    setProcessedText('');
    regenerateResult();
  };

  const cancelPreview = () => resetPipeline();

  const resetPipeline = async () => {
    transitionTo('idle');
    activeModeRef.current = null;
    setActiveModeName(null);
    previewAfterForegroundChangeRef.current = false;
    clearRecordingTimers();
    restoreSystemVolume();
    setRawText('');
    setProcessedText('');
    setPartialText('');
    setActionConfirmation('');
    setAudioLevel(0);
    setRecordingStartTime(null);
    setCountdown(0);
    clearSilenceTimer();
    if (smartSendTimerRef.current) {
      clearInterval(smartSendTimerRef.current);
      smartSendTimerRef.current = null;
    }
    if (previewTimerRef.current) {
      clearTimeout(previewTimerRef.current);
      previewTimerRef.current = null;
    }
    await invoke('hide_window', { label: 'overlay' }).catch(() => {});
  };

  const showError = (msg: string) => {
    logToFile(`ERROR: ${msg}`);
    clearRecordingTimers();
    restoreSystemVolume();
    if (settingsRef.current.enableSoundFeedback) playFeedbackTone('error');
    setErrorMsg(msg);
    transitionTo('error');
    scheduleReset(8000, 'error');
  };

  return {
    state,
    audioLevel,
    rawText,
    processedText,
    partialText,
    actionConfirmation,
    errorMsg,
    countdown,
    recordingStartTime,
    settings,
    secrets,
    updateSettings,
    reloadSecrets,
    activeModeName,
    settingsTabRequest,
    startRecording,
    stopRecording,
    toggleRecording,
    cancelRecording,
    confirmInject,
    regenerateResult,
    retryLastAction,
    cancelPreview,
    cancelConfirming,
    /// 讓 UI 直接讀 analyser 畫波形，繞開 React state 延遲
    audioChain,
  };
}
