// 比對使用者選的快捷鍵是否撞到已知系統／常見 App 熱鍵。
// 移植自原生版 Core/HotKey/HotKeyConflictChecker.swift，並補上 Windows 側常見組合。
//
// 這是 best-effort 的「軟性」警告：真正的系統熱鍵表在各平台都沒有穩定的公開 API，
// 撞到清單只代表「很可能被攔截」，不代表一定不能用。

export interface KnownShortcut {
  /// 正規化後的組合字串，例如 "cmd+space"
  combo: string;
  name: string;
  platform: 'macos' | 'windows' | 'all';
}

export const KNOWN_SHORTCUTS: KnownShortcut[] = [
  // macOS
  { combo: 'cmd+space', name: 'Spotlight (⌘ Space)', platform: 'macos' },
  { combo: 'ctrl+space', name: '切換輸入來源 (⌃ Space)', platform: 'macos' },
  { combo: 'cmd+shift+3', name: '螢幕截圖 (⌘⇧3)', platform: 'macos' },
  { combo: 'cmd+shift+4', name: '區域截圖 (⌘⇧4)', platform: 'macos' },
  { combo: 'cmd+shift+5', name: '截圖工具 (⌘⇧5)', platform: 'macos' },
  { combo: 'ctrl+up', name: 'Mission Control (⌃↑)', platform: 'macos' },
  { combo: 'ctrl+down', name: 'App Windows (⌃↓)', platform: 'macos' },
  { combo: 'ctrl+left', name: '切換桌面 (⌃←)', platform: 'macos' },
  { combo: 'ctrl+right', name: '切換桌面 (⌃→)', platform: 'macos' },
  { combo: 'cmd+tab', name: 'App 切換器 (⌘Tab)', platform: 'macos' },
  { combo: 'cmd+h', name: '隱藏 App (⌘H)', platform: 'macos' },
  { combo: 'cmd+q', name: '結束 App (⌘Q)', platform: 'macos' },
  { combo: 'cmd+c', name: '複製 (⌘C)', platform: 'macos' },
  { combo: 'cmd+v', name: '貼上 (⌘V)', platform: 'macos' },
  { combo: 'cmd+x', name: '剪下 (⌘X)', platform: 'macos' },
  { combo: 'cmd+a', name: '全選 (⌘A)', platform: 'macos' },
  { combo: 'cmd+z', name: '還原 (⌘Z)', platform: 'macos' },
  { combo: 'cmd+s', name: '儲存 (⌘S)', platform: 'macos' },
  { combo: 'cmd+n', name: '開新檔案 (⌘N)', platform: 'macos' },
  { combo: 'cmd+o', name: '開啟 (⌘O)', platform: 'macos' },
  { combo: 'cmd+w', name: '關閉視窗 (⌘W)', platform: 'macos' },
  { combo: 'ctrl+cmd+q', name: '鎖定螢幕 (⌃⌘Q)', platform: 'macos' },

  // Windows
  { combo: 'ctrl+alt+delete', name: '安全性選項 (Ctrl+Alt+Del)', platform: 'windows' },
  { combo: 'alt+tab', name: '視窗切換 (Alt+Tab)', platform: 'windows' },
  { combo: 'ctrl+shift+esc', name: '工作管理員', platform: 'windows' },
  { combo: 'ctrl+c', name: '複製 (Ctrl+C)', platform: 'windows' },
  { combo: 'ctrl+v', name: '貼上 (Ctrl+V)', platform: 'windows' },
  { combo: 'ctrl+x', name: '剪下 (Ctrl+X)', platform: 'windows' },
  { combo: 'ctrl+a', name: '全選 (Ctrl+A)', platform: 'windows' },
  { combo: 'ctrl+z', name: '還原 (Ctrl+Z)', platform: 'windows' },
  { combo: 'ctrl+s', name: '儲存 (Ctrl+S)', platform: 'windows' },
  { combo: 'ctrl+w', name: '關閉分頁 (Ctrl+W)', platform: 'windows' },
];

/// 把 "CommandOrControl+Shift+D" 這類 Tauri 加速器字串正規化成 "cmd+shift+d"。
export function normalizeAccelerator(accelerator: string, isMac: boolean): string {
  const parts = accelerator
    .split('+')
    .map((p) => p.trim().toLowerCase())
    .filter(Boolean);

  const modifiers = new Set<string>();
  let key = '';

  for (const part of parts) {
    switch (part) {
      case 'command':
      case 'cmd':
      case 'super':
      case 'meta':
        modifiers.add('cmd');
        break;
      case 'commandorcontrol':
      case 'cmdorctrl':
        modifiers.add(isMac ? 'cmd' : 'ctrl');
        break;
      case 'control':
      case 'ctrl':
        modifiers.add('ctrl');
        break;
      case 'alt':
      case 'option':
        modifiers.add('alt');
        break;
      case 'shift':
        modifiers.add('shift');
        break;
      default:
        key = part;
    }
  }

  // 固定順序，讓比對不受使用者輸入順序影響
  const ordered = ['ctrl', 'alt', 'shift', 'cmd'].filter((m) => modifiers.has(m));
  return [...ordered, key].filter(Boolean).join('+');
}

/// 回傳撞到的已知熱鍵；沒撞到回 null。
export function findConflict(
  accelerator: string,
  platform: 'macos' | 'windows' | 'linux'
): KnownShortcut | null {
  const isMac = platform === 'macos';
  const normalized = normalizeAccelerator(accelerator, isMac);
  return (
    KNOWN_SHORTCUTS.find(
      (shortcut) =>
        shortcut.combo === normalized &&
        (shortcut.platform === 'all' || shortcut.platform === platform)
    ) ?? null
  );
}

/// 沒有修飾鍵的單鍵快捷鍵幾乎一定會誤觸，單獨提醒。
export function isBareKey(accelerator: string): boolean {
  return !/(\+)/.test(accelerator.trim());
}
