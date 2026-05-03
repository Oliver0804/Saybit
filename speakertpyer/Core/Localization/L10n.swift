//
//  L10n.swift
//  speakertpyer
//
//  Centralized localization for app-internal language switching.
//  Each string uses a dictionary lookup keyed by AppLanguage.
//

import SwiftUI

// swiftlint:disable type_body_length file_length
enum L10n {
    static var lang: AppLanguage {
        SettingsStore.shared?.appLanguage ?? .zhTW
    }

    // MARK: - About

    enum About {
        static var description: String { d("智慧語音輸入助手，將語音轉換為精準文字，支援聽寫、指令與編輯模式。", "智能语音输入助手，将语音转换为精准文字，支持听写、指令与编辑模式。", "Smart voice input assistant that converts speech to precise text. Supports dictation, command, and edit modes.", "スマート音声入力アシスタント。音声を正確なテキストに変換し、ディクテーション、コマンド、編集モードをサポートします。") }
        static var priceTitle: String { d("超低成本，用多少算多少", "超低成本，用多少算多少", "Ultra-low cost, pay as you go", "超低コスト、使った分だけ") }
        static var priceDesc: String { d("使用 GPT-4.1-nano，每次請求不到 1 分錢。相比訂閱制產品（$9-10/月），US$5 可用超久！", "使用 GPT-4.1-nano，每次请求不到 1 分钱。相比订阅制产品（$9-10/月），US$5 可用超久！", "Uses GPT-4.1-nano, ~$0.0002/request. Compared to subscriptions ($9-10/mo), $5 lasts forever!", "GPT-4.1-nano 使用、リクエストごとに 1 分以下。サブスク（$9-10/月）と比べ、US$5 で超長持ち！") }
    }

    // MARK: - Common

    enum Common {
        static var save: String { d("儲存", "保存", "Save", "保存") }
        static var cancel: String { d("取消", "取消", "Cancel", "キャンセル") }
        static var delete: String { d("刪除", "删除", "Delete", "削除") }
        static var add: String { d("新增", "新增", "Add", "追加") }
        static var test: String { d("測試", "测试", "Test", "テスト") }
        static var done: String { d("完成", "完成", "Done", "完了") }
        static var settings: String { d("設定...", "设置...", "Settings...", "設定...") }
        static var show: String { d("顯示", "显示", "Show", "表示") }
        static var hide: String { d("隱藏", "隐藏", "Hide", "隠す") }
        static var reset: String { d("重置", "重置", "Reset", "リセット") }
        static var close: String { d("關閉", "关闭", "Close", "閉じる") }
        static var next: String { d("下一步", "下一步", "Next", "次へ") }
        static var previous: String { d("上一步", "上一步", "Back", "戻る") }
        static var skip: String { d("跳過", "跳过", "Skip", "スキップ") }
        static var confirm: String { d("確認", "确认", "Confirm", "確認") }
        static var quit: String { d("結束 Saybit", "退出 Saybit", "Quit Saybit", "Saybit を終了") }
        static var about: String { d("關於 Saybit", "关于 Saybit", "About Saybit", "Saybit について") }
        static var developer: String { d("開發者", "开发者", "Developer", "開発者") }
        static var website: String { d("官方網站", "官方网站", "Website", "ウェブサイト") }
        static var visitWebsite: String { d("造訪網站 →", "访问网站 →", "Visit Website →", "ウェブサイトを見る →") }
        static var recheck: String { d("重新檢查", "重新检查", "Recheck", "再確認") }
        static var openSettings: String { d("開啟設定", "打开设置", "Open Settings", "設定を開く") }
        static var saved: String { d("已儲存", "已保存", "Saved", "保存済み") }
        static var cleared: String { d("已清除", "已清除", "Cleared", "クリア済み") }
        static var saveFailed: String { d("儲存失敗", "保存失败", "Save Failed", "保存失敗") }
        static var set: String { d("已設定", "已设置", "Set", "設定済み") }
        static var notSet: String { d("未設定", "未设置", "Not Set", "未設定") }
        static var authorized: String { d("已授權", "已授权", "Authorized", "許可済み") }
        static var notAuthorized: String { d("未授權", "未授权", "Not Authorized", "未許可") }
        static var requestAccess: String { d("請求授權", "请求授权", "Request Access", "アクセスを要求") }
        static var testConnection: String { d("測試連線", "测试连接", "Test Connection", "接続テスト") }
        static var connectionSuccess: String { d("連線成功", "连接成功", "Connected", "接続成功") }
        static var startUsing: String { d("開始使用", "开始使用", "Get Started", "使い始める") }
        static var searchSettings: String { d("搜尋設定…", "搜索设置…", "Search settings…", "設定を検索…") }
        static var all: String { d("全部", "全部", "All", "すべて") }
        static var noResults: String { d("找不到符合的設定", "找不到匹配的设置", "No matching settings", "一致する設定が見つかりません") }
    }

    // MARK: - Tabs

    enum Tabs {
        static var general: String { d("一般", "通用", "General", "一般") }
        static var ai: String { d("AI 引擎", "AI 引擎", "AI Engine", "AIエンジン") }
        static var hotkey: String { d("快捷鍵", "快捷键", "Hotkey", "ショートカット") }
        static var dictionary: String { d("字典 / 技能", "字典 / 技能", "Dictionary / Skills", "辞書 / スキル") }
        static var history: String { d("歷史", "历史", "History", "履歴") }
        static var statistics: String { d("統計", "统计", "Statistics", "統計") }
        static var logs: String { d("日誌", "日志", "Logs", "ログ") }
    }

    // MARK: - Settings (Logs)

    enum Settings {
        static var logs: String { d("日誌檢視器", "日志查看器", "Log Viewer", "ログビューア") }
        static var logLevel: String { d("等級", "等级", "Level", "レベル") }
        static var logCategory: String { d("分類", "分类", "Category", "カテゴリ") }
        static var logSearch: String { d("搜尋日誌…", "搜索日志…", "Search logs…", "ログを検索…") }
        static var logAutoScroll: String { d("自動捲動", "自动滚动", "Auto-scroll", "自動スクロール") }
        static var logExport: String { d("匯出", "导出", "Export", "エクスポート") }
        static var logClear: String { d("清除", "清除", "Clear", "クリア") }
        static var logEmpty: String { d("目前沒有日誌", "当前没有日志", "No logs yet", "ログがありません") }
    }

    // MARK: - General Settings

    enum General {
        static var enableAutoUpdateCheck: String { d("啟動時自動檢查更新", "启动时自动检查更新", "Auto-check for updates on launch", "起動時に自動でアップデート確認") }
        static var autoUpdateCheckDesc: String { d("每 24 小時詢問 GitHub Releases，新版本可用時於設定中提示。", "每 24 小时询问 GitHub Releases，新版本可用时于设置中提示。", "Polls GitHub Releases every 24 hours and notifies you here when a new version is available.", "24 時間ごとに GitHub Releases を確認し、新バージョンがある場合はここでお知らせします。") }

        static var language: String { d("語言", "语言", "Language", "言語") }
        static var preferredLanguage: String { d("偏好語言", "偏好语言", "Preferred Language", "表示言語") }
        static var autoLanguageDetection: String { d("自動語言偵測", "自动语言检测", "Auto Language Detection", "自動言語検出") }
        static var autoLanguageDetectionDesc: String { d("讓 Whisper API 自動偵測說話語言，無需手動指定", "让 Whisper API 自动检测说话语言，无需手动指定", "Let Whisper API auto-detect the spoken language", "Whisper API に話す言語を自動検出させます") }

        // Features
        static var features: String { d("功能", "功能", "Features", "機能") }
        static var contextAwareness: String { "Context Awareness" }
        static var contextAwarenessDesc: String { d("讀取目前選取的文字作為上下文", "读取当前选中的文字作为上下文", "Reads selected text as context", "選択中のテキストをコンテキストとして読み取る") }
        static var soundFeedback: String { d("音效回饋", "音效反馈", "Sound Feedback", "サウンドフィードバック") }
        static var whisperMode: String { "Whisper Mode" }
        static var whisperModeDesc: String { d("提示 LLM 過濾背景噪音與雜訊", "提示 LLM 过滤背景噪音与杂讯", "Hints LLM to filter background noise", "LLM にバックグラウンドノイズのフィルタリングを指示") }

