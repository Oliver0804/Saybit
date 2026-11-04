// 平台判斷。專案沒有裝 @tauri-apps/plugin-os（v2 已把 os API 移到 plugin），
// 這裡只靠 userAgent：WKWebView / WebView2 / WebKitGTK 的 UA 都帶得出作業系統。
export type DesktopPlatform = 'macos' | 'windows' | 'linux';

export function detectPlatform(): DesktopPlatform {
  const ua = navigator.userAgent;
  if (ua.includes('Mac')) return 'macos';
  if (ua.includes('Win')) return 'windows';
  return 'linux';
}

/// 快捷鍵顯示：macOS 用 ⌃⌥⇧⌘ 符號，其他平台維持文字
export function displayHotkey(accelerator: string, platform: DesktopPlatform = detectPlatform()): string {
  if (!accelerator) return '';
  if (platform !== 'macos') return accelerator.replace(/Super/g, 'Win');
  const symbols: Record<string, string> = {
    Ctrl: '⌃',
    Control: '⌃',
    Alt: '⌥',
    Option: '⌥',
    Shift: '⇧',
    Super: '⌘',
    Cmd: '⌘',
    Command: '⌘',
    CmdOrCtrl: '⌘',
    CommandOrControl: '⌘',
  };
  const parts = accelerator.split('+');
  const key = parts.pop() ?? '';
  return parts.map((p) => symbols[p] ?? p).join('') + key;
}
