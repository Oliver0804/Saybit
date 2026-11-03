# 程式碼審查報告（2026-11-03）

## 概要
- 審查範圍：原生 macOS App（`speakertpyer/`）、iOS App（`SaybitiOS/`、`SaybitKeyboard/`、`SaybitShared/`）、共用程式碼、`Config/`、`scripts/`、測試。`saybit-desktop/` 不在範圍。
- 審查類型：深度審查 + 安全審查（OWASP Top 10 2021 逐項對照）
- 方法：五位審查員分區逐檔讀完（音訊/Pipeline、LLM/儲存/安全、macOS 殼層/注入/快捷鍵、設定 UI、iOS/鍵盤），所有 Critical/High 由主審再對照原始碼確認。
- 基準 commit：`2a69571`

## 問題統計
| 等級 | 數量 |
|------|------|
| Critical | 1 |
| High | 15 |
| Medium | 47 |
| Low | 25 |

成功標準對照（審查當下）：Critical 須為 0 → 未達；OWASP 命中 A02/A03/A04/A05/A06/A08/A09 → 未達。

## 修正狀態（同日）
- **已修**：C1；H1–H15 全部；M1–M31、M33–M47（M32 只做了「自動語言偵測只在 Whisper 顯示」）；L1–L25 全部（L3 為有限度：短指令才判 needsSelection；L25 子項全部）。
- **未修／需產品決定**：M32 介面語言與辨識語言拆開；L3 的「改以口述輸入」按鈕（`TextRefiner.lastUnhandledTranscript` 已留好，UI 未接）；M41 的徹底解法（鍵盤待命時停 engine）；M45 的 background URLSession。
- **行為變更**（使用者可見）：處理中再按快捷鍵會被忽略（以前會錯誤地開新錄音）；`saybit://` 第一次遇到的來源會詢問（Shortcuts / Raycast / Alfred / Stream Deck 預設允許，可在「快捷鍵 → 語音模式」管理）；自動學習字典預設改為關閉；前景 App 在處理期間切走時改為預覽不自動注入；終端機或用了螢幕上下文時不會智慧送出；日誌檔與匯出不再含口述內容。
- **驗證**：macOS / iOS Debug、macOS Release 建置通過；單元測試 60 個全數通過（`xcodebuild test -only-testing:speakertpyerTests`，測試 target 已補 sherpa header 搜尋路徑）；純邏輯另有三組獨立 harness（SilenceDetector / SherpaInputRing 9 項、E 批次 33 項、B 批次 62 項）全過。**未做**實機錄音 / 注入 / URL 來源詢問 / iOS 實機的端到端測試。

---

## Critical

### C1. 處理中再按快捷鍵會啟動新錄音，舊結果覆寫並貼進新錄音；舊 STT 永久孤兒
- 位置：`speakertpyer/Core/Pipeline/VoicePipeline.swift` `startRecording()`（約 189-264）、`toggleRecording()`（約 327-334）、LLM/Whisper/Sherpa 收尾 Task（約 462-512、601-655）、`observeTranscript()`（約 541-577）
- 問題：`startRecording()` 只處理 `.listening/.confirming/.previewing`，在 `.processing/.done` 直接 `session.reset()` 進 `.recording`。在飛的 LLM Task 沒有取消也不回頭檢查 state：`onPartial` 持續覆寫 `processedText`，完成後 `performInject()` 把**上一段**文字貼進前景 App，接著 `.done → autoReset → .idle`，但新錄音的 `speechRecognizer/whisperClient/sherpaEngine` 仍是 consumer 且 `stopRecordingAndProcess()` 因 state 非 `.recording` 永遠不再停它們（Sherpa 持續 decode 燒 CPU）。`observeTranscript` 被取消時還會 `SystemAudioDucker.restore()`，新錄音音量先彈回再壓低。
- 修法：(1) `startRecording()` 在 `.recording/.processing` 直接 return（或 `.processing` 時取消目前處理）；(2) 收尾 Task 存成 `processingTask`，加 `sessionGeneration` 遞增計數，所有 `await` 之後與 `onPartial` 內比對 generation 不符即 return；`startRecording/cancelRecording` 時取消；(3) ducking restore 搬到真正離開 recording 的轉換點。

---

## High

### H1. `SharedAudioEngine.consumersLock` 只有 `allocate` 沒有 `initialize`
- 位置：`SharedAudioEngine.swift:27`、`init`（約 66-70）
- 問題：`os_unfair_lock` 跑在未初始化記憶體上；殘值非零時 render thread 永久等待或 `os_unfair_lock is corrupt` crash。`PreBufferRing.swift:35` 有正確寫法。
- 修法：`init` 內 `consumersLock.initialize(to: os_unfair_lock())`；建議兩處共用一個 `UnfairLock` 包裝。

### H2. Apple Speech task 自己停掉（isFinal / error），pipeline 不知情；舊 task 的取消回呼可殺掉新 session
- 位置：`SpeechRecognizer.swift:89-119`
- 問題：callback 內 `_ = self.stopListening()` 移除 consumer，但 `session.state` 仍 `.recording`，使用者繼續講都白講。`stopListening()` 的 `cancel()` 會再觸發一次 error 回呼，沒有 `sessionID` 守衛（`BackgroundSTTEngine.swift:38/218` 有）。
- 修法：加 `onSessionEnded` callback 讓 pipeline 決定 stop/error；加 `sessionID` 守衛；見 M5 改 async 等 final。