        // STT Engine
        static var sttEngine: String { d("語音辨識引擎", "语音识别引擎", "Speech Recognition Engine", "音声認識エンジン") }
        static var sttEnginePicker: String { d("辨識引擎", "识别引擎", "Engine", "エンジン") }
        static var whisperAPIKey: String { "Whisper API Key" }
        static var whisperDesc: String { d("使用 OpenAI Whisper API 進行語音辨識，辨識準確度更高，但需網路連線且會產生 API 費用", "使用 OpenAI Whisper API 进行语音识别，识别准确度更高，但需网络连接且会产生 API 费用", "Uses OpenAI Whisper API for speech recognition. Higher accuracy but requires internet and incurs API costs.", "OpenAI Whisper API を使用した音声認識。精度は高いですが、ネット接続と API 費用が必要です。") }
        static var onDeviceSTT: String { "On-Device STT" }
        static var onDeviceSTTDesc: String { d("使用本地語音辨識，不需網路", "使用本地语音识别，不需网络", "Uses on-device speech recognition, no internet needed", "ローカル音声認識を使用、ネット不要") }

        // Capsule
        static var capsuleSize: String { d("膠囊大小", "胶囊大小", "Capsule Size", "カプセルサイズ") }
        static var scaleRatio: String { d("縮放比例", "缩放比例", "Scale", "拡大率") }
        static var capsuleSizeDesc: String { d("調整浮動膠囊的顯示大小", "调整浮动胶囊的显示大小", "Adjust the floating capsule display size", "フローティングカプセルの表示サイズを調整") }

        // Input Device
        static var inputDevice: String { d("輸入裝置", "输入设备", "Input Device", "入力デバイス") }
        static var systemDefault: String { d("系統預設", "系统默认", "System Default", "システムデフォルト") }
        static var selectMicDesc: String { d("選擇語音輸入使用的麥克風", "选择语音输入使用的麦克风", "Select the microphone for voice input", "音声入力に使用するマイクを選択") }
        static var testMic: String { d("測試麥克風", "测试麦克风", "Test Microphone", "マイクテスト") }
        static var stopTest: String { d("停止測試", "停止测试", "Stop Test", "テスト停止") }
        static var micTestHint: String { d("對麥克風說話，觀察音量條是否有反應", "对麦克风说话，观察音量条是否有反应", "Speak into the microphone and observe the volume bar", "マイクに向かって話し、音量バーの反応を確認してください") }

        // Mic Sensitivity
        static var micSensitivity: String { d("麥克風靈敏度", "麦克风灵敏度", "Microphone Sensitivity", "マイク感度") }
        static var gainMultiplier: String { d("增益倍數", "增益倍数", "Gain Multiplier", "ゲイン倍率") }
        static var micSensitivityDesc: String { d("調高此值可讓音量顯示更靈敏，建議錄音時觀察音量條調整至 3-4 格", "调高此值可让音量显示更灵敏，建议录音时观察音量条调整至 3-4 格", "Higher values increase volume sensitivity. Adjust while recording until the bar shows 3-4 segments.", "この値を上げると音量表示がより敏感になります。録音中に音量バーが3-4セグメント表示されるよう調整してください。") }

        // Auto Stop
        static var silenceAutoStop: String { d("靜音自動停止", "静音自动停止", "Silence Auto-Stop", "無音時自動停止") }
        static var enableAutoStop: String { d("啟用自動停止", "启用自动停止", "Enable Auto-Stop", "自動停止を有効化") }
        static var silenceTimeout: String { d("靜音等待時間", "静音等待时间", "Silence Timeout", "無音待機時間") }
        static var silenceAutoStopDesc: String { d("說完話後等待此時間未偵測到聲音即自動結束錄音", "说完话后等待此时间未检测到声音即自动结束录音", "Automatically stops recording after this duration of silence", "この時間無音が続くと自動的に録音を停止します") }

        // Preview & Send
        // Injection Mode
        static var injectionMode: String { d("注入方式", "注入方式", "Injection Mode", "注入モード") }
        static var injectionModeDesc: String { d("選擇文字注入到目標 App 的方式", "选择文字注入到目标 App 的方式", "Choose how text is injected into the target app", "テキストの注入方法を選択") }

        // Preview & Send
        static var previewAndSend: String { d("預覽與送出", "预览与发送", "Preview & Send", "プレビューと送信") }
        static var previewBeforeInject: String { d("注入前預覽", "注入前预览", "Preview Before Inject", "注入前プレビュー") }
        static var enablePreview: String { d("啟用注入前預覽", "启用注入前预览", "Enable Preview Before Inject", "注入前プレビューを有効化") }
        static var previewDesc: String { d("LLM 處理完成後先顯示預覽，手動確認後再注入文字", "LLM 处理完成后先显示预览，手动确认后再注入文字", "Shows a preview after LLM processing. Manually confirm before injecting text.", "LLM 処理完了後にプレビューを表示し、手動確認後にテキストを注入します。") }

        // Smart Send
        static var smartSend: String { "Smart Send" }
        static var enableSmartSend: String { d("啟用 Smart Send", "启用 Smart Send", "Enable Smart Send", "Smart Send を有効化") }
        static var smartSendDesc: String { d("文字貼上後自動倒數，到期自動按下 Enter 送出", "文字粘贴后自动倒数，到期自动按下 Enter 发送", "Auto-countdown after paste, then auto-presses Enter to send", "貼り付け後自動カウントダウンし、Enter を自動送信") }
        static var countdownSeconds: String { d("倒數秒數", "倒计时秒数", "Countdown", "カウントダウン") }
        static var previewTimeout: String { d("預覽超時", "预览超时", "Preview Timeout", "プレビュータイムアウト") }
        static var previewTimeoutDesc: String { d("預覽顯示後自動確認/取消的等待時間", "预览显示后自动确认/取消的等待时间", "Time to wait before auto-confirming/cancelling preview", "プレビュー表示後の自動確認/キャンセルまでの待機時間") }

        static var smartSendCancelHint: String { d("倒數期間若偵測到說話，會自動取消送出", "倒计时期间若检测到说话，会自动取消发送", "Speaking during countdown will cancel auto-send", "カウントダウン中に話すと自動送信がキャンセルされます") }

        // Context Rules
        static var contextRules: String { d("App 語氣規則", "App 语气规则", "App Tone Rules", "アプリトーンルール") }
        static var contextRulesDesc: String { d("為不同 App 設定專屬語氣和額外指令", "为不同 App 设置专属语气和额外指令", "Set custom tone and extra instructions per app", "アプリごとにトーンと追加指示を設定") }
        static var contextRulesManage: String { d("管理規則", "管理规则", "Manage Rules", "ルールを管理") }
        static var contextRuleApp: String { d("App 識別名", "App 识别名", "App Identifier", "アプリ識別子") }
        static var contextRuleTone: String { d("語氣覆寫", "语气覆写", "Tone Override", "トーン上書き") }
        static var contextRulePrompt: String { d("額外指令", "额外指令", "Extra Instructions", "追加指示") }
        static var contextRulePromptPlaceholder: String { d("（選填）額外的 Prompt 指令…", "（选填）额外的 Prompt 指令…", "(Optional) Extra prompt instructions…", "（任意）追加のプロンプト指示…") }
        static var contextRuleEnabled: String { d("啟用", "启用", "Enabled", "有効") }
        static var contextRuleAddNew: String { d("新增規則", "新增规则", "Add Rule", "ルールを追加") }

        // History Cleanup
        static var historyCleanup: String { d("歷史記錄清理", "历史记录清理", "History Cleanup", "履歴クリーンアップ") }
        static var autoCleanup: String { d("自動清理舊紀錄", "自动清理旧记录", "Auto-Clean Old Records", "古い記録の自動クリーンアップ") }
        static var retentionDays: String { d("保留天數", "保留天数", "Retention Days", "保持日数") }
        static var historyCleanupDesc: String { d("超過此天數的歷史紀錄會在開啟時自動清除", "超过此天数的历史记录会在启动时自动清除", "Records older than this will be auto-deleted on launch", "この日数を超えた履歴は起動時に自動削除されます") }

        // Permissions
        static var permissionStatus: String { d("權限狀態", "权限状态", "Permission Status", "権限状態") }
        static var accessibility: String { "Accessibility" }
        static var microphone: String { d("麥克風", "麦克风", "Microphone", "マイク") }
        static var automation: String { d("自動化", "自动化", "Automation", "オートメーション") }
        static var reminders: String { d("備忘錄", "提醒事项", "Reminders", "リマインダー") }
        static var calendar: String { d("行事曆", "日历", "Calendar", "カレンダー") }

