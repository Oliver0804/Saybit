import { useState, useEffect, useRef, useMemo, useCallback } from 'react';
import { listen, emit } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';
import { getCurrentWindow } from '@tauri-apps/api/window';

import { db, cleanupHistory } from '../services/db';
import {
  transcribeAudio,
  refineTextStream,
  classifyIntent,
  completeJSON,
  type LLMPayload,
  type LLMUsage,
  type EventPayload,
  type ReminderPayload,
} from '../services/llm';
import {
  promptForStyle,
  promptForIntent,
  temperatureForStyle,
  type IntentResponse,
} from '../services/systemPrompts';
import {
  captureForegroundApp,
  captureSelectedText,
  isSelectionCaptureSafe,
  EMPTY_CONTEXT,
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
  type AppSettings,
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
}

// 前端 log 落地到 app data dir 的 frontend.log
function logToFile(msg: string) {
  console.log(`[Saybit] ${msg}`);
  invoke('frontend_log', { msg }).catch(() => {});
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
  const hotkeyHeldRef = useRef(false);
  /// startRecording 的 async 前置（查前景 App、開麥克風）期間 state 還是 idle，
  /// 這時再進來一次會開第二輪錄音並把第一輪錄到的音訊清掉。
  const isStartingRef = useRef(false);
  const monitorRafRef = useRef<number | null>(null);
  /// 這次錄音是否真的跑在串流模式（連線失敗會退回批次，要記住實際狀態）
  const streamingActiveRef = useRef(false);

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
    const unlisten = listen<string>('stt-partial', (event) => {
      setPartialText(event.payload);
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [isOverlay]);

  // ---------------------------------------------------------------- 設定同步

  useEffect(() => {
    const unlisten = listen<AppSettings>('settings-updated', (event) => {
      setSettings((prev) => {
        const incoming = event.payload;
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
    return () => {
      if (warmReleaseTimerRef.current) clearTimeout(warmReleaseTimerRef.current);
      if (monitorRafRef.current) cancelAnimationFrame(monitorRafRef.current);
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

  // 熱鍵註冊：只讓設定視窗負責，避免兩邊互相 unregister
  useEffect(() => {
    if (isOverlay) return;
    if (!settings.hotkey) return;
    invoke('set_hotkey', { shortcut: settings.hotkey }).catch((e) => {
      console.warn('set_hotkey 失敗:', e);
    });
  }, [settings.hotkey, isOverlay]);

  // 預覽無操作自動確認
  useEffect(() => {
    if (state !== 'previewing') return;
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

  const handleToggle = useCallback(() => {
    const s = stateRef.current;
    if (s === 'idle') startRecording();
    else if (s === 'recording') stopRecording();
    else if (s === 'confirming') cancelConfirming();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!isOverlay) return;

    const unlistenPressed = listen('hotkey-pressed', () => {
      // 自動重複濾除：上一次 press 還沒等到 release 就再進來，代表使用者只是
      // 按著沒放，不是新的一次觸發。doubleTap 不受影響 —— 兩次點按之間必然有 release。
      if (hotkeyHeldRef.current) return;
      hotkeyHeldRef.current = true;

      const mode = settingsRef.current.hotkeyTriggerMode;
      hotkeyPressedAtRef.current = Date.now();

      if (mode === 'toggle') {
        handleToggle();
        return;
      }
      if (mode === 'hold') {
        // 按住說話：按下就開錄，放開才停
        if (stateRef.current === 'idle') startRecording();
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

    const unlistenReleased = listen('hotkey-released', () => {
      hotkeyHeldRef.current = false;

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

  // ---------------------------------------------------------------- 錄音

  const startRecording = async () => {
    if (stateRef.current !== 'idle' && stateRef.current !== 'listening') return;
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

    const current = settingsRef.current;

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
      capturedContextRef.current = { ...EMPTY_CONTEXT };
    }

    try {
      invoke('show_window', { label: 'overlay' }).catch(() => {});

      await audioChain.start({
        deviceId: current.selectedInputDeviceId,
        echoCancellation: current.enableEchoCancellation,
        bandpass: current.enableVoiceBandpass,
        preBufferSeconds: current.preBufferSeconds,
      });

      hasDetectedSpeechRef.current = false;
      recordingStartRef.current = Date.now();
      setPartialText('');

      // 串流模式：先把連線開起來再開始擷取，讓第一塊音訊就有地方送。
      // 連線失敗不中斷錄音 —— 退回批次辨識，使用者頂多是慢一點而不是整個用不了。
      streamingActiveRef.current = false;
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
          streamingActiveRef.current = true;
          audioChain.setLiveTap((chunk) => {
            pushStreamingAudio(pcmToInt16Bytes(chunk)).catch(() => {});
          });
          logToFile(`串流辨識連線成功（${current.streamingProvider}）`);
        } catch (e: any) {
          logToFile(`串流辨識連線失敗，改用批次辨識：${e?.message || e}`);
          audioChain.setLiveTap(null);
        }
      } else {
        audioChain.setLiveTap(null);
      }

      audioChain.beginCapture();

      if (current.enableSoundFeedback) playFeedbackTone('start');

      setRecordingStartTime(Date.now());
      transitionTo('recording');
      monitorAudioLevel();
    } catch (err: any) {
      showError(`麥克風開啟失敗: ${err?.message || err}`);
    } finally {
      isStartingRef.current = false;
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

    audioChain.setLiveTap(null);
    const captured = audioChain.endCapture();
    if (settingsRef.current.enableSoundFeedback) playFeedbackTone('stop');
    scheduleWarmRelease();

    processAudio(captured.pcm, captured.sampleRate, captured.durationSeconds);
  };

  /// 取消錄音（誤觸 hold 模式時用），不送去辨識。
  const cancelRecording = () => {
    clearSilenceTimer();
    audioChain.setLiveTap(null);
    if (streamingActiveRef.current) {
      streamingActiveRef.current = false;
      cancelStreaming();
    }
    audioChain.endCapture();
    scheduleWarmRelease();
    resetPipeline();
  };

  // ---------------------------------------------------------------- 主流程

  const processAudio = async (
    pcm: Float32Array,
    sampleRate: number,
    durationSeconds: number
  ) => {
    transitionTo('processing');
    setRawText('');
    setProcessedText('');
    setActionConfirmation('');

    const current = settingsRef.current;
    const keys = secretsRef.current;
    const context = capturedContextRef.current;

    try {
      const pcm16k = resampleTo16k(pcm, sampleRate);
      if (pcm16k.length < 16000 * 0.2) {
        // 少於 0.2 秒基本上是誤觸，直接收工
        logToFile(`錄音過短（${(pcm16k.length / 16000).toFixed(2)}s），略過`);
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
        resetPipeline();
        return;
      }

      // ---- 個人字典（同時給 STT 偏置與 LLM 精煉用）----
      const dictEntries = await db.dictionary.toArray().catch(() => []);
      const personalDictionary: Record<string, string> = {};
      for (const entry of dictEntries) {
        if (entry.word) personalDictionary[entry.word] = entry.replacement || entry.word;
      }

      let sttPrompt = '以下是繁體中文（台灣）的語音逐字稿。';
      const dictWords = Object.values(personalDictionary).filter(Boolean);
      if (dictWords.length > 0) {
        sttPrompt += `常見詞彙：${dictWords.slice(0, 30).join('、')}。`;
      }

      // ---- Stage 0：STT ----
      const transcript = await runSTT(pcm16k, current, keys.sttKey, sttPrompt);
      logToFile(`STT ok: "${transcript.slice(0, 80)}"`);

      if (!transcript.trim()) {
        resetPipeline();
        return;
      }

      // 第二道防線：音量閘放行了但模型還是吐出字幕檔殘留（例如背景音樂夠大聲）
      if (isLikelyHallucination(transcript)) {
        logToFile(`判定為 whisper 幻覺，丟棄："${transcript}"`);
        resetPipeline();
        return;
      }
      setRawText(transcript);
      retryContextRef.current = { transcript, context };

      // ---- 自訂技能（snippets）----
      const skillEntries = await db.skills.toArray().catch(() => []);
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

      // ---- Stage 1：意圖分類 ----
      const intent = await classifyIntent(
        transcript,
        llmKey,
        provider,
        current.selectedModel,
        snippets,
        Boolean(context.selectedText)
      );
      logToFile(
        `intent=${intent.intent} lang=${intent.language ?? '-'} style=${intent.style ?? '-'}` +
          (intent.degradedReason ? ` ⚠️ 意圖分析未成功，降級為聽寫：${intent.degradedReason}` : '')
      );

      // ---- 行事曆 / 提醒事項（僅 macOS 有原生後端）----
      if (
        current.enableActionIntents &&
        (intent.intent === 'create_event' || intent.intent === 'create_reminder')
      ) {
        const handled = await handleActionIntent(intent, provider, llmKey, current, transcript);
        if (handled) return;
        // 沒處理成功就往下走一般精煉流程，至少把話打出來
      }

      // ---- 語氣：per-app 規則優先，其次全域設定 ----
      const rule = matchContextRule(current.contextRules, context.identifier);
      const ruleTone = rule?.toneOverride && rule.toneOverride !== 'auto' ? rule.toneOverride : null;
      const globalTone = current.toneStyle !== 'auto' ? current.toneStyle : null;
      const tone = intent.style || ruleTone || globalTone;

      // ---- system prompt：專用意圖優先，否則走風格 prompt ----
      let systemPrompt = promptForIntent(intent, current.languagePreference);
      if (!systemPrompt) systemPrompt = promptForStyle(current.promptStyle);
      if (rule?.additionalPrompt) {
        systemPrompt += `\n\n## App-Specific Instruction (${context.identifier})\n${rule.additionalPrompt}`;
      }
      // 技能命中時把該技能的指令附上
      if (intent.intent === 'skill' && intent.skill_name && snippets[intent.skill_name]) {
        systemPrompt += `\n\n## Skill: ${intent.skill_name}\n${snippets[intent.skill_name]}`;
      }

      const payload: LLMPayload = {
        transcript: intent.content || transcript,
        context: context.identifier,
        mode: modeForIntent(intent, current.selectedMode, Boolean(context.selectedText)),
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
        temperatureForStyle(current.promptStyle),
        current.useCustomLLMParams
          ? {
              maxTokens: current.llmMaxTokens,
              frequencyPenalty: current.llmFrequencyPenalty,
              presencePenalty: current.llmPresencePenalty,
              topP: current.llmTopP,
            }
          : {},
        (chunk) => setProcessedText((prev) => prev + chunk)
      );

      const finalText = extractReplacementIfCommandJSON(result.text);
      setProcessedText(finalText);
      logToFile(`refine ok: "${finalText.slice(0, 80)}" usage=${JSON.stringify(result.usage)}`);

      await saveHistory({
        transcript,
        finalText,
        context,
        intent,
        tone,
        durationSeconds,
        model: current.selectedModel,
        usage: result.usage,
      });

      if (current.enablePreviewBeforeInject) {
        transitionTo('previewing');
      } else {
        await injectResult(finalText);
      }
    } catch (err: any) {
      showError(err?.message || String(err));
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
    current: AppSettings,
    sttKey: string,
    sttPrompt: string
  ): Promise<string> => {
    // 兩條本機路徑共用同一份 raw PCM body
    const rawPcm = () =>
      new Uint8Array(pcm16k.buffer, pcm16k.byteOffset, pcm16k.byteLength);

    if (current.sttEngine === 'local' || current.sttEngine === 'apple') {
      let peak = 0;
      for (let i = 0; i < pcm16k.length; i++) {
        const a = Math.abs(pcm16k[i]);
        if (a > peak) peak = a;
      }
      logToFile(
        `${current.sttEngine} STT start: ${(pcm16k.length / 16000).toFixed(2)}s, peak=${peak.toFixed(3)}`
      );
    }

    // 串流模式：音訊在錄音期間就一路推過去了，這裡只要送結束訊號收結果。
    // 連線當初沒建立成功（streamingActiveRef 為 false）就直接往下走批次路徑。
    if (current.sttEngine === 'streaming' && streamingActiveRef.current) {
      streamingActiveRef.current = false;
      try {
        const streamed = await finishStreaming();
        logToFile(`串流辨識完成："${streamed.slice(0, 80)}"`);
        if (streamed.trim()) return streamed;
        logToFile('串流辨識回空結果，退回批次辨識');
      } catch (e: any) {
        logToFile(`串流辨識收尾失敗，退回批次辨識：${e?.message || e}`);
      }
      // 走到這裡代表串流沒給出東西 —— 整段音訊還在手上，用雲端 Whisper 補救
    }

    if (current.sttEngine === 'apple') {
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

    if (current.sttEngine === 'local') {
      try {
        return await invoke<string>('transcribe_local', rawPcm());
      } catch (e: any) {
        logToFile(`local STT FAILED: ${e?.message || e}`);
        throw new Error(`本地 STT 失敗: ${e?.message || e}`);
      }
    }

    if (!sttKey) {
      throw new Error(
        current.sttEngine === 'streaming'
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
        sttPrompt
      );
    } catch (e: any) {
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
        intent: args.intent.intent,
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
    transcript: string
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
          current.selectedModel
        );
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
        current.selectedModel
      );
      if (!parsed?.title) return false;
      await invoke('create_reminder', {
        title: parsed.title,
        dueIso: parsed.due_date ?? null,
        notes: parsed.notes ?? null,
      });
      finishWithConfirmation(parsed.confirmation_text || `已建立提醒：${parsed.title}`);
      return true;
    } catch (e: any) {
      // 非 macOS 平台沒有這兩個 command，或使用者拒絕授權 → 降級成一般聽寫
      logToFile(`action intent 失敗，降級為聽寫: ${e?.message || e}`);
      return false;
    }
  };

  const finishWithConfirmation = (text: string) => {
    setActionConfirmation(text);
    setProcessedText(text);
    transitionTo('done');
    setTimeout(() => resetPipeline(), 2500);
  };

  // ---------------------------------------------------------------- 注入

  const injectResult = async (text: string) => {
    const current = settingsRef.current;
    try {
      logToFile(
        `inject start: mode=${current.injectionMode} smartSend=${current.enableSmartSend} len=${text.length}`
      );
      transitionTo('done');

      // 剪貼簿備份/還原、逐字輸入、取代選取都在 Rust 端處理
      await invoke('inject_text', { text, mode: current.injectionMode });
      logToFile('inject invoked');

      if (current.enableSmartSend) {
        transitionTo('confirming');
        let remaining = Math.round(current.smartSendDelay);
        setCountdown(remaining);

        smartSendTimerRef.current = setInterval(async () => {
          remaining -= 1;
          setCountdown(remaining);
          if (remaining <= 0) {
            if (smartSendTimerRef.current) clearInterval(smartSendTimerRef.current);
            smartSendTimerRef.current = null;
            logToFile('smart send: invoking Enter');
            await invoke('simulate_enter').catch(() => {});
            resetPipeline();
          }
        }, 1000);
      } else {
        setTimeout(() => resetPipeline(), 2000);
      }
    } catch (err: any) {
      showError(`注入失敗: ${err?.message || err}`);
    }
  };

  const confirmInject = async () => {
    if (stateRef.current !== 'previewing') return;
    await injectResult(processedTextRef.current);
  };

  autoConfirmRef.current = () => {
    if (stateRef.current === 'previewing') injectResult(processedTextRef.current);
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
      const personalDictionary: Record<string, string> = {};
      for (const entry of dictEntries) {
        if (entry.word) personalDictionary[entry.word] = entry.replacement || entry.word;
      }

      const rule = matchContextRule(current.contextRules, retry.context.identifier);
      const ruleTone =
        rule?.toneOverride && rule.toneOverride !== 'auto' ? rule.toneOverride : null;
      const globalTone = current.toneStyle !== 'auto' ? current.toneStyle : null;

      let systemPrompt = promptForStyle(current.promptStyle);
      if (rule?.additionalPrompt) {
        systemPrompt += `\n\n## App-Specific Instruction (${retry.context.identifier})\n${rule.additionalPrompt}`;
      }

      const result = await refineTextStream(
        {
          transcript: retry.transcript,
          context: retry.context.identifier,
          mode: retry.context.selectedText ? 'edit' : current.selectedMode,
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
        temperatureForStyle(current.promptStyle),
        {},
        (chunk) => setProcessedText((prev) => prev + chunk)
      );

      setProcessedText(extractReplacementIfCommandJSON(result.text));
      transitionTo('previewing');
    } catch (err: any) {
      showError(err?.message || String(err));
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
    if (settingsRef.current.enableSoundFeedback) playFeedbackTone('error');
    setErrorMsg(msg);
    transitionTo('error');
    setTimeout(() => resetPipeline(), 8000);
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
    startRecording,
    stopRecording,
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
