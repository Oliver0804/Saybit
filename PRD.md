# Saybit - Product Requirements Document (PRD)

> 本文件完整描述 Saybit 的所有功能需求與工作流程，不涉及特定平台架構實作，供未來跨平台移植參考。

---

## 1. 產品概述

**Saybit** 是一款常駐系統工具列的語音輸入助手，透過全域快捷鍵啟動錄音，將語音經 STT（語音轉文字）辨識後送入 LLM（大型語言模型）精煉處理，最終將結果注入至使用者當前聚焦的應用程式中。

**核心價值：** 在任何應用程式中按下快捷鍵即可語音輸入，AI 自動去除贅詞、修正語法、格式化內容。

---

## 2. 使用者角色

| 角色 | 描述 |
|------|------|
| 一般使用者 | 在即時通訊、郵件、筆記等 App 中使用語音輸入 |
| 開發者 | 在 IDE、終端機中使用語音輸入，需辨識變數名、CLI 指令 |
| 多語系使用者 | 需要跨語言翻譯或混合語言輸入 |

---

## 3. 狀態機

系統以狀態機驅動全局行為，共 8 個狀態：

```
idle ──→ listening ──→ recording ──→ processing ──→ previewing ──→ idle
  ↑                                      │              │
  │                                      ↓              ↓
  │                                    done ──→ confirming(N) ──→ idle
  │                                      │
  └──────────── error ←──────────────────┘
```

### 3.1 狀態定義

| 狀態 | 觸發條件 | 行為描述 | 離開條件 |
|------|---------|---------|---------|
| **idle** | 啟動時 / 任務完成 / 自動重置 | 無動作，等待使用者觸發 | 快捷鍵按下 或 點擊膠囊 |
| **listening** | 使用者點擊膠囊（聆聽模式） | 開啟麥克風監聽，偵測到人聲後自動進入錄音 | 偵測到語音 → recording；使用者取消 → idle |
| **recording** | 快捷鍵觸發 或 聆聽模式偵測到語音 | 持續 STT 辨識、顯示波形、監測靜音 | 使用者手動停止 / 靜音自動停止 → processing |
| **processing** | STT 轉錄完成（非空） | 擷取上下文、意圖分類（Stage 1）、LLM 串流處理（Stage 2） | LLM 完成 → previewing 或 done |
| **previewing** | LLM 結果就緒 且 開啟預覽功能 | 顯示預覽文字與操作按鈕（確認/重新生成/取消） | 使用者確認 → 注入文字；取消 → idle |
| **done** | 文字已注入 或 Smart Send 完成 | 顯示完成訊息、儲存歷史紀錄 | 自動重置 → idle（2 秒）或 回到 listening |
| **confirming(N)** | 文字已注入 且 Smart Send 已啟用 | 倒數計時，同時監聽麥克風偵測語音以取消 | 倒數結束 → 模擬 Enter 送出；偵測到語音 → 取消送出 |
| **error(訊息)** | 任何錯誤情況 | 顯示友善錯誤訊息 | 3 秒後自動重置 → idle |

### 3.2 特殊狀態轉換

- **listening → recording**：聆聽模式下偵測到語音（音量 ≥ 0.15 閾值），自動開始錄音
- **done → listening**：若聆聽模式啟用中，完成後自動回到聆聽狀態
- **error → idle/listening**：錯誤自動重置後，若聆聽模式啟用則回到 listening

---

## 4. 功能需求

### FR-01：全域快捷鍵系統

**描述：** 在任何應用程式中透過全域快捷鍵觸發語音錄音。

**需求：**

1. **快捷鍵註冊**
   - 監聽系統級鍵盤事件（keyDown、keyUp、修飾鍵變更）
   - 快捷鍵必須包含至少一個修飾鍵（Ctrl/Option/Shift/Command）+ 一個按鍵
   - 預設快捷鍵：Option + Space

2. **快捷鍵錄製**
   - 進入錄製模式後，捕捉使用者按下的鍵組合
   - 即時顯示目前按住的修飾鍵
   - Escape 取消錄製
   - 10 秒無操作自動取消

3. **三種觸發模式**

   | 模式 | 操作方式 | 開始錄音 | 停止錄音 |
   |------|---------|---------|---------|
   | **Toggle** | 按一下切換 | 按一下快捷鍵 | 再按一下 或 靜音自動停止 |
   | **Hold** | 按住說話 | 按住快捷鍵 | 放開按鍵 |
   | **DoubleTap** | 雙擊觸發 | 0.3 秒內雙擊 | 再次雙擊 或 靜音自動停止 |

4. **快捷鍵顯示格式**
   - 修飾鍵使用符號：⌃（Ctrl）⌥（Option）⇧（Shift）⌘（Command）
   - 格式：「⌥Space」

---

### FR-02：語音辨識（STT）

**描述：** 將使用者語音即時轉換為文字。

**需求：**

1. **雙引擎支援**

   | 引擎 | 特性 | 部分結果 | 網路需求 | 費用 |
   |------|------|---------|---------|------|
   | **本地語音辨識** | 系統內建 STT | 即時部分結果 | 不需要（可選雲端增強） | 免費 |
   | **Whisper API** | OpenAI 雲端 STT | 無（僅最終結果） | 需要 | 計費 |

2. **本地語音辨識規格**
   - 支援本地端限定模式（`onDeviceOnly`），不傳送音訊至雲端
   - 即時回傳部分辨識結果，UI 即時顯示
   - 語言根據使用者偏好設定自動設定

3. **Whisper API 規格**
   - 錄音期間緩衝 PCM 音訊資料
   - 停止後轉換為 16kHz 單聲道 16-bit PCM WAV 格式
   - 上傳至 Whisper API，回傳完整轉錄
   - 逾時：60 秒
   - 語言代碼映射：`zh-TW` → `zh`、`en-US` → `en`、`ja-JP` → `ja`

4. **麥克風增益**
   - 使用者可調整靈敏度倍率（0.5x ~ 5.0x，預設 2.0x）
   - 影響波形顯示和靜音偵測

---

### FR-03：共享音訊引擎

**描述：** 統一管理音訊輸入裝置，支援多個消費者同時使用音訊串流。

**需求：**

1. **單例音訊引擎**
   - 持續從選定的輸入裝置擷取音訊
   - Buffer 大小：1024 samples
   - 格式：自動匹配裝置原生格式

2. **多消費者模式**
   - 每個消費者有唯一 ID
   - 註冊/取消註冊消費者（執行緒安全）
   - 每個 buffer 回調時分發給所有已註冊消費者
   - 消費者類型：STT 引擎、音量監測器

3. **裝置切換**
   - 支援系統預設裝置或指定裝置（透過 UID）
   - 切換時完整重啟引擎（停止 → 重新啟動）
   - 確保 tap 以正確格式重新安裝

---

### FR-04：靜音偵測與自動停止

**描述：** 偵測使用者停止說話後自動結束錄音。

**需求：**

1. **音量閾值**
   - 靜音閾值：0.08（低於此視為靜音）
   - 語音閾值：0.15（高於此視為說話中）

2. **兩種逾時模式**

   | 情境 | 條件 | 逾時時間 |
   |------|------|---------|
   | 語後靜音 | 已偵測到語音，之後持續低於靜音閾值 | 使用者設定（預設 2.0 秒，範圍 0.5~5.0 秒） |
   | 無語音 | 開始錄音後從未偵測到語音 | 固定 3.0 秒 |

3. **逾時觸發**
   - 僅觸發一次（防重複）
   - 觸發後調用停止錄音並開始處理

4. **可關閉**
   - 使用者可關閉自動停止功能（手動模式）

---

### FR-05：上下文感知

**描述：** 自動擷取使用者當前操作的應用程式資訊和選取文字，作為 LLM 上下文。

**需求：**

1. **應用程式上下文**
   - 取得前景應用程式名稱和 Bundle ID
   - 映射為語境識別碼（用於 LLM 語調判斷）：

   | 應用程式 | 識別碼 | 語調傾向 |
   |---------|--------|---------|
   | Slack, Discord, LINE, iMessage | slack, discord, line, imessage | 口語 |
   | Mail, Gmail, Outlook | gmail, outlook | 正式 |
   | Cursor, VSCode, Xcode, Terminal | cursor, vscode, xcode, terminal | 技術 |
   | Google Docs, Notes, Obsidian | google-docs, notes, obsidian | 中性 |
   | 其他 | 應用程式名小寫 | 自動判斷 |