        // Launch at Login
        static var launchAtLogin: String { d("開機自動啟動", "开机自动启动", "Launch at Login", "ログイン時に起動") }
        static var enableLaunchAtLogin: String { d("登入時自動啟動 Saybit", "登录时自动启动 Saybit", "Launch Saybit at Login", "ログイン時に Saybit を起動") }
        static var launchAtLoginDesc: String { d("Mac 開機登入後自動啟動 Saybit", "Mac 开机登录后自动启动 Saybit", "Automatically launch Saybit when you log in to your Mac", "Mac にログインした際に Saybit を自動起動します") }

        // Tutorial
        static var tutorial: String { d("教學", "教程", "Tutorial", "チュートリアル") }
        static var replayTutorial: String { d("重新查看教學", "重新查看教程", "Replay Tutorial", "チュートリアルを再表示") }

        // Format helpers
        static func seconds(_ value: Double) -> String {
            String(format: "%.1f %@", value, d("秒", "秒", "s", "秒"))
        }
        static func days(_ value: Int) -> String {
            "\(value) \(d("天", "天", "days", "日"))"
        }
    }

    // MARK: - API Settings

    enum API {
        static var provider: String { d("API 服務商", "API 服务商", "API Provider", "API プロバイダー") }
        static var providerPicker: String { d("服務商", "服务商", "Provider", "プロバイダー") }
        static func removeProvider(_ name: String) -> String {
            d("移除「\(name)」", "移除「\(name)」", "Remove \"\(name)\"", "「\(name)」を削除")
        }
        static var addCustomEndpoint: String { d("新增自訂端點", "新增自定端点", "Add Custom Endpoint", "カスタムエンドポイントを追加") }
        static var clear: String { d("清除", "清除", "Clear", "クリア") }
        static func apiKeySet(_ hasKey: Bool) -> String {
            hasKey ? Common.set : Common.notSet
        }
        static func providerStatus(_ name: String) -> String {
            d("\(name) 狀態", "\(name) 状态", "\(name) Status", "\(name) ステータス")
        }
        static var checking: String { d("檢查中...", "检查中...", "Checking...", "確認中...") }
        static func connectedModels(_ count: Int) -> String {
            d("已連線 (\(count) 個模型)", "已连接 (\(count) 个模型)", "Connected (\(count) models)", "接続済み (\(count) モデル)")
        }
        static var notDetected: String { d("未偵測到 Ollama", "未检测到 Ollama", "Ollama Not Detected", "Ollama が検出されません") }
        static func notDetectedServer(_ name: String) -> String {
            d("未偵測到 \(name)", "未检测到 \(name)", "\(name) Not Detected", "\(name) が検出されません")
        }
        static var availableModels: String { d("可用模型：", "可用模型：", "Available Models:", "利用可能なモデル：") }
        static var ollamaHint: String { d("無需 API Key，請確保 Ollama 已啟動（ollama serve）", "无需 API Key，请确保 Ollama 已启动（ollama serve）", "No API Key needed. Make sure Ollama is running (ollama serve).", "API Key 不要。Ollama が起動していることを確認してください（ollama serve）") }
        static var model: String { d("模型", "模型", "Model", "モデル") }
        static func commonModels(_ hint: String) -> String {
            d("常用: \(hint)", "常用: \(hint)", "Common: \(hint)", "よく使われる: \(hint)")
        }
        // Sheet
        static var addCustomTitle: String { d("新增自訂端點", "新增自定端点", "Add Custom Endpoint", "カスタムエンドポイントを追加") }
        static var nameHint: String { d("名稱（如 Ollama）", "名称（如 Ollama）", "Name (e.g. Ollama)", "名前（例：Ollama）") }
        static var baseURLHint: String { d("Base URL（如 http://localhost:11434/v1/chat/completions）", "Base URL（如 http://localhost:11434/v1/chat/completions）", "Base URL (e.g. http://localhost:11434/v1/chat/completions)", "Base URL（例：http://localhost:11434/v1/chat/completions）") }
        static func connectionSuccessModel(_ model: String) -> String {
            "✓ \(d("連線成功", "连接成功", "Connected", "接続成功")) (\(model))"
        }

        // Advanced LLM Parameters
        static var advancedParams: String { d("進階參數", "高级参数", "Advanced Parameters", "詳細パラメータ") }
        static var useCustomParams: String { d("使用自訂 LLM 參數", "使用自定义 LLM 参数", "Use Custom LLM Parameters", "カスタム LLM パラメータを使用") }
        static var maxTokens: String { d("最大 Token 數", "最大 Token 数", "Max Tokens", "最大トークン数") }
        static var frequencyPenalty: String { d("頻率懲罰", "频率惩罚", "Frequency Penalty", "頻度ペナルティ") }
        static var presencePenalty: String { d("存在懲罰", "存在惩罚", "Presence Penalty", "存在ペナルティ") }
        static var topP: String { "Top P" }
        static var advancedParamsDesc: String { d("調整 LLM 生成行為，關閉時使用服務商預設值", "调整 LLM 生成行为，关闭时使用服务商默认值", "Fine-tune LLM generation. When off, provider defaults are used.", "LLM 生成を微調整。オフの場合はプロバイダーのデフォルト値を使用。") }
    }

    // MARK: - HotKey Settings

    enum HotKey {
        static var hotkey: String { d("快捷鍵", "快捷键", "Hotkey", "ショートカット") }
        static var currentHotkey: String { d("目前快捷鍵", "当前快捷键", "Current Hotkey", "現在のショートカット") }
        static var recordNew: String { d("錄製新快捷鍵", "录制新快捷键", "Record New Hotkey", "新しいショートカットを録音") }
        static var recording: String { d("按下新的快捷鍵...", "按下新的快捷键...", "Press new hotkey...", "新しいショートカットを押してください...") }
        static var recordingHint: String { d("按住修飾鍵 (⌘⌃⌥⇧) 再按一個按鍵，按 Esc 取消", "按住修饰键 (⌘⌃⌥⇧) 再按一个按键，按 Esc 取消", "Hold modifier keys (⌘⌃⌥⇧) then press a key. Press Esc to cancel.", "修飾キー (⌘⌃⌥⇧) を押しながら別のキーを押してください。Esc でキャンセル。") }
        static var requirement: String { d("需包含至少一個修飾鍵 (⌘⌃⌥⇧) + 一個按鍵", "需包含至少一个修饰键 (⌘⌃⌥⇧) + 一个按键", "Requires at least one modifier (⌘⌃⌥⇧) + one key", "修飾キー (⌘⌃⌥⇧) 1つ以上 + キー1つが必要") }
        static var triggerMode: String { d("觸發模式", "触发模式", "Trigger Mode", "トリガーモード") }
        static var usageGuide: String { d("使用方式", "使用方式", "Usage Guide", "使い方") }

        // Toggle mode steps
        static var toggleStep1: String { d("按一下快捷鍵開始錄音", "按一下快捷键开始录音", "Press the hotkey once to start recording", "ショートカットを1回押して録音開始") }
        static var toggleStep2: String { d("說出想要輸入的文字", "说出想要输入的文字", "Speak what you want to type", "入力したい内容を話す") }
        static var toggleStep3: String { d("說完後自動停止，AI 處理並輸入", "说完后自动停止，AI 处理并输入", "Auto-stops after speaking, AI processes and types", "話し終わると自動停止、AI が処理して入力") }
        static var toggleStep4: String { d("也可再按一次手動停止", "也可再按一次手动停止", "Or press again to stop manually", "もう一度押して手動停止も可能") }

        // Hold mode steps
        static var holdStep1: String { d("按住快捷鍵開始錄音", "按住快捷键开始录音", "Hold the hotkey to start recording", "ショートカットを押し続けて録音開始") }
        static var holdStep2: String { d("說出想要輸入的文字", "说出想要输入的文字", "Speak what you want to type", "入力したい内容を話す") }
        static var holdStep3: String { d("放開按鍵，AI 自動處理並輸入", "放开按键，AI 自动处理并输入", "Release to stop, AI processes and types", "キーを離すと停止、AI が処理して入力") }

