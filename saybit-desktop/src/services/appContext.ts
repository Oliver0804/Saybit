// 前景 App 辨識：把作業系統回報的 App 名稱 / bundle id / exe 路徑歸類成穩定的
// context identifier（"slack"、"cursor"、"gmail"…），供 prompt 與 per-app 規則使用。
//
// 對應原生版 Models/AppContext.swift。比對規則刻意用「名稱或 bundle 任一命中」，
// 因為三個平台給的資訊不同：macOS 有 bundle id、Windows 只有 exe 路徑、
// Linux 只有 WM_CLASS。

import { invoke } from '@tauri-apps/api/core';

export interface ForegroundApp {
  appName: string;
  bundleId: string;
}

export type ContextCategory =
  | 'code_editor'
  | 'chat_messaging'
  | 'email_document'
  | 'note_taking'
  | 'design'
  | 'project_management'
  | 'browser'
  | 'ai_tool'
  | 'unknown';

export interface AppContext {
  appName: string;
  bundleId: string;
  /// 正規化後的識別字，例如 "slack"
  identifier: string;
  category: ContextCategory;
  selectedText: string;
  /// 前景 App 是 Saybit 自己（通常是在設定視窗前景時按了快捷鍵）
  isSelf: boolean;
}

export const EMPTY_CONTEXT: AppContext = {
  appName: '',
  bundleId: '',
  identifier: 'unknown',
  category: 'unknown',
  selectedText: '',
  isSelf: false,
};

// 比對表：[識別字, 名稱關鍵字[], bundle 關鍵字[]]
// 順序有意義 —— 先命中的先贏，所以較specific 的項目要排前面。
const MATCHERS: Array<[string, string[], string[]]> = [
  // 程式編輯器與 IDE
  ['cursor', ['cursor'], ['cursor']],
  ['vscode', ['code'], ['vscode']],
  ['windsurf', ['windsurf'], ['windsurf']],
  ['xcode', ['xcode'], ['xcode']],
  ['intellij', ['intellij'], ['intellij']],
  ['pycharm', ['pycharm'], ['pycharm']],
  ['android-studio', ['android studio'], ['android-studio']],
  ['sublime', ['sublime'], ['sublimetext']],
  ['fleet', ['fleet'], ['fleet']],
  ['zed', ['zed'], ['zed']],
  ['vim', ['vim', 'neovim'], []],
  ['terminal', ['terminal', 'iterm', 'warp', 'wezterm', 'alacritty'], ['terminal', 'iterm', 'warp']],
  ['terminal', ['windowsterminal', 'powershell', 'cmd'], []],

  // 聊天與即時通訊
  ['slack', ['slack'], ['slack']],
  ['discord', ['discord'], ['discord']],
  ['line', [], ['naver.line']],
  ['imessage', ['messages'], ['imessage']],
  ['telegram', ['telegram'], ['telegram']],
  ['wechat', ['wechat'], ['wechat']],
  ['teams', ['teams'], ['teams']],
  ['messenger', ['messenger'], ['messenger']],
  ['zoom-chat', ['zoom'], ['zoom']],

  // 郵件與文件
  ['gmail', ['mail'], ['mail']],
  ['outlook', ['outlook'], ['outlook']],
  ['google-docs', ['docs'], ['docs']],
  ['google-sheets', ['sheets'], ['sheets']],
  ['word', ['word', 'winword'], ['msword']],

  // 筆記
  ['obsidian', ['obsidian'], ['obsidian']],
  ['notes', ['notes'], ['notes']],
  ['notion', ['notion'], ['notion']],

  // 設計
  ['figma', ['figma'], ['figma']],
  ['sketch', ['sketch'], ['sketch']],

  // 專案管理
  ['linear', ['linear'], ['linear']],
  ['jira', ['jira'], ['jira']],
  ['clickup', ['clickup'], ['clickup']],
  ['asana', ['asana'], ['asana']],

  // 瀏覽器
  ['safari', ['safari'], ['safari']],
  ['chrome', ['chrome'], ['chrome']],
  ['firefox', ['firefox'], ['firefox']],
  ['arc', ['arc'], ['arc']],
  ['edge', ['msedge', 'microsoft edge'], ['edge']],

  // AI 工具
  ['chatgpt', ['chatgpt'], ['chatgpt']],
  ['claude', ['claude'], ['claude']],
];

