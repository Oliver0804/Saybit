// 「其他 App 想透過 saybit:// 控制 Saybit」詢問對話框（只在 main 視窗掛載）。
// overlay 在 urlSchemeDecision = 'ask' 時 emit url-command-ask；這裡把決定寫回設定
//（updateSettings 會 emit settings-updated 同步到 overlay，overlay 收到 'allow' 後自己補執行暫存的那個指令，
// 這裡不要再轉送，否則 toggle 會被執行兩次）。
import { useEffect, useState } from 'react';
import { listen } from '@tauri-apps/api/event';
import { getCurrentWindow } from '@tauri-apps/api/window';

import type { AppSettings } from '../services/settings';
import { parseUrlCommand, URL_COMMAND_ASK_EVENT, type UrlCommand } from '../services/urlCommands';
import type { Translator } from '../services/l10n';
import { ConfirmDialog } from '../components/ui';

interface Props {
  update: (patch: Partial<AppSettings>) => void;
  tr: Translator;
}

function describe(cmd: UrlCommand): string {
  const params = new URLSearchParams();
  if (cmd.mode) params.set('mode', cmd.mode);
  if (cmd.tab) params.set('tab', cmd.tab);
  const q = params.toString();
  return `saybit://${cmd.command}${q ? `?${q}` : ''}`;
}

export function UrlCommandAskDialog({ update, tr }: Props) {
  const [pending, setPending] = useState<UrlCommand | null>(null);

  useEffect(() => {
    const unlisten = listen<unknown>(URL_COMMAND_ASK_EVENT, (event) => {
      const cmd = parseUrlCommand(event.payload);
      if (!cmd) return;
      setPending(cmd);
      // 要使用者回答，視窗得在前面（overlay 不可搶焦點，所以由 main 出面）
      const win = getCurrentWindow();
      win.show().catch(() => {});
      win.setFocus().catch(() => {});
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const decide = (allow: boolean) => {
    setPending(null);
    update({ urlSchemeDecision: allow ? 'allow' : 'deny' });
  };

  return (
    <ConfirmDialog
      open={pending !== null}
      title={tr('urlAskTitle')}
      message={tr('urlAskMessage')}
      confirmLabel={tr('urlDecisionAllow')}
      cancelLabel={tr('urlDecisionDeny')}
      onConfirm={() => decide(true)}
      onCancel={() => decide(false)}
    >
      {pending && (
        <code className="block text-[11px] font-mono text-emerald-300 bg-slate-950/70 border border-white/5 rounded-lg px-3 py-2 break-all">
          {tr('urlAskCommand', { command: describe(pending) })}
        </code>
      )}
    </ConfirmDialog>
  );
}