        static func conflictWarning(_ name: String) -> String {
            d("可能與系統熱鍵衝突：\(name)。Saybit 的事件 tap 順序在系統之後，這個組合可能不會被觸發。",
              "可能与系统热键冲突：\(name)。Saybit 的事件 tap 顺序在系统之后，这个组合可能不会被触发。",
              "May conflict with system shortcut: \(name). Saybit's event tap runs after the system, so this combo may never fire.",
              "システムショートカットと競合する可能性：\(name)。Saybit のイベントタップはシステムの後に動くため、発火しない可能性があります。")
        }

        // DoubleTap mode steps
        static var doubleTapStep1: String { d("快速雙擊快捷鍵開始錄音", "快速双击快捷键开始录音", "Double-tap the hotkey to start recording", "ショートカットをダブルタップして録音開始") }
        static var doubleTapStep2: String { d("說出想要輸入的文字", "说出想要输入的文字", "Speak what you want to type", "入力したい内容を話す") }
        static var doubleTapStep3: String { d("說完後自動停止，AI 處理並輸入", "说完后自动停止，AI 处理并输入", "Auto-stops after speaking, AI processes and types", "話し終わると自動停止、AI が処理して入力") }
        static var doubleTapStep4: String { d("也可再次雙擊手動停止", "也可再次双击手动停止", "Or double-tap again to stop manually", "もう一度ダブルタップして手動停止も可能") }
    }

    // MARK: - Dictionary Settings

    enum Dict {
        static var addEntry: String { d("新增詞條", "新增词条", "Add Entry", "エントリーを追加") }
        static var originalTerm: String { d("原始詞", "原始词", "Original Term", "元の語") }
        static var preferredForm: String { d("偏好寫法", "偏好写法", "Preferred Form", "優先表記") }
        static var dictDesc: String { d("語音辨識容易出錯的詞彙，LLM 會自動替換", "语音识别容易出错的词汇，LLM 会自动替换", "Words often misrecognized by speech recognition. LLM will auto-replace them.", "音声認識で誤認識されやすい語彙。LLM が自動的に置換します。") }
        static var dictList: String { d("字典列表", "字典列表", "Dictionary List", "辞書リスト") }
        static var emptyDict: String { d("尚無字典項目", "尚无字典项目", "No dictionary entries yet", "辞書エントリーがありません") }

        // Voice Skills
        static var addSkill: String { d("新增語音技能", "新增语音技能", "Add Voice Skill", "ボイススキルを追加") }
        static var triggerWord: String { d("觸發詞（例：寫信）", "触发词（例：写信）", "Trigger word (e.g. write email)", "トリガーワード（例：メール作成）") }
        static var promptInstruction: String { d("Prompt 指令:", "Prompt 指令:", "Prompt Instruction:", "プロンプト指示：") }
        static var skillDesc: String { d("說出觸發詞時，會載入對應的 Prompt 指令引導 LLM 處理後續語音內容", "说出触发词时，会载入对应的 Prompt 指令引导 LLM 处理后续语音内容", "When the trigger word is spoken, the corresponding prompt guides LLM to process the following speech", "トリガーワードを話すと、対応するプロンプト指示が LLM の処理を導きます") }
        static var example: String { d("範例：", "范例：", "Examples:", "例：") }
        static var exampleWrite: String { d("觸發詞「寫信」→ Prompt「請用正式商業書信格式撰寫，包含問候語與結尾敬語」", "触发词「写信」→ Prompt「请用正式商业书信格式撰写，包含问候语与结尾敬语」", "Trigger \"write email\" → Prompt \"Write in formal business letter format with greetings and sign-off\"", "トリガー「メール作成」→ プロンプト「正式なビジネスレター形式で挨拶と結びを含めて書いてください」") }
        static var exampleSummary: String { d("觸發詞「摘要」→ Prompt「請將以下內容整理為 3-5 條重點摘要」", "触发词「摘要」→ Prompt「请将以下内容整理为 3-5 条重点摘要」", "Trigger \"summary\" → Prompt \"Summarize the following into 3-5 key points\"", "トリガー「要約」→ プロンプト「以下の内容を3-5つの要点にまとめてください」") }
        static var skillList: String { d("語音技能列表", "语音技能列表", "Voice Skill List", "ボイススキルリスト") }
        static var emptySkills: String { d("尚無語音技能", "尚无语音技能", "No voice skills yet", "ボイススキルがありません") }
    }

    // MARK: - Prompt Settings

    enum Prompt {
        static var promptStyle: String { d("Prompt 風格", "Prompt 风格", "Prompt Style", "プロンプトスタイル") }
        static var tone: String { d("語調", "语调", "Tone", "トーン") }
        static var toneAutoDesc: String { d("「自動」會根據當前 App 推斷語調（Slack → 口語，Mail → 正式）", "「自动」会根据当前 App 推断语调（Slack → 口语，Mail → 正式）", "\"Auto\" infers tone from the current app (Slack → casual, Mail → formal)", "「自動」は現在のアプリからトーンを推定します（Slack → カジュアル、Mail → フォーマル）") }
        static var typelessDesc: String { d("強調意圖理解、自動格式化清單、去贅詞/改口修正。適合一般文字輸入。", "强调意图理解、自动格式化列表、去赘词/改口修正。适合一般文字输入。", "Focuses on intent understanding, auto-formatting lists, and removing filler words. Best for general text input.", "意図の理解、リストの自動フォーマット、冗語の除去に重点を置きます。一般的なテキスト入力に最適です。") }
        static var wisprFlowDesc: String { d("強調開發者功能（變數命名、CLI 命令）、Command Mode。適合程式開發。", "强调开发者功能（变量命名、CLI 命令）、Command Mode。适合程序开发。", "Focuses on developer features (variable naming, CLI commands) and Command Mode. Best for programming.", "開発者機能（変数命名、CLI コマンド）と Command Mode に重点を置きます。プログラミングに最適です。") }
    }

    // MARK: - Statistics

    enum Stats {
        static var timeRange: String { d("時間範圍", "时间范围", "Time Range", "期間") }
        static var week: String { d("7 天", "7 天", "7 Days", "7 日") }
        static var month: String { d("30 天", "30 天", "30 Days", "30 日") }
        static var all: String { d("全部", "全部", "All", "すべて") }
        static var totalCount: String { d("總次數", "总次数", "Total", "合計回数") }
        static var totalTokens: String { d("總 Token", "总 Token", "Total Tokens", "合計 Token") }
        static var avgDuration: String { d("平均時長", "平均时长", "Avg Duration", "平均時間") }
        static var todayCount: String { d("今日次數", "今日次数", "Today", "今日") }
        static var dailyUsage: String { d("每日使用次數", "每日使用次数", "Daily Usage", "毎日の使用回数") }
        static var topApps: String { d("常用 App", "常用 App", "Top Apps", "よく使うアプリ") }
        static var noData: String { d("尚無資料", "尚无数据", "No Data", "データなし") }
        static var times: String { d("次", "次", "times", "回") }
        static var tokenTrend: String { d("Token 消耗趨勢", "Token 消耗趋势", "Token Usage Trend", "Token 消費トレンド") }
        static var modeDistribution: String { d("模式分佈", "模式分布", "Mode Distribution", "モード分布") }
    }

    // MARK: - History

