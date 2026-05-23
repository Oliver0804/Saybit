import { useEffect, useRef } from 'react';
import { 
  Mic, 
  Loader2, 
  Check, 
  RotateCw, 
  X, 
  Volume2, 
  Send,
  AlertCircle
} from 'lucide-react';
import { type useVoicePipeline } from '../hooks/useVoicePipeline';

interface OverlayViewProps {
  pipeline: ReturnType<typeof useVoicePipeline>;
}

export function OverlayView({ pipeline }: OverlayViewProps) {
  const {
    state,
    audioLevel,
    rawText,
    processedText,
    errorMsg,
    countdown,
    confirmInject,
    regenerateResult,
    cancelPreview,
    cancelConfirming,
  } = pipeline;

  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const animationRef = useRef<number | null>(null);
  const phaseRef = useRef<number>(0);

  // 渲染正弦波形 (Canvas 60FPS)
  useEffect(() => {
    if (state !== 'recording') {
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

    // 高解析度適配
    const dpr = window.devicePixelRatio || 1;
    const width = 160;
    const height = 40;
    canvas.width = width * dpr;
    canvas.height = height * dpr;
    ctx.scale(dpr, dpr);

    const draw = () => {
      ctx.clearRect(0, 0, width, height);
      phaseRef.current += 0.15; // 波的移動速度

      // 繪製多層正弦波產生立體感
      const waves = [
        { color: 'rgba(52, 211, 153, 0.6)', amp: 14, freq: 0.05 },
        { color: 'rgba(52, 211, 153, 0.3)', amp: 8, freq: 0.08 },
        { color: 'rgba(16, 185, 129, 0.15)', amp: 5, freq: 0.12 }
      ];

      waves.forEach((wave) => {
        ctx.beginPath();
        ctx.strokeStyle = wave.color;
        ctx.lineWidth = 2;

        for (let x = 0; x < width; x++) {
          // 動態振幅受 audioLevel 影響
          const dynamicAmp = wave.amp * (audioLevel * 1.5 + 0.1);
          const y = height / 2 + Math.sin(x * wave.freq + phaseRef.current) * dynamicAmp;
          if (x === 0) {
            ctx.moveTo(x, y);
          } else {
            ctx.lineTo(x, y);
          }
        }
        ctx.stroke();
      });

      animationRef.current = requestAnimationFrame(draw);
    };

    draw();

    return () => {
      if (animationRef.current) {
        cancelAnimationFrame(animationRef.current);
      }
    };
  }, [state, audioLevel]);

  // 不同狀態對應的邊框與發光陰影
  const getStatusShadow = () => {
    switch (state) {
      case 'recording': return '0 0 20px rgba(52, 211, 153, 0.4)';
      case 'processing': return '0 0 20px rgba(59, 130, 246, 0.4)';
      case 'previewing': return '0 0 20px rgba(139, 92, 246, 0.4)';
      case 'confirming': return '0 0 20px rgba(245, 158, 11, 0.4)';
      case 'error': return '0 0 20px rgba(239, 68, 68, 0.4)';
      default: return '0 8px 32px rgba(0, 0, 0, 0.3)';
    }
  };

  const getStatusBorder = () => {
    switch (state) {
      case 'recording': return 'border-emerald-500/50';
      case 'processing': return 'border-blue-500/50';
      case 'previewing': return 'border-violet-500/50';
      case 'confirming': return 'border-amber-500/50';
      case 'error': return 'border-red-500/50';
      default: return 'border-white/10';
    }
  };

  return (
    <div 
      className={`fixed inset-0 flex items-center justify-center p-2 bg-transparent select-none`}
      style={{ fontFamily: 'system-ui, -apple-system, sans-serif' }}
    >
      <div 
        className={`
          flex items-center w-full h-[76px] px-4 rounded-full border backdrop-blur-xl transition-all duration-300
          bg-slate-900/75 ${getStatusBorder()}
        `}
        style={{ boxShadow: getStatusShadow() }}
      >
        {/* 左側狀態圓圈與圖示 */}
        <div className="flex-shrink-0 flex items-center justify-center w-10 h-10 rounded-full bg-white/5 border border-white/10 mr-3">
          {state === 'recording' && (
            <div className="relative flex items-center justify-center w-6 h-6 rounded-full bg-emerald-500 animate-pulse">
              <Mic className="w-3.5 h-3.5 text-white" />
            </div>
          )}
          {state === 'processing' && (
            <Loader2 className="w-5 h-5 text-blue-400 animate-spin" />
          )}
          {state === 'previewing' && (
            <Volume2 className="w-5 h-5 text-violet-400 animate-bounce" />
          )}
          {state === 'confirming' && (
            <Send className="w-5 h-5 text-amber-400" />
          )}
          {state === 'done' && (
            <Check className="w-5 h-5 text-emerald-400" />
          )}
          {state === 'error' && (
            <AlertCircle className="w-5 h-5 text-red-400" />
          )}
        </div>

        {/* 中間主要展示區 */}
        <div className="flex-grow flex flex-col justify-center min-w-0 mr-3">
          {state === 'recording' && (
            <div className="flex items-center justify-between">
              <span className="text-xs text-white/50 font-medium">Saybit 正在錄音...</span>
              <canvas ref={canvasRef} className="w-[160px] h-[40px] opacity-90" />
            </div>
          )}

          {state === 'processing' && (
            <div className="flex flex-col">
              <span className="text-xs font-semibold text-blue-400">正在處理語意...</span>
              <span className="text-xs text-white/40 truncate mt-0.5">"{rawText}"</span>
            </div>
          )}

          {state === 'previewing' && (
            <div className="flex flex-col min-w-0">
              <span className="text-xs font-bold text-violet-400">預覽結果：</span>
              <span className="text-[13px] text-white font-medium truncate mt-0.5">
                {processedText || '正在精煉...'}
              </span>
            </div>
          )}

          {state === 'confirming' && (
            <div className="flex items-center justify-between">
              <div className="flex flex-col">
                <span className="text-xs font-semibold text-amber-400">自動送出倒數...</span>
                <span className="text-xs text-white/60 truncate mt-0.5">"{processedText}"</span>
              </div>
              <div className="flex-shrink-0 flex items-center justify-center w-8 h-8 rounded-full bg-amber-500/10 border border-amber-500/30 text-amber-400 text-xs font-bold">
                {countdown}
              </div>
            </div>
          )}

          {state === 'done' && (
            <span className="text-sm font-semibold text-emerald-400">已成功注入！</span>
          )}

          {state === 'error' && (
            <div className="flex flex-col">
              <span className="text-xs font-bold text-red-400">發生錯誤</span>
              <span className="text-xs text-white/60 truncate mt-0.5">{errorMsg}</span>
            </div>
          )}
        </div>

        {/* 右側操作按鈕列 (預覽或倒數狀態) */}
        {state === 'previewing' && (
          <div className="flex-shrink-0 flex items-center space-x-1.5">
            <button 
              onClick={confirmInject}
              className="flex items-center justify-center w-8 h-8 rounded-full bg-emerald-500/20 hover:bg-emerald-500 text-emerald-400 hover:text-white transition-all border border-emerald-500/30 cursor-pointer"
              title="注入"
            >
              <Check className="w-4 h-4" />
            </button>
            <button 
              onClick={regenerateResult}
              className="flex items-center justify-center w-8 h-8 rounded-full bg-amber-500/20 hover:bg-amber-500 text-amber-400 hover:text-white transition-all border border-amber-500/30 cursor-pointer"
              title="重新生成"
            >
              <RotateCw className="w-3.5 h-3.5" />
            </button>
            <button 
              onClick={cancelPreview}
              className="flex items-center justify-center w-8 h-8 rounded-full bg-white/5 hover:bg-red-500/20 text-white/60 hover:text-red-400 transition-all border border-white/10 cursor-pointer"
              title="取消"
            >
              <X className="w-4 h-4" />
            </button>
          </div>
        )}

        {state === 'confirming' && (
          <div className="flex-shrink-0">
            <button 
              onClick={cancelConfirming}
              className="flex items-center justify-center w-[72px] h-8 rounded-full bg-white/5 hover:bg-white/10 text-xs font-medium text-white/80 transition-all border border-white/10 cursor-pointer"
            >
              取消發送
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