### H3. 錄音中切換 STT 引擎 / 關閉持續 STT，停止時用「新設定」的引擎去停
- 位置：`VoicePipeline.swift` `cancelRecording`（約 343-347）、`stopRecordingAndProcess`（約 402-424）、`enableSilenceAutoStop`（約 382-392）、`$sttEngine` sink（約 112-127）
- 問題：Sherpa 錄音中切到 Apple → 停止時呼叫 `speechRecognizer.stopListening()` 回空字串，`sherpaEngine` 永遠是 consumer、模型常駐、持續 decode。關閉持續 STT 同理整段內容丟失。
- 修法：`startRecording()` 把實際啟動的引擎快照成 `activeSTTBackend`，stop/cancel/silence 都只看它；設定 sink 在 `.recording` 中先 `cancelRecording()` 或延後套用。

### H4. Core Data 載入失敗直接刪 store 重建，歷史/字典/技能靜默消失且不重新播種
- 位置：`Storage/Persistence.swift:98-111`、`124-143`、`158-177`
- 問題：任何載入錯誤（含磁碟滿、暫時 I/O 錯）都 `removeItem`；只刪 `.sqlite` 留 `-wal/-shm`；`hasSeeded*_v1` 旗標已 true 所以預設字典不會回來；只有一個模型版本，未來 schema 變更就是清庫。
- 修法：移除自動刪檔；失敗時搬到 `…/Saybit/corrupt-<date>/` 備份並 `AppLogger.error` + UI 告知；真要重建用 `destroyPersistentStore(at:ofType:options:)`；重建後清三個 seed 旗標。

### H5. `saybit://` 無任何來源驗證即可錄音、注入、Smart Send 按 Enter
- 位置：`App/AppDelegate.swift:63-111`、`Config/Saybit-macOS-Info.plist`
- 問題：任何本機程序（含沙盒 App、`shortcuts://`、瀏覽器）`open saybit://start` + 播 TTS + `saybit://stop` → Saybit 用自己的輔助使用權限在前景 App 打字並送出。`application(_:open:)` 還會幫呼叫者把焦點還給前一個 App。
- 修法：用 Apple Event 的 `keySenderPIDAttr` 取得送出者 bundle ID；首次遇到的來源以 NSAlert 詢問「允許／拒絕（記住）」存成允許清單（Shortcuts、Raycast 等常用 launcher 可預設允許）；同一指令 1 秒內重複丟棄並 log；新增設定「允許其他 App 透過 URL 控制 Saybit」。

### H6. 注入與 Smart Send Enter 不比對前景 App，LLM 回來時使用者已切走就打進錯的 App
- 位置：`VoicePipeline.swift` `performInject`（約 753-756）、Smart Send 送 Enter（約 843-845）；`TextInjector.swift:21-48`
- 問題：錄音開始時已有 `session.appContext.bundleIdentifier`，注入前從未比對。這是先前 Discord 誤送出事故的根因。
- 修法：`startRecording` 記下前景 pid；`performInject` 與送 Enter 前比對 `NSWorkspace.shared.frontmostApplication?.processIdentifier`，不一致 → 改進 `.previewing`（或 activate 原 App 後等 150ms），Smart Send 直接取消。

### H7. 主快捷鍵長按的 auto-repeat keyDown 漏到前景 App（hold 模式必現）
- 位置：`Core/HotKey/GlobalHotKeyManager.swift:180-224`
- 問題：第一個 keyDown 設 `isHotkeyDown = true` 後 `return nil`，但後續 repeat keyDown 因 `!isHotkeyDown` 不成立一路落到 `passUnretained`。extraBindings 有抑制（約 170 行），主快捷鍵沒有。
- 修法：`if type == .keyDown && keyCode == registeredKeyCode && isHotkeyDown { return nil }` 或檢查 `.keyboardEventAutorepeat`。

### H8. 語音模式快捷鍵錄製沒有逾時、離開不取消，全系統鍵盤被吃掉
- 位置：`GlobalHotKeyManager.swift:120-155`、`UI/Settings/VoiceModesSection.swift:132-169`
- 問題：錄製期間無修飾鍵的 keyDown、所有 keyUp/flagsChanged 都 `return nil`；`VoiceModesSection` 沒倒數、沒 `onDisappear` 取消；Esc 取消不通知 UI；callback 捕捉 stale Binding。
- 修法：manager 內建 `startRecording(timeout: 10, completion:)` 自動 `cancelRecording()` + `onRecordingCancelled` callback；`VoiceModesSection` 加倒數顯示與 `.onDisappear` 取消；callback 用 `m.id` 查 index 寫入。

### H9. 「讀取螢幕內容」文案宣稱「不上傳」，但 OCR 文字隨 prompt 送到雲端 LLM，且無任何 App 排除
- 位置：`Core/Accessibility/ScreenContextCapture.swift:5-7、27-49`、`Config/Saybit-macOS-Info.plist` `NSScreenCaptureUsageDescription`、`L10n.swift` `screenContextDesc`
- 問題：截圖不上傳，但辨識出的 2000 字進 `LLMPayload.screen_context` → OpenRouter 等。只排除 Saybit 自己；1Password、Keychain Access、Terminal、網銀不排除；密碼欄位不排除。
- 修法：三處文案改為「截圖在本機 OCR，辨識出的文字會和語音一起送給所選 AI 服務（Apple 本機模型除外）」；加 bundle ID 黑名單（`com.1password.*`、`com.apple.keychainaccess`、`com.apple.Terminal`、`com.googlecode.iterm2`、遠端桌面類）；焦點元素 subrole 為 `AXSecureTextField` 時跳過。

