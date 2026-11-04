// 系統匣選單（對應原生 UI/MenuBar/MenuBarView.swift）：開始／停止錄音、用語音模式錄音、設定、結束。
//
// 托盤圖示由 Rust（lib.rs build_tray）建立；這裡從 overlay webview 換掉它的選單，因為錄音由 overlay 驅動，
// 選單動作的 JS 回呼必須落在擁有 pipeline 的那個 webview。
// 「設定」「結束」沿用 Rust 已在處理的選單 id（show_settings / quit），不需要新增命令。
// 前提：Rust 端要用 TrayIconBuilder::with_id(TRAY_ID) 建立托盤，否則 getById 找不到，就保留 Rust 原本的選單。
import { useEffect, useRef } from 'react';
import { TrayIcon } from '@tauri-apps/api/tray';
import { Menu, MenuItem, PredefinedMenuItem, Submenu } from '@tauri-apps/api/menu';

import type { VoiceMode } from '../services/voiceModes';
import type { Translator } from '../services/l10n';
import { displayHotkey } from './platform';

export const TRAY_ID = 'main';

interface TrayMenuInput {
  enabled: boolean;
  tr: Translator;
  isRecording: boolean;
  /// 引導沒走完不允許開始錄音（停止仍可），與原生 isRecordingAllowed 一致
  canStart: boolean;
  hotkey: string;
  voiceModes: VoiceMode[];
  toggle: (mode?: VoiceMode) => void;
}

export function useTrayMenu(input: TrayMenuInput) {
  const toggleRef = useRef(input.toggle);
  toggleRef.current = input.toggle;
  const { enabled, tr, isRecording, canStart, hotkey, voiceModes } = input;
  // 只在影響選單內容的值變動時重建
  const modesKey = voiceModes.map((m) => `${m.id}\u0000${m.name}\u0000${m.hotkey ?? ''}`).join('\u0001');

  useEffect(() => {
    if (!enabled) return;
    let cancelled = false;

    (async () => {
      const tray = await TrayIcon.getById(TRAY_ID).catch(() => null);
      if (!tray || cancelled) return;

      const items: Array<MenuItem | Submenu | PredefinedMenuItem> = [];
      items.push(
        await MenuItem.new({
          id: 'saybit_tray_toggle',
          text: isRecording
            ? tr('trayStopRecording')
            : tr('trayStartRecording', { hotkey: displayHotkey(hotkey) }),
          enabled: isRecording || canStart,
          action: () => toggleRef.current(),
        })
      );

      if (voiceModes.length > 0) {
        const modeItems = await Promise.all(
          voiceModes.map((mode) =>
            MenuItem.new({
              id: `saybit_tray_mode_${mode.id}`,
              text: mode.hotkey ? `${mode.name}（${displayHotkey(mode.hotkey)}）` : mode.name,
              enabled: isRecording || canStart,
              action: () => toggleRef.current(mode),
            })
          )
        );
        items.push(
          await Submenu.new({
            text: tr('trayRecordWithMode'),
            enabled: isRecording || canStart,
            items: modeItems,
          })
        );
      }

      items.push(await PredefinedMenuItem.new({ item: 'Separator' }));
      items.push(await MenuItem.new({ id: 'show_settings', text: tr('traySettings') }));
      items.push(await PredefinedMenuItem.new({ item: 'Separator' }));
      items.push(await MenuItem.new({ id: 'quit', text: tr('trayQuit') }));

      if (cancelled) return;
      const menu = await Menu.new({ items });
      if (cancelled) return;
      await tray.setMenu(menu).catch(() => {});
    })().catch((e) => console.warn('[Saybit] 系統匣選單更新失敗:', e));

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, tr, isRecording, canStart, hotkey, modesKey]);
}
