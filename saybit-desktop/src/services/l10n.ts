// 應用內語言切換。沿用原生版 Core/Localization/L10n.swift 的做法：
// 每個字串一個四語對照，用目前 appLanguage 取值，不走 i18n 檔案載入。
//
// 涵蓋範圍是 Tauri 版 UI 實際用到的字串（原生版有些畫面 Tauri 沒有、反之亦然），
// 機制本身與原生一致，新增字串就是多寫一個 d(...) 條目。

export type AppLanguage = 'zh-TW' | 'zh-CN' | 'en-US' | 'ja-JP';

export const APP_LANGUAGES: Array<{ id: AppLanguage; displayName: string }> = [
  { id: 'zh-TW', displayName: '繁體中文' },
  { id: 'zh-CN', displayName: '简体中文' },
  { id: 'en-US', displayName: 'English' },
  { id: 'ja-JP', displayName: '日本語' },
];

type Quad = [string, string, string, string]; // [zh-TW, zh-CN, en-US, ja-JP]

const INDEX: Record<AppLanguage, 0 | 1 | 2 | 3> = {
  'zh-TW': 0,
  'zh-CN': 1,
  'en-US': 2,
  'ja-JP': 3,
};

const STRINGS = {
  // ---- 共用 ----
  save: ['儲存', '保存', 'Save', '保存'] as Quad,
  cancel: ['取消', '取消', 'Cancel', 'キャンセル'] as Quad,
  delete: ['刪除', '删除', 'Delete', '削除'] as Quad,
  add: ['新增', '新增', 'Add', '追加'] as Quad,
  test: ['測試', '测试', 'Test', 'テスト'] as Quad,
  done: ['完成', '完成', 'Done', '完了'] as Quad,
  close: ['關閉', '关闭', 'Close', '閉じる'] as Quad,
  next: ['下一步', '下一步', 'Next', '次へ'] as Quad,
  previous: ['上一步', '上一步', 'Back', '戻る'] as Quad,
  skip: ['跳過', '跳过', 'Skip', 'スキップ'] as Quad,
  reset: ['重置', '重置', 'Reset', 'リセット'] as Quad,
  refresh: ['重新整理', '刷新', 'Refresh', '更新'] as Quad,
  enabled: ['已啟用', '已启用', 'Enabled', '有効'] as Quad,
  disabled: ['已停用', '已停用', 'Disabled', '無効'] as Quad,
  notSet: ['未設定', '未设置', 'Not set', '未設定'] as Quad,
  startUsing: ['開始使用', '开始使用', 'Get Started', '使い始める'] as Quad,
  unsupportedPlatform: [
    '此平台不支援',
    '此平台不支持',
    'Not supported on this platform',
    'このプラットフォームでは非対応',
  ] as Quad,

  // ---- 導覽 ----
  navGeneral: ['一般', '通用', 'General', '一般'] as Quad,
  navApi: ['API 與模型', 'API 与模型', 'API & Model', 'API とモデル'] as Quad,
  navSpeech: ['語音輸入', '语音输入', 'Speech Input', '音声入力'] as Quad,
  navPrompt: ['精煉風格', '润色风格', 'Refinement', '整形スタイル'] as Quad,
  navHotkey: ['快捷鍵', '快捷键', 'Hotkey', 'ショートカット'] as Quad,
  navInjection: ['輸出與注入', '输出与注入', 'Output', '出力と挿入'] as Quad,
  navContextRules: ['情境規則', '情境规则', 'Context Rules', 'コンテキスト規則'] as Quad,
  navDictionary: ['個人字典', '个人词典', 'Dictionary', '個人辞書'] as Quad,
  navSkills: ['自訂技能', '自定义技能', 'Skills', 'カスタムスキル'] as Quad,
  navHistory: ['歷史紀錄', '历史记录', 'History', '履歴'] as Quad,
  navStats: ['數據統計', '数据统计', 'Statistics', '統計'] as Quad,
  navLogs: ['執行日誌', '运行日志', 'Logs', 'ログ'] as Quad,
  navAbout: ['關於', '关于', 'About', 'について'] as Quad,
  navTutorial: ['使用教學', '使用教程', 'Tutorial', 'チュートリアル'] as Quad,

  // ---- 一般 ----
  appLanguage: ['介面語言', '界面语言', 'Interface Language', '表示言語'] as Quad,
  launchAtLogin: ['開機時自動啟動', '开机时自动启动', 'Launch at Login', 'ログイン時に起動'] as Quad,
  launchAtLoginDesc: [
    '登入系統後自動在背景啟動 Saybit。',
    '登录系统后自动在后台启动 Saybit。',
    'Start Saybit in the background after you log in.',
    'ログイン後に Saybit をバックグラウンドで起動します。',
  ] as Quad,
  soundFeedback: ['音效回饋', '音效反馈', 'Sound Feedback', 'サウンドフィードバック'] as Quad,
  soundFeedbackDesc: [
    '開始與結束錄音時播放提示音。',
    '开始与结束录音时播放提示音。',
    'Play a tone when recording starts and stops.',
    '録音の開始・終了時に音を鳴らします。',
  ] as Quad,
  capsuleScale: ['膠囊大小', '胶囊大小', 'Capsule Size', 'カプセルサイズ'] as Quad,
  historyRetention: ['歷史自動清理', '历史自动清理', 'Auto-clean History', '履歴の自動削除'] as Quad,
  historyRetentionDays: ['保留天數', '保留天数', 'Retention (days)', '保存日数'] as Quad,
  autoUpdateCheck: ['自動檢查更新', '自动检查更新', 'Check for Updates', '更新を自動確認'] as Quad,
  updateAvailable: ['有新版本', '有新版本', 'Update available', '新しいバージョンがあります'] as Quad,

  // ---- API ----
  provider: ['服務商', '服务商', 'Provider', 'プロバイダー'] as Quad,
  apiKey: ['API 金鑰', 'API 密钥', 'API Key', 'API キー'] as Quad,
  apiKeyStoredSecurely: [
    '金鑰存放在系統金鑰庫，不會寫進設定檔。',
    '密钥存放在系统钥匙串，不会写入配置文件。',
    'Keys are stored in the system keychain, never in config files.',
    'キーはシステムキーチェーンに保存され、設定ファイルには書き込まれません。',
  ] as Quad,
  model: ['模型', '模型', 'Model', 'モデル'] as Quad,
  fetchModels: ['抓取模型清單', '获取模型列表', 'Fetch Models', 'モデル一覧を取得'] as Quad,
  customProviders: ['自訂服務商', '自定义服务商', 'Custom Providers', 'カスタムプロバイダー'] as Quad,
  advancedParams: ['進階參數', '高级参数', 'Advanced Parameters', '詳細パラメータ'] as Quad,
  advancedParamsDesc: [
    '關閉時使用服務商預設值。不確定就別開。',
    '关闭时使用服务商默认值。不确定就别开。',
    'When off, provider defaults are used. Leave off if unsure.',
    'オフの場合はプロバイダーの既定値を使用します。',
  ] as Quad,

  // ---- 語音輸入 ----
  sttEngine: ['辨識引擎', '识别引擎', 'STT Engine', '認識エンジン'] as Quad,
  sttLocal: ['本地 whisper（離線・免費）', '本地 whisper（离线・免费）', 'Local whisper (offline, free)', 'ローカル whisper（オフライン・無料）'] as Quad,
  sttCloud: ['雲端 Whisper API', '云端 Whisper API', 'Cloud Whisper API', 'クラウド Whisper API'] as Quad,
  sttApple: ['Apple 語音辨識', 'Apple 语音识别', 'Apple Speech', 'Apple 音声認識'] as Quad,
  sttAppleDesc: [
    '使用 macOS 內建的語音辨識，不需下載模型也不需金鑰，延遲比 whisper 低。標點與長句整理較弱，但後續的 LLM 精煉會補上。',
    '使用 macOS 内置的语音识别，无需下载模型也无需密钥，延迟比 whisper 低。标点与长句整理较弱，但后续的 LLM 润色会补上。',
    "Uses macOS's built-in speech recognition — no model download, no API key, and lower latency than whisper. Punctuation and long-sentence structure are weaker, but the LLM refinement step fixes that.",
    'macOS 内蔵の音声認識を使用します。モデルのダウンロードもキーも不要で、whisper より低遅延です。句読点や長文の整形は弱めですが、後続の LLM 整形が補います。',
  ] as Quad,
  appleSpeechLocale: ['辨識語言', '识别语言', 'Recognition Language', '認識言語'] as Quad,
  appleOnDeviceOnly: ['僅限離線辨識', '仅限离线识别', 'On-device Only', 'オンデバイスのみ'] as Quad,
  appleOnDeviceOnlyDesc: [
    '強制在本機辨識，音訊不會送到 Apple 伺服器。該語言若沒有本機模型會直接報錯而不是偷偷連網。',
    '强制在本机识别，音频不会送到 Apple 服务器。该语言若没有本机模型会直接报错而不是偷偷联网。',
    'Forces local recognition so audio never leaves the machine. If the language has no on-device model this errors out rather than silently going online.',
    'ローカル認識を強制し、音声が端末外に出ないようにします。該当言語のローカルモデルが無い場合は、黙って通信せずエラーになります。',
  ] as Quad,
  appleAuthorization: ['語音辨識權限', '语音识别权限', 'Speech Recognition Access', '音声認識の許可'] as Quad,
  sttStreaming: ['串流辨識（邊講邊出字）', '流式识别（边说边出字）', 'Streaming (live)', 'ストリーミング認識'] as Quad,
  sttStreamingDesc: [
    '透過 WebSocket 邊講邊辨識，講完的瞬間逐字稿就好了，省掉整段辨識的等待。連線失敗會自動退回雲端 Whisper。',
    '通过 WebSocket 边说边识别，说完的瞬间逐字稿就好了，省掉整段识别的等待。连接失败会自动退回云端 Whisper。',
    'Recognizes over a WebSocket while you speak, so the transcript is ready the moment you stop. Falls back to cloud Whisper if the connection fails.',
    'WebSocket で話しながら認識するため、話し終えた瞬間に文字起こしが完成します。接続失敗時はクラウド Whisper に自動フォールバックします。',
  ] as Quad,
  streamingProvider: ['串流服務商', '流式服务商', 'Streaming Provider', 'ストリーミング提供元'] as Quad,
  streamingEndpoint: ['WebSocket 端點', 'WebSocket 端点', 'WebSocket Endpoint', 'WebSocket エンドポイント'] as Quad,
  testConnection: ['測試連線', '测试连接', 'Test Connection', '接続テスト'] as Quad,
  streamingUntested: [
    '⚠️ 這兩家的協定是照官方文件實作的，但沒有在真實帳號上驗證過。請先用「測試連線」確認憑證與端點。',
    '⚠️ 这两家的协议是照官方文档实现的，但没有在真实账号上验证过。请先用「测试连接」确认凭证与端点。',
    '⚠️ Both protocols are implemented from the official docs but have not been verified against a live account. Use "Test Connection" first.',
    '⚠️ 両プロトコルは公式ドキュメントに基づく実装ですが、実アカウントでの検証は行っていません。まず「接続テスト」をご利用ください。',
  ] as Quad,
  authorized: ['已授權', '已授权', 'Authorized', '許可済み'] as Quad,
  requestAccess: ['請求授權', '请求授权', 'Request Access', 'アクセスを要求'] as Quad,
  inputDevice: ['輸入裝置', '输入设备', 'Input Device', '入力デバイス'] as Quad,
  systemDefault: ['系統預設', '系统默认', 'System Default', 'システム既定'] as Quad,
  micSensitivity: ['麥克風靈敏度', '麦克风灵敏度', 'Mic Sensitivity', 'マイク感度'] as Quad,
  voiceBandpass: ['人聲帶通降噪', '人声带通降噪', 'Voice Bandpass Filter', '音声帯域フィルタ'] as Quad,
  voiceBandpassDesc: [
    '80Hz–8kHz 帶通濾波，濾掉低頻嗡嗡聲與高頻雜訊。',
    '80Hz–8kHz 带通滤波，滤掉低频嗡嗡声与高频杂讯。',
    '80Hz–8kHz band-pass; removes low rumble and high-frequency hiss.',
    '80Hz–8kHz バンドパス。低域のうなりと高域のノイズを除去します。',
  ] as Quad,
  echoCancellation: ['回音消除', '回声消除', 'Echo Cancellation', 'エコーキャンセル'] as Quad,
  echoCancellationDesc: [
    '消除喇叭播放洩漏進麥克風的聲音。會略微增加延遲。',
    '消除扬声器播放泄漏进麦克风的声音。会略微增加延迟。',
    'Cancels speaker audio leaking into the mic. Adds slight latency.',
    'スピーカー音のマイクへの回り込みを除去します。わずかに遅延が増えます。',
  ] as Quad,
  preBuffer: ['預錄緩衝', '预录缓冲', 'Pre-roll Buffer', 'プリロールバッファ'] as Quad,
  preBufferDesc: [
    '保留按下快捷鍵之前的音訊，避免開頭被吃掉。',
    '保留按下快捷键之前的音频，避免开头被吃掉。',
    'Keeps audio from before you pressed the hotkey so the start is not clipped.',
    'ショートカットを押す前の音声を保持し、冒頭の欠落を防ぎます。',
  ] as Quad,
  autoStop: ['靜音自動停止', '静音自动停止', 'Auto-stop on Silence', '無音で自動停止'] as Quad,
  silenceTimeout: ['語後靜音逾時（秒）', '语后静音超时（秒）', 'Silence Timeout (s)', '無音タイムアウト（秒）'] as Quad,
  micTest: ['測試麥克風', '测试麦克风', 'Test Microphone', 'マイクをテスト'] as Quad,

  // ---- 精煉風格 ----
  promptStyle: ['精煉風格', '润色风格', 'Refinement Style', '整形スタイル'] as Quad,
  styleTypeless: ['智慧模式', '智能模式', 'Smart', 'スマート'] as Quad,
  styleWispr: ['工程師風格', '工程师风格', 'Developer', 'エンジニア向け'] as Quad,
  processingMode: ['處理模式', '处理模式', 'Processing Mode', '処理モード'] as Quad,
  modeDictation: ['聽寫', '听写', 'Dictation', 'ディクテーション'] as Quad,
  modeCommand: ['指令', '指令', 'Command', 'コマンド'] as Quad,
  modeEdit: ['編輯', '编辑', 'Edit', '編集'] as Quad,
  toneStyle: ['語氣', '语气', 'Tone', 'トーン'] as Quad,
  toneAuto: ['自動', '自动', 'Auto', '自動'] as Quad,
  toneFormal: ['正式', '正式', 'Formal', 'フォーマル'] as Quad,
  toneCasual: ['口語', '口语', 'Casual', 'カジュアル'] as Quad,
  toneVeryCasual: ['很口語', '很口语', 'Very Casual', 'とてもカジュアル'] as Quad,
  outputLanguage: ['輸出語言', '输出语言', 'Output Language', '出力言語'] as Quad,
  autoLanguageDetection: ['自動偵測語言', '自动检测语言', 'Auto-detect Language', '言語を自動検出'] as Quad,
  whisperMode: ['悄悄話模式', '悄悄话模式', 'Whisper Mode', 'ささやきモード'] as Quad,
  whisperModeDesc: [
    '小聲說話時加強雜訊過濾並更依賴上下文。',
    '小声说话时加强噪声过滤并更依赖上下文。',
    'More aggressive noise filtering and context reliance for quiet speech.',
    '小声で話すときにノイズ除去と文脈依存を強化します。',
  ] as Quad,
  contextAwareness: ['情境感知', '情境感知', 'Context Awareness', 'コンテキスト認識'] as Quad,
  contextAwarenessDesc: [
    '讀取前景 App 名稱，依 App 調整語氣與格式。',
    '读取前景 App 名称，依 App 调整语气与格式。',
    'Reads the focused app name to adapt tone and formatting.',
    'フォアグラウンドのアプリ名を読み取り、トーンと書式を調整します。',
  ] as Quad,
  selectionCapture: ['擷取選取文字', '获取选中文字', 'Capture Selection', '選択テキストを取得'] as Quad,
  selectionCaptureDesc: [
    '說話前先選取文字，就能用語音下指令改寫它。做法是模擬複製鍵，會短暫借用剪貼簿並自動還原；終端機視窗會自動跳過（避免 Ctrl+C 中斷程式）。',
    '说话前先选中文字，就能用语音下指令改写它。做法是模拟复制键，会短暂借用剪贴板并自动还原；终端窗口会自动跳过（避免 Ctrl+C 中断程序）。',
    'Select text before speaking to transform it by voice. This simulates the copy key and briefly borrows the clipboard, restoring it after. Terminals are skipped so Ctrl+C never interrupts a running process.',
    '話す前にテキストを選択すると音声で変換できます。コピーキーを模擬しクリップボードを一時的に使用後、復元します。ターミナルは Ctrl+C の誤送信を避けるため対象外です。',
  ] as Quad,
  actionIntents: ['行事曆與提醒', '日历与提醒', 'Calendar & Reminders', 'カレンダーとリマインダー'] as Quad,
  actionIntentsDesc: [
    '說「幫我排明天三點開會」直接建立行程。僅 macOS 支援。',
    '说「帮我排明天三点开会」直接创建日程。仅 macOS 支持。',
    'Say "schedule a meeting tomorrow at 3" to create an event. macOS only.',
    '「明日3時に会議を入れて」で予定を作成します。macOS のみ。',
  ] as Quad,

  // ---- 快捷鍵 ----
  hotkeyRecord: ['點此錄製快捷鍵', '点此录制快捷键', 'Click to record hotkey', 'クリックしてショートカットを記録'] as Quad,
  hotkeyRecording: ['請按下組合鍵…', '请按下组合键…', 'Press a key combination…', 'キーの組み合わせを押してください…'] as Quad,
  hotkeyTriggerMode: ['觸發方式', '触发方式', 'Trigger Mode', 'トリガー方式'] as Quad,
  triggerToggle: ['按一下開始／再按一下結束', '按一下开始／再按一下结束', 'Press to start, press again to stop', '押して開始、もう一度押して停止'] as Quad,
  triggerHold: ['按住說話，放開送出', '按住说话，松开发送', 'Hold to talk, release to send', '押している間だけ録音'] as Quad,
  triggerDoubleTap: ['連按兩下觸發', '连按两下触发', 'Double-tap to trigger', 'ダブルタップで起動'] as Quad,
  hotkeyConflict: [
    '這組快捷鍵可能與系統功能衝突',
    '这组快捷键可能与系统功能冲突',
    'This shortcut may conflict with a system shortcut',
    'このショートカットはシステム機能と競合する可能性があります',
  ] as Quad,

  // ---- 輸出 ----
  injectionMode: ['注入方式', '注入方式', 'Injection Mode', '挿入方式'] as Quad,
  injectPaste: ['貼上（快速）', '粘贴（快速）', 'Paste (fast)', 'ペースト（高速）'] as Quad,
  injectKeypress: ['逐字輸入（相容性佳）', '逐字输入（兼容性好）', 'Type character by character', '一文字ずつ入力'] as Quad,
  injectReplaceSelection: ['取代選取內容', '替换选中内容', 'Replace selection', '選択範囲を置換'] as Quad,
  previewBeforeInject: ['注入前預覽', '注入前预览', 'Preview Before Inject', '挿入前にプレビュー'] as Quad,
  previewTimeout: ['預覽自動確認秒數', '预览自动确认秒数', 'Auto-confirm after (s)', '自動確定までの秒数'] as Quad,
  smartSend: ['智慧傳送（自動按 Enter）', '智能发送（自动按 Enter）', 'Smart Send (auto Enter)', 'スマート送信（自動 Enter）'] as Quad,
  smartSendDelay: ['倒數秒數', '倒计时秒数', 'Countdown (s)', 'カウントダウン（秒）'] as Quad,

  // ---- 情境規則 ----
  contextRulesDesc: [
    '依前景 App 自動切換語氣。例如在 Slack 用口語、在 Gmail 用正式。',
    '依前景 App 自动切换语气。例如在 Slack 用口语、在 Gmail 用正式。',
    'Automatically switch tone based on the focused app — casual in Slack, formal in Gmail.',
    'フォアグラウンドのアプリに応じてトーンを切り替えます。',
  ] as Quad,
  appIdentifier: ['App 識別字', 'App 标识', 'App identifier', 'アプリ識別子'] as Quad,
  additionalPrompt: ['額外指示', '额外指令', 'Additional instruction', '追加指示'] as Quad,
  addRule: ['新增規則', '新增规则', 'Add Rule', '規則を追加'] as Quad,

  // ---- 統計 ----
  totalCount: ['累積使用次數', '累计使用次数', 'Total Uses', '累計使用回数'] as Quad,
  avgDuration: ['平均錄音時長', '平均录音时长', 'Avg Duration', '平均録音時間'] as Quad,
  totalTokens: ['累計 Token', '累计 Token', 'Total Tokens', '累計トークン'] as Quad,
  totalCost: ['估計花費', '估计花费', 'Estimated Cost', '推定コスト'] as Quad,
  topApps: ['常用應用程式', '常用应用程序', 'Top Apps', 'よく使うアプリ'] as Quad,
  byIntent: ['意圖分布', '意图分布', 'By Intent', '意図別'] as Quad,
  noData: ['尚無資料', '尚无数据', 'No data yet', 'データがありません'] as Quad,
} as const;

export type L10nKey = keyof typeof STRINGS;

let currentLanguage: AppLanguage = 'zh-TW';

export function setLanguage(lang: AppLanguage): void {
  currentLanguage = lang;
}

export function t(key: L10nKey, lang: AppLanguage = currentLanguage): string {
  const quad = STRINGS[key];
  return quad[INDEX[lang] ?? 0];
}

/// 給 React 元件用：語言變動時重新算字串。
export function makeTranslator(lang: AppLanguage) {
  return (key: L10nKey) => t(key, lang);
}