### H10. 自動學習字典會把「事實修改」學成「錯字更正」，之後每次聽寫被字面替換，且預設開啟
- 位置：`Core/Accessibility/DictionaryAutoLearner.swift:81-115`、`DictionaryHints.swift:51-69`、`SettingsStore.swift`（`enableAutoLearnDictionary` 預設 true）
- 問題：「我們三點見」改成「我們四點見」→ 「三→四」→ CJK 擴展成「們三→們四」→ 寫入字典；之後所有含「們三」的轉錄被靜默改掉。「給小王→給小李」同理。只播一聲音效，無可見提示、無撤銷。
- 修法：新舊任一含數字（阿拉伯／零一二三…十百千萬／點號月日）直接不學；拉丁字要求 edit distance ≤ 1；學習時膠囊顯示「已學習 X→Y（撤銷）」3 秒；預設改關閉或首次詢問。

### H11. Apple 本機 LLM 在 API 設定頁落入 Ollama 分支：無法測試連線，Ollama 有開時會改掉 selectedModel
- 位置：`UI/Settings/APISettingsView.swift:92、165、285-334、654-678`
- 問題：分支 `requiresAPIKey → lmstudio → else(Ollama)`；`apple-on-device` 落入 else，`checkOllamaStatus()` 在 Ollama 回應時覆寫 `selectedModel`。
- 修法：Ollama 分支改明確 `id == "ollama"`；Apple 單獨分支顯示可用性＋測試連線，不呼叫 `checkOllamaStatus`。

### H12. 檔案轉錄「停止」無效；換檔/切分頁時舊任務把段落混進新檔
- 位置：`UI/Transcribe/FileTranscriptionView.swift:191-219`、`UI/Settings/SettingsView.swift`（switch 建構子 view）
- 問題：`Task.detached` 不繼承取消，`job?.cancel()` 到不了 `transcribe()` 的 `checkCancellation`；切分頁 view 銷毀但任務繼續跑；再拖檔案就有兩個 recognizer 同時往同一個 `segments` append。
- 修法：改結構化併發（直接 `try await` 或 `withThrowingTaskGroup`）；`SherpaFileTranscriber.transcribe` 進入點與 `drain()` 加 `checkCancellation`，`onSegment` 前檢查 `Task.isCancelled`；轉錄狀態搬到 `@Observable final class FileTranscriptionModel` 由 `SettingsView` 持有。

### H13. iOS：鍵盤冷啟動 URL 無條件開啟背景麥克風待命，且任何 App 都能觸發
- 位置：`SaybitiOS/App/SaybitiOSApp.swift:58-73`、`SaybitiOS/Pipeline/MobileVoicePipeline.swift:90-97`
- 問題：`handleKeyboardLaunch()` 丟掉 `takeCommand` 結果，無條件 `keyboardSession.activate(minutes:)` + `startRecording(source: .keyboard, selectedText: bridge.storedSelectedText)`。任意 App 開 `saybit://dictate?source=keyboard` 即可；與 Onboarding「不會背景偷錄」矛盾，也有 App Review 2.5.4 風險。
- 修法：先驗證最近幾秒內確實有一筆 `.start` 指令（`KeyboardBridge.send` 寫 `commandAt`），沒有就當一般 `dictate`、不 activate 待命；`storedSelectedText` 消費後 `removeObject`。

### H14. iOS：處理中按取消 → 狀態被改成「AI 沒有回應」，且 LLM 請求仍在背景跑完
- 位置：`MobileVoicePipeline.swift:293-308、359-364`、`Core/LLM/TextRefiner.swift:206-219`、`OpenRouterClient.swift:89-90`
- 問題：取消後串流 `next()` 回 nil，`accumulated` 為空 → `emptyResponse` → `fail()` 把剛 reset 的 session 改成 `.error`。`sendStreaming` 沒 `onTermination`，HTTP 不中止。macOS `VoicePipeline` 共用 `TextRefiner`，同病。
- 修法：`TextRefiner.refine` 串流 loop 後 `try Task.checkCancellation()`；`runRefine` 所有 `fail` 前 `guard !Task.isCancelled`；`classifyIntentWithTimeout` 取消時 rethrow 而非 fallback；見 M13。

### H15. iOS：Whisper 轉錄中按取消被當失敗
- 位置：`MobileVoicePipeline.swift:251-268`
- 問題：`URLSession` 取消拋 `URLError(.cancelled)` 不是 `CancellationError`，catch-all `fail(...)`。
- 修法：成功/失敗分支先 `guard !Task.isCancelled`；或判斷 `URLError.cancelled` 直接 return（Sherpa 分支已有範例）。

---

## Medium

