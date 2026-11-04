import { useEffect, useMemo, useRef, useState } from 'react';
import {
  Mic,
  Loader2,
  Check,
  RotateCw,
  X,
  AlertCircle,
} from 'lucide-react';
import { getCurrentWindow, currentMonitor, LogicalPosition } from '@tauri-apps/api/window';
import { invoke } from '@tauri-apps/api/core';
import { type useVoicePipeline } from '../hooks/useVoicePipeline';
import { makeTranslator } from '../services/l10n';

interface OverlayViewProps {
  pipeline: ReturnType<typeof useVoicePipeline>;
}

export function OverlayView({ pipeline }: OverlayViewProps) {
  const {
    state,
    rawText,
    processedText,
    partialText,
    errorMsg,
    countdown,
    recordingStartTime,
    audioChain,
    settings,
    updateSettings,
    startRecording,
    stopRecording,
    confirmInject,
    regenerateResult,
    retryLastAction,
    cancelPreview,
    cancelConfirming,
    activeModeName,
  } = pipeline;
  const tr = useMemo(() => makeTranslator(settings.appLanguage), [settings.appLanguage]);

  // 用語音模式錄音／處理時，膠囊上顯示紫色模式標籤（對齊原生 OverlayView.modeTag）
  const modeTag = activeModeName ? (
    <span className="flex-shrink-0 max-w-[90px] truncate px-2 py-0.5 rounded-full bg-purple-500/75 text-[10px] font-semibold text-white leading-tight">
      {activeModeName}
    </span>
  ) : null;

  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const animationRef = useRef<number | null>(null);
  const levelsRef = useRef<number[]>([]);
  const lastPushRef = useRef<number>(0);
  const [elapsedSec, setElapsedSec] = useState<number>(0);
  const saveTimerRef = useRef<any | null>(null);

  // 位置：載入儲存或置中頂部；拖曳後 debounce 儲存
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    (async () => {
      const win = getCurrentWindow();
      if (settings.hasCustomOverlayPosition) {
        try {
          await win.setPosition(
            new LogicalPosition(settings.overlayPositionX, settings.overlayPositionY)
          );
        } catch { /* ignore */ }
      } else {
        try {
          const monitor = await currentMonitor();
          const size = await win.outerSize();
          if (monitor) {
            const scale = monitor.scaleFactor;
            const screenW = monitor.size.width / scale;
            const w = size.width / scale;
            const x = Math.round((screenW - w) / 2);
            await win.setPosition(new LogicalPosition(x, 12));
          }
        } catch { /* ignore */ }
      }

      unlisten = await win.onMoved(({ payload }) => {
        if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
        saveTimerRef.current = setTimeout(async () => {
          try {
            const monitor = await currentMonitor();
            const scale = monitor?.scaleFactor ?? 1;
            const logicalX = Math.round(payload.x / scale);
            const logicalY = Math.round(payload.y / scale);
            updateSettings({
              overlayPositionX: logicalX,
              overlayPositionY: logicalY,
              hasCustomOverlayPosition: true,
            });
          } catch { /* ignore */ }
        }, 300);
      });
    })();
    return () => {
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
      if (unlisten) unlisten();
    };
    // 只在掛載時定位一次；之後的位置變動由使用者拖曳驅動，不該反向覆寫視窗位置
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Elapsed timer during recording
  useEffect(() => {
    if (state !== 'recording' || !recordingStartTime) {
      setElapsedSec(0);
      return;
    }
    const tick = () => setElapsedSec(Math.floor((Date.now() - recordingStartTime) / 1000));
    tick();
    const id = setInterval(tick, 250);
    return () => clearInterval(id);
  }, [state, recordingStartTime]);

  // Waveform：滾動長條（對齊原生 SwiftUI WaveformView）。
  // 抗延遲關鍵：最右一根 bar 每幀即時反映當前麥克風音量（零感知延遲），
  // 舊 bar 每 ~40ms 往左捲動一格成為歷史，聲音與畫面緊密耦合。
  useEffect(() => {
    const showWave = state === 'recording' || state === 'listening';
    if (!showWave) {
      if (animationRef.current) {
        cancelAnimationFrame(animationRef.current);
        animationRef.current = null;
      }
      return;
    }
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const dpr = window.devicePixelRatio || 1;
    const width = state === 'recording' ? 100 : 80;
    const height = 22;
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    ctx.scale(dpr, dpr);

    const BAR_W = 2;
    const GAP = 2;
    const PITCH = BAR_W + GAP;
    const BARS = Math.floor(width / PITCH);
    const PUSH_MS = 40; // 捲動速率（~25Hz），對齊原生節流後的 audioLevel 更新率
    const rgba = state === 'recording' ? '255, 255, 255' : '251, 191, 36';

    levelsRef.current = new Array(BARS).fill(0);
    lastPushRef.current = 0;
    let dataArray: Uint8Array | null = null;

    const instantLevel = (): number => {
      const analyser = audioChain.getAnalyser();
      if (!analyser) return 0;
      if (!dataArray || dataArray.length !== analyser.frequencyBinCount) {
        dataArray = new Uint8Array(analyser.frequencyBinCount);
      }
      analyser.getByteTimeDomainData(dataArray);
      let sum = 0;
      for (let i = 0; i < dataArray.length; i++) {
        const v = (dataArray[i] - 128) / 128;
        sum += v * v;
      }
      // 視覺增益：語音 RMS 偏小，放大後 clamp 到 0..1
      return Math.min(1, Math.sqrt(sum / dataArray.length) * 4.5);
    };

    const draw = (now: number) => {
      const levels = levelsRef.current;
      const live = instantLevel();
      // 最右一根永遠是「當下」音量 → 零延遲手感
      levels[levels.length - 1] = live;
      // 每 PUSH_MS 捲動一格
      if (now - lastPushRef.current >= PUSH_MS) {
        levels.shift();
        levels.push(live);
        lastPushRef.current = now;
      }

      ctx.clearRect(0, 0, width, height);
      const maxH = height - 2;
      for (let i = 0; i < levels.length; i++) {
        const h = Math.max(2, levels[i] * maxH);
        const x = i * PITCH;
        const y = (height - h) / 2;
        // 越新（越右）越亮，形成尾流感
        const alpha = 0.35 + 0.5 * (i / (levels.length - 1));
        ctx.fillStyle = `rgba(${rgba}, ${alpha.toFixed(3)})`;
        ctx.beginPath();
        if (ctx.roundRect) ctx.roundRect(x, y, BAR_W, h, 1);
        else ctx.rect(x, y, BAR_W, h);
        ctx.fill();
      }
      animationRef.current = requestAnimationFrame(draw);
    };
    animationRef.current = requestAnimationFrame(draw);
    return () => {
      if (animationRef.current) cancelAnimationFrame(animationRef.current);
    };
  }, [state, audioChain]);

  const fmtDuration = (sec: number) => {
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    return `${m}:${s.toString().padStart(2, '0')}`;
  };

  const handleClick = () => {
    if (state === 'idle') startRecording();
    else if (state === 'recording') stopRecording();
    else if (state === 'confirming') cancelConfirming();
  };

  const handleContextMenu = (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    invoke('show_overlay_menu').catch(() => {});
  };

  // 狀態色對齊原生 SwiftUI：listening=橙、recording=紅、processing=橙、
  // done=綠、previewing=藍、confirming=青、error=紅。
  const borderClass = {
    idle: 'border-white/10',
    listening: 'border-orange-500/50',
    recording: 'border-red-500/50',
    processing: 'border-orange-500/50',
    previewing: 'border-blue-500/50',
    done: 'border-green-500/50',
    confirming: 'border-cyan-500/50',
    error: 'border-red-500/50',
  }[state];

  const shadowStyle = {
    idle: '0 4px 14px rgba(0, 0, 0, 0.3)',
    listening: '0 0 16px rgba(249, 115, 22, 0.4)',
    recording: '0 0 16px rgba(239, 68, 68, 0.4)',
    processing: '0 0 16px rgba(249, 115, 22, 0.4)',
    previewing: '0 0 16px rgba(59, 130, 246, 0.4)',
    done: '0 0 16px rgba(34, 197, 94, 0.4)',
    confirming: '0 0 16px rgba(6, 182, 212, 0.4)',
    error: '0 0 16px rgba(239, 68, 68, 0.4)',
  }[state];

  return (
    <div
      className="fixed inset-0 flex items-center justify-center bg-transparent select-none"
      data-tauri-drag-region
      style={{ fontFamily: 'system-ui, -apple-system, sans-serif' }}
    >
      <div
        className={`inline-flex items-center min-h-11 py-1 px-3 rounded-full border backdrop-blur-xl transition-all duration-300 cursor-pointer bg-slate-900/75 ${borderClass}`}
        // CSS transform 會連同邊框與圓角一起縮放，不會發生原生 SwiftUI 那種
        // 「內容縮了但膠囊形狀沒變」的問題。
        style={{ boxShadow: shadowStyle, transform: `scale(${settings.capsuleScale})` }}
        onClick={handleClick}
        onContextMenu={handleContextMenu}
        data-tauri-drag-region
      >
        {state === 'idle' && (
          <div className="flex items-center space-x-2 pointer-events-none">
            <Mic className="w-3.5 h-3.5 text-white/70" />
            <span className="text-[13px] font-medium text-white/70 pr-1">Saybit</span>
          </div>
        )}

        {state === 'listening' && (
          <div className="flex items-center space-x-2 pointer-events-none">
            <div className="w-2.5 h-2.5 rounded-full bg-orange-400 animate-pulse" />
            <canvas ref={canvasRef} className="w-[80px] h-[22px]" />
            <span className="text-[11px] font-medium text-orange-300/80 pr-1">{tr('ovListening')}</span>
          </div>
        )}

        {state === 'recording' && (
          <div className="flex items-center space-x-2 pointer-events-none">
            <div className="w-2.5 h-2.5 rounded-full bg-red-500 animate-pulse" />
            {modeTag}
            <canvas ref={canvasRef} className="w-[100px] h-[22px]" />
            <span className="text-[11px] font-mono text-white/50 tabular-nums">
              {fmtDuration(elapsedSec)}
            </span>
            {/* 串流辨識時邊講邊出字；其他引擎沒有中途結果，這裡就不會出現 */}
            {partialText && (
              <span className="text-[12px] text-white/80 truncate max-w-[240px] border-l border-white/10 pl-2">
                {partialText}
              </span>
            )}
          </div>
        )}

        {state === 'processing' && (
          <div className="flex items-center space-x-2 pointer-events-none">
            <Loader2 className="w-3.5 h-3.5 text-orange-400 animate-spin" />
            {modeTag}
            <span className="text-[12px] text-white/70 pr-1">{tr('ovProcessing')}</span>
            {(rawText || partialText) && (
              <span className="text-[11px] text-white/30 max-w-[180px] truncate">
                {rawText || partialText}
              </span>
            )}
          </div>
        )}

        {state === 'previewing' && (
          <div className="flex items-center space-x-2 pointer-events-none">
            <div className="flex flex-col min-w-0 max-w-[220px]">
              <span className="text-[10px] font-semibold text-blue-300 leading-none">{tr('ovPreview')}</span>
              <span className="text-[12px] text-white truncate mt-0.5">
                {processedText || tr('ovRefining')}
              </span>
            </div>
            <div className="flex items-center space-x-1 pointer-events-auto" onClick={(e) => e.stopPropagation()}>
              <button
                onClick={confirmInject}
                className="flex items-center justify-center w-7 h-7 rounded-full bg-emerald-500/20 hover:bg-emerald-500 text-emerald-300 hover:text-white transition-all border border-emerald-500/30"
                title={tr('ovInject')}
              >
                <Check className="w-3.5 h-3.5" />
              </button>
              <button
                onClick={regenerateResult}
                className="flex items-center justify-center w-7 h-7 rounded-full bg-amber-500/20 hover:bg-amber-500 text-amber-300 hover:text-white transition-all border border-amber-500/30"
                title={tr('ovRegenerate')}
              >
                <RotateCw className="w-3 h-3" />
              </button>
              <button
                onClick={cancelPreview}
                className="flex items-center justify-center w-7 h-7 rounded-full bg-white/5 hover:bg-red-500/20 text-white/60 hover:text-red-400 transition-all border border-white/10"
                title={tr('cancel')}
              >
                <X className="w-3.5 h-3.5" />
              </button>
            </div>
          </div>
        )}

        {state === 'done' && (
          <div className="flex items-center space-x-2 pointer-events-none">
            <Check className="w-3.5 h-3.5 text-emerald-400" />
            <span className="text-[12px] text-white truncate max-w-[280px]">
              {processedText || rawText || tr('done')}
            </span>
          </div>
        )}

        {state === 'confirming' && (
          <div className="flex items-center space-x-2 pointer-events-none">
            <div className="flex items-center justify-center w-7 h-7 rounded-full bg-cyan-500/20 border border-cyan-500/40 text-cyan-300 text-xs font-bold animate-pulse">
              {countdown}
            </div>
            <span className="text-[12px] text-white truncate max-w-[200px]">{processedText}</span>
            <button
              onClick={(e) => { e.stopPropagation(); cancelConfirming(); }}
              className="text-[11px] text-white/50 hover:text-red-400 border border-white/10 rounded-full px-2.5 py-1 transition-colors pointer-events-auto"
            >
              {tr('cancel')}
            </button>
          </div>
        )}

        {state === 'error' && (
          <div className="flex items-center space-x-2 pointer-events-none">
            <AlertCircle className="w-3.5 h-3.5 text-red-400 flex-shrink-0" />
            {/* 錯誤最多兩行（原生 lineLimit(2)），完整訊息放 title */}
            <span className="text-[11px] leading-snug text-red-300 max-w-[260px] line-clamp-2 break-words" title={errorMsg}>
              {errorMsg}
            </span>
            {rawText && (
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  retryLastAction();
                }}
                className="flex items-center justify-center w-7 h-7 rounded-full bg-amber-500/20 hover:bg-amber-500 text-amber-300 hover:text-white transition-all border border-amber-500/30 flex-shrink-0 pointer-events-auto"
                title={tr('ovRetryHint')}
              >
                <RotateCw className="w-3 h-3" />
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
