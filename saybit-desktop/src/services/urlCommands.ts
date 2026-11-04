// saybit:// URL 指令（對應原生版 AppDelegate.handleURL + 審查 H5）。
// Rust（deep-link plugin）解析後 emit "url-command" { command, mode?, tab? } 到 overlay；
// settings 指令直接送 main 視窗。這裡只做純邏輯：解析 payload、依使用者決定分流。

export const URL_COMMAND_EVENT = 'url-command';
/// 尚未決定是否允許時，overlay emit 給 main 視窗顯示詢問對話框
export const URL_COMMAND_ASK_EVENT = 'url-command-ask';

export type UrlCommandName = 'toggle' | 'start' | 'stop' | 'cancel' | 'settings';

export interface UrlCommand {
  command: UrlCommandName;
  mode?: string;
  tab?: string;
}

export type UrlSchemeDecisionLike = 'ask' | 'allow' | 'deny';

const COMMANDS = new Set<UrlCommandName>(['toggle', 'start', 'stop', 'cancel', 'settings']);

function normalizeCommand(raw: unknown): UrlCommandName | null {
  if (typeof raw !== 'string') return null;
  const c = raw.trim().replace(/^\/+|\/+$/g, '').toLowerCase();
  if (c === 'dictate') return 'toggle'; // 原生版的別名
  return COMMANDS.has(c as UrlCommandName) ? (c as UrlCommandName) : null;
}

function cleanParam(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const s = v.trim();
  return s ? s : undefined;
}

/// 接受 Rust 事件 payload（{ command, mode?, tab? }）或原始 URL 字串（saybit://toggle?mode=Email）。
/// 不認得的一律回 null。
export function parseUrlCommand(input: unknown): UrlCommand | null {
  if (typeof input === 'string') {
    let url: URL;
    try {
      url = new URL(input.trim());
    } catch {
      return null;
    }
    if (url.protocol.toLowerCase() !== 'saybit:') return null;
    // saybit://toggle → host = toggle；saybit:toggle / saybit:///toggle → pathname
    const command = normalizeCommand(url.hostname || url.pathname);
    if (!command) return null;
    const out: UrlCommand = { command };
    const mode = cleanParam(url.searchParams.get('mode'));
    const tab = cleanParam(url.searchParams.get('tab'));
    if (mode) out.mode = mode;
    if (tab) out.tab = tab;
    return out;
  }
  if (input && typeof input === 'object') {
    const o = input as Record<string, unknown>;
    const command = normalizeCommand(o.command);
    if (!command) return null;
    const out: UrlCommand = { command };
    const mode = cleanParam(o.mode);
    const tab = cleanParam(o.tab);
    if (mode) out.mode = mode;
    if (tab) out.tab = tab;
    return out;
  }
  return null;
}

/// settings 指令不會錄音、不注入，不用問；其他依使用者的決定。
export function routeUrlCommand(
  cmd: UrlCommand,
  decision: UrlSchemeDecisionLike
): 'execute' | 'ask' | 'ignore' {
  if (cmd.command === 'settings') return 'execute';
  if (decision === 'allow') return 'execute';
  if (decision === 'deny') return 'ignore';
  return 'ask';
}