### 音訊 / Pipeline（macOS）
- **M1** `SharedAudioEngine.addConsumer` 先 append 再 snapshot/replay → 即時 buffer 與回放交錯、重複，且 render 與 main 同時 append 同一陣列（`SharedAudioEngine.swift:298-316`）。修：先 snapshot 回放完再上鎖 append。
- **M2** render thread 讀取 main thread 同時替換的非原子 reference/Array：`BackgroundSTTEngine.swift:174 vs 207/244`（每 50 秒 rollSession）、`SpeechRecognizer.swift:127 vs 112`、`WhisperSTTClient.swift:69 vs 40/57`。修：request 用鎖包裝，或 render 只丟到自家 serial queue（Sherpa 模式）。
- **M3** `SilenceDetector` 無任何同步但註解宣稱 thread-safe；Sherpa 從 main 與 render 同時 `update`（`SilenceDetector.swift:11-81`、`SherpaSTTEngine.swift:58-60/122`）。修：加 `os_unfair_lock`；修正三處註解。
- **M4** `retryLastAction()` 不取消 `autoResetTask`，`returnToIdle()` 無條件打回 `.idle`；`startListening()` 不先 cleanup 導致舊 monitor 永久留在 consumers（`VoicePipeline.swift:668-680、881-896、146-166`）。
- **M5** `SpeechRecognizer.stopListening()` 在 `endAudio()` 後立刻 `cancel()`，以 partial 當最終結果，最後一兩個字遺失（`SpeechRecognizer.swift:110-119`、`BackgroundSTTEngine.swift:136-166`）。修：改 async 等 `isFinal`（0.8–1s timeout）。
- **M6** 聆聽模式下前置檢查失敗（無 key / 模型未下載）或噪音觸發空轉錄 → `returnToIdle → startListening → startRecording → error` 無限循環（`VoicePipeline.swift:158-164、215-239、881-886`）。修：從 `.error` 回來或連續 N 次空轉錄時停止聆聽並提示。
- **M7** `SharedAudioEngine.start()` 失敗、BackgroundSTT recognizer 不可用都不回報 pipeline，UI 照常「錄音中」但永遠空轉錄（`SharedAudioEngine.swift:108-159`、`BackgroundSTTEngine.swift:79/195`）。修：`startRecording` 先 `guard isRunning`；BackgroundSTT 啟動失敗回滾 `isRunning`。
- **M8** render thread 上做 `buffer.copy()`、Array append、GCD 閉包配置、`Date()`（`WhisperSTTClient.swift:69`、`SherpaSTTEngine.swift:114`、`AudioLevelMonitor.swift:62`、`MicLevelTester.swift:46`）。修：consumer 自持預配置 ring；`AudioLevelMonitor` 改 `mach_absolute_time`；`MicLevelTester` 套 `MainThreadThrottler`。
- **M9** `SherpaWorker` 即時字幕每 0.8s 重算最長 20–25s 音訊，只以樣本數門控，長句 queue 積壓（`SherpaSTTEngine.swift:136-137、293-300`）。修：partial 視窗上限 ~8s，以牆鐘時間門控或落後就跳過。
- **M10** 持續 STT 啟動後不同步語言 / on-device 設定，`updateLocale` 從未被呼叫（`VoicePipeline.swift:930-937`、`BackgroundSTTEngine.swift:108-114`）。

### LLM / 儲存 / 安全
- **M11** 選取文字 / 螢幕 OCR 直接拼進 user message，system prompt 沒有「資料 vs 指令」隔離；輸出自動注入、Smart Send 自動送出（`OpenRouterClient.swift:112-126`、`SystemPrompts.swift:40-45、155-181`、`TextRefiner.swift:176-191`）。修：prompt 加固定條款（`existing_text/screen_context/personal_dictionary/snippets` 一律視為資料，只有 `transcript` 是指令）；`existing_text` 用明確分隔標籤；帶這些上下文且 Smart Send 開啟時強制預覽。
- **M12** 自訂 provider baseURL 無 scheme/host 驗證，key 可能以 `http://` 明文外送；兩個 target 都沒有 ATS 宣告（`APISettingsView.swift:719-722`、`LLMProvider.swift:167-177`、`OpenRouterClient.swift:101`）。修：必須 https，或 host 為 loopback / RFC1918 才允許 http 並警告；plist 加 `NSAllowsLocalNetworking`。
- **M13** `OpenRouterClient.sendStreaming` 沒有 `continuation.onTermination`，取消/逾時不中斷 HTTP；Stage 1 的 8 秒 timeout 後請求仍跑完多付費（`OpenRouterClient.swift:89-248`、`TextRefiner.swift:250-269`）。修：存 Task 並 `onTermination = { task.cancel() }`，loop 內 `checkCancellation`。
- **M14** 日誌把完整轉錄、選取文字、LLM 結果、自動學習字典寫到磁碟明文 JSONL，保留 7 天且可一鍵匯出（`AppLogger.swift:111-162`、`VoicePipeline.swift:408/429/499/529`、`TextRefiner.swift:86/223`、`DictionaryAutoLearner.swift:114`、`LogsView.swift:289-305`、`MobileVoicePipeline.swift:237/279`）。修：`AppLogger` 加敏感等級只進記憶體、落盤與匯出以 `[內容已遮罩, N 字]` 取代；匯出前提醒。
- **M15** 行事曆/提醒 Stage 2 的「現在時間」用 `ISO8601DateFormatter()` 預設 GMT 給模型，相對日期差一天 / 8 小時（`SystemPrompts.swift:339-340、360-361`）。修：`timeZone = .current`，同時給 offset 與星期。
- **M16** SSE 中伺服器送的 `{"error":…}` 被當空 chunk 吞掉；非 2xx 不讀 body；custom provider 不送 `stream_options` 導致 token 永遠 0（`OpenRouterClient.swift:187-232`、`LLMPayload.swift:105-122`）。修：`OpenRouterStreamChunk` 加 `error` 欄位即 `finish(throwing:)`；非 2xx 讀 body 前 4KB 進錯誤訊息。
- **M17** `scripts/fetch-sherpa-onnx.sh` 下載會連進出貨二進位的靜態庫，無 checksum；iOS 來源是 HF 可變分支 `resolve/main`。修：寫死 SHA-256 `shasum -a 256 -c`；HF 改 commit hash；解壓後拒絕 `../` 與絕對路徑。