    enum History {
        static func recordCount(_ n: Int) -> String {
            "\(n) \(d("筆紀錄", "笔记录", "records", "件の記録"))"
        }
        static func showing(_ displayed: Int, _ total: Int) -> String {
            d("(顯示 \(min(displayed, total)) 筆)", "(显示 \(min(displayed, total)) 笔)", "(Showing \(min(displayed, total)))", "(\(min(displayed, total)) 件表示中)")
        }
        static var cleanup: String { d("清理", "清理", "Cleanup", "クリーンアップ") }
        static var deleteOlder7: String { d("刪除 7 天前的紀錄", "删除 7 天前的记录", "Delete records older than 7 days", "7 日以前の記録を削除") }
        static var deleteOlder30: String { d("刪除 30 天前的紀錄", "删除 30 天前的记录", "Delete records older than 30 days", "30 日以前の記録を削除") }
        static var deleteAll: String { d("清除全部紀錄", "清除全部记录", "Delete All Records", "すべての記録を削除") }
        static var rawTranscript: String { d("原始轉錄", "原始转录", "Raw Transcript", "元の文字起こし") }
        static var processedText: String { d("處理後文字", "处理后文字", "Processed Text", "処理済みテキスト") }
        static var copyResult: String { d("複製結果", "复制结果", "Copy Result", "結果をコピー") }
        static var copyRaw: String { d("複製原始", "复制原始", "Copy Raw", "元をコピー") }
        static var selectRecord: String { d("選擇一筆紀錄查看詳情", "选择一笔记录查看详情", "Select a record to view details", "記録を選択して詳細を表示") }
        static var confirmDelete: String { d("確定刪除此紀錄？", "确定删除此记录？", "Delete this record?", "この記録を削除しますか？") }
        static var cannotUndo: String { d("此操作無法復原。", "此操作无法恢复。", "This action cannot be undone.", "この操作は元に戻せません。") }
        static var confirmDeleteAll: String { d("確定清除全部紀錄？", "确定清除全部记录？", "Delete all records?", "すべての記録を削除しますか？") }
        static func deleteAllMessage(_ count: Int) -> String {
            d("將刪除所有 \(count) 筆歷史紀錄，此操作無法復原。", "将删除所有 \(count) 笔历史记录，此操作无法恢复。", "This will delete all \(count) records. This action cannot be undone.", "すべての \(count) 件の記録が削除されます。この操作は元に戻せません。")
        }
        static var confirmDeleteOlder: String { d("確定刪除舊紀錄？", "确定删除旧记录？", "Delete old records?", "古い記録を削除しますか？") }
        static var deleteOlder7Message: String { d("將刪除 7 天前的所有紀錄，此操作無法復原。", "将删除 7 天前的所有记录，此操作无法恢复。", "This will delete all records older than 7 days. This cannot be undone.", "7 日以前のすべての記録が削除されます。この操作は元に戻せません。") }
        // Token detail labels
        static func inputTokens(_ n: Int32) -> String { d("輸入 \(n)", "输入 \(n)", "Input \(n)", "入力 \(n)") }
        static func outputTokens(_ n: Int32) -> String { d("輸出 \(n)", "输出 \(n)", "Output \(n)", "出力 \(n)") }
        static func totalTokensLabel(_ n: Int32) -> String { d("共 \(n) tokens", "共 \(n) tokens", "Total \(n) tokens", "合計 \(n) tokens") }
    }

    // MARK: - MenuBar

    enum Menu {
        static func promptLabel(_ name: String) -> String { "Prompt: \(name)" }
        static func toneLabel(_ name: String) -> String { d("語調: \(name)", "语调: \(name)", "Tone: \(name)", "トーン: \(name)") }
        static func reregisterHotkey(_ label: String) -> String {
            d("重新註冊快捷鍵 (\(label))", "重新注册快捷键 (\(label))", "Re-register Hotkey (\(label))", "ショートカットを再登録 (\(label))")
        }
        static func apiKeyStatus(_ hasKey: Bool) -> String {
            hasKey ? d("API Key 已設定", "API Key 已设置", "API Key Set", "API Key 設定済み")
                   : d("未設定 API Key", "未设置 API Key", "API Key Not Set", "API Key 未設定")
        }
        static func accessibilityStatus(_ authorized: Bool) -> String {
            authorized ? d("輔助使用已授權", "辅助功能已授权", "Accessibility Authorized", "アクセシビリティ許可済み")
                       : d("輔助使用未授權", "辅助功能未授权", "Accessibility Not Authorized", "アクセシビリティ未許可")
        }
    }

    // MARK: - Overlay

    enum Overlay {
        static var processing: String { d("處理中", "处理中", "Processing", "処理中") }
        static var cancelled: String { d("已取消", "已取消", "Cancelled", "キャンセル済み") }
        static var listening: String { d("等待語音...", "等待语音...", "Listening...", "音声待ち...") }
        static var chars: String { d("字", "字", "chars", "文字") }
        static var inject: String { d("輸入", "输入", "Inject", "入力") }
        static var regenerate: String { d("重新生成", "重新生成", "Regenerate", "再生成") }
        static var retry: String { d("重試", "重试", "Retry", "リトライ") }
        static var retrying: String { d("重試中...", "重试中...", "Retrying...", "リトライ中...") }
        // Context menu
        static var promptStyleMenu: String { d("Prompt 風格", "Prompt 风格", "Prompt Style", "プロンプトスタイル") }
        static var toneMenu: String { d("語調", "语调", "Tone", "トーン") }
        static var resetPosition: String { d("重置位置", "重置位置", "Reset Position", "位置をリセット") }
        static var settingsWindowTitle: String { d("Saybit 設定", "Saybit 设置", "Saybit Settings", "Saybit 設定") }
    }

    // MARK: - Onboarding

    enum Onboarding {
        static var title: String { d("Saybit 設定引導", "Saybit 设置引导", "Saybit Setup", "Saybit セットアップ") }
        static func stepOf(_ current: Int, _ total: Int) -> String {
            d("步驟 \(current) / \(total)", "步骤 \(current) / \(total)", "Step \(current) / \(total)", "ステップ \(current) / \(total)")
        }
        // Welcome step
        static var chooseLanguage: String { "Choose your language\n選擇語言 / 选择语言 / 言語を選択" }

        // Permissions step
        static var permissionsTitle: String { d("權限設定", "权限设置", "Permissions", "権限設定") }
        static var permissionsDesc: String { d("Saybit 需要以下權限才能正常運作。\n點擊「開啟設定」後，請在系統設定中允許 Saybit。", "Saybit 需要以下权限才能正常运作。\n点击「打开设置」后，请在系统设置中允许 Saybit。", "Saybit needs the following permissions to work properly.\nClick \"Open Settings\" to grant permissions in System Settings.", "Saybit が正常に動作するには以下の権限が必要です。\n「設定を開く」をクリックしてシステム設定で許可してください。") }
        static var micTitle: String { d("麥克風", "麦克风", "Microphone", "マイク") }
        static var micDesc: String { d("用於錄製語音", "用于录制语音", "For recording your voice", "音声を録音するために使用") }
        static var speechTitle: String { d("語音辨識", "语音识别", "Speech Recognition", "音声認識") }
        static var speechDesc: String { d("將語音轉換為文字", "将语音转换为文字", "Converts speech to text", "音声をテキストに変換") }
        static var accessibilityTitle: String { d("輔助使用", "辅助功能", "Accessibility", "アクセシビリティ") }
        static var accessibilityDesc: String { d("讀取選取文字、注入文字", "读取选取文字、注入文字", "Reads selected text & injects text", "選択テキストの読み取りとテキストの注入") }
        static var recheckPermissions: String { d("重新檢查權限", "重新检查权限", "Recheck Permissions", "権限を再確認") }

        // API Key step
        static var apiKeyTitle: String { d("設定 API Key", "设置 API Key", "Set Up API Key", "API Key を設定") }
        static var apiKeyDesc: String { d("Saybit 使用 AI 處理語音轉文字，需要 API Key 才能運作。", "Saybit 使用 AI 处理语音转文字，需要 API Key 才能运作。", "Saybit uses AI to process speech-to-text and requires an API Key to work.", "Saybit は音声からテキストへの処理に AI を使用し、API Key が必要です。") }
        static var apiKeySaved: String { d("API Key 已儲存", "API Key 已保存", "API Key Saved", "API Key 保存済み") }
        static var getOpenRouterKey: String { d("取得 OpenRouter API Key →", "获取 OpenRouter API Key →", "Get OpenRouter API Key →", "OpenRouter API Key を取得 →") }
        static var getOpenAIKey: String { d("取得 OpenAI API Key →", "获取 OpenAI API Key →", "Get OpenAI API Key →", "OpenAI API Key を取得 →") }
        // Price comparison
        static var priceCompareTitle: String { d("💰 超划算的價格", "💰 超划算的价格", "💰 Super Affordable", "💰 超お得な価格") }
        static var priceCompareDesc: String { d("相比 Wispr Flow（每月 $300）或 Superwhisper（每月 $270），Saybit 使用 API 按量計費，成本極低：", "相比 Wispr Flow（每月 $300）或 Superwhisper（每月 $270），Saybit 使用 API 按量计费，成本极低：", "Compared to Wispr Flow ($10/mo) or Superwhisper ($9/mo), Saybit uses pay-per-use API with ultra-low cost:", "Wispr Flow（月額 $10）や Superwhisper（月額 $9）と比べて、Saybit は従量課金 API を使用し、コストが非常に低いです：") }
        static var pricePerRequest: String { d("每次請求不到 1 分錢", "每次请求不到 1 分钱", "~$0.0002 USD per request", "リクエストごとに 1 分以下") }
        static var priceExample1: String { d("1 塊台幣 ≈ 200 次請求", "1 块台币 ≈ 200 次请求", "$1 USD ≈ 6,000 requests", "1 台湾ドル ≈ 200 リクエスト") }
        static var priceExample2: String { d("100 塊台幣 ≈ 20,000 次請求", "100 块台币 ≈ 20,000 次请求", "$10 USD ≈ 60,000 requests", "100 台湾ドル ≈ 20,000 リクエスト") }
        static var priceExample3: String { d("1,000 塊台幣可用約 200,000 次！", "1,000 块台币可用约 200,000 次！", "$100 USD ≈ 600,000 requests!", "1,000 台湾ドル ≈ 200,000 リクエスト！") }
        static var apiKeyHint: String { d("推薦使用 OpenRouter（支援多種模型）", "推荐使用 OpenRouter（支持多种模型）", "OpenRouter recommended (supports multiple models)", "OpenRouter を推奨（複数のモデルをサポート）") }

