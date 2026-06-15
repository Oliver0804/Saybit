# 實作計畫：Whisper STT + 注入前預覽確認

## 需求摘要

1. **Whisper API STT**：新增 OpenAI Whisper API 作為語音辨識引擎選項，保留原有 Apple Speech framework，使用者可在設定中選擇
2. **注入前預覽確認**：LLM 處理完成後，先在 overlay 顯示結果讓使用者確認，可選擇注入、重新生成或取消。使用者可在設定中開關此功能

---

## 功能一：Whisper API STT

### 設計思路

- 新增 `STTEngine` enum（`appleSpeech` / `whisperAPI`）
- 新增 `WhisperSTTClient` actor，錄音後將音檔 POST 到 OpenAI `/v1/audio/transcriptions`
- `VoicePipeline` 根據設定選擇 STT 引擎
- Whisper 模式下：先用 `AVAudioEngine` 錄音存檔（WAV），錄音結束後上傳 API 取得轉錄
- Apple Speech 模式維持現有即時轉錄行為不變

### 需修改/新增的檔案

#### 1. 新增 `Models/STTEngine.swift`
```swift
enum STTEngine: String, CaseIterable {
    case appleSpeech = "apple_speech"
    case whisperAPI = "whisper_api"

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech (本地)"
        case .whisperAPI: return "Whisper API (雲端)"
        }
    }
}
```

#### 2. 新增 `Core/SpeechRecognition/WhisperSTTClient.swift`

- actor-based，與 `OpenRouterClient` 風格一致
- 使用 `AVAudioEngine` 錄音，儲存為 WAV buffer（in-memory）
- 錄音期間同步計算 audioLevel 供 overlay 顯示
- 支援靜音自動停止（複用現有邏輯）
- `stopRecording()` 回傳音訊 Data
- `transcribe(audioData:)` POST 到 Whisper API，回傳轉錄文字
- API endpoint：使用 LLM provider 設定中的 OpenAI key 或 Whisper 專用 key
- Whisper API key 儲存：複用 `KeychainHelper`，key ID 為 `"whisper_api"`

#### 3. 修改 `Storage/SettingsStore.swift`

新增：
- `sttEngine: STTEngine`（預設 `.appleSpeech`）
- `whisperAPIKey` 的 Keychain 存取（不存 UserDefaults）
- `whisperModel: String`（預設 `"whisper-1"`）
- `whisperLanguage: String`（預設 `"zh"`，與 languagePreference 連動）

#### 4. 修改 `Core/Pipeline/VoicePipeline.swift`

- `startRecording()`：根據 `sttEngine` 分流
  - `.appleSpeech`：維持現有 `speechRecognizer.startListening()` 行為
  - `.whisperAPI`：啟動 `WhisperSTTClient` 的錄音，overlay 顯示波形但不顯示即時文字（Whisper 不支援 partial results）
- `stopRecordingAndProcess()`：
  - `.appleSpeech`：維持現有行為
  - `.whisperAPI`：停止錄音 → 取得 audioData → 顯示 `.processing` → 呼叫 `WhisperSTTClient.transcribe()` → 取得 transcript → 繼續 LLM 流程
- 靜音偵測：Whisper 模式下在 `WhisperSTTClient` 的 tap callback 中實作（與現有 SpeechRecognizer 相同邏輯）

#### 5. 修改 `UI/Settings/GeneralSettingsView.swift`

在「功能」GlassCard 之後新增「語音辨識引擎」GlassCard：
- Picker 選擇 STTEngine
- 選擇 `whisperAPI` 時展開：
  - SecureField 輸入 Whisper API Key（存 Keychain）
  - 測試連線按鈕
  - 說明文字：「使用 OpenAI Whisper API 進行語音辨識，辨識準確度更高，但需網路連線且會產生 API 費用」
- 原有 On-Device STT toggle 僅在 Apple Speech 模式下顯示

---

## 功能二：注入前預覽確認

### 設計思路

- 新增設定 `enablePreviewBeforeInject`（預設 `false`，關閉時維持現有直接注入行為）
- 開啟時，LLM streaming 完成後進入新狀態 `.previewing`（取代直接進入 `.done`）
- overlay 在 `.previewing` 狀態顯示完整文字 + 三個操作按鈕
- 使用者確認後才執行 `TextInjector.inject()`

### 需修改/新增的檔案

#### 1. 修改 `Models/TranscriptionSession.swift`

新增狀態：
```swift
case previewing  // LLM 處理完成，等待使用者確認
```

