// 語音模式：每個模式一段指令 + 一組快捷鍵（按一下開始、再按一下停止）。
// 對應原生 UI/Settings/VoiceModesSection.swift；快捷鍵錄製 10 秒逾時、Esc 取消。
import { useState } from 'react';
import { Layers, Plus, ChevronDown, ChevronRight, Trash2, XCircle, AlertTriangle } from 'lucide-react';

import type { AppSettings } from '../../services/settings';
import { newVoiceModeId, type VoiceMode } from '../../services/voiceModes';
import type { Translator } from '../../services/l10n';
import { useHotkeyCapture, sameAccelerator } from '../../components/hotkeyCapture';
import { detectPlatform, displayHotkey } from '../../components/platform';
import { Button, ConfirmDialog, GlassCard, SettingDescription } from '../../components/ui';

interface Props {
  settings: AppSettings;
  update: (patch: Partial<AppSettings>) => void;
  tr: Translator;
}

export function VoiceModesSection({ settings, update, tr }: Props) {
  const platform = detectPlatform();
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [conflictId, setConflictId] = useState<string | null>(null);
  const [pendingDelete, setPendingDelete] = useState<VoiceMode | null>(null);
  const modes = settings.voiceModes;

  const setModes = (next: VoiceMode[]) => update({ voiceModes: next });
  const patchMode = (id: string, patch: Partial<VoiceMode>) =>
    setModes(modes.map((m) => (m.id === id ? { ...m, ...patch } : m)));

  // 只記 id：回呼時列表可能已增刪重排，用 id 找回目標
  const capture = useHotkeyCapture<string>((id, accelerator) => {
    if (sameAccelerator(accelerator, settings.hotkey)) {
      setConflictId(id);
      return;
    }
    setConflictId(null);
    if (!modes.some((m) => m.id === id)) return;
    // 同一組快捷鍵只能給一個模式：搶過來，原本的清掉
    setModes(
      modes.map((m) => {
        if (m.id === id) return { ...m, hotkey: accelerator };
        if (sameAccelerator(m.hotkey, accelerator)) return { ...m, hotkey: null };
        return m;
      })
    );
  });

  const addMode = () => {
    const mode: VoiceMode = { id: newVoiceModeId(), name: tr('vmNewModeName'), instructions: '', hotkey: null };
    setModes([...modes, mode]);
    setExpandedId(mode.id);
  };

  const requestDelete = (mode: VoiceMode) => {
    // 還沒寫指令的空模式直接刪；有內容的先確認
    if (!mode.instructions.trim()) setModes(modes.filter((m) => m.id !== mode.id));
    else setPendingDelete(mode);
  };

  return (
    <GlassCard title={tr('vmTitle')} icon={Layers}>
      <div className="flex items-start justify-between gap-4">
        <SettingDescription>{tr('vmDesc')}</SettingDescription>
        <Button onClick={addMode} className="flex-shrink-0">
          <span className="flex items-center gap-1">
            <Plus className="w-3.5 h-3.5" /> {tr('vmAddMode')}
          </span>
        </Button>
      </div>

      <div className="space-y-2">
        {modes.map((mode) => {
          const expanded = expandedId === mode.id;
          const recording = capture.target === mode.id;
          return (
            <div key={mode.id} className="p-3 bg-slate-950/50 border border-white/5 rounded-xl space-y-2">
              <div className="flex items-center gap-2">
                <button
                  type="button"
                  onClick={() => setExpandedId(expanded ? null : mode.id)}
                  title={tr('expand')}
                  aria-label={tr('expand')}
                  className="p-1 text-white/50 hover:text-white cursor-pointer"
                >
                  {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
                </button>
                <input
                  type="text"
                  value={mode.name}
                  placeholder={tr('vmNamePlaceholder')}
                  onChange={(e) => patchMode(mode.id, { name: e.target.value })}
                  className="w-44 bg-slate-950 border border-white/10 rounded-lg px-3 py-1.5 text-xs focus:outline-none focus:border-emerald-500/50"
                />
                <div className="flex-1" />
                <button
                  type="button"
                  onClick={() => (recording ? capture.cancel() : (setConflictId(null), capture.start(mode.id)))}
                  title={recording ? tr('vmCancelRecordingHelp') : tr('vmSetHotkey')}
                  className={`px-3 py-1.5 rounded-lg border text-xs font-mono cursor-pointer transition-colors ${
                    recording
                      ? 'bg-orange-500/15 border-orange-500/40 text-orange-300 animate-pulse'
                      : 'bg-slate-950/60 border-white/10 text-white/70 hover:text-white'
                  }`}
                >
                  {recording
                    ? tr('vmPressHotkey', { n: capture.remaining })
                    : mode.hotkey
                      ? displayHotkey(mode.hotkey, platform)
                      : tr('vmSetHotkey')}
                </button>
                {mode.hotkey && !recording && (
                  <button
                    type="button"
                    onClick={() => patchMode(mode.id, { hotkey: null })}
                    title={tr('vmClearHotkey')}
                    aria-label={tr('vmClearHotkey')}
                    className="p-1 text-white/40 hover:text-white cursor-pointer"
                  >
                    <XCircle className="w-4 h-4" />
                  </button>
                )}
                <button
                  type="button"
                  onClick={() => requestDelete(mode)}
                  title={tr('vmDeleteMode')}
                  aria-label={tr('vmDeleteMode')}
                  className="p-1 text-white/35 hover:text-red-400 cursor-pointer"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>

              {recording && capture.needsModifier && (
                <p className="text-[11px] text-amber-300">{tr('vmNeedsModifier')}</p>
              )}
              {conflictId === mode.id && (
                <p className="flex items-center gap-1.5 text-xs text-amber-300">
                  <AlertTriangle className="w-3.5 h-3.5" /> {tr('vmConflictsWithMain')}
                </p>
              )}

              {expanded && (
                <div className="space-y-1.5 pl-7">
                  <div className="text-xs font-semibold text-white/70">{tr('vmInstructions')}</div>
                  <textarea
                    value={mode.instructions}
                    onChange={(e) => patchMode(mode.id, { instructions: e.target.value })}
                    rows={3}
                    className="w-full min-h-[70px] bg-slate-950 border border-white/10 rounded-lg px-3 py-2 text-xs leading-relaxed focus:outline-none focus:border-emerald-500/50"
                  />
                  <SettingDescription>{tr('vmInstructionsExample')}</SettingDescription>
                </div>
              )}
            </div>
          );
        })}
      </div>

      <ConfirmDialog
        open={pendingDelete !== null}
        title={tr('vmDeleteConfirm', { name: pendingDelete?.name ?? '' })}
        message={tr('vmDeleteMessage')}
        confirmLabel={tr('delete')}
        cancelLabel={tr('cancel')}
        destructive
        onConfirm={() => {
          if (pendingDelete) setModes(modes.filter((m) => m.id !== pendingDelete.id));
          setPendingDelete(null);
        }}
        onCancel={() => setPendingDelete(null)}
      />
    </GlassCard>
  );
}