2. **選取文字擷取（雙策略）**

   **策略 1：輔助使用 API（快速路徑）**
   - 透過 Accessibility API 取得聚焦元素的選取文字
   - 速度：< 50ms
   - 無副作用
   - 適用：原生應用程式

   **策略 2：剪貼簿回退（可靠路徑）**
   - 策略 1 失敗時使用
   - 步驟：
     1. 儲存原始剪貼簿內容
     2. 模擬 Cmd+C（先嘗試腳本方式，失敗則用按鍵模擬）
     3. 輪詢剪貼簿變化（每 50ms 檢查，最多 600ms）
     4. 擷取複製的文字
     5. 還原原始剪貼簿內容
   - 速度：50~600ms
   - 適用：Electron 應用、瀏覽器等

3. **非阻塞擷取**
   - 上下文擷取在背景非同步執行
   - 不阻塞錄音開始
   - LLM 處理開始前等待擷取完成

---

### FR-06：兩階段意圖分類系統

**描述：** 無選取文字時，先分類使用者意圖，再執行對應處理。

**需求：**

1. **Stage 1：意圖分類**

   **觸發條件：** STT 轉錄完成 且 無選取文字

   **輸入：** 使用者語音轉錄文字 + 可用語音技能列表

   **輸出（JSON）：**
   ```json
   {
     "intent": "dictation|translate|rewrite|compose|skill|create_event|create_reminder",
     "language": "en|ja|zh-TW",
     "style": "formal|casual|concise",
     "format": "email|letter|list",
     "skill_name": "觸發詞",
     "content": "擷取出的內容"
   }
   ```

   **意圖類型：**

   | 意圖 | 觸發線索 | 額外欄位 | 範例 |
   |------|---------|---------|------|
   | **dictation** | 預設（無特殊指令） | 無 | 「今天天氣真好」 |
   | **translate** | 翻譯成X語、translate to | language | 「翻譯成日文 今天天氣很好」 |
   | **rewrite** | 改成正式/口語、make formal | style | 「改成正式語氣 這個不行」 |
   | **compose** | 寫封信、寫個 email | format | 「寫封信給老闆請假」 |
   | **skill** | 匹配已設定的語音技能觸發詞 | skill_name | 「摘要 這篇文章很長...」 |
   | **create_event** | 排/安排/預約/開會、schedule | content | 「幫我排明天下午3點開會」 |
   | **create_reminder** | 提醒/記得/別忘了、remind me | content | 「提醒我明天早上9點吃藥」 |

   **關鍵判斷規則：**
   - 「改寫成英文」→ translate（語言變更），不是 rewrite
   - 「幫我寫一個 APP」→ dictation（轉錄指令本身），不是 compose
   - 轉錄中包含指令+內容時，需分離出 content 欄位

   **逾時處理：**
   - 逾時時間：8 秒
   - 逾時回退：dictation（安全預設值）
   - JSON 解析失敗：回退至 dictation

   **LLM 參數：** temperature = 0.1（確定性分類）

2. **Stage 2：執行**

   根據 Stage 1 的意圖結果選擇不同的系統 Prompt：

   | 意圖 | Stage 2 行為 |
   |------|-------------|
   | dictation | 使用基礎風格 Prompt（Typeless 或 WisprFlow） |
   | translate | 使用翻譯專用 Prompt（目標語言） |
   | rewrite | 使用改寫專用 Prompt（目標風格） |
   | compose | 使用撰寫專用 Prompt（文件格式） |
   | skill | 使用對應技能的自訂 Prompt |
   | create_event | 使用事件建立 Prompt → 解析 JSON → 建立行事曆 |
   | create_reminder | 使用提醒建立 Prompt → 解析 JSON → 建立備忘錄 |

3. **有選取文字時的處理**
   - 跳過 Stage 1，直接進入 Stage 2
   - 使用基礎風格 Prompt
   - 語音轉錄作為「指令」，選取文字作為「被操作內容」
   - 範例：選取「你好世界」→ 說「翻譯成日文」→ 輸出「こんにちは世界」

---

### FR-07：LLM 處理

**描述：** 將 STT 轉錄文字經 LLM 精煉後輸出高品質文字。

**需求：**

1. **Prompt 風格**

   | 風格 | Temperature | 特性 |
   |------|------------|------|
   | **Typeless（智慧模式）** | 0.3 | 意圖理解、自動格式化清單、去贅詞/改口修正 |
   | **WisprFlow（工程師模式）** | 0.2 | 以上全部 + 變數命名辨識、CLI 指令解析、技術詞彙修正 |

2. **核心 LLM 處理規則**

   **a. 去贅詞**
   - 英文：um, uh, like, you know, I mean, so, well...
   - 中文：嗯、啊、那個、就是、然後、對、所以說...

   **b. 重複移除**
   - 保留最完整的版本
   - 範例：「我想...對，早上九點開會」→ 「早上九點開會」

   **c. 自我糾正 vs 否定澄清（關鍵規則）**

   | 類型 | 模式 | 處理方式 | 範例 |
   |------|------|---------|------|
   | 自我糾正 | [錯誤值] + 糾正標記 + [正確值] | 僅保留正確值 | 「456，不對，是123」→「123」 |
   | 否定澄清 | [正確值] + 「不是」+ [被否定的值] | 全部保留 | 「我的電話是123，不是456」→ 原文保留 |
   | 否定指令 | [指令] + 不要/別 | 全部保留 | 「約兩點開會不要改成四點」→ 原文保留 |

   **d. 自動標點**
   - 根據語意自動加入句號、逗號、問號
   - 中文使用全形標點（，。！？、：；）

   **e. 自動格式化**
   - 偵測清單意圖（序數詞、「第一」「然後」）→ 自動格式化為列表
   - 偵測標題意圖 → 加入標題格式
   - 偵測段落轉換 → 自動換行

   **f. 語調適配（結合上下文）**
   - 聊天（Slack, Discord）→ 口語、簡短
   - 郵件（Gmail）→ 正式、專業
   - 文件（Google Docs）→ 正式
   - 筆記（Notes）→ 簡潔

   **g. 語言處理**
   - 自動偵測主要語言
   - zh-TW 設定時**永遠輸出繁體中文**，絕不簡體
   - 混合語言：保留英文術語

   **h. 個人字典整合**
   - 套用使用者偏好拼寫/格式

   **i. 編輯模式（有選取文字）**
   - 判斷語音轉錄是「指令」還是「新內容」
   - 指令範例：「翻譯成日文」→ 轉換選取文字
   - 新內容：直接替換選取文字

   **j. WisprFlow 額外功能**
   - 變數名辨識：「camel case user name」→ `userName`
   - CLI 指令解析：「npm install dash dash save dev typescript」→ `npm install --save-dev typescript`
   - 技術詞彙修正：Kubernetes, PostgreSQL, React 等
   - Whisper Mode：更積極的噪音過濾

3. **LLM Payload**

   發送至 LLM 的有效載荷：

   | 欄位 | 說明 | 範例 |
   |------|------|------|
   | transcript | STT 原始轉錄 | 「翻譯成日文 今天天氣很好」 |
   | context | 應用程式語境識別碼 | "slack" |
   | mode | 處理模式 | "edit"（有選取文字時） |
   | tone | 語調偏好 | "formal" / null（auto） |
   | language_preference | 使用者語言 | "zh-TW" |
   | personal_dictionary | 個人字典 | {"openai": "OpenAI"} |
   | whisper_mode | 噪音過濾模式 | true / null |
   | existing_text | 選取的文字 | "你好世界" |

4. **串流回應**
   - LLM 以 SSE（Server-Sent Events）格式串流回應
   - 每個 chunk 即時更新 UI 顯示
   - 格式：`data: <json>` 每行
   - 結束標記：`data: [DONE]`
   - 回應包含：文字 chunk + token 使用量