const CATEGORY_MAP: Record<string, ContextCategory> = {
  cursor: 'code_editor',
  vscode: 'code_editor',
  windsurf: 'code_editor',
  xcode: 'code_editor',
  intellij: 'code_editor',
  pycharm: 'code_editor',
  'android-studio': 'code_editor',
  sublime: 'code_editor',
  fleet: 'code_editor',
  zed: 'code_editor',
  vim: 'code_editor',
  terminal: 'code_editor',

  slack: 'chat_messaging',
  discord: 'chat_messaging',
  line: 'chat_messaging',
  imessage: 'chat_messaging',
  telegram: 'chat_messaging',
  wechat: 'chat_messaging',
  teams: 'chat_messaging',
  messenger: 'chat_messaging',
  'zoom-chat': 'chat_messaging',

  gmail: 'email_document',
  outlook: 'email_document',
  word: 'email_document',
  'google-docs': 'email_document',
  'google-sheets': 'email_document',

  obsidian: 'note_taking',
  notes: 'note_taking',
  notion: 'note_taking',

  figma: 'design',
  sketch: 'design',

  linear: 'project_management',
  jira: 'project_management',
  clickup: 'project_management',
  asana: 'project_management',

  safari: 'browser',
  chrome: 'browser',
  firefox: 'browser',
  arc: 'browser',
  edge: 'browser',

  chatgpt: 'ai_tool',
  claude: 'ai_tool',
};

/// 前景 App 是不是 Saybit 自己。
///
/// 在設定視窗前景時按快捷鍵就會發生。這時候把 "saybit-desktop" 當成 app context
/// 餵給 LLM 沒有任何意義（模型不認得這個 App），注入也會貼回 Saybit 自己的視窗。
export function isSelfApp(appName: string, bundleId: string): boolean {
  const name = (appName || '').toLowerCase();
  const bundle = (bundleId || '').toLowerCase();
  return (
    bundle.includes('com.oliver.saybit-desktop') ||
    name === 'saybit-desktop' ||
    name === 'saybit'
  );
}

/// 把 App 名稱 / bundle id 正規化成 context identifier。
export function resolveContextIdentifier(appName: string, bundleId: string): string {
  const name = (appName || '').toLowerCase();
  const bundle = (bundleId || '').toLowerCase();

  if (isSelfApp(appName, bundleId)) return 'unknown';

  // LINE 特例：用 bundle 或精確名比對，避免 Timeline / Streamline / Baseline
  // 這類含有 "line" 的名稱被誤判（原生版同樣的坑）。
  if (bundle.includes('naver.line') || bundle.endsWith('.line') || name === 'line') {
    return 'line';
  }

  for (const [id, nameKeys, bundleKeys] of MATCHERS) {
    if (nameKeys.some((k) => name.includes(k))) return id;
    if (bundleKeys.some((k) => bundle.includes(k))) return id;
  }

  return name || 'unknown';
}

export function categoryFor(identifier: string): ContextCategory {
  return CATEGORY_MAP[identifier] ?? 'unknown';
}

/// 查詢目前前景 App。必須在 Saybit 自己的視窗顯示「之前」呼叫。
export async function captureForegroundApp(): Promise<AppContext> {
  try {
    const fg = await invoke<ForegroundApp>('foreground_app');
    const identifier = resolveContextIdentifier(fg.appName, fg.bundleId);
    return {
      appName: fg.appName,
      bundleId: fg.bundleId,
      identifier,
      category: categoryFor(identifier),
      selectedText: '',
      isSelf: isSelfApp(fg.appName, fg.bundleId),
    };
  } catch {
    return { ...EMPTY_CONTEXT };
  }
}

/// 對這個 App 送出「複製」鍵是否安全。
///
/// 擷取選取文字的手法是模擬 Cmd/Ctrl+C 再讀剪貼簿。在終端機裡這是危險的：
/// 沒有選取內容時 Ctrl+C 會變成 SIGINT，直接中斷使用者正在跑的程式。
/// 原生 macOS 版走 AX API 讀取，沒有這個副作用；Tauri 沒有等價 API，
/// 因此對終端機類的 App 一律跳過選取擷取（其餘功能不受影響）。
export function isSelectionCaptureSafe(identifier: string): boolean {
  return identifier !== 'terminal';
}

/// 讀取前景 App 目前選取的文字（Rust 端會還原剪貼簿）。沒有選取時回空字串。
export async function captureSelectedText(): Promise<string> {
  try {
    return await invoke<string>('get_selected_text');
  } catch {
    return '';
  }
}