        // API Tutorial page
        static var apiTutorialTitle: String { d("超低成本 AI 語音輸入", "超低成本 AI 语音输入", "Ultra-Low Cost AI Voice Input", "超低コスト AI 音声入力") }
        static var apiTutorialDesc: String { d("Saybit 使用 OpenAI GPT-4.1-nano 模型，按量計費，用多少算多少，費用完全自己掌控。", "Saybit 使用 OpenAI GPT-4.1-nano 模型，按量计费，用多少算多少，费用完全自己掌控。", "Saybit uses OpenAI GPT-4.1-nano model with pay-as-you-go pricing. You only pay for what you use.", "Saybit は OpenAI GPT-4.1-nano モデルを使用し、従量課金制で、使った分だけお支払い。") }
        static var apiTutorialCompare: String { d("相比其他語音輸入產品（Wispr Flow $10/月、Superwhisper $9/月），Saybit 成本可低至：", "相比其他语音输入产品（Wispr Flow $10/月、Superwhisper $9/月），Saybit 成本可低至：", "Compared to other voice input products (Wispr Flow $10/mo, Superwhisper $9/mo), Saybit costs as low as:", "他の音声入力製品（Wispr Flow $10/月、Superwhisper $9/月）と比較して、Saybit のコストは：") }
        static var apiTutorialPrice1: String { d("每次請求不到 1 分錢", "每次请求不到 1 分钱", "~$0.0002 USD per request", "リクエストごとに 1 分以下") }
        static var apiTutorialPrice2: String { d("NT$1 ≈ 200 次請求", "NT$1 ≈ 200 次请求", "$1 USD ≈ 6,000 requests", "NT$1 ≈ 200 リクエスト") }
        static var apiTutorialPrice3: String { d("NT$100 ≈ 20,000 次請求", "NT$100 ≈ 20,000 次请求", "$10 USD ≈ 60,000 requests", "NT$100 ≈ 20,000 リクエスト") }
        static var apiTutorialPrice4: String { d("US$5 可以用超久！", "US$5 可以用超久！", "$5 USD lasts a very long time!", "US$5 で超長持ち！") }
        static var apiTutorialGetKey: String { d("取得 API Key（免費註冊）", "获取 API Key（免费注册）", "Get API Key (Free signup)", "API Key を取得（無料登録）") }

        // Test step
        static var readyTitle: String { d("準備完成！", "准备完成！", "All Set!", "準備完了！") }
        static var readyDesc: String { d("測試 API 連線是否正常，確認一切就緒。", "测试 API 连接是否正常，确认一切就绪。", "Test the API connection to make sure everything works.", "API 接続をテストして、すべてが正常に動作することを確認します。") }
        static var testing: String { d("測試中...", "测试中...", "Testing...", "テスト中...") }
        static var testAPI: String { d("測試 API 連線", "测试 API 连接", "Test API Connection", "API 接続をテスト") }
        static var testSuccess: String { d("✓ API 連線成功", "✓ API 连接成功", "✓ API Connected", "✓ API 接続成功") }
        static var continueTutorial: String { d("繼續教學", "继续教程", "Continue to Tutorial", "チュートリアルへ進む") }
    }

    // MARK: - Tutorial

    enum Tutorial {
        static var title: String { d("如何使用 Saybit", "如何使用 Saybit", "How to Use Saybit", "Saybit の使い方") }

        // Page 1: Hotkey
        static var hotkeyTitle: String { d("語音輸入快捷鍵", "语音输入快捷键", "Voice Input Hotkey", "音声入力ショートカット") }
        static var hotkeyDesc: String { d("使用快捷鍵隨時啟動語音輸入，在任何應用程式中都能使用。", "使用快捷键随时启动语音输入，在任何应用程序中都能使用。", "Use the hotkey to activate voice input anytime, in any application.", "ショートカットキーでいつでも音声入力を起動。どのアプリでも使えます。") }
        static var currentHotkey: String { d("目前快捷鍵", "当前快捷键", "Current Hotkey", "現在のショートカット") }

        // Page 2: Modes
        static var modesTitle: String { d("三種處理模式", "三种处理模式", "Three Processing Modes", "3つの処理モード") }
        static var modesDesc: String { d("根據不同需求選擇合適的模式。", "根据不同需求选择合适的模式。", "Choose the right mode for your needs.", "ニーズに合ったモードを選択してください。") }
        static var dictationName: String { d("聽寫", "听写", "Dictation", "ディクテーション") }
        static var dictationDesc: String { d("自然說話，獲得乾淨的文字", "自然说话，获得干净的文字", "Speak naturally, get clean text", "自然に話して、きれいなテキストを取得") }
        static var commandName: String { d("指令", "指令", "Command", "コマンド") }
        static var commandDesc: String { d("對 AI 下達指令", "对 AI 下达指令", "Give instructions to AI", "AI に指示を出す") }
        static var editName: String { d("編輯", "编辑", "Edit", "編集") }
        static var editDesc: String { d("先選取文字，再用語音修改", "先选取文字，再用语音修改", "Select text first, then speak to modify", "テキストを選択してから音声で修正") }

        // Page 3: Context & Preview
        static var contextTitle: String { d("智慧功能", "智慧功能", "Smart Features", "スマート機能") }
        static var contextFeature: String { d("上下文感知", "上下文感知", "Context Awareness", "コンテキスト認識") }
        static var contextFeatureDesc: String { d("在任何 App 選取文字，Saybit 會自動讀取作為上下文", "在任何 App 选取文字，Saybit 会自动读取作为上下文", "Select text in any app — Saybit reads it as context", "任意のアプリでテキストを選択すると、Saybit がコンテキストとして読み取ります") }
        static var previewFeature: String { d("注入前預覽", "注入前预览", "Preview Before Inject", "注入前プレビュー") }
        static var previewFeatureDesc: String { d("啟用後，處理完成的文字會先顯示預覽，確認後再注入", "启用后，处理完成的文字会先显示预览，确认后再注入", "When enabled, processed text is previewed before injection", "有効にすると、処理済みテキストが注入前にプレビューされます") }

        // Page 4: Smart Send & Skills
        static var advancedTitle: String { d("進階功能", "进阶功能", "Advanced Features", "高度な機能") }
        static var smartSendFeature: String { "Smart Send" }
        static var smartSendDesc: String { d("文字注入後自動倒數，時間到自動按下 Enter 送出。說話可取消倒數。", "文字注入后自动倒数，时间到自动按下 Enter 发送。说话可取消倒数。", "Auto-countdown after text injection, then auto-presses Enter. Speaking cancels the countdown.", "テキスト注入後に自動カウントダウンし、Enter を自動送信。話すとカウントダウンがキャンセルされます。") }
        static var voiceSkills: String { d("語音技能", "语音技能", "Voice Skills", "ボイススキル") }
        static var voiceSkillsDesc: String { d("設定觸發詞來載入自訂 Prompt，例如說「寫信」自動切換到書信格式。", "设定触发词来载入自定义 Prompt，例如说「写信」自动切换到书信格式。", "Set trigger words to load custom prompts. Say \"write email\" to auto-switch to letter format.", "トリガーワードでカスタムプロンプトを読み込みます。「メール作成」と言うとレター形式に自動切り替え。") }