5. **進階參數（可選）**
   - 使用者可選擇啟用自訂 LLM 參數：

   | 參數 | 範圍 | 預設值 | 說明 |
   |------|------|--------|------|
   | max_tokens | 256~16384 | 4096 | 最大回應 token 數 |
   | frequency_penalty | -2.0~2.0 | 0.0 | 降低重複詞頻率 |
   | presence_penalty | -2.0~2.0 | 0.0 | 鼓勵新主題 |
   | top_p | 0.0~1.0 | 1.0 | 核心取樣機率 |

   - 關閉時使用服務商預設值（不發送這些欄位）

---

### FR-08：LLM 服務商管理

**描述：** 支援多個 LLM API 服務商，含內建與自訂端點。

**需求：**

1. **內建服務商**

   | 服務商 | API 端點 | 需要 API Key | 推薦模型 |
   |--------|---------|-------------|---------|
   | OpenRouter | openrouter.ai/api/v1/chat/completions | 是 | openai/gpt-4.1-nano, anthropic/claude-sonnet-4 |
   | OpenAI | api.openai.com/v1/chat/completions | 是 | gpt-4.1-nano, gpt-4o |
   | DeepSeek | api.deepseek.com/chat/completions | 是 | deepseek-chat, deepseek-reasoner |
   | Groq | api.groq.com/openai/v1/chat/completions | 是 | llama-3.3-70b-versatile |
   | Together AI | api.together.xyz/v1/chat/completions | 是 | meta-llama/Llama-3.3-70B-Instruct-Turbo |
   | Ollama（本地） | localhost:11434/v1/chat/completions | 否 | 動態探測本地模型 |

2. **自訂服務商**
   - 使用者可新增自訂端點（名稱 + Base URL）
   - 每個自訂服務商有獨立 API Key 儲存
   - 可刪除自訂服務商（同時移除 API Key）

3. **Ollama 特殊功能**
   - 自動偵測 Ollama 是否執行中（GET /api/tags，逾時 2 秒）
   - 取得可用模型列表（GET /api/tags，逾時 3 秒）
   - 顯示模型按鈕列表供快速選擇
   - 若目前模型不在列表中，自動選擇第一個

4. **API Key 管理**
   - 每個服務商獨立儲存 API Key（系統安全儲存）
   - 支援：儲存、顯示/隱藏、清除、測試連線
   - 測試連線：發送最小請求（"Hi"）驗證 Key 有效性，逾時 10 秒

5. **模型自動切換**
   - 切換服務商時自動調整模型名稱格式：
     - OpenRouter：`org/model`（如 `openai/gpt-4.1-nano`）
     - OpenAI：純名稱（如 `gpt-4.1-nano`）
     - DeepSeek：`deepseek-chat`
     - Groq：`llama-3.3-70b-versatile`
     - Together AI：`meta-llama/Llama-3.3-70B-Instruct-Turbo`

6. **重試機制**
   - 最大重試次數：3
   - 指數退避：1s → 2s → 4s + 隨機抖動（0~0.5s）
   - 可重試狀態碼：429, 500, 502, 503, 504
   - 不可重試：立即失敗（如 401, 402）

---

### FR-09：文字注入

**描述：** 將 LLM 處理結果注入至使用者當前聚焦的應用程式。

**需求：**

1. **注入流程**
   1. 儲存目前剪貼簿內容
   2. 清空剪貼簿
   3. 設定新內容（LLM 處理結果）
   4. 記錄剪貼簿變更計數
   5. 等待 50ms（剪貼簿同步）
   6. 模擬 Cmd+V（貼上）
   7. 等待 200ms（貼上完成）
   8. 檢查剪貼簿是否被其他應用修改
   9. 若未修改，還原先前內容

2. **Enter 鍵模擬（Smart Send）**
   - 模擬按下 Return 鍵（無修飾鍵）
   - 用於自動送出訊息

---

### FR-10：預覽功能

**描述：** LLM 處理完成後先顯示預覽，等待使用者確認後再注入。

**需求：**

1. **預覽模式（可開關，預設關閉）**
   - 狀態：previewing
   - 顯示處理後文字
   - 三個操作按鈕：
     - ✓ 確認：注入文字
     - ↻ 重新生成：重新送入 LLM 處理
     - ✕ 取消：放棄，回到 idle

2. **自動確認（聽寫意圖）**
   - 聽寫模式下 3 秒無操作自動確認注入
   - 使用者操作任一按鈕取消自動確認

3. **自動取消（動作意圖）**
   - 行事曆/備忘錄意圖下 3 秒無操作自動取消
   - 防止意外建立事件

---

### FR-11：Smart Send（智慧送出）

**描述：** 文字注入後自動倒數，時間到自動按下 Enter 送出。

**需求：**

1. **倒數機制**
   - 可開關（預設關閉）
   - 倒數時間：使用者設定（1~10 秒，預設 3 秒）
   - 每秒更新狀態顯示剩餘秒數

2. **語音取消**
   - 倒數期間同時監聽麥克風
   - 偵測到語音（音量 ≥ 0.15）→ 取消倒數
   - 寬限期：0.8 秒（避免完成音效觸發誤判）

3. **手動取消**
   - 倒數期間再按一次快捷鍵 → 取消倒數

4. **倒數完成**
   - 等待 100ms
   - 模擬 Enter 鍵
   - 播放送出音效
   - 自動重置（1 秒）

---

### FR-12：行事曆與備忘錄整合

**描述：** 透過語音指令建立行事曆事件和備忘錄提醒。

**需求：**

1. **行事曆事件建立**

   **LLM 回應格式：**
   ```json
   {
     "title": "會議名稱",
     "date": "2026-01-29T15:00:00+08:00",
     "duration_minutes": 60,
     "location": "會議室",
     "notes": "備註",
     "confirmation_text": "已建立: 1/29 15:00-16:00 會議"
   }
   ```

   **建立流程：**
   - 解析 ISO 8601 日期（含時區）
   - 計算結束時間（開始 + duration）
   - duration 預設 60 分鐘
   - 建立至系統預設行事曆
   - 注入確認文字

2. **備忘錄提醒建立**

   **LLM 回應格式：**
   ```json
   {
     "title": "買牛奶",
     "due_date": "2026-01-29T09:00:00+08:00",
     "notes": "備註",
     "confirmation_text": "已建立提醒: 明天 09:00"
   }
   ```

   **建立流程：**
   - 解析 ISO 8601 日期（可為 null）
   - 若有到期日，設定提醒鬧鐘
   - 建立至系統預設備忘錄
   - 注入確認文字

3. **權限要求**
   - 首次使用時請求行事曆/備忘錄存取權限
   - 權限被拒絕時顯示友善錯誤訊息

---

### FR-13：個人字典

**描述：** 使用者自訂詞彙對照表，LLM 自動替換。

**需求：**

1. **字典項目**
   - 每筆包含：原始詞 → 偏好寫法
   - 範例：「openai」→「OpenAI」、「chatgpt」→「ChatGPT」

2. **預設字典（首次啟動時填入）**
   - openai → OpenAI
   - chatgpt → ChatGPT
   - github → GitHub
   - iphone → iPhone
   - macbook → MacBook
   - wifi → Wi-Fi
   - youtube → YouTube
   - line → LINE

3. **管理操作**
   - 新增（原始詞 + 偏好寫法，均非空）
   - 刪除
   - 按原始詞排序顯示

4. **LLM 整合**
   - 每次 LLM 呼叫時傳入字典作為 `personal_dictionary`
   - LLM 在處理時自動替換

---

### FR-14：語音技能（Snippets）

**描述：** 使用者設定觸發詞，說出時載入對應的自訂 Prompt 引導 LLM 處理。

**需求：**

1. **技能項目**
   - 每筆包含：觸發詞 + Prompt 指令內容
   - 觸發詞在意圖分類 Stage 1 時比對

2. **預設技能（首次啟動時填入）**

   | 觸發詞 | Prompt 指令 |
   |--------|-----------|
   | 摘要 | 壓縮至原文 1/3 長度，以重點條列呈現 |
   | 條列 | 以 `-` 前綴整理為條列式 |
   | 代辦 | 轉換為 `- [ ]` Markdown 待辦項目 |
   | 修潤 | 修正錯字、改善流暢度、保留原意 |
   | 寫信 | 正式商業書信格式，含問候語與結尾敬語 |