### macOS 殼層 / 注入 / 快捷鍵
- **M18** `TextExtractor` 在 AX 成功但 `selectedText == ""` 時仍走 AppleScript/CGEvent ⌘C fallback，每次錄音都對前景 App 送 ⌘C：VS Code 複製整行、Finder 複製檔案、1Password 複製密碼進 `selectedText` 送雲端（`TextExtractor.swift:36-39、77、102-138`）。修：AX 回三態 `.text/.emptySelection/.unsupported`，只有 `.unsupported` 才 fallback；fallback 前檢查 role；bundle ID 黑名單。
- **M19** 貼上後固定 0.5s 還原剪貼簿，慢 App 貼到舊內容（`TextInjector.swift:61-69`）。修：輪詢焦點元素值已含注入文字才還原（最多 2s）；優先 `AXSelectedText` 直接寫入。
- **M20** 注入文字未標 `org.nspasteboard.TransientType`，剪貼簿管理器永久記錄每句聽寫，還原又多一筆（`TextInjector.swift:57-58`、`ClipboardBackup.swift:29-41`）。
- **M21** 逐字輸入模式：`"\n"` 以 unicode string 送出被 Chromium 當 Enter 中途送出；N 個 `asyncAfter` 無法取消，切 App 後剩餘字打進新 App；`virtualKey: 0` 讓依 `event.code` 的網頁看到連續 A（`TextInjector.swift:76-97`）。修：換行送 virtualKey 0x24（聊天類加 Shift）；改單一可取消 Task，每字前比對前景 pid；每 event 塞多字加速。
- **M22** `DictionaryAutoLearner` 在主執行緒同步讀整份文件內容，每 2 秒一次持續 30 秒，切走 App 也不停（`DictionaryAutoLearner.swift:15、45-51、129-133`）。修：AX 讀取移到背景；`kAXNumberOfCharactersAttribute` 超過 ~20k 放棄；`AXUIElementSetMessagingTimeout`；前景 pid 不符即停。
- **M23** 輔助使用尚未授權時 event tap 建立失敗後不重試；權限撤銷無提示（`AppDelegate.swift:38-39、252-263`、`GlobalHotKeyManager.swift:71-86`）。修：失敗時輪詢 `AXIsProcessTrusted()` 自動 register；膠囊顯示錯誤。
- **M24** 設定／關於視窗把 activation policy 改成 `.regular` 後永不還原，Saybit 永久出現在 Dock 與 ⌘Tab（`OverlayWindow.swift:476、498`）。修：`willCloseNotification` 無其他可見視窗時改回 `.accessory`。
- **M25** AppIntents 無確認即可啟動/停止錄音；`StartDictationIntent` 自行複製 auto-stop 只對 Apple Speech 生效（`SpeakerTyperShortcuts.swift:47-100`）。修：改呼叫 `voicePipeline.toggleRecording(mode:)`；加 `requestConfirmation` 或共用 H5 的允許開關。
- **M26** 在終端機類 App 貼上多行文字 / Smart Send 會直接執行指令（`TextInjector.swift:33-71`、`AppContext.swift:34-36` 已有 `terminal` 識別）。修：`contextIdentifier == "terminal"` 時去尾端換行、強制預覽、停用 Smart Send。

