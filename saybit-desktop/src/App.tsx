import { useState, useEffect } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { invoke } from '@tauri-apps/api/core';
import { useVoicePipeline } from './hooks/useVoicePipeline';
import { OverlayView } from './views/OverlayView';
import { SettingsView } from './views/SettingsView';
import { initDefaultData } from './services/db';

function App() {
  const [windowLabel, setWindowLabel] = useState<string>('');
  const pipeline = useVoicePipeline();

  useEffect(() => {
    // 1. 初始化資料庫預設資料
    initDefaultData().catch(console.error);

    // 2. 獲取並設定目前視窗 Label
    try {
      const currentWindow = getCurrentWindow();
      setWindowLabel(currentWindow.label);

      // 3. 呼叫 Rust 後端為此視窗套用 Acrylic 磨砂玻璃效果
      invoke('apply_vibrancy', { label: currentWindow.label })
        .catch((e) => console.log('磨砂玻璃效果套用失敗或在此平台不支援：', e));
    } catch (e) {
      console.error('無法獲取視窗標籤：', e);
      setWindowLabel('main');
    }
  }, []);

  if (!windowLabel) {
    return (
      <div className="flex items-center justify-center w-screen h-screen bg-slate-950 text-white/50 text-xs">
        正在加載 Saybit 服務...
      </div>
    );
  }

  // 根據視窗 Label 渲染對應 View
  return windowLabel === 'overlay' ? (
    <OverlayView pipeline={pipeline} />
  ) : (
    <SettingsView pipeline={pipeline} />
  );
}

export default App;