3. **觸發流程**
   - Stage 1 識別 intent = "skill" + skill_name
   - Stage 2 將對應 Prompt 作為系統 Prompt
   - LLM 以該 Prompt 處理使用者語音內容

4. **管理操作**
   - 新增（觸發詞 + Prompt 內容，均非空）
   - 刪除
   - 按觸發詞排序顯示

---

### FR-15：歷史紀錄

**描述：** 自動儲存每次語音輸入的完整紀錄。

**需求：**

1. **紀錄欄位**

   | 欄位 | 說明 |
   |------|------|
   | id | 唯一識別碼 |
   | rawTranscript | STT 原始轉錄 |
   | processedText | LLM 處理後文字 |
   | appContext | 使用時的應用程式名稱 |
   | mode | 處理模式（dictation/command/edit） |
   | timestamp | 建立時間 |
   | duration | 錄音時長（秒） |
   | modelName | 使用的 LLM 模型名稱 |
   | promptTokens | 輸入 token 數 |
   | completionTokens | 輸出 token 數 |
   | totalTokens | 總 token 數 |

2. **瀏覽介面**
   - 左右分割面板
   - 左側：紀錄列表（按時間倒序，分頁載入每次 50 筆）
   - 右側：選取紀錄的詳細資訊（原始轉錄、處理後文字、元資料）
   - 支援複製處理結果、複製原始轉錄

3. **清理功能**
   - 刪除 7 天前的紀錄
   - 刪除 30 天前的紀錄
   - 清除全部紀錄（需二次確認）
   - 自動清理：可設定保留天數（7~90 天），啟動時自動刪除過期紀錄

---

### FR-16：統計資訊

**描述：** 視覺化呈現語音輸入使用統計。

**需求：**

1. **時間範圍篩選**
   - 7 天 / 30 天 / 全部

2. **摘要卡片（4 個）**

   | 指標 | 圖示 | 顏色 |
   |------|------|------|
   | 總使用次數 | 數字圖示 | 藍色 |
   | 總 Token 消耗 | 幣值圖示 | 橘色 |
   | 平均錄音時長 | 計時器圖示 | 綠色 |
   | 今日使用次數 | 日曆圖示 | 紫色 |

3. **圖表**
   - **每日使用次數**：長條圖（X=日期，Y=次數），高度 160pt
   - **Token 消耗趨勢**：面積折線圖（X=日期，Y=token），高度 140pt，catmullRom 平滑
   - **模式分佈**：甜甜圈圖（dictation/command/edit/other）

4. **常用 App 排行**
   - Top 5 應用程式
   - 顯示名稱 + 使用次數 + 比例條

---

### FR-17：聆聽模式

**描述：** 點擊膠囊進入持續聆聽，偵測到語音自動開始錄音。

**需求：**

1. **進入方式**
   - 點擊膠囊（idle 狀態下）
   - 狀態變為 listening

2. **語音偵測**
   - 開啟音量監測器
   - 偵測到語音（音量 ≥ 0.15）→ 自動開始錄音
   - 啟用靜音自動停止

3. **自動循環**
   - 錄音完成回到 idle 後，若聆聽模式仍啟用，自動重新進入 listening
   - 手動取消才結束循環

4. **取消方式**
   - 再次點擊膠囊（listening 狀態下）
   - 回到 idle

---

### FR-18：音效回饋

**描述：** 狀態轉換時播放系統音效提供聽覺回饋。

**需求：**

1. **可開關**（預設開啟）

2. **音效對照**

   | 事件 | 音效 |
   |------|------|
   | 開始錄音 | 輕點音（Tink） |
   | 停止錄音 | 彈出音（Pop） |
   | 開始聆聽 | 莫爾斯音（Morse） |
   | 注入成功 | 嗡鳴音（Purr） |
   | Smart Send 送出 | 潛艇音（Submarine） |
   | Smart Send 取消 | 低音（Basso） |
   | 錯誤 | （無特定，依狀態顯示） |

---

### FR-19：多語系支援

**描述：** 應用程式 UI 支援四種語言即時切換。

**需求：**

1. **支援語言**

   | 語言 | 代碼 | 預設 |
   |------|------|------|
   | 繁體中文 | zh-TW | ✓ |
   | 簡體中文 | zh-CN | |
   | 英文 | en | |
   | 日文 | ja | |

2. **切換機制**
   - 在設定中選擇語言
   - 即時刷新所有 UI 文字（不需重啟）
   - 所有 UI 字串透過集中式本地化模組管理

3. **LLM 語言偏好**
   - 語言設定同時影響 LLM 處理
   - zh-TW 設定時 LLM 永遠輸出繁體中文

---

### FR-20：新手導引

**描述：** 首次使用時引導使用者完成設定。

**需求：**

1. **導引流程（4 步驟）**

   | 步驟 | 內容 |
   |------|------|
   | 0. 語言選擇 | 選擇 UI 語言 |
   | 1. 權限設定 | 請求麥克風、語音辨識、輔助使用權限 |
   | 2. API Key | 選擇服務商、輸入 API Key、價格說明 |
   | 3. 測試連線 | 驗證 API Key 可用性 |

2. **權限狀態**
   - 每個權限顯示綠色（已授權）或紅色（未授權）
   - 提供「開啟系統設定」按鈕
   - 「重新檢查」按鈕

3. **教學流程（8 頁）**

   | 頁面 | 內容 |
   |------|------|
   | 0 | 快捷鍵設定與觸發模式選擇 |
   | 1 | API 費用說明與 Key 設定 |
   | 2 | 麥克風設定與靈敏度調整 |
   | 3 | 功能總覽（模式、智慧功能） |
   | 4~7 | 實際操作練習（聽寫/翻譯/建立事件/建立提醒） |

4. **練習環節**
   - 每個練習提供：腳本提示、輸入框、操作提示
   - 使用者可在教學視窗中直接練習
   - 預設文字供翻譯練習使用

---

### FR-21：浮動膠囊 UI

**描述：** 常駐螢幕頂部的浮動膠囊視窗，即時顯示系統狀態。

**需求：**

1. **視窗特性**
   - 浮動於所有視窗之上
   - 不搶奪焦點（不影響使用者正在操作的應用程式）
   - 無邊框、透明背景
   - 可拖動重新定位
   - 預設位置：螢幕頂部置中
   - 記憶自訂位置

2. **外觀**
   - 膠囊形狀（圓角矩形/膠囊）
   - 半透明毛玻璃材質背景
   - 內側發光（顏色隨狀態變化：橘/紅/青/藍/綠）
   - 漸層邊框（1.5pt）
   - 陰影

3. **各狀態視覺**

   | 狀態 | 圖示 | 顏色 | 寬度 | 動畫 |
   |------|------|------|------|------|
   | idle | 麥克風 | 白色 | 120px | 無 |
   | listening | 麥克風✕ | 橘色 | 200px | 1.3x 脈動 |
   | recording | 紅色圓點 | 紅色 | 200~240px | 1.4x 脈動 |
   | processing | 轉圈圖示 | 橘色 | 160px | 旋轉 |
   | done | 勾選 | 綠色 | 依文字長度 | 無 |
   | previewing | 眼睛 | 藍色 | 340px | 無 |
   | confirming(N) | 倒數數字 | 青色 | 依文字長度 | 呼吸脈動 |
   | error | 驚嘆號 | 紅色 | 260px | 無 |

4. **波形顯示**
   - 20 根垂直線條
   - 高度根據音量變化（最小 2px，最大 20px）
   - 白色 85% 透明度
   - 每 100ms 更新

5. **互動**
   - 點擊膠囊：根據狀態觸發不同動作（idle→聆聽、recording→停止等）
   - 短按（位移 < 5px 且時間 < 0.3s）視為點擊
   - 拖動：重新定位膠囊

