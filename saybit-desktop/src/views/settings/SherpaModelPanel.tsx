// SenseVoice 離線模型：下載進度 / 已安裝 / 刪除確認 / 在檔案管理員顯示。
// 對應原生 GeneralSettingsView.swift 的 SherpaModelPanel。
import { useEffect, useRef, useState } from 'react';
import { CheckCircle2, MoreHorizontal, AlertTriangle, Download } from 'lucide-react';
import { revealItemInDir } from '@tauri-apps/plugin-opener';

import {
  getSenseVoiceStatus,
  downloadSenseVoiceModel,
  cancelSenseVoiceDownload,
  deleteSenseVoiceModel,
  type SenseVoiceStatus,
} from '../../services/sherpaStt';
import type { Translator } from '../../services/l10n';
import { Button, ConfirmDialog, ContextMenu, SettingRow } from '../../components/ui';

/// model.int8.onnx + tokens.txt + silero_vad.onnx（契約檔列的位元組數），狀態查不到時用這個顯示大小
const EXPECTED_TOTAL_BYTES = 237_115_547 + 315_894 + 643_854;

function formatSize(bytes: number): string {
  if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(1)} GB`;
  return `${Math.round(bytes / 1e6)} MB`;
}

type PanelState =
  | { kind: 'loading' }
  | { kind: 'unsupported' }
  | { kind: 'notInstalled' }
  | { kind: 'installed' }
  | { kind: 'downloading'; progress: number }
  | { kind: 'failed'; message: string };

/// onStatusChange：讓上層（例如檔案轉錄頁）知道模型是否已安裝
export function SherpaModelPanel({
  tr,
  onStatusChange,
}: {
  tr: Translator;
  onStatusChange?: (installed: boolean) => void;
}) {
  const [state, setState] = useState<PanelState>({ kind: 'loading' });
  const [status, setStatus] = useState<SenseVoiceStatus | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  const cancelledRef = useRef(false);
  const onStatusChangeRef = useRef(onStatusChange);
  onStatusChangeRef.current = onStatusChange;

  const refresh = async () => {
    try {
      const s = await getSenseVoiceStatus();
      setStatus(s);
      if (s.supported === false) {
        setState({ kind: 'unsupported' });
        onStatusChangeRef.current?.(false);
        return;
      }
      setState(s.installed ? { kind: 'installed' } : { kind: 'notInstalled' });
      onStatusChangeRef.current?.(s.installed);
    } catch (e: any) {
      setState({ kind: 'failed', message: String(e?.message || e) });
      onStatusChangeRef.current?.(false);
    }
  };

  useEffect(() => {
    refresh();
  }, []);

  const sizeText = formatSize(status?.total_bytes || EXPECTED_TOTAL_BYTES);

  const startDownload = async () => {
    cancelledRef.current = false;
    setState({ kind: 'downloading', progress: 0 });
    try {
      await downloadSenseVoiceModel((progress) => {
        if (!cancelledRef.current) setState({ kind: 'downloading', progress });
      });
      await refresh();
    } catch (e: any) {
      // 取消下載會丟 CancelledError：不當成失敗，回到實際狀態
      if (cancelledRef.current || (e as { name?: string })?.name === 'CancelledError') await refresh();
      else setState({ kind: 'failed', message: String(e?.message || e) });
    }
  };

  const cancelDownload = async () => {
    cancelledRef.current = true;
    await cancelSenseVoiceDownload();
    await refresh();
  };

  const doDelete = async () => {
    setConfirmDelete(false);
    try {
      await deleteSenseVoiceModel();
    } catch (e: any) {
      setState({ kind: 'failed', message: String(e?.message || e) });
      return;
    }
    await refresh();
  };

  const showInFolder = () => {
    if (status?.dir) revealItemInDir(status.dir).catch(() => {});
  };

  let trailing: React.ReactNode = null;
  switch (state.kind) {
    case 'loading':
      trailing = <span className="text-xs text-white/40">…</span>;
      break;
    case 'unsupported':
      trailing = <span className="text-xs text-amber-300">{tr('errSenseVoiceUnsupportedPlatform')}</span>;
      break;
    case 'installed':
      trailing = (
        <div className="flex items-center gap-2">
          <span className="flex items-center gap-1 text-xs font-semibold text-emerald-400">
            <CheckCircle2 className="w-4 h-4" /> {tr('sherpaInstalled')}
          </span>
          <button
            type="button"
            title={tr('sherpaMoreActions')}
            aria-label={tr('sherpaMoreActions')}
            onClick={(e) => {
              e.stopPropagation();
              const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
              setMenu({ x: rect.left - 150, y: rect.bottom + 4 });
            }}
            className="p-1 rounded-md text-white/50 hover:text-white hover:bg-white/5 cursor-pointer"
          >
            <MoreHorizontal className="w-4 h-4" />
          </button>
        </div>
      );
      break;
    case 'notInstalled':
      trailing = (
        <Button variant="primary" onClick={startDownload}>
          <span className="flex items-center gap-1.5">
            <Download className="w-3.5 h-3.5" /> {tr('sherpaDownload', { size: sizeText })}
          </span>
        </Button>
      );
      break;
    case 'downloading': {
      const pct = Math.round(state.progress * 100);
      trailing = (
        <div className="flex items-center gap-2">
          <div className="w-28 h-1.5 bg-white/5 rounded-full overflow-hidden">
            <div className="h-full bg-emerald-500 transition-all duration-200" style={{ width: `${pct}%` }} />
          </div>
          <span className="text-xs font-mono tabular-nums text-white/50 w-9 text-right">{pct}%</span>
          <Button onClick={cancelDownload}>{tr('cancel')}</Button>
        </div>
      );
      break;
    }
    case 'failed':
      trailing = (
        <div className="flex items-center gap-2 max-w-[260px]">
          <span className="flex items-center gap-1 text-xs text-amber-300 truncate" title={state.message}>
            <AlertTriangle className="w-3.5 h-3.5 flex-shrink-0" />
            <span className="truncate">{state.message}</span>
          </span>
          <Button onClick={startDownload}>{tr('sherpaRetry')}</Button>
        </div>
      );
      break;
  }

  return (
    <>
      <SettingRow title={tr('sherpaModelTitle')} description={tr('sherpaModelDesc')}>
        {trailing}
      </SettingRow>
      <ContextMenu
        position={menu}
        onClose={() => setMenu(null)}
        items={[
          { label: tr('sherpaShowInFolder'), onSelect: showInFolder },
          'separator',
          {
            label: tr('sherpaDeleteModel', { size: sizeText }),
            destructive: true,
            onSelect: () => setConfirmDelete(true),
          },
        ]}
      />
      <ConfirmDialog
        open={confirmDelete}
        title={tr('sherpaDeleteConfirmTitle')}
        message={tr('sherpaDeleteConfirmMessage', { size: sizeText })}
        confirmLabel={tr('delete')}
        cancelLabel={tr('cancel')}
        destructive
        onConfirm={doDelete}
        onCancel={() => setConfirmDelete(false)}
      />
    </>
  );
}