### 設定 UI（macOS）
- **M27** 按「儲存」時 API Key 為空仍寫入空字串並標「已設定」（`APISettingsView.swift:111-119、145、653-662`、`KeychainHelper.swift:20-21、53-68`）。修：空則 disabled；`saveAPIKey("")` 改 delete；`loadAPIKey` 空 Data 回 nil。
- **M28** 日誌累積到 500 筆後 `onChange(of: entries.count)` 不再觸發，自動捲動永久失效（`LogsView.swift:213-219`、`AppLogger.swift:54/116`）。修：改監聽 `entries.last?.id`。
- **M29** CSV 匯出未防公式注入（`HistoryView.swift:442-466`）。修：欄位以 `=+-@\t\r` 開頭前置 `'`。
- **M30** `List(…, id: \.objectID, selection: $selectedRecord)` id 型別與 selection 型別不一致，點列可能不更新（`HistoryView.swift:23、70`）。修：列加 `.tag(record)` 或 selection 改 `NSManagedObjectID?`。
- **M31** `filteredRecords` 為 computed，每列 `.onAppear` 重算整份過濾；FetchRequest 無 `fetchBatchSize`（`HistoryView.swift:17-42、100-106`）。修：改 `@State` 快取；設 batch size。
- **M32** `languagePreference` 同時是介面語言與辨識語言；「自動語言偵測」只對 Whisper 有效卻對所有引擎顯示並鎖死介面語言選單（`GeneralSettingsView.swift:378-391`、`L10n.swift:13-15`、`VoicePipeline.swift:287/299/466`）。修：拆 `uiLanguage` / `speechLanguage`（遷移時以舊值初始化）；偵測開關只在 Whisper 時顯示。**（需產品決定，本輪不修）**
- **M33** 一般設定頁每次回到前景都在主執行緒同步執行 AppleScript，首次會跳出「自動化」授權對話框（`GeneralSettingsView.swift:71-81、565-585`）。修：Automation 狀態只在使用者按「請求授權」時執行；其餘用 `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)`。
- **M34** 教學頁 Provider 分段選單只有 3 個 tag，其他 provider 使用者看到錯誤連結並把 key 存到錯的地方（`TutorialView.swift:258-300`）。修：用 `allProviders.filter(\.requiresAPIKey)` 動態產生；key portal URL 抽到 `LLMProvider`。
- **M35** `ContextRulesView` 以索引捕捉 Binding 再 `remove(at:)`，刪除時 Binding 失效/越界（`ContextRulesView.swift:58-67`）。修：`ForEach($settingsStore.contextRules)`。
- **M36** 用紅色關閉鈕關掉 Onboarding / Tutorial 視窗會跳過收尾（hotkey 未註冊、權限未請求、Dock 圖示留著、micTester 可能持續開著）（`AppDelegate.swift:35-39、157-231`）。修：設 `NSWindowDelegate`，`windowWillClose` 走同一份收尾。
- **M37** 多個完整功能區塊硬編碼繁中，四語切換後仍顯示中文：`SettingsView.swift:46`（檔案轉錄）、`GeneralSettingsView` SherpaModelPanel、`FileTranscriptionView` 整頁、`VoiceModesSection` 整卡、`DictionarySettingsView:87-128`、`APISettingsView:168/181/282/351/354`、`HistoryView:51/65/312/420-435`、`StatisticsView` Chart `.value("日期"…)`。修：新增 `L10n.Transcribe / VoiceModes / Sherpa` 區塊。