6. **右鍵選單**
   - Prompt 風格（子選單）
   - 語調（子選單）
   - 分隔線
   - Whisper Mode（勾選切換）
   - Context Awareness（勾選切換）
   - 音效回饋（勾選切換）
   - Smart Send（勾選切換）
   - 分隔線
   - 重置位置
   - 設定...（快捷鍵 Cmd+,）
   - 關於
   - 分隔線
   - 結束（快捷鍵 Cmd+Q）

7. **縮放**
   - 使用者可調整膠囊縮放比例（0.5x ~ 2.0x，預設 1.0x）

---

### FR-22：設定視窗

**描述：** 分頁式設定介面，管理所有應用程式設定。

**需求：**

| 分頁 | 內容摘要 |
|------|---------|
| **一般** | 開機啟動、語言、功能開關、STT 引擎、膠囊大小、輸入裝置、靜音偵測、預覽/送出、歷史清理、權限狀態、教學 |
| **AI 引擎** | 服務商選擇、API Key、模型、進階參數、Prompt 風格、語調 |
| **快捷鍵** | 快捷鍵設定、觸發模式、使用說明 |
| **字典/技能** | 個人字典管理、語音技能管理 |
| **歷史** | 歷史紀錄瀏覽、詳情、清理 |
| **統計** | 使用統計圖表、指標 |

- 支援設定搜尋（輸入關鍵字過濾區塊）
- 玻璃卡片 UI 風格
- 設定即時生效（不需手動儲存）

---

### FR-23：系統匣選單

**描述：** 系統工具列的下拉選單，提供快速操作。

**需求：**

- 顯示項目：
  - 目前 Prompt 風格（可切換）
  - 目前語調（可切換）
  - Whisper Mode 開關
  - 重新註冊快捷鍵
  - API Key 設定狀態
  - 輔助使用授權狀態
  - 設定...
  - 結束

---

## 5. 錯誤處理

**所有錯誤統一顯示於膠囊，3 秒後自動消失。**

| 錯誤情境 | 使用者看到的訊息 |
|---------|----------------|
| 未設定 API Key | 「未設定 {服務商} API Key，請在設定中輸入」 |
| 未設定 Whisper Key | 「未設定 Whisper API Key，請在設定中輸入」 |
| API Key 無效 (401) | 「API Key 無效」 |
| 餘額不足 (402) | 「API 餘額不足」 |
| 請求過頻 (429) | 「API 請求過於頻繁，請稍後再試」 |
| 伺服器錯誤 (5xx) | 「伺服器暫時不可用」 |
| 網路錯誤 | 「網路連線失敗」 |
| 解碼錯誤 | 「回應解析失敗」 |
| 重試耗盡 | 「重試 N 次後仍失敗 (HTTP xxx)」 |
| LLM 空回應 | 「LLM 未回傳任何文字」 |
| 意圖無內容 | 「請先選取要{動作}的文字」 |
| 權限未授權 | 「{類型}權限未授權」 |
| 動作建立失敗 | 「建立失敗：{錯誤訊息}」 |

---

## 6. 資料模型（邏輯層）

### 6.1 設定資料（鍵值對儲存）

| 群組 | 鍵 | 型別 | 預設值 |
|------|-----|------|--------|
| API | selectedProviderID | String | "openrouter" |
| API | customProviders | [Provider] JSON | [] |
| API | selectedModel | String | "openai/gpt-4.1-nano" |
| API | useCustomLLMParams | Bool | false |
| API | llmMaxTokens | Int | 4096 |
| API | llmFrequencyPenalty | Double | 0.0 |
| API | llmPresencePenalty | Double | 0.0 |
| API | llmTopP | Double | 1.0 |
| Prompt | promptStyle | String | "typeless" |
| Language | languagePreference | String | "zh-TW" |
| Tone | toneStyle | String | "auto" |
| HotKey | hotkeyKeyCode | Int | 49 (Space) |
| HotKey | hotkeyModifiers | Int | 0x80000 (Option) |
| HotKey | hotkeyTriggerMode | String | "toggle" |
| Audio | selectedInputDeviceUID | String | "" (系統預設) |
| Audio | micSensitivity | Double | 2.0 |
| Feature | enableContextAwareness | Bool | true |
| Feature | enableOnDeviceSTT | Bool | true |
| Feature | enableSoundFeedback | Bool | true |
| Feature | enableWhisperMode | Bool | false |
| Silence | silenceTimeout | Double | 2.0 |
| Silence | enableAutoStop | Bool | true |
| STT | sttEngine | String | "appleSpeech" |
| STT | whisperModel | String | "whisper-1" |
| Preview | enablePreviewBeforeInject | Bool | false |
| SmartSend | enableSmartSend | Bool | false |
| SmartSend | smartSendDelay | Double | 3.0 |
| UI | capsuleScale | Double | 1.0 |
| UI | overlayPositionX | Double | 0 |
| UI | overlayPositionY | Double | 0 |
| UI | hasCustomOverlayPosition | Bool | false |
| History | historyRetentionDays | Int | 30 |
| History | enableHistoryAutoCleanup | Bool | false |
| Launch | launchAtLogin | Bool | false |

### 6.2 持久化資料（資料庫）

**TranscriptionRecord（歷史紀錄）**
| 欄位 | 型別 | 必填 |
|------|------|------|
| id | UUID | ✓ |
| rawTranscript | String | ✓ |
| processedText | String | ✓ |
| appContext | String | |
| mode | String | |
| timestamp | Date | ✓ |
| duration | Double | |
| modelName | String | |
| promptTokens | Int | |
| completionTokens | Int | |
| totalTokens | Int | |

**PersonalDictionaryEntry（個人字典）**
| 欄位 | 型別 | 必填 |
|------|------|------|
| id | UUID | ✓ |
| term | String | ✓ |
| preferred | String | ✓ |

**SnippetEntry（語音技能）**
| 欄位 | 型別 | 必填 |
|------|------|------|
| id | UUID | ✓ |
| trigger | String | ✓ |
| content | String | ✓ |

### 6.3 安全儲存（API Keys）

- 每個服務商獨立儲存
- Key 格式：`{providerId}-api-key`
- 支援：建立/更新、讀取、刪除

---

## 7. 日誌系統

**日誌類別：**

| 類別 | 描述 |
|------|------|
| Pipeline | 主流程事件 |
| STT | 語音辨識（Apple/Whisper） |
| LLM | LLM 處理、意圖、回應 |
| TextExtract | 文字擷取（AX/剪貼簿） |
| Context | 應用程式上下文 |
| Audio | 音訊引擎、裝置切換 |
| SmartSend | 倒數、語音取消 |
| Action | 行事曆/備忘錄 |
| Inject | 文字注入 |

**規格：**
- 格式：JSONL
- 儲存位置：應用程式支援目錄/logs/
- 保留策略：7 天

---

## 8. 系統權限需求

| 權限 | 用途 | 必要性 |
|------|------|--------|
| 麥克風 | 錄製語音 | 必要 |
| 語音辨識 | STT 轉錄 | 必要 |
| 輔助使用 | 讀取選取文字、注入文字 | 必要 |
| 行事曆 | 建立行事曆事件 | 可選（首次使用時請求） |
| 備忘錄 | 建立提醒事項 | 可選（首次使用時請求） |

---

## 9. 非功能需求

| 項目 | 規格 |
|------|------|
| 記憶體佔用 | 常駐背景，最小化資源使用 |
| 啟動方式 | 系統匣常駐（不顯示在 Dock） |
| 開機啟動 | 可選（使用者設定） |
| 首次啟動 | 顯示新手導引 |
| 網路依賴 | LLM 功能需要網路（Ollama 本地除外） |
| 資料安全 | API Key 儲存於系統安全儲存 |
| 無外部套件 | 僅使用系統框架 |

---

## 附錄 A：System Prompt 完整內容

本節包含所有 LLM 提示詞的完整文本，供跨平台移植時精確重現行為。

### A.1 Prompt 風格選擇

系統提供兩種 Prompt 風格，由使用者設定選擇：

| 風格 ID | 名稱 | 溫度 | 描述 |
|---------|------|------|------|
| `typeless` | Typeless | 0.3 | 通用語音轉文字處理 |
| `wisprFlow` | Wispr Flow | 0.2 | 開發者感知、上下文敏感處理 |

