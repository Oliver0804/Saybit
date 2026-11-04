// 在 webview 內錄製快捷鍵，轉成 Tauri global-shortcut 的加速器字串（例：Ctrl+Alt+Space）。
// 對應原生 GlobalHotKeyManager.startRecording：Esc 取消、逾時自動結束、至少一個修飾鍵。
import { useCallback, useEffect, useRef, useState } from 'react';

const MODIFIER_KEYS = ['Control', 'Alt', 'Shift', 'Meta', 'OS', 'AltGraph'];

/// 用 event.code 而不是 event.key：macOS 按住 Option 時 key 會變成特殊字元（⌥E → ´），
/// code 永遠是實體鍵位。global-shortcut 的解析器接受 KeyA / Digit1 / Space / F1 / ArrowUp 這類名稱。
export function acceleratorFromEvent(event: KeyboardEvent): { accelerator: string; hasModifier: boolean } | null {
  if (MODIFIER_KEYS.includes(event.key)) return null;
  const parts: string[] = [];
  if (event.ctrlKey) parts.push('Ctrl');
  if (event.altKey) parts.push('Alt');
  if (event.shiftKey) parts.push('Shift');
  if (event.metaKey) parts.push('Super');
  const hasModifier = parts.length > 0;

  const code = event.code;
  let main: string;
  if (/^Key[A-Z]$/.test(code)) main = code.slice(3);
  else if (/^Digit[0-9]$/.test(code)) main = code.slice(5);
  else if (code) main = code;
  else main = event.key.length === 1 ? event.key.toUpperCase() : event.key;
  parts.push(main);
  return { accelerator: parts.join('+'), hasModifier };
}

/// 錄製狀態機：start(target) 開始等按鍵；按下合法組合時呼叫 onCapture(target, accel)。
/// timeoutSeconds 秒內沒按就自動取消（原生版 10 秒）。
export function useHotkeyCapture<T extends string>(
  onCapture: (target: T, accelerator: string) => void,
  options: { timeoutSeconds?: number; requireModifier?: boolean } = {}
) {
  const { timeoutSeconds = 10, requireModifier = true } = options;
  const [target, setTarget] = useState<T | null>(null);
  const [remaining, setRemaining] = useState(0);
  const [needsModifier, setNeedsModifier] = useState(false);
  const onCaptureRef = useRef(onCapture);
  onCaptureRef.current = onCapture;

  const cancel = useCallback(() => {
    setTarget(null);
    setRemaining(0);
  }, []);

  const start = useCallback(
    (next: T) => {
      setNeedsModifier(false);
      setTarget(next);
      setRemaining(timeoutSeconds);
    },
    [timeoutSeconds]
  );

  useEffect(() => {
    if (target === null) return;
    const timer = window.setInterval(() => {
      setRemaining((r) => {
        if (r <= 1) {
          setTarget(null);
          return 0;
        }
        return r - 1;
      });
    }, 1000);

    const onKeyDown = (event: KeyboardEvent) => {
      event.preventDefault();
      event.stopPropagation();
      if (event.key === 'Escape' && !event.ctrlKey && !event.altKey && !event.metaKey && !event.shiftKey) {
        setTarget(null);
        return;
      }
      const result = acceleratorFromEvent(event);
      if (!result) return; // 只按了修飾鍵，繼續等主鍵
      if (requireModifier && !result.hasModifier) {
        setNeedsModifier(true);
        return;
      }
      const captured = target;
      setTarget(null);
      setRemaining(0);
      onCaptureRef.current(captured, result.accelerator);
    };

    window.addEventListener('keydown', onKeyDown, true);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener('keydown', onKeyDown, true);
    };
  }, [target, requireModifier]);

  return { target, remaining, needsModifier, start, cancel };
}

/// 比對兩組加速器是否相同（修飾鍵順序、大小寫、KeyA/A 寫法不同都視為同一組）
export function sameAccelerator(a: string | null | undefined, b: string | null | undefined): boolean {
  if (!a || !b) return false;
  const norm = (s: string) => {
    const parts = s.split('+').map((p) => p.trim().toLowerCase());
    const key = (parts.pop() ?? '').replace(/^key([a-z])$/, '$1').replace(/^digit([0-9])$/, '$1');
    const mods = parts
      .map((m) => (m === 'control' ? 'ctrl' : m === 'option' ? 'alt' : ['cmd', 'command', 'meta'].includes(m) ? 'super' : m))
      .sort();
    return [...mods, key].join('+');
  };
  return norm(a) === norm(b);
}
