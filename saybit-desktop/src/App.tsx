import { useState, useEffect, useMemo } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { invoke } from '@tauri-apps/api/core';
import { useVoicePipeline } from './hooks/useVoicePipeline';
import { OverlayView } from './views/OverlayView';
import { SettingsView } from './views/SettingsView';
import { UrlCommandAskDialog } from './views/UrlCommandAskDialog';
import { initDefaultData } from './services/db';
import { makeTranslator } from './services/l10n';
import { useTrayMenu } from './components/trayMenu';

function App() {
  const [windowLabel, setWindowLabel] = useState<string>('');
  const pipeline = useVoicePipeline();
  const { settings } = pipeline;
  const tr = useMemo(() => makeTranslator(settings.appLanguage), [settings.appLanguage]);

  useEffect(() => {
    // 1. 初始化資料庫預設資料
    initDefaultData().catch(console.error);

    // 2. 獲取並設定目前視窗 Label
    try {
      const currentWindow = getCurrentWindow();
      setWindowLabel(currentWindow.label);

      // 3. 呼叫 Rust 後端為此視窗套用 Acrylic 磨砂玻璃效果（overlay 保持完全透明，不套）
      if (currentWindow.label !== 'overlay') {
        invoke('apply_vibrancy', { label: currentWindow.label })
          .catch((e) => console.log('磨砂玻璃效果套用失敗或在此平台不支援：', e));
      }
    } catch (e) {
      console.error('無法獲取視窗標籤：', e);
      setWindowLabel('main');
    }
  }, []);

  // 系統匣選單由 overlay 負責：錄音在 overlay 的 pipeline 跑，選單動作要落在這裡
  useTrayMenu({
    enabled: windowLabel === 'overlay',
    tr,
    isRecording: pipeline.state === 'recording' || pipeline.state === 'listening',
    canStart: settings.hasCompletedOnboarding,
    hotkey: settings.hotkey,
    voiceModes: settings.voiceModes,
    toggle: (mode) => pipeline.toggleRecording(mode),
  });

  if (!windowLabel) {
    return (
      <div className="flex items-center justify-center w-screen h-screen bg-slate-950 text-white/50 text-xs">
        {tr('loading')}
      </div>
    );
  }

  // 根據視窗 Label 渲染對應 View
  return windowLabel === 'overlay' ? (
    <OverlayView pipeline={pipeline} />
  ) : (
    <>
      <SettingsView pipeline={pipeline} />
      <UrlCommandAskDialog update={pipeline.updateSettings} tr={tr} />
    </>
  );
}

export default App;