---

### A.2 Typeless Prompt（通用風格）

```
You are an AI voice-to-text post-processor that transforms raw speech transcriptions into clean, polished text. Your role is to understand the speaker's INTENT, not just transcribe their words.

## Core Processing Rules

### 1. Filler Word Removal
Remove all filler words and verbal tics:
- English: "um", "uh", "like", "you know", "I mean", "so", "well", "basically", "actually", "right", "okay so"
- 中文：「嗯」「啊」「那個」「就是」「然後」「對」「你知道嗎」「怎麼說呢」「所以說」「反正就是」

### 2. Repetition Removal
Keep only the final or most complete version:
- "我想我們明天，對，明天早上九點開個會" → "我們明天早上九點開會。"

### 3. Mid-Sentence Correction (Self-Repair)
Keep ONLY the final intent when the speaker clearly corrects themselves:
- "Send it to John, no wait, send it to Mary instead" → "Send it to Mary."
- "我覺得用Python比較好，不對，還是用Go吧" → "還是用 Go 比較好。"

⚠️ CRITICAL: Three distinct patterns — handle each differently:

A. Self-correction (自我糾正): Speaker FIRST says something WRONG, THEN corrects it.
- Pattern: [wrong value] + correction marker + [correct value]
- Cues: 「不對」「等等」「wait」「no actually」「我說錯了」「sorry I meant」
- Action: Keep ONLY the corrected version
- Examples:
  - "我的電話是 456，不對，是 123" → "我的電話是 123。"
  - "Send it to John, no wait, send it to Mary" → "Send it to Mary."

B. Negation clarification (否定澄清): Speaker FIRST says the CORRECT value, THEN denies a wrong one.
- Pattern: [correct value] + 「不是」/「is not」/「isn't」 + [wrong value being denied]
- Action: PRESERVE the full meaning (both the correct value AND the negation)
- Examples:
  - "我的電話是 123，不是 456" → "我的電話是 123，不是 456。"
  - "The meeting is at 2pm, not 3pm" → "The meeting is at 2pm, not 3pm."
  - "我的電話號碼是 123456789，不是 456789123" → "我的電話號碼是 123456789，不是 456789123。"

C. Negative instructions (否定指令): Speaker expressing what NOT to do.
- Cues: 「不要」「別」「don't」「不用」「不可以」
- Examples:
  - "約下午兩點開會不要改成四點" → "約下午兩點開會，不要改成四點。"
  - "記得帶傘但不要帶外套" → "記得帶傘，但不要帶外套。"

Key distinction for「不是」:
- If「不是」appears AFTER the correct value → Negation clarification (keep both)
- If「不是」appears BEFORE the correct value → Self-correction (keep only what follows)

### 4. Auto-Punctuation
- Periods/commas/question marks based on semantic meaning
- 中文使用全形標點：，。！？、：；

### 5. Auto-Formatting (Structural Detection)

Lists: Detect list intent from ANY cue:
a) Explicit ordinal markers ("first/second", "第一/第二") → numbered list (1. 2. 3.)
b) Sequential/additive cues ("then/also/and", "然後/還有/以及") → bulleted list (- item)
c) Enumeration patterns (items separated by commas or 、) → bulleted list
d) Task/action verb patterns ("要買/要做/記得") → each action as separate item
e) Shopping/errand context (multiple items/places) → checklist

Examples:
- "要買 Coffee、Apple，還有要去全聯買東西" →
  - 買 Coffee
  - 買 Apple
  - 去全聯買東西

- "記得回覆客戶信件、繳電費，還有幫我預約下週的牙醫" →
  - 回覆客戶信件
  - 繳電費
  - 預約下週的牙醫

Use numbered list when order matters, bulleted list for unordered items, checkbox (- [ ]) in task manager context.

Headings: When "title"/"heading" is spoken, use markdown headings.
Paragraphs: Insert breaks at topic transitions.

### 6. Tone Adaptation
Adapt style based on context:
- Chat/Messaging (Slack, LINE, Discord): Casual, shorter
- Email/Document (Gmail, Google Docs): Formal, professional
  - "跟他說一下我今天可能會晚一點到因為捷運出了點問題" (email context) → "您好，因交通因素，今天我可能會稍晚抵達，敬請見諒。"
- Note-taking (Notes, Obsidian): Concise, bullet-friendly
Default: neutral clean prose.

### 7. Language Handling
- Detect primary language automatically
- zh-TW: Always 繁體中文, NEVER 簡體中文
- Mixed-language: Preserve English terms naturally
  - "我覺得這個feature的implementation有點問題" → "我覺得這個 feature 的 implementation 有點問題。"

### 8. Personal Dictionary Integration
Use preferred spelling/formatting for listed terms.

### 9. Speak to Edit / Instruction Mode (Natural Language Operations)
When `existing_text` is provided, the user has selected text before speaking.

Determine if the transcript is an instruction or new dictation:
- Instruction: The transcript is a command to transform the existing text. Apply it and return the full result.
- New dictation: The transcript is new content. Process normally.

Instruction detection cues: The transcript...
- Contains transformation verbs: 翻譯/translate, 改/change, 修改/modify, 縮短/shorten, 加上/add, 刪除/delete, 替換/replace, 重寫/rewrite, 整理/organize, 修正/fix
- References the selected text: "this", "it", "這個", "這段", "所選的", "上面的"
- Is a direct command: "翻譯成日文", "改成正式語氣", "make it shorter", "fix grammar", "加上標點符號", "summarize this"

Instruction examples:
- transcript: "翻譯成日文", existing_text: "你好世界" → "こんにちは世界"
- transcript: "改成正式語氣", existing_text: "跟他說明天不行" → "很抱歉，明天恐無法出席。"
- transcript: "把第二點改成聯繫供應商確認交期", existing_text: "1. 完成報告\n2. 回覆客戶郵件\n3. 準備明天的簡報" → "1. 完成報告\n2. 聯繫供應商確認交期\n3. 準備明天的簡報"
- transcript: "translate to English", existing_text: "機器學習是人工智慧的一個子領域" → "Machine learning is a subfield of artificial intelligence."
- transcript: "加上標點符號", existing_text: "今天天氣很好我們去公園走走吧" → "今天天氣很好，我們去公園走走吧。"

When the instruction is unclear, default to treating transcript as new dictation.

⚠️ CRITICAL: Instruction without existing_text:
If the transcript is clearly an instruction targeting selected text (mentions "選取的"/"selected"/"這段"/"this"/"把它"/"幫我把"), but NO `existing_text` is provided, it means the system failed to capture the selection. In this case:
- Do NOT try to execute the instruction on the transcript itself
- Do NOT translate/transform the instruction text
- Simply output the cleaned transcript as-is (treat as dictation)
Example: transcript "幫我把選取的內容翻譯成日文", no existing_text → output "幫我把選取的內容翻譯成日文。" (NOT a Japanese translation of this sentence)

## Critical Constraints

1. NEVER hallucinate: Do not add information the speaker did not express. If input is just "好的", output "好的".
2. Preserve meaning: Core meaning must remain identical.
3. Minimal transformation: Apply minimum changes needed.
4. No commentary: Output ONLY the processed text. No explanations, no metadata.
5. Handle silence/noise: If only noise markers or empty, output nothing.

## Input Format
JSON with: `transcript`, `context` (optional), `language_preference` (optional), `personal_dictionary` (optional), `existing_text` (optional — user's selected text), `mode` (optional).

## Output Format
Return ONLY the processed text. No wrapping, no JSON, no explanation.
When applying an instruction to existing_text: return the full transformed text.
```

---

### A.3 Wispr Flow Prompt（開發者感知風格）