### iOS / 鍵盤
- **M38** 鍵盤重新出現時把 ≤120 秒前的舊結果自動插進「當下任何 App 的任何輸入框」；`source` 在鍵盤錄音後不重置，App 內「重新生成」也會 publish（`KeyboardModel.swift:70-71、110-112、185-191`、`KeyboardBridge.swift:149-155`）。修：自動插入只在本鍵盤實例於 `.launching/.recording/.processing` 期間收到結果時；否則顯示「插入剛才的結果」按鈕；`regenerate/retry` 時 `source` 若鍵盤 session 不在則重設 `.app`。
- **M39** 「復原」在目前游標位置盲刪 N 字，不驗證上下文；沒覆寫 `selectionDidChange`（`KeyboardModel.swift:194-199`、`KeyboardViewController.swift:62-65`）。修：游標移動即清 `.inserted`；`undoInsert` 前檢查 `documentContextBeforeInput?.hasSuffix(text)`。
- **M40** 轉錄內容、選取文字、結果以明文長駐 App Group plist（可備份、永不清除、錄音中每 ~170ms 落盤）（`KeyboardBridge.swift:122-166`、`MobileVoicePipeline.swift:217-219`）。修：消費後 `removeObject` result/partial/selectedText；cancel/finishEmpty/dismiss 也清；partial 降頻或不落盤。
- **M41** 待命期間 `.playAndRecord + .allowBluetoothHFP` 長時間活躍且無 `.allowBluetoothA2DP`，AirPods 音樂降為通話音質、橘點常駐（`SharedAudioEngine.swift:214-229` iOS 區段、`KeyboardSessionController.swift:33-54`）。修：至少加 `.allowBluetoothA2DP`；理想是待命時停 engine、收到指令再 start。
- **M42** 長錄音記憶體無上限（Sherpa `samples`、Whisper `audioBuffers`）；App 進背景時若正在錄音會持續錄到停止為止（`SherpaSTTEngine.swift:263`、`WhisperSTTClient.swift:68-71`、`MobileVoicePipeline.swift:487-489`）。修：錄音最長時間（如 5 分）自動停止；非鍵盤來源進背景即停止；Sherpa 丟掉已 commit 樣本；Whisper 即時轉 16k Int16。
- **M43** 鍵盤待命期間 SenseVoice 模型（~250MB）常駐背景不釋放（`MobileVoicePipeline.swift:491-496`）。修：模型卸載獨立於 engine，非 active 時錄完就 `unloadModel()`。
- **M44** 行事曆/提醒的確認文字會被當成鍵盤結果插進宿主 App；`confirmPendingAction` 的 Task 不受 `processingTask` 管（`MobileVoicePipeline.swift:377-398、441-453`）。修：動作完成改 `bridge.publish(state: .idle)`；Task 存入 `processingTask` 並檢查 `pendingAction` 仍相同。
- **M45** 離線模型「取消下載」顯示成失敗（`URLError.cancelled` 不是 `CancellationError`），取消後立刻再下載，舊 Task 的 `defer` 清掉新的 `downloadTask`；非 background session（`SherpaModelManager.swift:79、107-120`）。修：catch 判斷 `Task.isCancelled || URLError.cancelled`；`defer` 只在仍指向自己時清。
- **M46** iOS target 無 `NSAppTransportSecurity`/`NSLocalNetworkUsageDescription`，設定頁卻建議填 `http://192.168…` 的 LM Studio（`SaybitiOS/Info.plist`、`SettingsRootView.swift:242-252`）。修：加 `NSAllowsLocalNetworking` 與本地網路說明。
- **M47** Keychain 未設 `kSecAttrAccessible`（預設 WhenUnlocked），iOS 背景處理期間鎖機會得到誤導的「未設定 API Key」（`KeychainHelper.swift:37-43`）。修：`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 並遷移既有項目。

---

## Low
- **L1** `ModelPricing` 用 `contains("o1")` 子字串比對誤配 `sao10k/...` 等模型；Claude Opus 4.x 價格疑似過時（`ModelPricing.swift:39-81`）。修：去掉 `provider/` 前綴後 `hasPrefix` 或邊界 regex。
- **L2** `UpdateChecker.compareSemver` 忽略 pre-release 後綴，beta 使用者收不到同號正式版；測試 `compareIgnoresPreReleaseSuffix` 把 bug 當規格（`UpdateChecker.swift:111-129`）。
- **L3** Stage 1 回非 dictation 但 `content == nil` → `.needsSelection`，整段口述被吞（`TextRefiner.swift:139-154`）。修：保留 transcript 並提供「改以口述輸入」。
- **L4** `SettingsStore.shared` 為 Optional 全域、`OverlayWindow` 的 `?? SettingsStore()` 會產生第二個實例；`voiceModes` didSet 無 debounce；滑桿/位置拖曳中每 tick 寫 UserDefaults（`SettingsStore.swift:15、330-336`、`OverlayWindow.swift:115、453`）。
- **L5** Core Data `try? save()` 多處吞錯且不 rollback；seeding 用 `print`；`cleanupLegacySkills` fetch 失敗仍標完成（`Persistence.swift:141-250`、`HistoryView.swift:280`、`DictionarySettingsView.swift:120/227/269/281`）。
- **L6** `SherpaModelManager` 同 M45（macOS 側）。
- **L7** Smart Send 倒數 `Int(smartSendDelay)` 截斷，滑桿卻允許 0.5 步進（`VoicePipeline.swift:792`）。
- **L8** `processWithLLM` 無限期等待螢幕 OCR / 上下文擷取，無 timeout（`VoicePipeline.swift:523-524、586`）。
- **L9** onboarding 未完成時 URL scheme / 膠囊 / 選單列 / 捷徑仍可錄音（`AppDelegate.swift:25、35-40`）。
- **L10** URL 重新 activate 的 `lastExternalApp` 可能是 launcher（Raycast/Alfred）而非目標 App（`AppDelegate.swift:45-50、70-76`）。
- **L11** `AppContext.contextIdentifier` 子字串比對過寬：`"xcode".contains("code")` 永遠判成 vscode；`arc`/`mail` 誤傷（`AppContext.swift:24-26、51、59、76`）。
- **L12** 主快捷鍵改成與語音模式相同時不檢查，模式綁定先吃掉主快捷鍵（`GlobalHotKeyManager.swift:162-169`、`HotKeySettingsView.swift:191-199`）。
- **L13** `ScreenContextCapture` 在非主執行緒讀 `NSWorkspace/NSScreen`；用 `NSScreen.main` 的 scale 而非視窗所在螢幕（`ScreenContextCapture.swift:29、40`）。
- **L14** `ClipboardBackup` 對 promised/lazy 型別同步 materialize（`ClipboardBackup.swift:17-25`）。
- **L15** 搜尋「沒有結果」關鍵字清單與卡片不一致，會同時顯示卡片與「找不到」（`APISettingsView.swift:41/428/485/506 vs 527-539`、`HotKeySettingsView.swift:119 vs 155-159`）。
- **L16** `ContextRulesView` 空清單顯示「找不到符合的設定」（`ContextRulesView.swift:52-55`）。
- **L17** L10n 內容錯誤：473 行中文價格 `$300` 應為 `NT$`；23/474/484 行日文「1 分以下」誤譯；640 行硬寫「2 秒靜音」（`L10n.swift`）。
- **L18** `TutorialView` 快捷鍵倒數用遞迴 `asyncAfter`（`TutorialView.swift:460-470`）。
- **L19** 語音模式快捷鍵與主快捷鍵相同時只寫日誌，UI 無回饋（`VoiceModesSection.swift:151-154`）。
- **L20** body 內讀 Keychain，麥克風測試時高頻重複查詢（`GeneralSettingsView.swift:663-673`、`TutorialView.swift:307`、`OnboardingView.swift:409`）。
- **L21** 輸入裝置 Picker 綁的 UID 已拔除時顯示空白（`GeneralSettingsView.swift:92-97`、`TutorialView.swift:359-364`）。
- **L22** 統計「全部」圖表只畫 365 天但彙總含全部；nil timestamp 處理不一致（`StatisticsView.swift:331-333 vs 51-120`）。
- **L23** 設定頁權限卡沒有「語音辨識」項（`GeneralSettingsView.swift:468-514`）。
- **L24** 純圖示按鈕缺 `.help`/`.accessibilityLabel`，含破壞性的「移除自訂端點」（多處）。
- **L25** iOS：鍵盤待命啟動失敗無提示且殘留 `sessionExpiresAt`；來電中斷不通知 pipeline、`.ended` 不看 `shouldResume`；路由改變後 Whisper 以舊格式打包 WAV；responder chain `openURL` hack；SenseVoice 載入失敗只在停止時才發現；鍵盤按鍵音永不播放（缺 `UIInputViewAudioFeedback`）；診斷記錄含內容片段且納入備份。

---

## OWASP Top 10（2021）對照
| 項目 | 結果 | 對應 |
|---|---|---|
| A01 Broken Access Control | 有 | H5（URL scheme 無來源驗證）、M25（AppIntents 無確認）、H13（iOS URL 開背景待命） |
| A02 Cryptographic Failures | 有 | M12（http 明文送 key）、M14（日誌明文落地）、M40（App Group 明文）、M47（Keychain accessible） |
| A03 Injection | 有 | M11（prompt injection）、M29（CSV 公式）、M26（終端機貼上即執行） |
| A04 Insecure Design | 有 | H4（刪庫重建）、H6（注入不比對目標）、H10（自動學習誤學）、M18（⌘C 副作用） |
| A05 Security Misconfiguration | 有 | M12/M46（無 ATS 宣告）、H9（權限文案與實際不符） |
| A06 Vulnerable & Outdated Components | 有 | M17（預編譯庫無校驗）、L1（價格表過時） |
| A07 Identification & Auth Failures | 無明顯問題 | key 只以 Bearer 送到使用者設定端點；日誌/錯誤/匯出均未含 key |
| A08 Software & Data Integrity Failures | 有 | M17（供應鏈）；UpdateChecker 只開瀏覽器不自動執行 ✓ |
| A09 Security Logging & Monitoring Failures | 有 | M14（過度記錄敏感內容） |
| A10 SSRF | 無問題 | baseURL 由同一使用者控制、純 client 端 |

## 測試覆蓋評估
- 已覆蓋：純函式層（`modelsEndpoint`、`TranscriptionSession.reset`、SSE chunk 解碼 happy path、semver、HotKey 衝突、`ModelPricingTable` 基本命中、LM Studio URL 正規化）。
- 未覆蓋（本次多數 bug 所在）：`TextRefiner.refine` 分流、`DictionaryHints.apply`、`OpenRouterClient` 整條 SSE（`[DONE]`、error chunk、取消、重試）、`DictionaryAutoLearner.learn`、`Persistence` 載入失敗路徑、`VoicePipeline` 狀態機重入。
- 缺基礎設施：無 `URLProtocol` mock；`PersistenceController(inMemory:)` 存在卻無 Core Data 測試。
- 建議優先補：SSE 全流程含 error chunk 與 cancel；`SystemPrompts.forIntent` 時區；`ModelPricingTable.price(for: "sao10k/...")` 為 nil；`Persistence` 載入失敗不得刪資料；`DictionaryAutoLearner.learn` 對「三→四」不得學；`VoicePipeline` 在 `.processing` 時 `toggleRecording` 不得啟動新錄音。

## 正面回饋
- Sherpa 執行緒紀律乾淨：所有 sherpa-onnx 物件只在 `SherpaWorker` serial queue 存取；`PreBufferRing` 預配置 + `os_unfair_lock` + 時間計回放，註解把踩過的坑寫清楚。
- `BackgroundSTTEngine.sessionID` 守衛、Smart Send 送 Enter 前兩段重新驗證 `.confirming`、`SystemAudioDucker` 先寫 UserDefaults 再降音量的崩潰安全，都是正確的防禦設計。
- API key 全程 Keychain、UI 用 `SecureField`，所有 log/print 只印 provider id，沒有一處外洩 key；鍵盤擴充讀不到 key（未設 access group）是正確隔離；Darwin notification payload 一律從 App Group 讀且以 `commandID` 去重，外部偽造無法觸發錄音。
- 行事曆/提醒的危險動作閘門正確：Stage 1 只看 transcript，`.action` 必須使用者確認、超時自動取消。
- `RecordsRepository` 用 background context 寫、`@MainActor` 讀，Core Data 執行緒紀律正確；`ClipboardBackup` 完整保留所有型別；`GlobalHotKeyManager` 正確處理 tap 被系統停用後重啟。
- 共用設定元件（`SettingRow/SettingToggle/SettingSlider`）與 `GeneralSettingsView.Keys` 讓卡片顯示與搜尋共用同一份關鍵字，是其他頁應效法的寫法；`StatisticsView.cachedRecords` 的快取與註解到位。
- L10n 416 個 `d()` 呼叫四語槽位全數一致。

## 總體建議
1. 先修 C1 + H1–H8（狀態機重入、鎖初始化、注入目標比對、URL 來源驗證、快捷鍵吞鍵）——這些是「正常使用就會踩到」或「會把文字打進錯的地方」的問題。
2. 再修隱私面：H9、M14、M18、M20、M40——Saybit 的核心價值是「在任何 App 裡打字」，使用者對它看得到什麼、留下什麼的信任必須對得上文案。
3. 建立 `URLProtocol` mock 與狀態機測試，把本次 Critical/High 各寫成一個回歸測試再合併。
4. M32（介面語言與辨識語言拆開）、H5 的允許清單 UX、H10 的預設值需要產品決定。