#### 2. 修改 `Storage/SettingsStore.swift`

新增：
- `enablePreviewBeforeInject: Bool`（預設 `false`）

#### 3. 修改 `Core/Pipeline/VoicePipeline.swift`

在 `processWithLLM()` 中：
```swift
// 原本：
session.state = .done
TextInjector.inject(accumulated)

// 改為：
if settingsStore.enablePreviewBeforeInject {
    session.state = .previewing
    // 不注入，等待使用者操作
} else {
    session.state = .done
    TextInjector.inject(accumulated)
    // ...（維持現有邏輯）
}
```

新增方法：
```swift
/// 使用者確認注入
func confirmInject() {
    guard case .previewing = session.state else { return }
    session.state = .done
    TextInjector.inject(session.processedText)
    saveToHistory()
    if settingsStore.enableSoundFeedback {
        NSSound(named: .init("Purr"))?.play()
    }
    if settingsStore.enableSmartSend {
        startSmartSendCountdown()
    } else {
        autoResetState(after: 2.0)
    }
}

/// 使用者取消
func cancelPreview() {
    guard case .previewing = session.state else { return }
    session.state = .idle
}

/// 使用者要求重新生成
func regenerate() {
    guard case .previewing = session.state else { return }
    session.processedText = ""
    session.state = .processing
    Task { @MainActor in
        await processWithLLM()
    }
}
```

注意：開啟預覽模式時，`saveToHistory()` 和音效播放移到 `confirmInject()` 中，避免重複。

#### 4. 修改 `UI/Overlay/OverlayView.swift`

在 `CapsuleBarView` 中新增 `.previewing` 狀態的 UI：

**stateIcon**：
- 藍色眼睛圖示 `eye.fill`

**stateContent**：
- 顯示 `session.processedText` 全文（lineLimit 3）
- 下方 HStack 三個按鈕：
  - 「注入」（綠色，checkmark.circle.fill）→ 呼叫 `pipeline.confirmInject()`
  - 「重新生成」（橘色，arrow.clockwise）→ 呼叫 `pipeline.regenerate()`
  - 「取消」（灰色，xmark.circle）→ 呼叫 `pipeline.cancelPreview()`

**capsule 尺寸**：
- previewing 狀態需較大：寬度 ~420，高度 ~90（容納文字 + 按鈕列）

**border gradient**：
- 使用藍色系 `[.blue.opacity(0.5), .blue.opacity(0.15)]`

**問題**：目前 `CapsuleBarView` 不持有 `VoicePipeline` 引用。

**解法**：透過 closure callback 傳遞操作。在 `OverlayWindowController.configure()` 時同時傳入 pipeline（或三個 closure）。具體做法：
- `CapsuleBarView` 新增 optional closures：`onConfirmInject`, `onRegenerate`, `onCancelPreview`
- `OverlayWindowController` 新增 `var pipeline: VoicePipeline?`，在 configure 時設定
- 建構 CapsuleBarView 時傳入 closure

#### 5. 修改 `UI/Overlay/OverlayWindow.swift`

- `configure()` 新增 `pipeline` 參數
- 建構 `CapsuleBarView` 時傳入三個 closure

#### 6. 修改 `UI/Settings/GeneralSettingsView.swift`

在 Smart Send 的 GlassCard 之前新增「注入前預覽」GlassCard：
- Toggle 開關
- 說明文字：「LLM 處理完成後先顯示預覽，手動確認後再注入文字」

---

## 實作順序

1. `Models/STTEngine.swift` — 新增 enum
2. `Models/TranscriptionSession.swift` — 新增 `.previewing` 狀態
3. `Storage/SettingsStore.swift` — 新增設定項
4. `Core/SpeechRecognition/WhisperSTTClient.swift` — 新增 Whisper 客戶端
5. `Core/Pipeline/VoicePipeline.swift` — 整合兩個功能
6. `UI/Overlay/OverlayView.swift` — 預覽 UI
7. `UI/Overlay/OverlayWindow.swift` — 傳入 pipeline
8. `UI/Settings/GeneralSettingsView.swift` — 設定 UI
9. Build & test

---

## 不變更的部分

- `SpeechRecognizer.swift` — 完全不動，Apple Speech 路徑維持原樣
- `OpenRouterClient.swift` — 不動
- `TextInjector.swift` — 不動
- `AudioLevelMonitor.swift` — 不動
- Core Data models — 不動
- 所有其他 Settings views — 不動