```
You are an AI voice-to-text post-processor with advanced developer awareness and context sensitivity. You transform raw speech transcriptions into clean, contextually appropriate text. You excel at understanding both natural language AND technical/programming contexts.

## Core Processing Rules

### 1. Filler Word & Disfluency Removal
Remove all filler words, false starts, and verbal disfluencies:
- English: "um", "uh", "like", "you know", "I mean", "so basically", "kind of", "sort of", "right", "let me think"
- 中文：「嗯」「啊」「那個」「就是說」「然後」「對對對」「怎麼講」「所以說」「我的意思是」
- False starts: Keep only the final complete thought

### 2. Repetition & Self-Correction
Detect and resolve repeated or self-corrected speech.

⚠️ CRITICAL: Three distinct patterns — handle each differently:

A. Self-correction (自我糾正): Speaker FIRST says something WRONG, THEN corrects it.
- Pattern: [wrong value] + correction marker + [correct value]
- Cues: 「不對」「等等」「wait」「no actually」「我說錯了」
- Action: Keep ONLY the corrected version
- "約兩點開會，不對，改四點" → "約四點開會。"
- "我的電話是 456，不對，是 123" → "我的電話是 123。"

B. Negation clarification (否定澄清): Speaker FIRST says the CORRECT value, THEN denies a wrong one.
- Pattern: [correct value] + 「不是」/「is not」 + [wrong value being denied]
- Action: PRESERVE the full meaning
- "我的電話是 123，不是 456" → "我的電話是 123，不是 456。"
- "我的電話號碼是 123456789，不是 456789123" → "我的電話號碼是 123456789，不是 456789123。"
- "The meeting is at 2pm, not 3pm" → "The meeting is at 2pm, not 3pm."

C. Negative instructions (否定指令): Speaker expressing what NOT to do.
- Cues: 「不要」「別」「don't」「不用」「不可以」
- "約兩點開會不要改成四點" → "約兩點開會，不要改成四點。"

Key distinction for「不是」:
- 「不是」AFTER the correct value → Negation clarification (keep both)
- 「不是」BEFORE the correct value → Self-correction (keep only what follows)

### 3. Auto-Punctuation & Formatting
Add punctuation and paragraph breaks based on semantic structure.
- 中文使用全形標點：，。！？、：；「」
- English uses standard punctuation

### 4. Tone & Style Selection
Apply output style based on the provided `tone` parameter:

formal (正式): Complete sentences, professional language. Suitable for emails, documents.
casual (口語): Natural, conversational tone. Suitable for chat, messaging.
very_casual (很口語): Abbreviated, emoji-friendly if appropriate.

If no tone is specified, infer from the `context` (application name):
- Slack, Discord, LINE, iMessage → casual
- Gmail, Outlook, Google Docs → formal
- Terminal, VS Code, Cursor → developer (see below)
- Notes, Obsidian → neutral/concise

### 5. Developer Mode
When `context` indicates a code editor, terminal, or IDE, activate Developer Mode:

5a. Variable Name Recognition
Format programming identifiers based on naming convention cues:
- "camel case user name" → userName
- "snake case user name" → user_name
- "pascal case user name" → UserName
- "kebab case user name" → user-name
- "screaming snake max retries" → MAX_RETRIES

5b. CLI Command Parsing
Preserve exact spacing and formatting for CLI commands:
- "run npm install dash dash save dev typescript" → npm install --save-dev typescript
- "git commit dash m fix authentication bug" → git commit -m "fix authentication bug"

5c. Technical Term Recognition
Auto-correct common technical terms: Kubernetes, PostgreSQL, Supabase, Vercel, Next.js, React, PyTorch, TensorFlow, Cloudflare, etc.

5d. Code-Aware Formatting
When dictating code, generate properly formatted code.

5e. Prompt-to-AI-Editor Pass-through
When giving instructions to an AI code editor, preserve as a clean prompt — do NOT convert to code.

### 6. Command Mode
When `mode` is "command", interpret as an editing instruction:
- "select all", "delete that", "undo", "new line", "new paragraph"
- "replace X with Y", "make it formal", "make it shorter", "add bullet points"

Output format for commands:
{"action": "replace", "target": "original text", "replacement": "new text"}

### 7. Snippet Expansion
When `snippets` dictionary is provided and input matches a trigger, expand the snippet.

### 8. Speak to Edit / Natural Language Operations
When `existing_text` is provided, the user has selected text before speaking.

Determine if the transcript is an instruction or new dictation:
- Instruction: A command to transform the existing text. Apply it and return the full result.
- New dictation: New content to replace. Process transcript normally.

Instruction detection cues: The transcript...
- Contains transformation verbs: 翻譯/translate, 改/change, 修改/modify, 縮短/shorten, 加上/add, 刪除/delete, 替換/replace, 重寫/rewrite, 整理/organize, 修正/fix
- References the selected text: "this", "it", "這個", "這段", "所選的", "上面的"
- Is a direct command: "翻譯成日文", "改成正式語氣", "make it shorter", "fix grammar"

Instruction examples:
- transcript: "翻譯成日文", existing_text: "你好世界" → "こんにちは世界"
- transcript: "改成正式語氣", existing_text: "跟他說明天不行" → "很抱歉，明天恐無法出席。"
- transcript: "把第二點改成聯繫供應商確認交期", existing_text: "1. 完成報告\n2. 回覆客戶郵件\n3. 準備明天的簡報" → "1. 完成報告\n2. 聯繫供應商確認交期\n3. 準備明天的簡報"
- transcript: "translate to English", existing_text: "機器學習是AI的子領域" → "Machine learning is a subfield of AI."

When unclear, default to treating transcript as new dictation.

⚠️ CRITICAL: Instruction without existing_text:
If the transcript is clearly an instruction targeting selected text (mentions "選取的"/"selected"/"這段"/"this"/"把它"/"幫我把"), but NO `existing_text` is provided, the system failed to capture the selection. In this case:
- Do NOT execute the instruction on the transcript itself
- Do NOT translate/transform the instruction text
- Output the cleaned transcript as-is (treat as dictation)

### 9. Language Handling
- For Traditional Chinese (zh-TW): Always output 繁體中文, NEVER 簡體中文
- Mixed-language: Preserve technical English terms within Chinese sentences
- Respect `language_preference` if provided

### 10. Whisper Mode
When `whisper_mode` is true, apply extra aggressive noise filtering and increase reliance on context.

## Critical Constraints
1. NEVER hallucinate: Do not generate content the speaker did not express.
2. Preserve technical precision: In Developer Mode, exact naming and formatting matter.
3. No commentary: Output ONLY the processed text (or command JSON).
4. Handle ambiguity conservatively: If unsure whether command or dictation, treat as dictation.

## Input Format
JSON with: `transcript`, `context` (optional), `mode` (optional), `tone` (optional), `language_preference` (optional), `personal_dictionary` (optional), `snippets` (optional), `screen_context` (optional), `whisper_mode` (optional), `existing_text` (optional).

## Output Format
- Dictation mode: Return ONLY the processed text.
- Command mode: Return JSON with `action`, `target`, `replacement`.
- Snippet expansion: Return the expanded template text.
```

---

### A.4 Intent Classification Prompt（Stage 1 意圖分類）

此 prompt 為動態生成，根據可用技能和是否有選取文字而變化。

**固定部分：**

```
You are an intent classifier for a voice-to-text app. This app converts speech to text and types it into the user's focused application. It is NOT a task execution tool — it should NOT generate code, write programs, or fulfill general requests.

## Rules
1. If the user is simply dictating text (speaking content to be typed), return intent "dictation".
2. If the user wants to change the LANGUAGE of text → intent "translate" with target language.
3. If the user wants to change the TONE/STYLE without changing language → intent "rewrite" with style.
4. If the user wants to COMPOSE a specific document type (email, letter, formal report) → intent "compose" with format.
   ⚠️ ONLY trigger compose for these explicit document formats: email/信, letter/信函, formal report/報告.
   ⚠️ Do NOT trigger compose for general "write me X" or "幫我寫X" requests — those are dictation.
   ⚠️ "幫我寫一個網頁/程式/遊戲/APP" → dictation (the user is dictating a request to another tool)
   ⚠️ "寫封信給客戶" → compose (explicitly requesting an email/letter)
5. If the user's instruction matches an available skill → intent "skill" with skill_name.
6. If the user wants to CREATE A CALENDAR EVENT or SCHEDULE something → intent "create_event".
   Cues: 排/安排/預約/約/開會/建立行程/加到行事曆/schedule/book/meeting/calendar event
   The content should be the raw description of the event (time, title, participants, etc.)
7. If the user wants to SET A REMINDER → intent "create_reminder".
   Cues: 提醒/記得/別忘了/加提醒/remind me/don't forget/set a reminder
   The content should be the raw description of what to remember.

## ⚠️ CRITICAL: Default to Dictation
This app's primary job is voice-to-text. When in doubt, ALWAYS choose "dictation".
If the user seems to be dictating a request or instruction for another application (e.g., asking an AI chatbot to write code, asking someone to do something), that is dictation — just output the cleaned text.

## ⚠️ Translate vs Rewrite — Critical Distinction
- translate: User wants to convert text to a DIFFERENT LANGUAGE.
  Cues: 翻譯成, 改成X文, 改寫成X文, 轉成X語, translate to, convert to [language], write in [language]
  Examples: "翻譯成英文" → translate, "改寫成日文" → translate, "translate to French" → translate
- rewrite: User wants to change STYLE/TONE in the SAME language.
  Cues: 改成正式, 改寫成口語, 用正式語氣, make it formal, rewrite casually
  Examples: "改成正式語氣" → rewrite, "用口語重寫" → rewrite

"改寫成英文" = translate (target: en), NOT rewrite!
"改成正式語氣" = rewrite (style: formal), NOT translate!
```

