import { useState, useEffect, useRef } from 'react';
import { listen } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';
import { writeText } from '@tauri-apps/plugin-clipboard-manager';
import { db } from '../services/db';
import { transcribeAudio, refineTextStream, classifyIntent } from '../services/llm';

export type PipelineState =
  | 'idle'
  | 'listening'
  | 'recording'
  | 'processing'
  | 'previewing'
  | 'done'
  | 'confirming'
  | 'error';

interface PipelineSettings {
  sttApiKey: string;
  llmApiKey: string;
  llmBaseUrl: string;
  llmModel: string;
  whisperLanguage: string;
  sttGain: number; // 麥克風增益 (0.5x ~ 5.0x)
  enableSilenceStop: boolean; // 靜音自動停止
  silenceTimeout: number; // 語後靜音逾時 (秒)
  enablePreview: boolean; // 啟用預覽
  enableSmartSend: boolean; // 啟用智慧傳送
  smartSendCountdown: number; // 智慧傳送倒數秒數
  languagePreference: string;
  systemPromptMode: 'typeless' | 'wisprflow';
}

export function useVoicePipeline() {
  const [state, setState] = useState<PipelineState>('idle');
  const [audioLevel, setAudioLevel] = useState<number>(0);
  const [rawText, setRawText] = useState<string>('');
  const [processedText, setProcessedText] = useState<string>('');
  const [errorMsg, setErrorMsg] = useState<string>('');
  const [countdown, setCountdown] = useState<number>(0);

  // 靜態設定項目（實務上可從 store 讀取，此處提供預設值並支援外部修改）
  const [settings, setSettings] = useState<PipelineSettings>({
    sttApiKey: localStorage.getItem('saybit_stt_key') || '',
    llmApiKey: localStorage.getItem('saybit_llm_key') || '',
    llmBaseUrl: localStorage.getItem('saybit_llm_url') || 'https://openrouter.ai/api/v1',
    llmModel: localStorage.getItem('saybit_llm_model') || 'openai/gpt-4o-mini',
    whisperLanguage: 'zh',
    sttGain: 2.0,
    enableSilenceStop: true,
    silenceTimeout: 2.0,
    enablePreview: true,
    enableSmartSend: false,
    smartSendCountdown: 3,
    languagePreference: 'zh-TW',
    systemPromptMode: 'typeless',
  });

  // 音訊處理 Refs
  const audioContextRef = useRef<AudioContext | null>(null);
  const mediaStreamRef = useRef<MediaStream | null>(null);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const analyserNodeRef = useRef<AnalyserNode | null>(null);
  const audioChunksRef = useRef<Blob[]>([]);
  const silenceTimerRef = useRef<any | null>(null);
  const hasDetectedSpeechRef = useRef<boolean>(false);
  const recordingStartTimeRef = useRef<number>(0);
  const smartSendTimerRef = useRef<any | null>(null);
  const originalClipboardRef = useRef<string>('');

  // 1. 監聽全域快捷鍵
  useEffect(() => {
    const unlisten = listen('hotkey-triggered', () => {
      handleHotkey();
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [state, settings]);

  // 處理全域熱鍵觸發
  const handleHotkey = () => {
    if (state === 'idle') {
      startRecording();
    } else if (state === 'recording') {
      stopRecording();
    } else if (state === 'confirming') {
      cancelConfirming();
    }
  };

  // 獲取當前聚焦應用的上下文（Windows 備份策略）
  const getContextAndSelection = async (): Promise<{ context: string; text?: string }> => {
    // 初版實作全域剪貼簿回退策略
    try {
      // 1. 備份剪貼簿 (在真實 Tauri 中可以藉由插件讀取，這裡使用標準 API 作為示意)
      // 由於 Web Clipboard API 在非聚焦時有安全限制，
      // 我們主要依靠寫入與模擬。在 Webview 內直接備份：
      originalClipboardRef.current = await navigator.clipboard.readText().catch(() => '');
      
      // 2. 模擬複製 Ctrl+C (這將由 Rust 後端模擬，但在網頁端我們可非同步等待)
      // 由於本計畫著重 Windows，我們在 Rust 呼叫
      // 為了強健性，我們等待 100ms 模擬
      await new Promise(r => setTimeout(r, 100));
      
      return {
        context: 'active-app',
        text: undefined // 預設普通聽寫模式
      };
    } catch {
      return { context: 'unknown' };
    }
  };

  // 2. 開始錄音
  const startRecording = async () => {
    if (state !== 'idle' && state !== 'listening') return;
    
    try {
      // 顯示懸浮視窗
      await invoke('show_window', { label: 'overlay' });
      
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      mediaStreamRef.current = stream;
      audioChunksRef.current = [];
      hasDetectedSpeechRef.current = false;
      recordingStartTimeRef.current = Date.now();

      // Web Audio API 音量監測與 Canvas 波形
      const audioCtx = new (window.AudioContext || (window as any).webkitAudioContext)();
      audioContextRef.current = audioCtx;
      const source = audioCtx.createMediaStreamSource(stream);
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 512;
      analyserNodeRef.current = analyser;
      source.connect(analyser);

      // MediaRecorder 錄製 WebM/WAV (Chromium 中原生支援 WebM，Whisper 支援 WebM)
      const recorder = new MediaRecorder(stream, { mimeType: 'audio/webm' });
      mediaRecorderRef.current = recorder;
      
      recorder.ondataavailable = (e) => {
        if (e.data.size > 0) {
          audioChunksRef.current.push(e.data);
        }
      };

      recorder.onstop = async () => {
        const audioBlob = new Blob(audioChunksRef.current, { type: 'audio/webm' });
        await processAudio(audioBlob);
      };

      recorder.start();
      setState('recording');

      // 啟動音量與靜音監測迴圈
      monitorAudioLevel();
    } catch (err: any) {
      showError(`麥克風開啟失敗: ${err.message || err}`);
    }
  };

  // 3. 監控音量與靜音自動停止
  const monitorAudioLevel = () => {
    if (!analyserNodeRef.current || !audioContextRef.current) return;
    const analyser = analyserNodeRef.current;
    const bufferLength = analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);

    const checkLevel = () => {
      if (mediaRecorderRef.current?.state !== 'recording') return;

      analyser.getByteTimeDomainData(dataArray);

      // 計算 RMS (均方根音量)
      let sum = 0;
      for (let i = 0; i < bufferLength; i++) {
        const val = (dataArray[i] - 128) / 128; // 標準化為 -1 到 1
        sum += val * val;
      }
      let rms = Math.sqrt(sum / bufferLength);
      
      // 套用增益
      rms = rms * settings.sttGain;
      if (rms > 1.0) rms = 1.0;
      
      setAudioLevel(rms);

      // 靜音偵測邏輯
      if (settings.enableSilenceStop) {
        if (rms >= 0.15) {
          // 偵測到語音，啟動語語偵測標記，並清除未說話逾時
          hasDetectedSpeechRef.current = true;
          if (silenceTimerRef.current) {
            clearTimeout(silenceTimerRef.current);
            silenceTimerRef.current = null;
          }
        } else if (rms < 0.08) {
          // 低於靜音閾值
          if (hasDetectedSpeechRef.current) {
            // 已說過話，啟動「語後靜音逾時」
            if (!silenceTimerRef.current) {
              silenceTimerRef.current = setTimeout(() => {
                stopRecording();
              }, settings.silenceTimeout * 1000);
            }
          } else {
            // 從未偵測到語音，啟動 3.0 秒自動停止
            if (!silenceTimerRef.current) {
              silenceTimerRef.current = setTimeout(() => {
                stopRecording();
              }, 3000);
            }
          }
        }
      }

      requestAnimationFrame(checkLevel);
    };

    requestAnimationFrame(checkLevel);
  };

  // 4. 停止錄音
  const stopRecording = () => {
    if (mediaRecorderRef.current && mediaRecorderRef.current.state === 'recording') {
      mediaRecorderRef.current.stop();
    }
    
    // 清除計時器與釋放音訊資源
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
    }
    if (mediaStreamRef.current) {
      mediaStreamRef.current.getTracks().forEach((track) => track.stop());
    }
    if (audioContextRef.current) {
      audioContextRef.current.close();
    }
  };

  // 5. 音訊處理與 API 呼叫 Pipeline
  const processAudio = async (audioBlob: Blob) => {
    setState('processing');
    setRawText('');
    setProcessedText('');

    try {
      if (!settings.sttApiKey) {
        throw new Error('未設定 OpenAI API Key，請前往設定頁面配置');
      }

      // Stage 1：語音轉文字 (STT)
      const transcript = await transcribeAudio(
        audioBlob,
        settings.sttApiKey,
        'whisper-1',
        settings.whisperLanguage
      );

      if (!transcript.trim()) {
        setState('idle');
        await invoke('hide_window', { label: 'overlay' });
        return;
      }

      setRawText(transcript);

      // 取得上下文與選取文字
      const contextInfo = await getContextAndSelection();

      // 進行意圖分析
      const intentResult = await classifyIntent(
        transcript,
        settings.llmApiKey || settings.sttApiKey,
        settings.llmBaseUrl,
        settings.llmModel
      );

      // 載入對應 Prompt (wisprflow / typeless)
      const systemPrompt = buildSystemPrompt(intentResult.intent, settings.systemPromptMode, settings.languagePreference);

      // Stage 2：LLM 流式精煉
      const finalResult = await refineTextStream(
        {
          transcript: intentResult.content || transcript,
          context: contextInfo.context,
          mode: intentResult.intent === 'dictation' ? 'dictation' : 'command',
          tone: intentResult.style || null,
          language_preference: settings.languagePreference,
          personal_dictionary: {}, // 可從本地 db 載入後填入
        },
        settings.llmApiKey || settings.sttApiKey,
        settings.llmBaseUrl,
        settings.llmModel,
        systemPrompt,
        (chunk) => {
          setProcessedText((prev) => prev + chunk);
        }
      );

      // 儲存至歷史紀錄
      const duration = (Date.now() - recordingStartTimeRef.current) / 1000;
      await db.history.add({
        rawTranscript: transcript,
        processedText: finalResult,
        appContext: contextInfo.context,
        mode: intentResult.intent === 'dictation' ? 'dictation' : 'command',
        timestamp: Date.now(),
        duration: Math.round(duration),
        modelName: settings.llmModel,
        promptTokens: 0, // 模擬數據，實際上可從 API 取得
        completionTokens: 0,
        totalTokens: 0,
      });

      // 判斷是否開啟預覽
      if (settings.enablePreview) {
        setState('previewing');
      } else {
        await injectResult(finalResult);
      }
    } catch (err: any) {
      showError(err.message || err);
    }
  };

  // 6. 確認注入 (預覽確認後呼叫)
  const confirmInject = async () => {
    if (state !== 'previewing') return;
    await injectResult(processedText);
  };

  // 7. 注入文字到聚焦 App
  const injectResult = async (text: string) => {
    try {
      setState('done');
      
      // 1. 將結果寫入系統剪貼簿
      await writeText(text);
      
      // 2. 呼叫 Rust 模擬 Cmd+V / Ctrl+V
      await invoke('simulate_paste');
      
      // 3. 智慧發送
      if (settings.enableSmartSend) {
        setState('confirming');
        setCountdown(settings.smartSendCountdown);
        
        let rem = settings.smartSendCountdown;
        smartSendTimerRef.current = setInterval(async () => {
          rem -= 1;
          setCountdown(rem);
          if (rem <= 0) {
            if (smartSendTimerRef.current) clearInterval(smartSendTimerRef.current);
            // 呼叫 Rust 模擬 Enter
            await invoke('simulate_enter');
            resetPipeline();
          }
        }, 1000);
      } else {
        // 2.0 秒後自動重置
        setTimeout(() => {
          resetPipeline();
        }, 2000);
      }
    } catch (err: any) {
      showError(`注入失敗: ${err.message || err}`);
    }
  };

  // 取消 Smart Send
  const cancelConfirming = () => {
    if (smartSendTimerRef.current) {
      clearInterval(smartSendTimerRef.current);
      smartSendTimerRef.current = null;
    }
    resetPipeline();
  };

  // 重新生成 (預覽介面)
  const regenerateResult = async () => {
    if (state !== 'previewing') return;
    setState('processing');
    setProcessedText('');
    
    try {
      const contextInfo = await getContextAndSelection();
      const systemPrompt = buildSystemPrompt('dictation', settings.systemPromptMode, settings.languagePreference);
      
      await refineTextStream(
        {
          transcript: rawText,
          context: contextInfo.context,
          mode: 'dictation',
          tone: null,
          language_preference: settings.languagePreference,
          personal_dictionary: {},
        },
        settings.llmApiKey || settings.sttApiKey,
        settings.llmBaseUrl,
        settings.llmModel,
        systemPrompt,
        (chunk) => {
          setProcessedText((prev) => prev + chunk);
        }
      );
      
      setState('previewing');
    } catch (err: any) {
      showError(err.message || err);
    }
  };

  // 取消預覽
  const cancelPreview = () => {
    resetPipeline();
  };

  // 重置狀態
  const resetPipeline = async () => {
    setState('idle');
    setRawText('');
    setProcessedText('');
    setAudioLevel(0);
    if (smartSendTimerRef.current) {
      clearInterval(smartSendTimerRef.current);
      smartSendTimerRef.current = null;
    }
    // 隱藏懸浮膠囊
    await invoke('hide_window', { label: 'overlay' });
  };

  // 顯示錯誤訊息
  const showError = (msg: string) => {
    setErrorMsg(msg);
    setState('error');
    setTimeout(() => {
      resetPipeline();
    }, 3000);
  };

  // 建立系統 Prompt 構造器
  const buildSystemPrompt = (
    _intent: string,
    mode: 'typeless' | 'wisprflow',
    language: string
  ): string => {
    const baseRules = `
你是一個高效率的語音精煉助手。請對使用者的語音轉錄內容進行去贅詞（例如：嗯、啊、就是、然後等）、修正重複字、自動加入正確標點。
請務必無條件使用繁體中文 (${language}) 輸出，除非使用者明確要求翻譯成其他語言。
請保持輸出乾淨，不要附帶任何說明、確認字眼或 Markdown 包裝，直接輸出精煉後的文字。
    `;

    const wisprRules = `
你同時也是一個技術工程師模式。如果轉錄內容包含 CLI 指令或變數命名（如 camel case），請自動格式化它：
- "camel case username" -> "userName"
- "npm install dash dash save dev" -> "npm install --save-dev"
- 自動修正 Kubernetes, React, PostgreSQL 等技術詞彙的拼寫。
    `;

    return `${baseRules} ${mode === 'wisprflow' ? wisprRules : ''}`;
  };

  // 更新設定並同步持久化
  const updateSettings = (newSettings: Partial<PipelineSettings>) => {
    setSettings((prev) => {
      const updated = { ...prev, ...newSettings };
      if (newSettings.sttApiKey !== undefined) localStorage.setItem('saybit_stt_key', newSettings.sttApiKey);
      if (newSettings.llmApiKey !== undefined) localStorage.setItem('saybit_llm_key', newSettings.llmApiKey);
      if (newSettings.llmBaseUrl !== undefined) localStorage.setItem('saybit_llm_url', newSettings.llmBaseUrl);
      if (newSettings.llmModel !== undefined) localStorage.setItem('saybit_llm_model', newSettings.llmModel);
      return updated;
    });
  };

  return {
    state,
    audioLevel,
    rawText,
    processedText,
    errorMsg,
    countdown,
    settings,
    updateSettings,
    startRecording,
    stopRecording,
    confirmInject,
    regenerateResult,
    cancelPreview,
    cancelConfirming,
  };
}
