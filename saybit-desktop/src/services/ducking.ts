// 錄音時降低系統輸出音量（對應原生版 SystemAudioDucker）。
// 實際調音量在 Rust（src-tauri/src/audio_duck.rs）；原音量先寫磁碟再降，
// App 當掉也能在下次啟動時由 restorePendingVolumeIfNeeded() 還原。
// 平台不支援或命令還沒註冊時一律靜默忽略 —— ducking 只是體驗加分，不能擋錄音。

import { invoke } from '@tauri-apps/api/core';

export const DUCK_RATIO = 0.2;
/// 錄音開始後延遲多久才降音量（讓開始提示音不被一起壓掉）
export const DUCK_DELAY_MS = 200;

let ducked = false;

function warn(cmd: string, e: unknown) {
  console.warn(`[Saybit] ${cmd} 失敗（忽略）:`, e);
}

export async function duckSystemVolume(ratio = DUCK_RATIO): Promise<void> {
  try {
    await invoke('duck_system_volume', { ratio });
    ducked = true;
  } catch (e) {
    warn('duck_system_volume', e);
  }
}

/// 沒降過就不呼叫（避免每次 reset 都打一次 Rust）；force 用在不確定狀態時。
export async function restoreSystemVolume(force = false): Promise<void> {
  if (!ducked && !force) return;
  ducked = false;
  try {
    await invoke('restore_system_volume');
  } catch (e) {
    warn('restore_system_volume', e);
  }
}

export async function restorePendingVolumeIfNeeded(): Promise<void> {
  try {
    await invoke('restore_pending_volume_if_needed');
  } catch (e) {
    warn('restore_pending_volume_if_needed', e);
  }
}