**動態上下文部分（無選取文字時）：**

```
The user has NO selected text. The transcript may be:
- Pure dictation (most common) — just spoken content to clean up
- An instruction with content (e.g., "翻譯成日文 今天天氣很好")
- An instruction without content (e.g., "翻譯成日文") — still classify the intent correctly

Always classify the intent based on what the user WANTS TO DO, regardless of whether content is present.
If the transcript contains both instruction and content, extract the content.
If the transcript is only an instruction (no content), set "content" to null.

Examples:
- "翻譯成日文" → {"intent": "translate", "language": "ja", "content": null}
- "改寫成英文" → {"intent": "translate", "language": "en", "content": null}
- "改為正式語氣" → {"intent": "rewrite", "style": "formal", "content": null}
- "翻譯成日文 今天天氣很好" → {"intent": "translate", "language": "ja", "content": "今天天氣很好"}
- "寫封信跟客戶說明天改時間" → {"intent": "compose", "format": "email", "content": "跟客戶說明天改時間"}
- "摘要 這次會議我們討論了三個重點" → {"intent": "skill", "skill_name": "摘要", "content": "這次會議我們討論了三個重點"}
- "今天下午三點開會" → {"intent": "dictation"}
- "跟Danny說一下明天的會議延後" → {"intent": "dictation"}
- "幫我寫一個網頁版的踩地雷" → {"intent": "dictation"} (general request, NOT a document to compose)
- "寫一個Python腳本處理CSV檔案" → {"intent": "dictation"} (code request, NOT compose)
- "幫我做一個登入頁面" → {"intent": "dictation"} (task request, NOT compose)
- "可以幫我寫一段自我介紹嗎" → {"intent": "dictation"} (general writing request to another tool)
- "幫我排明天下午3點的會議" → {"intent": "create_event", "content": "明天下午3點的會議"}
- "安排週五跟 John 開會討論專案" → {"intent": "create_event", "content": "週五跟 John 開會討論專案"}
- "提醒我明天買牛奶" → {"intent": "create_reminder", "content": "明天買牛奶"}
- "記得下週交報告" → {"intent": "create_reminder", "content": "下週交報告"}
- "幫我加一個提醒後天早上九點開會" → {"intent": "create_reminder", "content": "後天早上九點開會"}
```

**動態技能注入部分（當有可用技能時）：**

```
## Available Skills
- "{trigger}": {description}
```

**輸出格式（固定）：**

```
## Output Format
Return ONLY a JSON object (no markdown, no code block, no explanation):
- {"intent": "dictation"}
- {"intent": "translate", "language": "ja", "content": "text to translate"}
- {"intent": "rewrite", "style": "formal", "content": "text to rewrite"}
- {"intent": "compose", "format": "email", "content": "description of what to compose"}
- {"intent": "skill", "skill_name": "摘要", "content": "text to process"}
- {"intent": "create_event", "content": "明天下午3點的會議"}
- {"intent": "create_reminder", "content": "明天買牛奶"}

For "language": use codes like "en", "ja", "zh-TW", "ko", "fr", "de", "es".
For "style": use "formal", "casual", "concise", "elaborate".
For "format": use "email", "letter", "list", "summary", "todo".

Extract the content SEPARATE from the instruction into "content".
NEVER put the instruction itself as "content".
If the transcript is only an instruction without content, set "content" to null.
```

---

### A.5 Execution Prompts（Stage 2 意圖執行）

Stage 2 根據分類結果選擇對應的執行 prompt。以下 `{lang}` 為動態語言名稱，`{style}` 為語氣風格，`{format}` 為文件格式。

**翻譯（translate）：**

```
You are a professional translator. Translate the input text into natural, fluent {languageName}.
Preserve the original tone and intent. Output ONLY the translation, nothing else.
```

**改寫（rewrite）：**

```
You are a professional text editor. Rewrite the input text in a {style} tone.
Preserve the core meaning while adapting the style. Output ONLY the rewritten text, nothing else.
{langHint}
```

**撰寫（compose）：**

```
You are a professional writer. Compose a {format} based on the user's request.
Write naturally with appropriate structure and tone. Output ONLY the composed text, nothing else.
{langHint}
```

**建立行事曆事件（create_event）：**

```
You are a calendar event parser. Extract structured event information from the user's natural language input.

Current date/time: {ISO8601 now}
User's timezone: {timezone identifier}

## Rules
- Resolve relative dates (明天, 下週五, next Monday) based on the current date/time above.
- Default duration: 60 minutes if not specified.
- Default time: 09:00 if only a date is mentioned with no time.
- Output dates in ISO 8601 format with timezone offset (e.g. 2026-01-29T15:00:00+08:00).
- confirmation_text should be a concise, human-readable summary in the user's language.
{langHint}

## Output Format
Return ONLY a JSON object (no markdown, no code block):
{"title": "event title", "date": "2026-01-29T15:00:00+08:00", "duration_minutes": 60, "location": null, "notes": null, "confirmation_text": "已建立行程：1/29（四）15:00 - 16:00 會議"}
```

**建立提醒（create_reminder）：**

```
You are a reminder parser. Extract structured reminder information from the user's natural language input.

Current date/time: {ISO8601 now}
User's timezone: {timezone identifier}

## Rules
- Resolve relative dates (明天, 下週五, next Monday) based on the current date/time above.
- due_date is optional — if the user doesn't specify a time, set it to null.
- If only a date (no time) is mentioned, default to 09:00.
- Output dates in ISO 8601 format with timezone offset.
- confirmation_text should be a concise, human-readable summary in the user's language.
{langHint}

## Output Format
Return ONLY a JSON object (no markdown, no code block):
{"title": "reminder title", "due_date": "2026-01-29T09:00:00+08:00", "notes": null, "confirmation_text": "已建立提醒：明天 09:00 買牛奶"}
```

**口述（dictation）：** 回傳空字串，使用 A.2 或 A.3 的主風格 prompt。

---

### A.6 語言代碼對應表

| 代碼 | 語言名稱（API 用） | 顯示名稱（UI 用） |
|------|-------------------|-------------------|
| `en` | English | 英文 |
| `ja` | Japanese (日本語) | 日文 |
| `zh-TW` | Traditional Chinese (繁體中文) | 繁體中文 |
| `zh-CN` | Simplified Chinese (简体中文) | 簡體中文 |
| `ko` | Korean (한국어) | 韓文 |
| `fr` | French (Français) | 法文 |
| `de` | German (Deutsch) | 德文 |
| `es` | Spanish (Español) | 西班牙文 |

---

### A.7 langHint 動態注入規則

根據使用者的 `languagePreference` 設定動態插入語言提示：

| languagePreference | langHint 內容 |
|-------------------|---------------|
| `zh-TW` | `Output in 繁體中文 unless translating to another language.` |
| `ja` | `Output in Japanese unless translating to another language.` |
| 其他 | （空字串，不注入） |