        // Action Intents
        static var actionIntents: String { d("行事曆 / 備忘錄", "日历 / 提醒", "Calendar / Reminders", "カレンダー / リマインダー") }
        static var actionIntentsDesc: String { d("說「幫我排明天下午3點的會議」直接建立行程，或「提醒我下週一交報告」建立提醒事項。", "说「帮我排明天下午3点的会议」直接创建日程，或「提醒我下周一交报告」创建提醒事项。", "Say \"Schedule a meeting tomorrow at 3pm\" to create an event, or \"Remind me to submit report next Monday\" for reminders.", "「明日午後3時に会議を入れて」でイベント作成、「月曜にレポート提出をリマインド」でリマインダー作成。") }

        // Page 5: Quick Reference
        static var quickRefTitle: String { d("快速參考", "快速参考", "Quick Reference", "クイックリファレンス") }
        static var quickRefDesc: String { d("記住這些要點，馬上開始使用 Saybit！", "记住这些要点，马上开始使用 Saybit！", "Remember these key points and start using Saybit!", "これらのポイントを覚えて、Saybit を使い始めましょう！") }
        static var tipHotkey: String { d("按快捷鍵開始語音輸入", "按快捷键开始语音输入", "Press hotkey to start voice input", "ショートカットで音声入力開始") }
        static var tipModes: String { d("三種模式：聽寫、指令、編輯", "三种模式：听写、指令、编辑", "Three modes: Dictation, Command, Edit", "3つのモード：ディクテーション、コマンド、編集") }
        static var tipContext: String { d("選取文字可作為 AI 上下文", "选取文字可作为 AI 上下文", "Select text to use as AI context", "テキストを選択して AI コンテキストに") }
        static var tipOverlay: String { d("右鍵點擊膠囊可快速切換設定", "右键点击胶囊可快速切换设置", "Right-click the capsule for quick settings", "カプセルを右クリックで素早く設定変更") }
        static var tipActionIntents: String { d("語音建立行事曆和備忘錄", "语音创建日历和提醒", "Create calendar events & reminders by voice", "音声でカレンダーとリマインダーを作成") }

        // Page: Practice
        static var practiceTitle: String { d("實際操作練習", "实际操作练习", "Hands-on Practice", "実践練習") }
        static var practiceDesc: String { d("跟著以下稿子念，體驗 Saybit 的核心功能。按下快捷鍵後開始說話！", "跟着以下稿子念，体验 Saybit 的核心功能。按下快捷键后开始说话！", "Follow the scripts below to experience Saybit's core features. Press the hotkey and start speaking!", "以下のスクリプトに沿って話し、Saybit のコア機能を体験しましょう。ショートカットを押して話し始めてください！") }
        static var practiceStep: String { d("練習", "练习", "Practice", "練習") }

        // Practice scripts
        static var practice1Title: String { d("基本聽寫", "基本听写", "Basic Dictation", "基本ディクテーション") }
        static var practice1Script: String { d("「今天天氣真好，我想出去走走。」", "「今天天气真好，我想出去走走。」", "\"The weather is nice today, I want to go for a walk.\"", "「今日はいい天気ですね、散歩に行きたいです。」") }
        static var practice1Hint: String { d("直接說話，Saybit 會自動去除贅詞並整理文字", "直接说话，Saybit 会自动去除赘词并整理文字", "Just speak naturally, Saybit will clean up filler words", "自然に話すだけで、Saybit が冗長な言葉を削除します") }

        static var practice2Title: String { d("翻譯指令", "翻译指令", "Translation Command", "翻訳コマンド") }
        static var practice2Script: String { d("「翻譯成英文」", "「翻译成英文」", "\"Translate to English\"", "「英語に翻訳」") }
        static var practice2Hint: String { d("⚠️ 先用滑鼠框選下方「歡迎使用 Saybit」文字，再按快捷鍵說話", "⚠️ 先用鼠标框选下方「欢迎使用 Saybit」文字，再按快捷键说话", "⚠️ First select \"Welcome to Saybit\" below, then press hotkey and speak", "⚠️ まず下の「Saybit へようこそ」を選択し、ショートカットを押して話してください") }
        static var practice2DefaultText: String { d("歡迎使用 Saybit", "欢迎使用 Saybit", "Welcome to Saybit", "Saybit へようこそ") }
        static var practice2SelectHint: String { d("👆 請先框選上方文字", "👆 请先框选上方文字", "👆 Select the text above first", "👆 上のテキストを選択してください") }

        static var practice3Title: String { d("建立行程", "创建日程", "Create Event", "イベント作成") }
        static var practice3Script: String { d("「幫我排明天下午三點開會」", "「帮我排明天下午三点开会」", "\"Schedule a meeting tomorrow at 3pm\"", "「明日午後3時に会議を入れて」") }
        static var practice3Hint: String { d("Saybit 會自動建立行事曆事件", "Saybit 会自动创建日历事件", "Saybit will create a calendar event automatically", "Saybit が自動でカレンダーイベントを作成します") }

        static var practice4Title: String { d("建立提醒", "创建提醒", "Create Reminder", "リマインダー作成") }
        static var practice4Script: String { d("「提醒我明天早上九點吃藥」", "「提醒我明天早上九点吃药」", "\"Remind me to take medicine at 9am tomorrow\"", "「明日朝9時に薬を飲むのをリマインドして」") }
        static var practice4Hint: String { d("Saybit 會自動建立備忘錄提醒", "Saybit 会自动创建提醒事项", "Saybit will create a reminder automatically", "Saybit が自動でリマインダーを作成します") }

        static var practiceReady: String { d("準備好了嗎？", "准备好了吗？", "Ready?", "準備はいいですか？") }
        static var practiceTryIt: String { d("按下快捷鍵試試看！", "按下快捷键试试看！", "Press the hotkey and try it!", "ショートカットを押して試してみましょう！") }
        static var practiceSuccess: String { d("太棒了！你已經學會使用 Saybit 了 🎉", "太棒了！你已经学会使用 Saybit 了 🎉", "Awesome! You've learned how to use Saybit 🎉", "素晴らしい！Saybit の使い方を学びました 🎉") }
        static var practiceInputPlaceholder: String { d("點擊此處，然後按快捷鍵說話，結果會顯示在這裡...", "点击此处，然后按快捷键说话，结果会显示在这里...", "Click here, press the hotkey and speak. Results will appear here...", "ここをクリックし、ショートカットを押して話してください。結果がここに表示されます...") }
        static var practiceInputHint: String { d("👆 先點擊上方輸入框，再按快捷鍵開始說話", "👆 先点击上方输入框，再按快捷键开始说话", "👆 Click the input box above, then press the hotkey to speak", "👆 上の入力欄をクリックしてから、ショートカットを押して話してください") }
        static var practiceInputClear: String { d("清除", "清除", "Clear", "クリア") }
    }

    // MARK: - Errors (used in VoicePipeline)

    enum Errors {
        static func noAPIKey(_ provider: String) -> String {
            d("未設定 \(provider) API Key，請在設定中輸入", "未设置 \(provider) API Key，请在设置中输入", "\(provider) API Key not set. Please enter it in Settings.", "\(provider) API Key が未設定です。設定で入力してください。")
        }
        static var noWhisperKey: String { d("未設定 Whisper API Key，請在設定中輸入", "未设置 Whisper API Key，请在设置中输入", "Whisper API Key not set. Please enter it in Settings.", "Whisper API Key が未設定です。設定で入力してください。") }
        static var llmNoResponse: String { d("LLM 未回傳任何文字", "LLM 未返回任何文字", "LLM returned no text", "LLM がテキストを返しませんでした") }
        static var invalidAPIKey: String { d("API Key 無效", "API Key 无效", "Invalid API Key", "API Key が無効です") }
        static var insufficientBalance: String { d("API 餘額不足", "API 余额不足", "Insufficient API balance", "API残高不足です") }
        static var rateLimited: String { d("API 請求過於頻繁，請稍後再試", "API 请求过于频繁，请稍后再试", "Too many API requests. Please try again later.", "APIリクエストが多すぎます。しばらくしてから再試行してください。") }
        static var serverUnavailable: String { d("伺服器暫時不可用", "服务器暂时不可用", "Server temporarily unavailable", "サーバーが一時的に利用できません") }
        static func apiError(_ code: Int) -> String { d("API 錯誤 (\(code))", "API 错误 (\(code))", "API error (\(code))", "APIエラー (\(code))") }
        static var decodingError: String { d("回應解析失敗", "响应解析失败", "Failed to parse response", "レスポンスの解析に失敗しました") }
        static var networkError: String { d("網路連線失敗", "网络连接失败", "Network connection failed", "ネットワーク接続に失敗しました") }
        static func retriesExhausted(_ attempts: Int, _ code: Int) -> String {
            d("重試 \(attempts) 次仍失敗 (HTTP \(code))", "重试 \(attempts) 次仍失败 (HTTP \(code))", "Failed after \(attempts) retries (HTTP \(code))", "\(attempts)回リトライしても失敗 (HTTP \(code))")
        }

