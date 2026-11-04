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
        static var reportIssue: String { d("回報問題", "反馈问题", "Report Issue", "問題を報告") }
        static var description: String { d("智慧語音輸入助手，將語音轉換為精準文字，支援聽寫、指令與編輯模式。", "智能语音输入助手，将语音转换为精准文字，支持听写、指令与编辑模式。", "Smart voice input assistant that converts speech to precise text. Supports dictation, command, and edit modes.", "スマート音声入力アシスタント。音声を正確なテキストに変換し、ディクテーション、コマンド、編集モードをサポートします。") }
        static var priceTitle: String { d("超低成本，用多少算多少", "超低成本，用多少算多少", "Ultra-low cost, pay as you go", "超低コスト、使った分だけ") }
        static var priceDesc: String { d("使用 GPT-4.1-nano，每次請求不到 1 分錢。相比訂閱制產品（$9-10/月），US$5 可用超久！", "使用 GPT-4.1-nano，每次请求不到 1 分钱。相比订阅制产品（$9-10/月），US$5 可用超久！", "Uses GPT-4.1-nano, ~$0.0002/request. Compared to subscriptions ($9-10/mo), $5 lasts forever!", "GPT-4.1-nano 使用、1 リクエストあたり約 0.03 円。サブスク（月額 $9-10）と比べ、US$5 で超長持ち！") }
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
        static var clearSearch: String { d("清除搜尋", "清除搜索", "Clear Search", "検索をクリア") }
    }

    // MARK: - Tabs

    enum Tabs {
        static var groupSettings: String { d("設定", "设置", "Settings", "設定") }
        static var groupTools: String { d("工具", "工具", "Tools", "ツール") }
        static var groupData: String { d("紀錄", "记录", "Data", "記録") }
        static var general: String { d("一般", "通用", "General", "一般") }
        static var ai: String { d("AI 引擎", "AI 引擎", "AI Engine", "AIエンジン") }
        static var hotkey: String { d("快捷鍵", "快捷键", "Hotkey", "ショートカット") }
        static var dictionary: String { d("字典 / 技能", "字典 / 技能", "Dictionary / Skills", "辞書 / スキル") }
        static var history: String { d("歷史", "历史", "History", "履歴") }
        static var statistics: String { d("統計", "统计", "Statistics", "統計") }
        static var logs: String { d("日誌", "日志", "Logs", "ログ") }
        static var transcribe: String { d("檔案轉錄", "文件转录", "File Transcription", "ファイル文字起こし") }
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

        // Sections
        static var sectionRecording: String { d("錄音", "录音", "Recording", "録音") }
        static var sectionRecognition: String { d("語音辨識", "语音识别", "Speech Recognition", "音声認識") }
        static var sectionAI: String { d("AI 理解", "AI 理解", "AI Understanding", "AI の理解") }
        static var sectionOutput: String { d("輸出", "输出", "Output", "出力") }
        static var sectionInterface: String { d("介面", "界面", "Interface", "インターフェース") }
        static var sectionSystem: String { d("系統", "系统", "System", "システム") }
        static var screenContext: String { d("讀取螢幕內容", "读取屏幕内容", "Use Screen Content", "画面の内容を使用") }
        static var screenContextDesc: String { d("錄音時辨識前景視窗上的文字給 AI 參考，人名與專有名詞會拼得更準。截圖只在本機辨識；辨識出的文字會隨你的語音一起送到所選的 AI 服務（Apple 本機模型除外）。", "录音时识别前台窗口上的文字给 AI 参考，人名与专有名词会拼得更准。截图只在本机识别；识别出的文字会随你的语音一起发送到所选的 AI 服务（Apple 本机模型除外）。", "Reads text in the front window so the AI spells names and terms right. The screenshot is recognized on this Mac only; the recognized text is sent along with your speech to the selected AI service (except Apple's on-device model).", "録音中に前面のウィンドウの文字を認識して AI の参考にし、人名や固有名詞をより正確にします。スクリーンショットはこの Mac 上でのみ認識しますが、認識した文字は音声と一緒に選択中の AI サービスへ送信されます（Apple のオンデバイスモデルを除く）。") }
        static var grantScreenRecording: String { d("授權螢幕錄製", "授权屏幕录制", "Grant Screen Recording", "画面収録を許可") }
        static var screenRecording: String { d("螢幕錄製", "屏幕录制", "Screen Recording", "画面収録") }
        static var ducking: String { d("錄音時降低系統音量", "录音时降低系统音量", "Lower System Volume While Recording", "録音中にシステム音量を下げる") }
        static var duckingDesc: String { d("把音樂、影片等聲音降到 20%，錄完自動恢復", "把音乐、视频等声音降到 20%，录完自动恢复", "Lowers music and video to 20%, restored when recording ends", "音楽や動画の音量を 20% に下げ、録音後に戻します") }
        static var voiceBandpass: String { d("人聲降噪", "人声降噪", "Voice Noise Filter", "音声ノイズフィルター") }
        static var voiceBandpassDesc: String { d("只保留 80Hz–8kHz 的人聲頻段，濾掉風扇、電源嗡嗡聲與高頻雜音", "只保留 80Hz–8kHz 的人声频段，滤掉风扇、电源嗡嗡声与高频杂音", "Keeps the 80 Hz–8 kHz voice band, filtering fan hum and hiss", "80Hz–8kHz の音声帯域のみを残し、ファンやハム音を除去") }
        static var echoCancellation: String { d("回音消除", "回声消除", "Echo Cancellation", "エコーキャンセル") }
        static var echoCancellationDesc: String { d("邊播放聲音邊講話時，消除喇叭漏進麥克風的音樂、影片與通話聲。戴耳機可關閉，切換時收音會短暫重啟。", "边播放声音边讲话时，消除扬声器漏进麦克风的音乐、视频与通话声。戴耳机可关闭，切换时收音会短暂重启。", "Removes speaker audio leaking into the mic. Not needed with headphones; toggling briefly restarts capture.", "スピーカーからマイクへ漏れる音を除去します。ヘッドホン使用時は不要です。") }
        static var continuousSTTDesc: String { d("辨識在背景持續運行，按下快捷鍵時不會漏掉開頭的字。會多用一點 CPU。", "识别在背景持续运行，按下快捷键时不会漏掉开头的字。会多用一点 CPU。", "Keeps recognition running so the first words are never cut off. Uses a bit more CPU.", "認識をバックグラウンドで継続し、話し始めの欠落を防ぎます。") }
        static var requiredBadge: String { d("必要", "必要", "Required", "必須") }
        static var speechRecognition: String { d("語音辨識", "语音识别", "Speech Recognition", "音声認識") }
        static var deviceUnavailable: String { d("已選的裝置目前未連接", "已选的设备当前未连接", "Selected device is not connected", "選択したデバイスは未接続です") }
        static var contextRulesEmpty: String { d("還沒有規則。按「新增規則」為特定 App 指定語氣與額外指令。", "还没有规则。点「新增规则」为特定 App 指定语气与额外指令。", "No rules yet. Click \"Add Rule\" to set a tone and extra instructions for a specific app.", "ルールはまだありません。「ルールを追加」で特定アプリのトーンと追加指示を設定できます。") }
        static var expand: String { d("展開", "展开", "Expand", "展開") }
        static var screenRecordingMissing: String { d("尚未取得「螢幕錄製」權限，這個功能目前不會作用。", "尚未取得「屏幕录制」权限，这个功能目前不会生效。", "Screen Recording permission is missing, so this has no effect yet.", "画面収録の権限がないため、まだ機能しません。") }
        static var tutorialDesc: String { d("重新看一次快捷鍵與基本操作說明", "重新看一次快捷键与基本操作说明", "Walk through the hotkey and basics again", "ホットキーと基本操作をもう一度確認") }

        // Features
        static var features: String { d("功能", "功能", "Features", "機能") }
        static var contextAwareness: String { d("讀取選取的文字", "读取选中的文字", "Use Selected Text", "選択テキストを使用") }
        static var contextAwarenessDesc: String { d("錄音時若有選取文字，AI 會把它當上下文，可以口頭指示「改寫這段」「翻成英文」", "录音时若有选中文字，AI 会把它当上下文，可以口头指示「改写这段」「翻成英文」", "Selected text is sent as context, so you can say \"rewrite this\" or \"translate to English\"", "選択中のテキストをコンテキストとして使い、「書き直して」などの音声指示が可能") }
        static var soundFeedback: String { d("音效回饋", "音效反馈", "Sound Feedback", "サウンドフィードバック") }
        static var whisperMode: String { d("嘈雜環境模式", "嘈杂环境模式", "Noisy Environment Mode", "騒がしい環境モード") }
        static var whisperModeDesc: String { d("提醒 AI 忽略辨識到的背景人聲與雜訊，只保留你說的內容", "提醒 AI 忽略识别到的背景人声与杂讯，只保留你说的内容", "Tells the AI to drop background chatter and noise picked up by recognition", "認識された背景の声やノイズを AI に無視させます") }
        static var continuousBackgroundSTT: String { d("持續背景辨識", "持续背景识别", "Continuous Background Recognition", "継続的バックグラウンド認識") }

        // STT Engine
        static var sttEngine: String { d("語音辨識引擎", "语音识别引擎", "Speech Recognition Engine", "音声認識エンジン") }
        static var sttEnginePicker: String { d("辨識引擎", "识别引擎", "Engine", "エンジン") }
        static var whisperAPIKey: String { "Whisper API Key" }
        static var whisperDesc: String { d("使用 OpenAI Whisper API 進行語音辨識，辨識準確度更高，但需網路連線且會產生 API 費用", "使用 OpenAI Whisper API 进行语音识别，识别准确度更高，但需网络连接且会产生 API 费用", "Uses OpenAI Whisper API for speech recognition. Higher accuracy but requires internet and incurs API costs.", "OpenAI Whisper API を使用した音声認識。精度は高いですが、ネット接続と API 費用が必要です。") }
        static var onDeviceSTT: String { d("僅在本機辨識", "仅在本机识别", "On-Device Only", "デバイス上のみで認識") }
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
        static var enableAutoStop: String { d("說完自動停止", "说完自动停止", "Stop When I Stop Talking", "話し終えたら自動停止") }
        static var silenceTimeout: String { d("靜音等待時間", "静音等待时间", "Silence Timeout", "無音待機時間") }
        static var silenceAutoStopDesc: String { d("說完話後等待此時間未偵測到聲音即自動結束錄音", "说完话后等待此时间未检测到声音即自动结束录音", "Automatically stops recording after this duration of silence", "この時間無音が続くと自動的に録音を停止します") }

        // Preview & Send
        // Injection Mode
        static var injectionMode: String { d("注入方式", "注入方式", "Injection Mode", "注入モード") }
        static var injectionModeDesc: String { d("選擇文字注入到目標 App 的方式", "选择文字注入到目标 App 的方式", "Choose how text is injected into the target app", "テキストの注入方法を選択") }

        // Preview & Send
        static var previewAndSend: String { d("預覽與送出", "预览与发送", "Preview & Send", "プレビューと送信") }
        static var previewBeforeInject: String { d("注入前預覽", "注入前预览", "Preview Before Inject", "注入前プレビュー") }
        static var enablePreview: String { d("輸入前先預覽", "输入前先预览", "Preview Before Inject", "注入前にプレビュー") }
        static var previewDesc: String { d("LLM 處理完成後先顯示預覽，手動確認後再注入文字", "LLM 处理完成后先显示预览，手动确认后再注入文字", "Shows a preview after LLM processing. Manually confirm before injecting text.", "LLM 処理完了後にプレビューを表示し、手動確認後にテキストを注入します。") }

        // Smart Send
        static var smartSend: String { d("智慧送出", "智能发送", "Smart Send", "スマート送信") }
        static var enableSmartSend: String { d("智慧送出", "智能发送", "Smart Send", "スマート送信") }
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
        static var accessibility: String { d("輔助使用", "辅助功能", "Accessibility", "アクセシビリティ") }
        static var microphone: String { d("麥克風", "麦克风", "Microphone", "マイク") }
        static var automation: String { d("自動化", "自动化", "Automation", "オートメーション") }
        static var reminders: String { d("提醒事項", "提醒事项", "Reminders", "リマインダー") }
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
        static var serverAddress: String { d("伺服器位址", "服务器地址", "Server Address", "サーバーアドレス") }
        static var apiKeyOptional: String { d("API Key（選填）", "API Key（选填）", "API Key (optional)", "API Key（任意）") }
        static var lmStudioHint: String { d("連接 LM Studio 本地伺服器，支援所有 OpenAI 相容模型。", "连接 LM Studio 本地服务器，支持所有 OpenAI 兼容模型。", "Connects to a local LM Studio server; works with any OpenAI-compatible model.", "LM Studio のローカルサーバーに接続します。OpenAI 互換モデルすべてに対応。") }
        static var appleAvailable: String { d("Apple Intelligence 本機模型可用", "Apple Intelligence 本机模型可用", "Apple Intelligence on-device model is available", "Apple Intelligence のオンデバイスモデルが利用可能") }
        static var appleDesc: String { d("完全在這台 Mac 上處理，不連網、不需 API Key、不收費。搭配 SenseVoice 離線辨識時整條流程都是離線的。本機模型較小，複雜指令（翻譯長文、寫信）品質不如雲端模型。", "完全在这台 Mac 上处理，不联网、不需 API Key、不收费。搭配 SenseVoice 离线识别时整条流程都是离线的。本机模型较小，复杂指令（翻译长文、写信）质量不如云端模型。", "Runs entirely on this Mac: no network, no API key, no cost. Paired with SenseVoice offline recognition, the whole pipeline is offline. The on-device model is small, so complex instructions (long translations, emails) are weaker than cloud models.", "この Mac 上だけで処理し、通信・API Key・料金は不要です。SenseVoice のオフライン認識と組み合わせれば全工程がオフラインになります。モデルが小さいため、複雑な指示（長文翻訳、メール作成）はクラウドモデルに劣ります。") }
        static var invalidURL: String { d("網址格式不正確", "网址格式不正确", "Invalid URL", "URL の形式が正しくありません") }
        static var insecureURLWarning: String { d("只有本機或區域網路位址（localhost、127.x、10.x、172.16–31.x、192.168.x、*.local）可以用 http://；其他端點請改用 https://，否則 API Key 會以明文傳送。", "只有本机或局域网地址（localhost、127.x、10.x、172.16–31.x、192.168.x、*.local）可以用 http://；其他端点请改用 https://，否则 API Key 会以明文传送。", "http:// is only allowed for local or LAN addresses (localhost, 127.x, 10.x, 172.16–31.x, 192.168.x, *.local). Use https:// for other endpoints, or your API key would be sent in plain text.", "http:// はローカルまたは LAN アドレス（localhost、127.x、10.x、172.16–31.x、192.168.x、*.local）のみ使用できます。それ以外は https:// を使用してください。API Key が平文で送信されてしまいます。") }
        static var localHTTPNote: String { d("這是本機 / 區網的 http:// 端點，API Key 不會加密傳送。", "这是本机 / 局域网的 http:// 端点，API Key 不会加密传送。", "This is a local/LAN http:// endpoint; the API key is not encrypted in transit.", "ローカル / LAN の http:// エンドポイントです。API Key は暗号化されずに送信されます。") }

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
        static var dictDesc: String { d("辨識常出錯的詞：辨識完會直接換成偏好寫法，Apple 辨識也會優先認出這些詞。按 Enter 新增。", "识别常出错的词：识别完会直接换成偏好写法，Apple 识别也会优先认出这些词。按 Enter 新增。", "Words that get misrecognized are replaced right after recognition, and Apple Speech is biased toward them. Press Enter to add.", "誤認識されやすい語を認識直後に置換し、Apple 音声認識でも優先されます。Enter で追加。") }
        static var dictList: String { d("個人字典", "个人字典", "Personal Dictionary", "個人辞書") }
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
        static func duplicateTerm(_ term: String) -> String {
            d("「\(term)」已在字典裡，新增會覆蓋原本的寫法", "「\(term)」已在字典里，新增会覆盖原本的写法", "\"\(term)\" is already in the dictionary; adding it will overwrite the preferred form", "「\(term)」は既に辞書にあります。追加すると表記が上書きされます")
        }
        static var autoLearn: String { d("自動學習更正", "自动学习更正", "Learn Corrections Automatically", "修正を自動学習") }
        static var autoLearnDesc: String { d("文字輸入後 30 秒內，你手動把某個詞改掉（例如「鄭」→「John」），Saybit 會把這組更正加進字典，學到時有提示音。只學單一短詞的修改。", "文字输入后 30 秒内，你手动把某个词改掉（例如「郑」→「John」），Saybit 会把这组更正加进字典，学到时有提示音。只学单一短词的修改。", "If you manually change a word within 30 seconds after text is inserted (e.g. \"Jon\" → \"John\"), Saybit adds the correction to the dictionary and plays a sound. Only single short-word edits are learned.", "テキスト入力後 30 秒以内に単語を手動で修正すると（例：「Jon」→「John」）、Saybit がその修正を辞書に追加し、効果音で知らせます。短い単語 1 つの修正のみ学習します。") }
        static var filterPlaceholder: String { d("篩選詞條", "筛选词条", "Filter entries", "エントリーを絞り込む") }
        static func noFilterMatch(_ q: String) -> String {
            d("沒有符合「\(q)」的詞條", "没有匹配「\(q)」的词条", "No entries match \"\(q)\"", "「\(q)」に一致するエントリーはありません")
        }
        static var deleteSkill: String { d("刪除語音技能", "删除语音技能", "Delete Voice Skill", "ボイススキルを削除") }
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
        static var chartDate: String { d("日期", "日期", "Date", "日付") }
        static var chartCount: String { d("次數", "次数", "Count", "回数") }
        static var chartMode: String { d("模式", "模式", "Mode", "モード") }
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
        static var searchPlaceholder: String { d("搜尋紀錄…", "搜索记录…", "Search records…", "記録を検索…") }
        static var emptyTitle: String { d("還沒有紀錄", "还没有记录", "No Records Yet", "記録はまだありません") }
        static var emptyDesc: String { d("按下快捷鍵說話，結果會出現在這裡。", "按下快捷键说话，结果会出现在这里。", "Press the hotkey and speak; results will appear here.", "ショートカットを押して話すと、結果がここに表示されます。") }
        static var yesterday: String { d("昨天", "昨天", "Yesterday", "昨日") }
        // Markdown export
        static var mdTitle: String { d("Saybit 歷史紀錄", "Saybit 历史记录", "Saybit History", "Saybit 履歴") }
        static func mdCount(_ n: Int) -> String { d("共 \(n) 筆", "共 \(n) 条", "\(n) records", "全 \(n) 件") }
        static func mdTokens(_ p: Int32, _ c: Int32, _ t: Int32) -> String {
            d("\(p) → \(c)（合計 \(t)）", "\(p) → \(c)（合计 \(t)）", "\(p) → \(c) (total \(t))", "\(p) → \(c)（合計 \(t)）")
        }
        static var mdDuration: String { d("時長", "时长", "Duration", "時間") }
        static var mdRaw: String { d("原文", "原文", "Original", "原文") }
        static var mdProcessed: String { d("處理後", "处理后", "Processed", "処理後") }
    }

    // MARK: - MenuBar

    enum Menu {
        static func promptLabel(_ name: String) -> String { d("處理風格：\(name)", "处理风格：\(name)", "Style: \(name)", "スタイル：\(name)") }
        static func toneLabel(_ name: String) -> String { d("語調：\(name)", "语调：\(name)", "Tone: \(name)", "トーン：\(name)") }
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
        static func updateAvailable(_ tag: String) -> String {
            d("有新版可用：\(tag)", "有新版可用：\(tag)", "Update available: \(tag)", "新バージョンあり：\(tag)")
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
        static var chooseProvider: String { d("選擇服務商", "选择服务商", "Choose Provider", "プロバイダーを選択") }
        static func getProviderKey(_ name: String) -> String {
            d("取得 \(name) API Key →", "获取 \(name) API Key →", "Get \(name) API Key →", "\(name) API Key を取得 →")
        }
        static var getOpenRouterKey: String { d("取得 OpenRouter API Key →", "获取 OpenRouter API Key →", "Get OpenRouter API Key →", "OpenRouter API Key を取得 →") }
        static var getOpenAIKey: String { d("取得 OpenAI API Key →", "获取 OpenAI API Key →", "Get OpenAI API Key →", "OpenAI API Key を取得 →") }
        // Price comparison
        static var priceCompareTitle: String { d("💰 超划算的價格", "💰 超划算的价格", "💰 Super Affordable", "💰 超お得な価格") }
        static var priceCompareDesc: String { d("相比 Wispr Flow（每月約 NT$300）或 Superwhisper（每月約 NT$270），Saybit 使用 API 按量計費，成本極低：", "相比 Wispr Flow（每月约 US$10）或 Superwhisper（每月约 US$9），Saybit 使用 API 按量计费，成本极低：", "Compared to Wispr Flow ($10/mo) or Superwhisper ($9/mo), Saybit uses pay-per-use API with ultra-low cost:", "Wispr Flow（月額 $10）や Superwhisper（月額 $9）と比べて、Saybit は従量課金 API を使用し、コストが非常に低いです：") }
        static var pricePerRequest: String { d("每次請求不到 1 分錢", "每次请求不到 1 分钱", "~$0.0002 USD per request", "1 リクエストあたり約 0.03 円") }
        static var priceExample1: String { d("1 塊台幣 ≈ 200 次請求", "1 块台币 ≈ 200 次请求", "$1 USD ≈ 6,000 requests", "1 台湾ドル ≈ 200 リクエスト") }
        static var priceExample2: String { d("100 塊台幣 ≈ 20,000 次請求", "100 块台币 ≈ 20,000 次请求", "$10 USD ≈ 60,000 requests", "100 台湾ドル ≈ 20,000 リクエスト") }
        static var priceExample3: String { d("1,000 塊台幣可用約 200,000 次！", "1,000 块台币可用约 200,000 次！", "$100 USD ≈ 600,000 requests!", "1,000 台湾ドル ≈ 200,000 リクエスト！") }
        static var apiKeyHint: String { d("推薦使用 OpenRouter（支援多種模型）", "推荐使用 OpenRouter（支持多种模型）", "OpenRouter recommended (supports multiple models)", "OpenRouter を推奨（複数のモデルをサポート）") }

        // API Tutorial page
        static var apiTutorialTitle: String { d("超低成本 AI 語音輸入", "超低成本 AI 语音输入", "Ultra-Low Cost AI Voice Input", "超低コスト AI 音声入力") }
        static var apiTutorialDesc: String { d("Saybit 使用 OpenAI GPT-4.1-nano 模型，按量計費，用多少算多少，費用完全自己掌控。", "Saybit 使用 OpenAI GPT-4.1-nano 模型，按量计费，用多少算多少，费用完全自己掌控。", "Saybit uses OpenAI GPT-4.1-nano model with pay-as-you-go pricing. You only pay for what you use.", "Saybit は OpenAI GPT-4.1-nano モデルを使用し、従量課金制で、使った分だけお支払い。") }
        static var apiTutorialCompare: String { d("相比其他語音輸入產品（Wispr Flow $10/月、Superwhisper $9/月），Saybit 成本可低至：", "相比其他语音输入产品（Wispr Flow $10/月、Superwhisper $9/月），Saybit 成本可低至：", "Compared to other voice input products (Wispr Flow $10/mo, Superwhisper $9/mo), Saybit costs as low as:", "他の音声入力製品（Wispr Flow $10/月、Superwhisper $9/月）と比較して、Saybit のコストは：") }
        static var apiTutorialPrice1: String { d("每次請求不到 1 分錢", "每次请求不到 1 分钱", "~$0.0002 USD per request", "1 リクエストあたり約 0.03 円") }
        static var apiTutorialPrice2: String { d("NT$1 ≈ 200 次請求", "NT$1 ≈ 200 次请求", "$1 USD ≈ 6,000 requests", "NT$1 ≈ 200 リクエスト") }
        static var apiTutorialPrice3: String { d("NT$100 ≈ 20,000 次請求", "NT$100 ≈ 20,000 次请求", "$10 USD ≈ 60,000 requests", "NT$100 ≈ 20,000 リクエスト") }
        static var apiTutorialPrice4: String { d("US$5 可以用超久！", "US$5 可以用超久！", "$5 USD lasts a very long time!", "US$5 で超長持ち！") }
        static var apiTutorialGetKey: String { d("取得 API Key（免費註冊）", "获取 API Key（免费注册）", "Get API Key (Free signup)", "API Key を取得（無料登録）") }

        // AI choice step
        static var aiChoiceTitle: String { d("要用哪種 AI 來整理文字？", "要用哪种 AI 来整理文字？", "Which AI should polish your text?", "どの AI でテキストを整えますか？") }
        static var aiChoiceDesc: String { d("Saybit 會先把你說的話轉成文字，再交給 AI 去除贅字、補標點、調整語氣。這一步選擇由誰來做，之後隨時可以在「設定 → AI 引擎」更改。", "Saybit 会先把你说的话转成文字，再交给 AI 去除赘字、补标点、调整语气。这一步选择由谁来做，之后随时可以在「设置 → AI 引擎」更改。", "Saybit transcribes your speech, then an AI removes fillers, adds punctuation and adjusts tone. Choose who does that here; you can change it anytime in Settings → AI Engine.", "Saybit は音声をテキストにした後、AI が言い淀みを除き句読点や口調を整えます。ここでその AI を選びます。後から「設定 → AI エンジン」で変更できます。") }
        static var choiceCloudTitle: String { d("雲端 AI（推薦）", "云端 AI（推荐）", "Cloud AI (recommended)", "クラウド AI（推奨）") }
        static var choiceCloudDesc: String { d("品質最好、速度快。用你自己的 API Key 按量計費，每次不到 1 分錢；語音內容會送到你選的服務商。", "质量最好、速度快。用你自己的 API Key 按量计费，每次不到 1 分钱；语音内容会发送到你选的服务商。", "Best quality and fast. Uses your own API key, pay-per-use (a fraction of a cent per request). Your speech text is sent to the provider you choose.", "最高品質で高速。自分の API Key で従量課金（1 回 1 円未満）。音声テキストは選んだプロバイダーに送られます。") }
        static var choiceLocalTitle: String { d("Apple 本機模型（離線）", "Apple 本机模型（离线）", "Apple on-device model (offline)", "Apple オンデバイスモデル（オフライン）") }
        static var choiceLocalDesc: String { d("完全不離開這台 Mac、免費、不用申請任何帳號。品質較弱，偶爾會留下「嗯、那個」。需要 macOS 26 並開啟 Apple Intelligence。", "完全不离开这台 Mac、免费、不用申请任何账号。质量较弱，偶尔会留下「嗯、那个」。需要 macOS 26 并开启 Apple Intelligence。", "Never leaves this Mac, free, no account needed. Weaker quality — may leave some fillers. Requires macOS 26 with Apple Intelligence on.", "この Mac から出ません。無料でアカウント不要。品質はやや劣り、言い淀みが残ることがあります。macOS 26 と Apple Intelligence が必要です。") }
        static var choiceServerTitle: String { d("自架伺服器（Ollama / LM Studio）", "自建服务器（Ollama / LM Studio）", "Self-hosted server (Ollama / LM Studio)", "セルフホスト（Ollama / LM Studio）") }
        static var choiceServerDesc: String { d("進階選項：先選這個，完成引導後到「設定 → AI 引擎」填入伺服器位址。", "进阶选项：先选这个，完成引导后到「设置 → AI 引擎」填入服务器地址。", "Advanced: pick this now, then enter the server address in Settings → AI Engine after setup.", "上級者向け：これを選び、セットアップ後に「設定 → AI エンジン」でサーバーアドレスを入力します。") }
        static var localAvailable: String { d("這台 Mac 可以使用", "这台 Mac 可以使用", "Available on this Mac", "この Mac で利用できます") }

        // API key step (detailed)
        static var apiKeyIntro: String { d("API Key 是一串像密碼的字串，代表你在服務商的帳號。Saybit 只把它存在這台 Mac 的鑰匙圈，呼叫 AI 時隨請求送給服務商，不會傳到其他地方。", "API Key 是一串像密码的字符串，代表你在服务商的账号。Saybit 只把它存在这台 Mac 的钥匙串，调用 AI 时随请求发给服务商，不会传到其他地方。", "An API key is a password-like string that identifies your account with the provider. Saybit keeps it only in this Mac's Keychain and sends it with each request to that provider — nowhere else.", "API Key はプロバイダーのアカウントを表すパスワードのような文字列です。Saybit はこの Mac のキーチェーンにのみ保存し、リクエスト時にそのプロバイダーへ送るだけです。") }
        static func keyStep1(_ provider: String) -> String { d("到 \(provider) 網站註冊帳號（免費）", "到 \(provider) 网站注册账号（免费）", "Create a free account at \(provider)", "\(provider) のサイトでアカウントを作成（無料）") }
        static var keyStep2: String { d("建立一把 API Key，複製整串（通常只會顯示一次）", "创建一个 API Key，复制整串（通常只会显示一次）", "Create an API key and copy the whole string (it is usually shown only once)", "API Key を作成し、全体をコピー（通常は一度しか表示されません）") }
        static var keyStep3: String { d("貼到下面的欄位，按「儲存並測試」", "粘贴到下面的输入框，点「保存并测试」", "Paste it below and click \"Save & Test\"", "下の欄に貼り付けて「保存してテスト」を押す") }
        static func keyNeedsCredit(_ provider: String) -> String { d("\(provider) 需要先儲值才能呼叫（US$5 就能用很久）。沒儲值時測試會顯示「餘額不足」。", "\(provider) 需要先充值才能调用（US$5 就能用很久）。没充值时测试会显示「余额不足」。", "\(provider) requires adding credit first (US$5 lasts a long time). Without credit the test reports \"insufficient balance\".", "\(provider) は先にクレジットのチャージが必要です（US$5 で長く使えます）。未チャージだとテストで「残高不足」と表示されます。") }
        static var openKeyPage: String { d("打開申請頁面", "打开申请页面", "Open key page", "取得ページを開く") }
        static var pasteFromClipboard: String { d("從剪貼簿貼上", "从剪贴板粘贴", "Paste from clipboard", "クリップボードから貼り付け") }
        static var saveAndTest: String { d("儲存並測試", "保存并测试", "Save & Test", "保存してテスト") }
        static var skipKeyHint: String { d("還沒有 Key？可以先按「下一步」，之後到「設定 → AI 引擎」再填。", "还没有 Key？可以先按「下一步」，之后到「设置 → AI 引擎」再填。", "No key yet? Click \"Next\" and add it later in Settings → AI Engine.", "まだ Key がない場合は「次へ」を押し、後で「設定 → AI エンジン」で入力できます。") }
        static var testHint401: String { d("服務商拒絕這把 Key。檢查是否複製完整、前後有沒有多餘空白，或 Key 是否已被撤銷。", "服务商拒绝这个 Key。检查是否复制完整、前后有没有多余空格，或 Key 是否已被撤销。", "The provider rejected this key. Check that it is complete, has no extra spaces, and has not been revoked.", "プロバイダーがこの Key を拒否しました。コピー漏れ、余分な空白、失効していないかを確認してください。") }
        static func testHint402(_ provider: String) -> String { d("Key 正確，但 \(provider) 帳號沒有餘額。到服務商網站儲值後再按一次測試。", "Key 正确，但 \(provider) 账号没有余额。到服务商网站充值后再按一次测试。", "The key works, but your \(provider) account has no credit. Add credit on the provider site and test again.", "Key は正しいですが \(provider) の残高がありません。チャージ後にもう一度テストしてください。") }
        static var testHintNetwork: String { d("連不到服務商。檢查網路、VPN 或防火牆設定後再試。", "连不上服务商。检查网络、VPN 或防火墙设置后再试。", "Could not reach the provider. Check your network, VPN or firewall and try again.", "プロバイダーに接続できません。ネットワーク、VPN、ファイアウォールを確認してください。") }
        static var blurbOpenRouter: String { d("一把 Key 用所有主流模型，可隨時換模型。最推薦。", "一个 Key 用所有主流模型，可随时换模型。最推荐。", "One key for all major models, switch anytime. Most recommended.", "1 つの Key で主要モデルをすべて利用可能。最もおすすめ。") }
        static var blurbOpenAI: String { d("GPT 系列，穩定可靠；價格略高。", "GPT 系列，稳定可靠；价格略高。", "GPT models, reliable; slightly pricier.", "GPT シリーズ。安定していますがやや高め。") }
        static var blurbDeepSeek: String { d("最便宜，中文品質好；尖峰時段偶爾變慢。", "最便宜，中文质量好；高峰时段偶尔变慢。", "Cheapest, strong Chinese quality; occasionally slow at peak times.", "最安で中国語品質が高い。混雑時はやや遅くなることも。") }
        static var blurbGroq: String { d("速度最快，有免費額度，適合先試用。", "速度最快，有免费额度，适合先试用。", "Fastest, with a free tier — good for trying things out.", "最速で無料枠あり。まず試すのに最適。") }

        // Done step
        static var doneTitle: String { d("可以開始了", "可以开始了", "You're ready", "準備完了") }
        static func doneHotkey(_ hotkey: String) -> String { d("在任何輸入框按 \(hotkey) 開始說話，再按一次結束，整理好的文字會自動輸入。", "在任何输入框按 \(hotkey) 开始说话，再按一次结束，整理好的文字会自动输入。", "In any text field press \(hotkey) to start talking, press again to stop; the polished text is typed for you.", "任意の入力欄で \(hotkey) を押して話し、もう一度押して終了。整えられたテキストが自動入力されます。") }
        static var doneSettings: String { d("選單列的麥克風圖示 → 設定，可以調整快捷鍵、AI 服務、語氣與字典。", "菜单栏的麦克风图标 → 设置，可以调整快捷键、AI 服务、语气与字典。", "Menu bar mic icon → Settings to change the hotkey, AI service, tone and dictionary.", "メニューバーのマイクアイコン → 設定でショートカット、AI サービス、口調、辞書を変更できます。") }
        static var doneOffline: String { d("想連語音辨識都離線？到「設定 → 一般 → 語音辨識」選 SenseVoice 並下載模型。", "想连语音识别都离线？到「设置 → 通用 → 语音识别」选 SenseVoice 并下载模型。", "Want speech recognition offline too? Choose SenseVoice in Settings → General → Speech Recognition and download the model.", "音声認識もオフラインにするには「設定 → 一般 → 音声認識」で SenseVoice を選びモデルをダウンロードします。") }
        static var doneNoKeyWarning: String { d("尚未設定 API Key：第一次使用時會提示你補上。", "尚未设置 API Key：第一次使用时会提示你补上。", "No API key yet: Saybit will remind you the first time you use it.", "API Key が未設定です。初回使用時に入力を促します。") }
        static var doneServerHint: String { d("記得到「設定 → AI 引擎」填入 Ollama / LM Studio 的位址，否則第一次使用會失敗。", "记得到「设置 → AI 引擎」填入 Ollama / LM Studio 的地址，否则第一次使用会失败。", "Remember to enter the Ollama / LM Studio address in Settings → AI Engine, or the first use will fail.", "「設定 → AI エンジン」で Ollama / LM Studio のアドレスを入力してください。未設定だと初回使用に失敗します。") }

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
        static var smartSendFeature: String { d("智慧送出", "智能发送", "Smart Send", "スマート送信") }
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
        case .toggle: return d("按一下開始錄音，再按一下停止；開啟「說完自動停止」時，靜音達設定秒數會自動結束", "按一下开始录音，再按一下停止；开启「说完自动停止」时，静音达到设定秒数会自动结束", "Tap to start, tap again to stop. With \"Stop When I Stop Talking\" on, recording ends after the configured silence", "1回タップで録音開始、もう一度で停止。「話し終えたら自動停止」がオンなら、設定した無音時間で自動終了")
        case .hold: return d("按住開始錄音，放開停止", "按住开始录音，放开停止", "Hold to record, release to stop", "押し続けて録音、離すと停止")
        case .doubleTap: return d("快速雙擊快捷鍵開始錄音，再雙擊停止", "快速双击快捷键开始录音，再双击停止", "Double-tap to start, double-tap again to stop", "ダブルタップで録音開始、もう一度ダブルタップで停止")
        }
    }

    static func sttEngine(_ engine: STTEngine) -> String {
        switch engine {
        case .appleSpeech: return d("Apple Speech (本地)", "Apple Speech (本地)", "Apple Speech (Local)", "Apple Speech (ローカル)")
        case .whisperAPI: return d("Whisper API (雲端)", "Whisper API (云端)", "Whisper API (Cloud)", "Whisper API (クラウド)")
        case .sherpaSenseVoice: return d("SenseVoice (離線・快速)", "SenseVoice (离线・快速)", "SenseVoice (Offline, Fast)", "SenseVoice (オフライン・高速)")
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

    // MARK: - File Transcription

    enum Transcribe {
        static var title: String { d("檔案轉錄", "文件转录", "File Transcription", "ファイル文字起こし") }
        static var subtitle: String { d("把會議錄音、語音備忘錄、影片拖進來，在這台 Mac 上轉成逐字稿，不上傳音訊。", "把会议录音、语音备忘录、视频拖进来，在这台 Mac 上转成逐字稿，不上传音频。", "Drop in meeting recordings, voice memos or videos to transcribe them on this Mac. Audio is never uploaded.", "会議の録音、ボイスメモ、動画をドロップすると、この Mac 上で文字起こしします。音声はアップロードされません。") }
        static var modelMissing: String { d("檔案轉錄使用 SenseVoice 離線模型，請先到「一般 › 語音辨識引擎」選 SenseVoice 並下載模型。", "文件转录使用 SenseVoice 离线模型，请先到「通用 › 语音识别引擎」选 SenseVoice 并下载模型。", "File transcription uses the SenseVoice offline model. Go to General › Speech Recognition, choose SenseVoice and download the model first.", "ファイル文字起こしには SenseVoice オフラインモデルを使用します。先に「一般 › 音声認識」で SenseVoice を選び、モデルをダウンロードしてください。") }
        static var dropHint: String { d("拖入音檔或影片", "拖入音频或视频", "Drop an audio or video file", "音声または動画ファイルをドロップ") }
        static var chooseFile: String { d("選擇檔案…", "选择文件…", "Choose File…", "ファイルを選択…") }
        static var stop: String { d("停止", "停止", "Stop", "停止") }
        static var stopped: String { d("已停止", "已停止", "Stopped", "停止しました") }
        static var transcript: String { d("逐字稿", "逐字稿", "Transcript", "文字起こし") }
        static var timestamps: String { d("時間戳", "时间戳", "Timestamps", "タイムスタンプ") }
        static func progress(_ percent: Int, _ seconds: Int) -> String {
            d("轉錄中 \(percent)%（已 \(seconds) 秒）", "转录中 \(percent)%（已 \(seconds) 秒）", "Transcribing \(percent)% (\(seconds)s elapsed)", "文字起こし中 \(percent)%（\(seconds) 秒経過）")
        }
        static func finished(_ count: Int, _ seconds: String) -> String {
            d("完成：\(count) 段，花費 \(seconds) 秒", "完成：\(count) 段，耗时 \(seconds) 秒", "Done: \(count) segments in \(seconds)s", "完了：\(count) 区間、\(seconds) 秒")
        }
        static var copy: String { d("複製", "复制", "Copy", "コピー") }
        static var saveText: String { d("存成文字檔…", "存为文本文件…", "Save as Text…", "テキストとして保存…") }
        static var transcriptSuffix: String { d("逐字稿", "逐字稿", "transcript", "文字起こし") }
        static var summarize: String { d("AI 整理成筆記", "AI 整理成笔记", "Summarize into Notes", "AI でノートにまとめる") }
        static var notes: String { d("AI 筆記", "AI 笔记", "AI Notes", "AI ノート") }
        static var saveMarkdown: String { d("存成 Markdown…", "存为 Markdown…", "Save as Markdown…", "Markdown として保存…") }
        static var notesSuffix: String { d("筆記", "笔记", "notes", "ノート") }
        static func summarizeFailed(_ msg: String) -> String {
            d("AI 整理失敗：\(msg)", "AI 整理失败：\(msg)", "Summarizing failed: \(msg)", "AI のまとめに失敗：\(msg)")
        }
    }

    // MARK: - Voice Modes

    enum VoiceModes {
        static var title: String { d("語音模式", "语音模式", "Voice Modes", "音声モード") }
        static var addMode: String { d("新增模式", "新增模式", "Add Mode", "モードを追加") }
        static var newModeName: String { d("新模式", "新模式", "New Mode", "新しいモード") }
        static var desc: String { d("每個模式有自己的指令和快捷鍵。用模式快捷鍵錄音時，AI 直接照該模式的指令處理（例如寫成 email、翻譯成英文），不必每次口頭交代。", "每个模式有自己的指令和快捷键。用模式快捷键录音时，AI 直接照该模式的指令处理（例如写成 email、翻译成英文），不必每次口头交代。", "Each mode has its own instructions and hotkey. When you record with a mode's hotkey, the AI follows that mode's instructions (e.g. write an email, translate to English) without you saying so every time.", "各モードには独自の指示とショートカットがあります。モードのショートカットで録音すると、AI はそのモードの指示（メール作成、英語に翻訳など）に従って処理するため、毎回口頭で伝える必要はありません。") }
        static var urlControlToggle: String { d("允許其他 App 透過 saybit:// 控制錄音", "允许其他 App 通过 saybit:// 控制录音", "Allow other apps to control recording via saybit://", "他のアプリに saybit:// での録音操作を許可") }
        static var urlControlDesc: String { d("關閉後 saybit://toggle 等指令一律忽略（saybit://settings 不受影響）。開啟時，第一次遇到的來源 App 會先詢問你是否允許。", "关闭后 saybit://toggle 等指令一律忽略（saybit://settings 不受影响）。开启时，第一次遇到的来源 App 会先询问你是否允许。", "When off, saybit://toggle and similar commands are ignored (saybit://settings still works). When on, you are asked the first time a new app sends a command.", "オフにすると saybit://toggle などのコマンドは無視されます（saybit://settings は影響なし）。オンの場合、新しいアプリからの初回コマンド時に確認します。") }
        static var allowedSenders: String { d("已允許的來源", "已允许的来源", "Allowed Sources", "許可済みの送信元") }
        static var allowedSendersEmpty: String { d("尚無已允許的來源", "尚无已允许的来源", "No allowed sources yet", "許可済みの送信元はありません") }
        static var removeSender: String { d("移除", "移除", "Remove", "削除") }
        static var resetSenders: String { d("恢復預設", "恢复默认", "Reset to Defaults", "デフォルトに戻す") }
        static var externalTrigger: String { d("從其他 App 觸發（Raycast、捷徑、Stream Deck）", "从其他 App 触发（Raycast、快捷指令、Stream Deck）", "Trigger from Other Apps (Raycast, Shortcuts, Stream Deck)", "他のアプリから起動（Raycast、ショートカット、Stream Deck）") }
        static var urlHelp: String {
            d("saybit://toggle　開始 / 停止錄音\nsaybit://start、saybit://stop、saybit://cancel\nsaybit://toggle?mode=Email　用指定模式錄音\nsaybit://settings?tab=dictionary　打開設定的指定分頁",
              "saybit://toggle　开始 / 停止录音\nsaybit://start、saybit://stop、saybit://cancel\nsaybit://toggle?mode=Email　用指定模式录音\nsaybit://settings?tab=dictionary　打开设置的指定分页",
              "saybit://toggle　Start / stop recording\nsaybit://start, saybit://stop, saybit://cancel\nsaybit://toggle?mode=Email　Record with a specific mode\nsaybit://settings?tab=dictionary　Open a specific settings tab",
              "saybit://toggle　録音の開始 / 停止\nsaybit://start、saybit://stop、saybit://cancel\nsaybit://toggle?mode=Email　指定モードで録音\nsaybit://settings?tab=dictionary　設定の指定タブを開く")
        }
        static func deleteConfirm(_ name: String) -> String {
            d("刪除語音模式「\(name)」？", "删除语音模式「\(name)」？", "Delete voice mode \"\(name)\"?", "音声モード「\(name)」を削除しますか？")
        }
        static var deleteMessage: String { d("模式的指令和快捷鍵會一起移除。", "模式的指令和快捷键会一起移除。", "The mode's instructions and hotkey will be removed too.", "モードの指示とショートカットも削除されます。") }
        static var namePlaceholder: String { d("模式名稱", "模式名称", "Mode name", "モード名") }
        static var clearHotkey: String { d("清除快捷鍵", "清除快捷键", "Clear Hotkey", "ショートカットをクリア") }
        static var deleteMode: String { d("刪除模式", "删除模式", "Delete Mode", "モードを削除") }
        static var instructions: String { d("指令", "指令", "Instructions", "指示") }
        static var instructionsExample: String { d("例：「把內容寫成給客戶的正式回覆，結尾加上『敬祝 商祺』」。有選取文字時，指令會套用在選取的文字上。", "例：「把内容写成给客户的正式回复，结尾加上『敬祝 商祺』」。有选中文字时，指令会套用在选中的文字上。", "E.g. \"Write this as a formal reply to a client, ending with 'Best regards'\". When text is selected, the instructions apply to the selection.", "例：「顧客への正式な返信として書き、最後に『よろしくお願いいたします』を付ける」。テキストを選択している場合は、選択範囲に指示が適用されます。") }
        static var setHotkey: String { d("設定快捷鍵", "设置快捷键", "Set Hotkey", "ショートカットを設定") }
        static func pressHotkey(_ remaining: Int) -> String {
            d("按下快捷鍵…（\(remaining) 秒）", "按下快捷键…（\(remaining) 秒）", "Press hotkey… (\(remaining)s)", "ショートカットを押してください…（\(remaining) 秒）")
        }
        static var cancelRecordingHelp: String { d("再按一次取消錄製；Esc 也可取消", "再按一次取消录制；Esc 也可取消", "Click again to cancel; Esc also cancels", "もう一度クリックでキャンセル。Esc でもキャンセルできます") }
        static var conflictsWithMain: String { d("這組快捷鍵和主快捷鍵相同，請換一組。", "这组快捷键和主快捷键相同，请换一组。", "This is the same as the main hotkey. Choose a different one.", "メインのショートカットと同じです。別の組み合わせを選んでください。") }
    }

    // MARK: - SenseVoice (Sherpa) model

    enum Sherpa {
        static var modelTitle: String { d("SenseVoice 離線模型", "SenseVoice 离线模型", "SenseVoice Offline Model", "SenseVoice オフラインモデル") }
        static var modelDesc: String { d("完全在本機辨識：速度快、中英夾雜表現好、不需網路。每句講完才定稿，字幕會比 Apple 稍晚出現。", "完全在本机识别：速度快、中英夹杂表现好、不需网络。每句讲完才定稿，字幕会比 Apple 稍晚出现。", "Recognizes entirely on this Mac: fast, handles mixed Chinese/English well, no network needed. Each sentence is finalized after you finish it, so live text appears a bit later than with Apple.", "完全にこの Mac 上で認識します。高速で中英混在にも強く、ネット不要です。文ごとに確定するため、字幕は Apple より少し遅れて表示されます。") }
        static var installed: String { d("已安裝", "已安装", "Installed", "インストール済み") }
        static var showInFinder: String { d("在 Finder 中顯示", "在 Finder 中显示", "Show in Finder", "Finder で表示") }
        static func deleteModel(_ size: String) -> String { d("刪除模型（\(size)）…", "删除模型（\(size)）…", "Delete Model (\(size))…", "モデルを削除（\(size)）…") }
        static func download(_ size: String) -> String { d("下載模型（\(size)）", "下载模型（\(size)）", "Download Model (\(size))", "モデルをダウンロード（\(size)）") }
        static var retry: String { d("重試", "重试", "Retry", "再試行") }
        static var moreActions: String { d("更多動作", "更多操作", "More Actions", "その他の操作") }
        static var deleteConfirmTitle: String { d("刪除 SenseVoice 模型？", "删除 SenseVoice 模型？", "Delete the SenseVoice model?", "SenseVoice モデルを削除しますか？") }
        static func deleteConfirmMessage(_ size: String) -> String {
            d("刪除後要重新下載（\(size)）才能使用離線辨識。", "删除后要重新下载（\(size)）才能使用离线识别。", "You'll need to download it again (\(size)) to use offline recognition.", "オフライン認識を使うには再ダウンロード（\(size)）が必要になります。")
        }
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