        // Action Intents
        static var actionJsonParseFailed: String { d("動作資料解析失敗", "动作数据解析失败", "Failed to parse action data", "アクションデータの解析に失敗しました") }
        static var invalidDateFormat: String { d("日期格式錯誤", "日期格式错误", "Invalid date format", "日付フォーマットが無効です") }
        static func actionPermissionDenied(_ type: String) -> String {
            d("\(type)權限未授權", "\(type)权限未授权", "\(type) permission not authorized", "\(type)の権限が未許可です")
        }
        static func actionCreationFailed(_ msg: String) -> String {
            d("建立失敗：\(msg)", "创建失败：\(msg)", "Creation failed: \(msg)", "作成に失敗：\(msg)")
        }
        static func actionExecutionFailed(_ msg: String) -> String {
            d("動作執行失敗：\(msg)", "动作执行失败：\(msg)", "Action failed: \(msg)", "アクション実行に失敗：\(msg)")
        }
    }

    // MARK: - Enum Display Names

    static func processingMode(_ mode: ProcessingMode) -> String {
        switch mode {
        case .dictation: return d("聽寫", "听写", "Dictation", "ディクテーション")
        case .command: return d("指令", "指令", "Command", "コマンド")
        case .edit: return d("編輯", "编辑", "Edit", "編集")
        }
    }

    static func toneStyle(_ tone: ToneStyle) -> String {
        switch tone {
        case .auto: return d("自動", "自动", "Auto", "自動")
        case .formal: return d("正式", "正式", "Formal", "フォーマル")
        case .casual: return d("口語", "口语", "Casual", "カジュアル")
        case .veryCasual: return d("很口語", "很口语", "Very Casual", "とてもカジュアル")
        }
    }

    static func hotkeyTriggerMode(_ mode: HotkeyTriggerMode) -> String {
        switch mode {
        case .toggle: return d("按一下觸發", "按一下触发", "Toggle", "トグル")
        case .hold: return d("按住說話", "按住说话", "Hold to Talk", "押し続けて話す")
        case .doubleTap: return d("雙擊觸發", "双击触发", "Double Tap", "ダブルタップ")
        }
    }

    static func hotkeyTriggerModeDesc(_ mode: HotkeyTriggerMode) -> String {
        switch mode {
        case .toggle: return d("按一下開始錄音，說完後自動停止（2 秒靜音）", "按一下开始录音，说完后自动停止（2 秒静音）", "Tap once to start recording, auto-stops after 2s silence", "1回タップで録音開始、2秒の無音で自動停止")
        case .hold: return d("按住開始錄音，放開停止", "按住开始录音，放开停止", "Hold to record, release to stop", "押し続けて録音、離すと停止")
        case .doubleTap: return d("快速雙擊快捷鍵開始錄音，再雙擊停止", "快速双击快捷键开始录音，再双击停止", "Double-tap to start, double-tap again to stop", "ダブルタップで録音開始、もう一度ダブルタップで停止")
        }
    }

    static func sttEngine(_ engine: STTEngine) -> String {
        switch engine {
        case .appleSpeech: return d("Apple Speech (本地)", "Apple Speech (本地)", "Apple Speech (Local)", "Apple Speech (ローカル)")
        case .whisperAPI: return d("Whisper API (雲端)", "Whisper API (云端)", "Whisper API (Cloud)", "Whisper API (クラウド)")
        }
    }

    static func injectionMode(_ mode: InjectionMode) -> String {
        switch mode {
        case .paste: return d("貼上 (Cmd+V)", "粘贴 (Cmd+V)", "Paste (Cmd+V)", "ペースト (Cmd+V)")
        case .keypress: return d("逐字輸入", "逐字输入", "Keypress", "キー入力")
        case .replaceSelection: return d("取代選取", "替换选中", "Replace Selection", "選択を置換")
        }
    }

    static func modeUsageDisplayName(_ mode: String) -> String {
        switch mode {
        case "dictation": return processingMode(.dictation)
        case "command": return processingMode(.command)
        case "edit": return processingMode(.edit)
        default: return mode
        }
    }

    // MARK: - Update Check (About)

    enum Update {
        static var checkButton: String { d("檢查更新", "检查更新", "Check for Updates", "アップデートを確認") }
        static var viewRelease: String { d("查看新版", "查看新版", "View Release", "リリースを見る") }
        static func upToDate(_ v: String) -> String {
            d("已是最新版本（v\(v)）", "已是最新版本（v\(v)）", "You're on the latest version (v\(v))", "最新バージョンです (v\(v))")
        }
        static func newer(latest: String, current: String) -> String {
            d("發現新版 \(latest)（目前 v\(current)）",
              "发现新版 \(latest)（当前 v\(current)）",
              "New version available: \(latest) (current v\(current))",
              "新バージョン \(latest) があります（現在 v\(current)）")
        }
        static func ahead(current: String, remote: String) -> String {
            d("本地 v\(current) 比遠端 v\(remote) 新（dev build）",
              "本地 v\(current) 比远端 v\(remote) 新（dev build）",
              "Local v\(current) is ahead of remote v\(remote) (dev build)",
              "ローカル v\(current) がリモート v\(remote) より新しい（開発ビルド）")
        }
    }

    // MARK: - API: list models button (cloud chips)

    enum APIModels {
        static var listButton: String { d("列出模型", "列出模型", "List Models", "モデル一覧") }
        static var searchPlaceholder: String { d("搜尋模型…", "搜索模型…", "Search models…", "モデルを検索…") }
        static func count(_ n: Int) -> String {
            d("共 \(n) 個模型", "共 \(n) 个模型", "\(n) models", "\(n) モデル")
        }
        static func filteredCount(query: String, total: Int, matched: Int) -> String {
            d("共 \(total) 個模型，符合「\(query)」共 \(matched) 個",
              "共 \(total) 个模型，匹配「\(query)」共 \(matched) 个",
              "\(total) models · \(matched) match \"\(query)\"",
              "\(total) モデル · \"\(query)\" に一致 \(matched) 件")
        }
        static var emptyResponse: String { d("服務商未回傳任何模型", "服务商未返回任何模型", "Provider returned no models", "プロバイダーがモデルを返しませんでした") }
        static func fetchFailed(_ msg: String) -> String {
            d("抓取失敗：\(msg)", "抓取失败：\(msg)", "Fetch failed: \(msg)", "取得失敗：\(msg)")
        }
    }

    // MARK: - Cost / Statistics

    enum Cost {
        static var totalEstimate: String { d("累計成本估算", "累计成本估算", "Estimated Total Cost", "累計コスト推定") }
        static func unknownIgnored(_ n: Int) -> String {
            d("\(n) 筆未知模型已忽略", "\(n) 条未知模型已忽略", "\(n) records with unknown model ignored", "\(n) 件の未知モデルを除外")
        }
        static func perRecord(_ formatted: String) -> String {
            d("估算成本：\(formatted)", "估算成本：\(formatted)", "Est. cost: \(formatted)", "推定コスト：\(formatted)")
        }
    }

    // MARK: - History export

    enum Export {
        static var menuLabel: String { d("匯出", "导出", "Export", "エクスポート") }
        static var asJSON: String { d("匯出為 JSON", "导出为 JSON", "Export as JSON", "JSON でエクスポート") }
        static var asMarkdown: String { d("匯出為 Markdown", "导出为 Markdown", "Export as Markdown", "Markdown でエクスポート") }
        static var asCSV: String { d("匯出為 CSV", "导出为 CSV", "Export as CSV", "CSV でエクスポート") }
        static var savePanelTitle: String { d("匯出歷史紀錄", "导出历史记录", "Export History", "履歴をエクスポート") }
    }

    // MARK: - Private Helper

    private static func d(_ zhTW: String, _ zhCN: String, _ en: String, _ ja: String) -> String {
        switch lang {
        case .zhTW: return zhTW
        case .zhCN: return zhCN
        case .en: return en
        case .ja: return ja
        }
    }
}
// swiftlint:enable type_body_length file_length
