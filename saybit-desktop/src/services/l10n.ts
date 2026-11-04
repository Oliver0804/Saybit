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
  voiceBandpass: ['人聲降噪', '人声降噪', 'Voice Noise Filter', '音声ノイズフィルター'] as Quad,
  voiceBandpassDesc: [
    '只保留 80Hz–8kHz 的人聲頻段，濾掉風扇、電源嗡嗡聲與高頻雜音',
    '只保留 80Hz–8kHz 的人声频段，滤掉风扇、电源嗡嗡声与高频杂音',
    'Keeps the 80 Hz–8 kHz voice band, filtering fan hum and hiss',
    '80Hz–8kHz の音声帯域のみを残し、ファンやハム音を除去',
  ] as Quad,
  echoCancellation: ['回音消除', '回声消除', 'Echo Cancellation', 'エコーキャンセル'] as Quad,
  echoCancellationDesc: [
    '邊播放聲音邊講話時，消除喇叭漏進麥克風的音樂、影片與通話聲。戴耳機可關閉，切換時收音會短暫重啟。',
    '边播放声音边讲话时，消除扬声器漏进麦克风的音乐、视频与通话声。戴耳机可关闭，切换时收音会短暂重启。',
    'Removes speaker audio leaking into the mic. Not needed with headphones; toggling briefly restarts capture.',
    'スピーカーからマイクへ漏れる音を除去します。ヘッドホン使用時は不要です。',
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
  whisperMode: ['嘈雜環境模式', '嘈杂环境模式', 'Noisy Environment Mode', '騒がしい環境モード'] as Quad,
  whisperModeDesc: [
    '提醒 AI 忽略辨識到的背景人聲與雜訊，只保留你說的內容',
    '提醒 AI 忽略识别到的背景人声与杂讯，只保留你说的内容',
    'Tells the AI to drop background chatter and noise picked up by recognition',
    '認識された背景の声やノイズを AI に無視させます',
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

  // ======== F2：對齊原生版（文案取自 L10n.swift，「Mac」等字眼改成跨平台說法） ========

  // ---- 共用 ----
  show: ['顯示', '显示', 'Show', '表示'] as Quad,
  hide: ['隱藏', '隐藏', 'Hide', '隠す'] as Quad,
  confirm: ['確認', '确认', 'Confirm', '確認'] as Quad,
  copy: ['複製', '复制', 'Copy', 'コピー'] as Quad,
  copied: ['已複製', '已复制', 'Copied', 'コピーしました'] as Quad,
  recheck: ['重新檢查', '重新检查', 'Recheck', '再確認'] as Quad,
  openSettings: ['開啟設定', '打开设置', 'Open Settings', '設定を開く'] as Quad,
  notAuthorized: ['未授權', '未授权', 'Not Authorized', '未許可'] as Quad,
  saveFailed: ['儲存失敗', '保存失败', 'Save Failed', '保存失敗'] as Quad,
  searchSettings: ['搜尋設定…', '搜索设置…', 'Search settings…', '設定を検索…'] as Quad,
  clearSearch: ['清除搜尋', '清除搜索', 'Clear Search', '検索をクリア'] as Quad,
  noResults: ['找不到符合的設定', '找不到匹配的设置', 'No matching settings', '一致する設定が見つかりません'] as Quad,
  secondsValue: ['{v} 秒', '{v} 秒', '{v} s', '{v} 秒'] as Quad,
  daysValue: ['{v} 天', '{v} 天', '{v} days', '{v} 日'] as Quad,
  appTagline: ['跨平台語音 AI 助手', '跨平台语音 AI 助手', 'Cross-platform voice AI', 'クロスプラットフォーム音声 AI'] as Quad,
  loading: ['正在載入 Saybit…', '正在加载 Saybit…', 'Loading Saybit…', 'Saybit を読み込み中…'] as Quad,

  // ---- 側欄分頁 ----
  groupSettings: ['設定', '设置', 'Settings', '設定'] as Quad,
  groupTools: ['工具', '工具', 'Tools', 'ツール'] as Quad,
  groupData: ['紀錄', '记录', 'Data', '記録'] as Quad,
  tabAi: ['AI 引擎', 'AI 引擎', 'AI Engine', 'AIエンジン'] as Quad,
  tabDictionary: ['字典 / 技能', '字典 / 技能', 'Dictionary / Skills', '辞書 / スキル'] as Quad,
  tabTranscribe: ['檔案轉錄', '文件转录', 'File Transcription', 'ファイル文字起こし'] as Quad,
  tabHistory: ['歷史', '历史', 'History', '履歴'] as Quad,
  tabStatistics: ['統計', '统计', 'Statistics', '統計'] as Quad,
  tabLogs: ['日誌', '日志', 'Logs', 'ログ'] as Quad,

  // ---- 一般：分組標題 ----
  sectionRecording: ['錄音', '录音', 'Recording', '録音'] as Quad,
  sectionRecognition: ['語音辨識', '语音识别', 'Speech Recognition', '音声認識'] as Quad,
  sectionAI: ['AI 理解', 'AI 理解', 'AI Understanding', 'AI の理解'] as Quad,
  sectionOutput: ['輸出', '输出', 'Output', '出力'] as Quad,
  sectionInterface: ['介面', '界面', 'Interface', 'インターフェース'] as Quad,
  sectionSystem: ['系統', '系统', 'System', 'システム'] as Quad,
  permissionStatus: ['權限狀態', '权限状态', 'Permission Status', '権限状態'] as Quad,

  // ---- 一般：錄音 ----
  selectMicDesc: ['選擇語音輸入使用的麥克風', '选择语音输入使用的麦克风', 'Select the microphone for voice input', '音声入力に使用するマイクを選択'] as Quad,
  deviceUnavailable: ['已選的裝置目前未連接', '已选的设备当前未连接', 'Selected device is not connected', '選択したデバイスは未接続です'] as Quad,
  stopTest: ['停止測試', '停止测试', 'Stop Test', 'テスト停止'] as Quad,
  micTestHint: ['對麥克風說話，觀察音量條是否有反應', '对麦克风说话，观察音量条是否有反应', 'Speak into the microphone and observe the volume bar', 'マイクに向かって話し、音量バーの反応を確認してください'] as Quad,
  micOpenFailed: ['無法開啟麥克風，請檢查系統權限', '无法打开麦克风，请检查系统权限', 'Could not open the microphone. Check system permissions.', 'マイクを開けません。システムの権限を確認してください'] as Quad,
  gainMultiplier: ['增益倍數', '增益倍数', 'Gain Multiplier', 'ゲイン倍率'] as Quad,
  micSensitivityDesc: [
    '調高此值可讓音量顯示更靈敏，建議錄音時觀察音量條調整至 3-4 格',
    '调高此值可让音量显示更灵敏，建议录音时观察音量条调整至 3-4 格',
    'Higher values increase volume sensitivity. Adjust while recording until the bar shows 3-4 segments.',
    'この値を上げると音量表示がより敏感になります。録音中に音量バーが3-4セグメント表示されるよう調整してください。',
  ] as Quad,
  enableAutoStop: ['說完自動停止', '说完自动停止', 'Stop When I Stop Talking', '話し終えたら自動停止'] as Quad,
  silenceAutoStopDesc: [
    '說完話後等待此時間未偵測到聲音即自動結束錄音',
    '说完话后等待此时间未检测到声音即自动结束录音',
    'Automatically stops recording after this duration of silence',
    'この時間無音が続くと自動的に録音を停止します',
  ] as Quad,
  silenceWait: ['靜音等待時間', '静音等待时间', 'Silence Timeout', '無音待機時間'] as Quad,
  ducking: ['錄音時降低系統音量', '录音时降低系统音量', 'Lower System Volume While Recording', '録音中にシステム音量を下げる'] as Quad,
  duckingDesc: [
    '把音樂、影片等聲音降到 20%，錄完自動恢復',
    '把音乐、视频等声音降到 20%，录完自动恢复',
    'Lowers music and video to 20%, restored when recording ends',
    '音楽や動画の音量を 20% に下げ、録音後に戻します',
  ] as Quad,
  maxRecording: ['單次錄音上限', '单次录音上限', 'Max Recording Length', '最大録音時間'] as Quad,
  maxRecordingDesc: [
    '錄音超過這個長度會自動停止並開始處理，避免忘記關掉而一直錄下去',
    '录音超过这个长度会自动停止并开始处理，避免忘记关掉而一直录下去',
    'Recording stops and is processed automatically after this length, so a forgotten recording never runs forever',
    'この長さを超えると自動的に停止して処理します。止め忘れを防ぎます',
  ] as Quad,

  // ---- 一般：語音辨識 ----
  sttSenseVoice: ['SenseVoice（離線・快速）', 'SenseVoice（离线・快速）', 'SenseVoice (Offline, Fast)', 'SenseVoice（オフライン・高速）'] as Quad,
  sttLanguage: ['辨識語言', '识别语言', 'Recognition Language', '認識言語'] as Quad,
  sttLanguageAuto: ['自動偵測', '自动检测', 'Auto-detect', '自動検出'] as Quad,
  whisperLanguageLabel: ['Whisper 語言', 'Whisper 语言', 'Whisper Language', 'Whisper 言語'] as Quad,

  // ---- SenseVoice 模型 ----
  sherpaModelTitle: ['SenseVoice 離線模型', 'SenseVoice 离线模型', 'SenseVoice Offline Model', 'SenseVoice オフラインモデル'] as Quad,
  sherpaModelDesc: [
    '完全在本機辨識：速度快、中英夾雜表現好、不需網路。每句講完才定稿，字幕會比串流辨識稍晚出現。',
    '完全在本机识别：速度快、中英夹杂表现好、不需网络。每句讲完才定稿，字幕会比流式识别稍晚出现。',
    'Recognizes entirely on this computer: fast, handles mixed Chinese/English well, no network needed. Each sentence is finalized after you finish it, so live text appears a bit later than with streaming recognition.',
    '完全にこのコンピューター上で認識します。高速で中英混在にも強く、ネット不要です。文ごとに確定するため、字幕はストリーミング認識より少し遅れて表示されます。',
  ] as Quad,
  sherpaInstalled: ['已安裝', '已安装', 'Installed', 'インストール済み'] as Quad,
  sherpaShowInFolder: ['在檔案管理員中顯示', '在文件管理器中显示', 'Show in File Manager', 'ファイルマネージャーで表示'] as Quad,
  sherpaDeleteModel: ['刪除模型（{size}）…', '删除模型（{size}）…', 'Delete Model ({size})…', 'モデルを削除（{size}）…'] as Quad,
  sherpaDownload: ['下載模型（{size}）', '下载模型（{size}）', 'Download Model ({size})', 'モデルをダウンロード（{size}）'] as Quad,
  sherpaRetry: ['重試', '重试', 'Retry', '再試行'] as Quad,
  sherpaMoreActions: ['更多動作', '更多操作', 'More Actions', 'その他の操作'] as Quad,
  sherpaDeleteConfirmTitle: ['刪除 SenseVoice 模型？', '删除 SenseVoice 模型？', 'Delete the SenseVoice model?', 'SenseVoice モデルを削除しますか？'] as Quad,
  sherpaDeleteConfirmMessage: [
    '刪除後要重新下載（{size}）才能使用離線辨識。',
    '删除后要重新下载（{size}）才能使用离线识别。',
    "You'll need to download it again ({size}) to use offline recognition.",
    'オフライン認識を使うには再ダウンロード（{size}）が必要になります。',
  ] as Quad,

  // ---- 一般：AI 理解 ----
  contextRulesTitle: ['App 語氣規則', 'App 语气规则', 'App Tone Rules', 'アプリトーンルール'] as Quad,
  contextRulesManageDesc: ['為不同 App 設定專屬語氣和額外指令', '为不同 App 设置专属语气和额外指令', 'Set custom tone and extra instructions per app', 'アプリごとにトーンと追加指示を設定'] as Quad,
  contextRulesManage: ['管理規則', '管理规则', 'Manage Rules', 'ルールを管理'] as Quad,
  contextRulesEmpty: [
    '還沒有規則。按「新增規則」為特定 App 指定語氣與額外指令。',
    '还没有规则。点「新增规则」为特定 App 指定语气与额外指令。',
    'No rules yet. Click "Add Rule" to set a tone and extra instructions for a specific app.',
    'ルールはまだありません。「ルールを追加」で特定アプリのトーンと追加指示を設定できます。',
  ] as Quad,

  // ---- 一般：輸出 ----
  injectionModeDesc: ['選擇文字注入到目標 App 的方式', '选择文字注入到目标 App 的方式', 'Choose how text is injected into the target app', 'テキストの注入方法を選択'] as Quad,
  enablePreview: ['輸入前先預覽', '输入前先预览', 'Preview Before Inject', '注入前にプレビュー'] as Quad,
  previewDesc: [
    'LLM 處理完成後先顯示預覽，手動確認後再注入文字',
    'LLM 处理完成后先显示预览，手动确认后再注入文字',
    'Shows a preview after LLM processing. Manually confirm before injecting text.',
    'LLM 処理完了後にプレビューを表示し、手動確認後にテキストを注入します。',
  ] as Quad,
  previewTimeoutLabel: ['預覽超時', '预览超时', 'Preview Timeout', 'プレビュータイムアウト'] as Quad,
  previewTimeoutDesc: [
    '預覽顯示後自動確認/取消的等待時間',
    '预览显示后自动确认/取消的等待时间',
    'Time to wait before auto-confirming/cancelling preview',
    'プレビュー表示後の自動確認/キャンセルまでの待機時間',
  ] as Quad,
  smartSendTitle: ['智慧送出', '智能发送', 'Smart Send', 'スマート送信'] as Quad,
  smartSendDesc: [
    '文字貼上後自動倒數，到期自動按下 Enter 送出',
    '文字粘贴后自动倒数，到期自动按下 Enter 发送',
    'Auto-countdown after paste, then auto-presses Enter to send',
    '貼り付け後自動カウントダウンし、Enter を自動送信',
  ] as Quad,
  countdownSeconds: ['倒數秒數', '倒计时秒数', 'Countdown', 'カウントダウン'] as Quad,
  smartSendCancelHint: [
    '倒數期間可點膠囊取消送出；切換到其他視窗也會自動取消',
    '倒计时期间可点胶囊取消发送；切换到其他窗口也会自动取消',
    'Click the capsule during the countdown to cancel; switching to another window cancels too',
    'カウントダウン中にカプセルをクリックするとキャンセル。別のウィンドウに切り替えてもキャンセルされます',
  ] as Quad,

  // ---- 一般：介面 ----
  preferredLanguage: ['偏好語言', '偏好语言', 'Preferred Language', '表示言語'] as Quad,
  autoLanguageDetectionDesc: [
    '讓 Whisper API 自動偵測說話語言，無需手動指定',
    '让 Whisper API 自动检测说话语言，无需手动指定',
    'Let Whisper API auto-detect the spoken language',
    'Whisper API に話す言語を自動検出させます',
  ] as Quad,
  capsuleSizeDesc: ['調整浮動膠囊的顯示大小', '调整浮动胶囊的显示大小', 'Adjust the floating capsule display size', 'フローティングカプセルの表示サイズを調整'] as Quad,

  // ---- 一般：系統 ----
  enableLaunchAtLogin: ['登入時自動啟動 Saybit', '登录时自动启动 Saybit', 'Launch Saybit at Login', 'ログイン時に Saybit を起動'] as Quad,
  enableAutoUpdateCheck: ['啟動時自動檢查更新', '启动时自动检查更新', 'Auto-check for updates on launch', '起動時に自動でアップデート確認'] as Quad,
  autoUpdateCheckDesc: [
    '每 24 小時詢問 GitHub Releases，新版本可用時於設定中提示。',
    '每 24 小时询问 GitHub Releases，新版本可用时于设置中提示。',
    'Polls GitHub Releases every 24 hours and notifies you here when a new version is available.',
    '24 時間ごとに GitHub Releases を確認し、新バージョンがある場合はここでお知らせします。',
  ] as Quad,
  updateNewer: ['發現新版 {latest}（目前 v{current}）', '发现新版 {latest}（当前 v{current}）', 'New version available: {latest} (current v{current})', '新バージョン {latest} があります（現在 v{current}）'] as Quad,
  viewRelease: ['查看新版', '查看新版', 'View Release', 'リリースを見る'] as Quad,
  autoCleanup: ['自動清理舊紀錄', '自动清理旧记录', 'Auto-Clean Old Records', '古い記録の自動クリーンアップ'] as Quad,
  historyCleanupDesc: [
    '超過此天數的歷史紀錄會在開啟時自動清除',
    '超过此天数的历史记录会在启动时自动清除',
    'Records older than this will be auto-deleted on launch',
    'この日数を超えた履歴は起動時に自動削除されます',
  ] as Quad,
  retentionDays: ['保留天數', '保留天数', 'Retention Days', '保持日数'] as Quad,
  tutorial: ['教學', '教程', 'Tutorial', 'チュートリアル'] as Quad,
  tutorialDesc: ['重新看一次快捷鍵與基本操作說明', '重新看一次快捷键与基本操作说明', 'Walk through the hotkey and basics again', 'ホットキーと基本操作をもう一度確認'] as Quad,
  replayTutorial: ['重新查看教學', '重新查看教程', 'Replay Tutorial', 'チュートリアルを再表示'] as Quad,
  replayOnboarding: ['重新執行首次引導', '重新运行首次引导', 'Run Setup Again', 'セットアップを再実行'] as Quad,
  aboutSaybit: ['關於 Saybit', '关于 Saybit', 'About Saybit', 'Saybit について'] as Quad,

  // ---- 一般：權限 ----
  accessibility: ['輔助使用', '辅助功能', 'Accessibility', 'アクセシビリティ'] as Quad,
  microphone: ['麥克風', '麦克风', 'Microphone', 'マイク'] as Quad,
  requiredBadge: ['必要', '必要', 'Required', '必須'] as Quad,
  permissionUnknown: ['無法偵測', '无法检测', 'Cannot detect', '検出できません'] as Quad,
  accessibilityManualDesc: [
    '注入文字與模擬按鍵需要這個權限。桌面版無法直接讀取授權狀態：請到「系統設定 → 隱私權與安全性 → 輔助使用」打開 Saybit。',
    '注入文字与模拟按键需要这个权限。桌面版无法直接读取授权状态：请到「系统设置 → 隐私与安全性 → 辅助功能」打开 Saybit。',
    'Needed to inject text and simulate keys. The desktop build cannot read this status directly: open System Settings → Privacy & Security → Accessibility and turn on Saybit.',
    'テキストの注入とキー操作に必要です。デスクトップ版は許可状態を直接取得できません。「システム設定 → プライバシーとセキュリティ → アクセシビリティ」で Saybit をオンにしてください。',
  ] as Quad,
  openSettingsFailed: [
    '無法自動打開系統設定，請手動前往上面的位置。',
    '无法自动打开系统设置，请手动前往上面的位置。',
    'Could not open System Settings automatically. Please go there manually.',
    'システム設定を自動で開けませんでした。手動で開いてください。',
  ] as Quad,

  // ---- 語音模式 ----
  vmTitle: ['語音模式', '语音模式', 'Voice Modes', '音声モード'] as Quad,
  vmAddMode: ['新增模式', '新增模式', 'Add Mode', 'モードを追加'] as Quad,
  vmNewModeName: ['新模式', '新模式', 'New Mode', '新しいモード'] as Quad,
  vmDesc: [
    '每個模式有自己的指令和快捷鍵。用模式快捷鍵錄音時，AI 直接照該模式的指令處理（例如寫成 email、翻譯成英文），不必每次口頭交代。',
    '每个模式有自己的指令和快捷键。用模式快捷键录音时，AI 直接照该模式的指令处理（例如写成 email、翻译成英文），不必每次口头交代。',
    "Each mode has its own instructions and hotkey. When you record with a mode's hotkey, the AI follows that mode's instructions (e.g. write an email, translate to English) without you saying so every time.",
    '各モードには独自の指示とショートカットがあります。モードのショートカットで録音すると、AI はそのモードの指示（メール作成、英語に翻訳など）に従って処理するため、毎回口頭で伝える必要はありません。',
  ] as Quad,
  vmExternalTrigger: [
    '從其他 App 觸發（Raycast、捷徑、Stream Deck）',
    '从其他 App 触发（Raycast、快捷指令、Stream Deck）',
    'Trigger from Other Apps (Raycast, Shortcuts, Stream Deck)',
    '他のアプリから起動（Raycast、ショートカット、Stream Deck）',
  ] as Quad,
  vmUrlHelp: [
    'saybit://toggle　開始 / 停止錄音\nsaybit://start、saybit://stop、saybit://cancel\nsaybit://toggle?mode=Email　用指定模式錄音\nsaybit://settings?tab=dictionary　打開設定的指定分頁',
    'saybit://toggle　开始 / 停止录音\nsaybit://start、saybit://stop、saybit://cancel\nsaybit://toggle?mode=Email　用指定模式录音\nsaybit://settings?tab=dictionary　打开设置的指定分页',
    'saybit://toggle　Start / stop recording\nsaybit://start, saybit://stop, saybit://cancel\nsaybit://toggle?mode=Email　Record with a specific mode\nsaybit://settings?tab=dictionary　Open a specific settings tab',
    'saybit://toggle　録音の開始 / 停止\nsaybit://start、saybit://stop、saybit://cancel\nsaybit://toggle?mode=Email　指定モードで録音\nsaybit://settings?tab=dictionary　設定の指定タブを開く',
  ] as Quad,
  vmDeleteConfirm: ['刪除語音模式「{name}」？', '删除语音模式「{name}」？', 'Delete voice mode "{name}"?', '音声モード「{name}」を削除しますか？'] as Quad,
  vmDeleteMessage: ['模式的指令和快捷鍵會一起移除。', '模式的指令和快捷键会一起移除。', "The mode's instructions and hotkey will be removed too.", 'モードの指示とショートカットも削除されます。'] as Quad,
  vmNamePlaceholder: ['模式名稱', '模式名称', 'Mode name', 'モード名'] as Quad,
  vmClearHotkey: ['清除快捷鍵', '清除快捷键', 'Clear Hotkey', 'ショートカットをクリア'] as Quad,
  vmDeleteMode: ['刪除模式', '删除模式', 'Delete Mode', 'モードを削除'] as Quad,
  vmInstructions: ['指令', '指令', 'Instructions', '指示'] as Quad,
  vmInstructionsExample: [
    '例：「把內容寫成給客戶的正式回覆，結尾加上『敬祝 商祺』」。有選取文字時，指令會套用在選取的文字上。',
    '例：「把内容写成给客户的正式回复，结尾加上『敬祝 商祺』」。有选中文字时，指令会套用在选中的文字上。',
    'E.g. "Write this as a formal reply to a client, ending with \'Best regards\'". When text is selected, the instructions apply to the selection.',
    '例：「顧客への正式な返信として書き、最後に『よろしくお願いいたします』を付ける」。テキストを選択している場合は、選択範囲に指示が適用されます。',
  ] as Quad,
  vmSetHotkey: ['設定快捷鍵', '设置快捷键', 'Set Hotkey', 'ショートカットを設定'] as Quad,
  vmPressHotkey: ['按下快捷鍵…（{n} 秒）', '按下快捷键…（{n} 秒）', 'Press hotkey… ({n}s)', 'ショートカットを押してください…（{n} 秒）'] as Quad,
  vmCancelRecordingHelp: ['再按一次取消錄製；Esc 也可取消', '再按一次取消录制；Esc 也可取消', 'Click again to cancel; Esc also cancels', 'もう一度クリックでキャンセル。Esc でもキャンセルできます'] as Quad,
  vmConflictsWithMain: ['這組快捷鍵和主快捷鍵相同，請換一組。', '这组快捷键和主快捷键相同，请换一组。', 'This is the same as the main hotkey. Choose a different one.', 'メインのショートカットと同じです。別の組み合わせを選んでください。'] as Quad,
  vmNeedsModifier: [
    '需包含至少一個修飾鍵（Ctrl / Alt / Shift / ⌘）＋一個按鍵',
    '需包含至少一个修饰键（Ctrl / Alt / Shift / ⌘）＋一个按键',
    'Requires at least one modifier (Ctrl / Alt / Shift / ⌘) + one key',
    '修飾キー（Ctrl / Alt / Shift / ⌘）1つ以上 + キー1つが必要',
  ] as Quad,
  expand: ['展開', '展开', 'Expand', '展開'] as Quad,
  mainHotkey: ['主快捷鍵', '主快捷键', 'Main Hotkey', 'メインショートカット'] as Quad,

  // ---- saybit:// ----
  urlDecisionTitle: ['其他 App 透過 saybit:// 控制錄音', '其他 App 通过 saybit:// 控制录音', 'Other apps controlling recording via saybit://', '他のアプリからの saybit:// による録音操作'] as Quad,
  urlDecisionDesc: [
    '「詢問」：第一次收到指令時跳出對話框，你的選擇會記住。「拒絕」：saybit://toggle 等指令一律忽略（saybit://settings 不受影響）。',
    '「询问」：第一次收到指令时弹出对话框，你的选择会记住。「拒绝」：saybit://toggle 等指令一律忽略（saybit://settings 不受影响）。',
    '"Ask": a dialog appears the first time a command arrives and your choice is remembered. "Deny": saybit://toggle and similar commands are ignored (saybit://settings still works).',
    '「確認」：初めてコマンドを受け取ったときにダイアログを表示し、選択を記憶します。「拒否」：saybit://toggle などのコマンドを無視します（saybit://settings は影響なし）。',
  ] as Quad,
  urlDecisionAsk: ['詢問', '询问', 'Ask', '確認'] as Quad,
  urlDecisionAllow: ['允許', '允许', 'Allow', '許可'] as Quad,
  urlDecisionDeny: ['拒絕', '拒绝', 'Deny', '拒否'] as Quad,
  urlAskTitle: ['允許其他 App 控制 Saybit？', '允许其他 App 控制 Saybit？', 'Allow other apps to control Saybit?', '他のアプリに Saybit の操作を許可しますか？'] as Quad,
  urlAskMessage: [
    '有其他 App 想透過 saybit:// 控制 Saybit 錄音。允許後，之後的指令會直接執行；可隨時在「設定 → 快捷鍵」更改。',
    '有其他 App 想通过 saybit:// 控制 Saybit 录音。允许后，之后的指令会直接执行；可随时在「设置 → 快捷键」更改。',
    'Another app wants to control Saybit recording via saybit://. If you allow it, future commands run directly. You can change this anytime in Settings → Hotkey.',
    '他のアプリが saybit:// で Saybit の録音を操作しようとしています。許可すると以降のコマンドはそのまま実行されます。「設定 → ショートカット」でいつでも変更できます。',
  ] as Quad,
  urlAskCommand: ['收到的指令：{command}', '收到的指令：{command}', 'Command received: {command}', '受信したコマンド：{command}'] as Quad,

  // ---- 檔案轉錄 ----
  trTitle: ['檔案轉錄', '文件转录', 'File Transcription', 'ファイル文字起こし'] as Quad,
  trSubtitle: [
    '把會議錄音、語音備忘錄、影片拖進來，在這台電腦上轉成逐字稿，不上傳音訊。',
    '把会议录音、语音备忘录、视频拖进来，在这台电脑上转成逐字稿，不上传音频。',
    'Drop in meeting recordings, voice memos or videos to transcribe them on this computer. Audio is never uploaded.',
    '会議の録音、ボイスメモ、動画をドロップすると、このコンピューター上で文字起こしします。音声はアップロードされません。',
  ] as Quad,
  trModelMissing: [
    '檔案轉錄使用 SenseVoice 離線模型，請先到「一般 › 語音辨識」選 SenseVoice 並下載模型。',
    '文件转录使用 SenseVoice 离线模型，请先到「通用 › 语音识别」选 SenseVoice 并下载模型。',
    'File transcription uses the SenseVoice offline model. Go to General › Speech Recognition, choose SenseVoice and download the model first.',
    'ファイル文字起こしには SenseVoice オフラインモデルを使用します。先に「一般 › 音声認識」で SenseVoice を選び、モデルをダウンロードしてください。',
  ] as Quad,
  trGoToModel: ['前往下載', '前往下载', 'Go to Download', 'ダウンロードへ'] as Quad,
  trDropHint: ['拖入音檔或影片', '拖入音频或视频', 'Drop an audio or video file', '音声または動画ファイルをドロップ'] as Quad,
  trPathPlaceholder: ['或貼上檔案的完整路徑', '或粘贴文件的完整路径', 'Or paste the full file path', 'またはファイルのフルパスを貼り付け'] as Quad,
  trStart: ['開始轉錄', '开始转录', 'Transcribe', '文字起こし開始'] as Quad,
  trStop: ['停止', '停止', 'Stop', '停止'] as Quad,
  trStopped: ['已停止', '已停止', 'Stopped', '停止しました'] as Quad,
  trTranscript: ['逐字稿', '逐字稿', 'Transcript', '文字起こし'] as Quad,
  trTimestamps: ['時間戳', '时间戳', 'Timestamps', 'タイムスタンプ'] as Quad,
  trProgress: ['轉錄中 {p}%（已 {s} 秒）', '转录中 {p}%（已 {s} 秒）', 'Transcribing {p}% ({s}s elapsed)', '文字起こし中 {p}%（{s} 秒経過）'] as Quad,
  trFinished: ['完成：{n} 段，花費 {s} 秒', '完成：{n} 段，耗时 {s} 秒', 'Done: {n} segments in {s}s', '完了：{n} 区間、{s} 秒'] as Quad,
  trSaveText: ['存成文字檔…', '存为文本文件…', 'Save as Text…', 'テキストとして保存…'] as Quad,
  trSummarize: ['AI 整理成筆記', 'AI 整理成笔记', 'Summarize into Notes', 'AI でノートにまとめる'] as Quad,
  trNotes: ['AI 筆記', 'AI 笔记', 'AI Notes', 'AI ノート'] as Quad,
  trSaveMarkdown: ['存成 Markdown…', '存为 Markdown…', 'Save as Markdown…', 'Markdown として保存…'] as Quad,
  trTranscriptSuffix: ['逐字稿', '逐字稿', 'transcript', '文字起こし'] as Quad,
  trNotesSuffix: ['筆記', '笔记', 'notes', 'ノート'] as Quad,
  trSummarizeFailed: ['AI 整理失敗：{msg}', 'AI 整理失败：{msg}', 'Summarizing failed: {msg}', 'AI のまとめに失敗：{msg}'] as Quad,
  trChooseFile: ['選擇檔案…', '选择文件…', 'Choose File…', 'ファイルを選択…'] as Quad,

  // ---- 歷史 ----
  histSearchPlaceholder: ['搜尋紀錄…', '搜索记录…', 'Search records…', '記録を検索…'] as Quad,
  histEmptyTitle: ['還沒有紀錄', '还没有记录', 'No Records Yet', '記録はまだありません'] as Quad,
  histEmptyDesc: ['按下快捷鍵說話，結果會出現在這裡。', '按下快捷键说话，结果会出现在这里。', 'Press the hotkey and speak; results will appear here.', 'ショートカットを押して話すと、結果がここに表示されます。'] as Quad,
  histNoMatch: ['沒有符合「{q}」的紀錄', '没有匹配「{q}」的记录', 'No records match "{q}"', '「{q}」に一致する記録はありません'] as Quad,
  histRecordCount: ['{n} 筆紀錄', '{n} 笔记录', '{n} records', '{n} 件の記録'] as Quad,
  histCopyResult: ['複製結果', '复制结果', 'Copy Result', '結果をコピー'] as Quad,
  histCopyRaw: ['複製原始', '复制原始', 'Copy Raw', '元をコピー'] as Quad,
  histDeleteRecord: ['刪除此紀錄', '删除此记录', 'Delete Record', '記録を削除'] as Quad,
  histConfirmDelete: ['確定刪除此紀錄？此操作無法復原。', '确定删除此记录？此操作无法恢复。', 'Delete this record? This action cannot be undone.', 'この記録を削除しますか？この操作は元に戻せません。'] as Quad,
  histConfirmDeleteAll: [
    '將刪除所有 {n} 筆歷史紀錄，此操作無法復原。',
    '将删除所有 {n} 笔历史记录，此操作无法恢复。',
    'This will delete all {n} records. This action cannot be undone.',
    'すべての {n} 件の記録が削除されます。この操作は元に戻せません。',
  ] as Quad,
  histDeleteAll: ['清除全部紀錄', '清除全部记录', 'Delete All Records', 'すべての記録を削除'] as Quad,
  histSelectRecord: ['選擇一筆紀錄查看詳情', '选择一笔记录查看详情', 'Select a record to view details', '記録を選択して詳細を表示'] as Quad,
  histRawTranscript: ['原始轉錄', '原始转录', 'Raw Transcript', '元の文字起こし'] as Quad,
  histProcessedText: ['處理後文字', '处理后文字', 'Processed Text', '処理済みテキスト'] as Quad,
  histDetailTitle: ['詳細紀錄', '详细记录', 'Details', '詳細'] as Quad,

  // ---- 首次引導 ----
  obTitle: ['Saybit 設定引導', 'Saybit 设置引导', 'Saybit Setup', 'Saybit セットアップ'] as Quad,
  obStepOf: ['步驟 {c} / {t}', '步骤 {c} / {t}', 'Step {c} / {t}', 'ステップ {c} / {t}'] as Quad,
  obChooseLanguage: ['Choose your language\n選擇語言 / 选择语言 / 言語を選択', 'Choose your language\n選擇語言 / 选择语言 / 言語を選択', 'Choose your language\n選擇語言 / 选择语言 / 言語を選択', 'Choose your language\n選擇語言 / 选择语言 / 言語を選択'] as Quad,
  obPermissionsTitle: ['權限設定', '权限设置', 'Permissions', '権限設定'] as Quad,
  obPermissionsDesc: [
    'Saybit 需要以下權限才能正常運作。\n點擊「開啟設定」後，請在系統設定中允許 Saybit。',
    'Saybit 需要以下权限才能正常运作。\n点击「打开设置」后，请在系统设置中允许 Saybit。',
    'Saybit needs the following permissions to work properly.\nClick "Open Settings" to grant permissions in System Settings.',
    'Saybit が正常に動作するには以下の権限が必要です。\n「設定を開く」をクリックしてシステム設定で許可してください。',
  ] as Quad,
  obPermissionsDescOther: [
    'Saybit 只需要麥克風權限。按「請求授權」後，在跳出的詢問中選擇允許。',
    'Saybit 只需要麦克风权限。点「请求授权」后，在弹出的询问中选择允许。',
    'Saybit only needs microphone access. Click "Request Access" and allow it when prompted.',
    'Saybit に必要なのはマイクの権限だけです。「アクセスを要求」を押し、表示された確認で許可してください。',
  ] as Quad,
  obMicDesc: ['用於錄製語音', '用于录制语音', 'For recording your voice', '音声を録音するために使用'] as Quad,
  obAccessibilityDesc: ['讀取選取文字、注入文字', '读取选取文字、注入文字', 'Reads selected text & injects text', '選択テキストの読み取りとテキストの注入'] as Quad,
  obAccessibilityManual: [
    '桌面版無法自動偵測這個權限。打開系統設定的「輔助使用」並開啟 Saybit 後，回來按「我已開啟」。',
    '桌面版无法自动检测这个权限。打开系统设置的「辅助功能」并开启 Saybit 后，回来点「我已开启」。',
    'The desktop build cannot detect this permission. Turn on Saybit in System Settings → Accessibility, then come back and click "I\'ve turned it on".',
    'デスクトップ版はこの権限を自動検出できません。システム設定の「アクセシビリティ」で Saybit をオンにしてから、「オンにしました」を押してください。',
  ] as Quad,
  obAccessibilityDone: ['我已開啟', '我已开启', "I've turned it on", 'オンにしました'] as Quad,
  obRecheckPermissions: ['重新檢查權限', '重新检查权限', 'Recheck Permissions', '権限を再確認'] as Quad,
  obAiChoiceTitle: ['要用哪種 AI 來整理文字？', '要用哪种 AI 来整理文字？', 'Which AI should polish your text?', 'どの AI でテキストを整えますか？'] as Quad,
  obAiChoiceDesc: [
    'Saybit 會先把你說的話轉成文字，再交給 AI 去除贅字、補標點、調整語氣。這一步選擇由誰來做，之後隨時可以在「設定 → AI 引擎」更改。',
    'Saybit 会先把你说的话转成文字，再交给 AI 去除赘字、补标点、调整语气。这一步选择由谁来做，之后随时可以在「设置 → AI 引擎」更改。',
    'Saybit transcribes your speech, then an AI removes fillers, adds punctuation and adjusts tone. Choose who does that here; you can change it anytime in Settings → AI Engine.',
    'Saybit は音声をテキストにした後、AI が言い淀みを除き句読点や口調を整えます。ここでその AI を選びます。後から「設定 → AI エンジン」で変更できます。',
  ] as Quad,
  obChoiceCloudTitle: ['雲端 AI（推薦）', '云端 AI（推荐）', 'Cloud AI (recommended)', 'クラウド AI（推奨）'] as Quad,
  obChoiceCloudDesc: [
    '品質最好、速度快。用你自己的 API Key 按量計費，每次不到 1 分錢；語音內容會送到你選的服務商。',
    '质量最好、速度快。用你自己的 API Key 按量计费，每次不到 1 分钱；语音内容会发送到你选的服务商。',
    'Best quality and fast. Uses your own API key, pay-per-use (a fraction of a cent per request). Your speech text is sent to the provider you choose.',
    '最高品質で高速。自分の API Key で従量課金（1 回 1 円未満）。音声テキストは選んだプロバイダーに送られます。',
  ] as Quad,
  obChoiceServerTitle: ['自架伺服器（Ollama / LM Studio）', '自建服务器（Ollama / LM Studio）', 'Self-hosted server (Ollama / LM Studio)', 'セルフホスト（Ollama / LM Studio）'] as Quad,
  obChoiceServerDesc: [
    '進階選項：先選這個，完成引導後到「設定 → AI 引擎」填入伺服器位址。',
    '进阶选项：先选这个，完成引导后到「设置 → AI 引擎」填入服务器地址。',
    'Advanced: pick this now, then enter the server address in Settings → AI Engine after setup.',
    '上級者向け：これを選び、セットアップ後に「設定 → AI エンジン」でサーバーアドレスを入力します。',
  ] as Quad,
  obApiKeyTitle: ['設定 API Key', '设置 API Key', 'Set Up API Key', 'API Key を設定'] as Quad,
  obApiKeyIntro: [
    'API Key 是一串像密碼的字串，代表你在服務商的帳號。Saybit 只把它存在這台電腦的系統金鑰庫，呼叫 AI 時隨請求送給服務商，不會傳到其他地方。',
    'API Key 是一串像密码的字符串，代表你在服务商的账号。Saybit 只把它存在这台电脑的系统钥匙串，调用 AI 时随请求发给服务商，不会传到其他地方。',
    "An API key is a password-like string that identifies your account with the provider. Saybit keeps it only in this computer's system keychain and sends it with each request to that provider — nowhere else.",
    'API Key はプロバイダーのアカウントを表すパスワードのような文字列です。Saybit はこのコンピューターのシステムキーチェーンにのみ保存し、リクエスト時にそのプロバイダーへ送るだけです。',
  ] as Quad,
  obChooseProvider: ['選擇服務商', '选择服务商', 'Choose Provider', 'プロバイダーを選択'] as Quad,
  obKeyStep1: ['到 {provider} 網站註冊帳號（免費）', '到 {provider} 网站注册账号（免费）', 'Create a free account at {provider}', '{provider} のサイトでアカウントを作成（無料）'] as Quad,
  obKeyStep2: [
    '建立一把 API Key，複製整串（通常只會顯示一次）',
    '创建一个 API Key，复制整串（通常只会显示一次）',
    'Create an API key and copy the whole string (it is usually shown only once)',
    'API Key を作成し、全体をコピー（通常は一度しか表示されません）',
  ] as Quad,
  obKeyStep3: ['貼到下面的欄位，按「儲存並測試」', '粘贴到下面的输入框，点「保存并测试」', 'Paste it below and click "Save & Test"', '下の欄に貼り付けて「保存してテスト」を押す'] as Quad,
  obKeyNeedsCredit: [
    '{provider} 需要先儲值才能呼叫（US$5 就能用很久）。沒儲值時測試會顯示「餘額不足」。',
    '{provider} 需要先充值才能调用（US$5 就能用很久）。没充值时测试会显示「余额不足」。',
    '{provider} requires adding credit first (US$5 lasts a long time). Without credit the test reports "insufficient balance".',
    '{provider} は先にクレジットのチャージが必要です（US$5 で長く使えます）。未チャージだとテストで「残高不足」と表示されます。',
  ] as Quad,
  obOpenKeyPage: ['打開申請頁面', '打开申请页面', 'Open key page', '取得ページを開く'] as Quad,
  obPasteFromClipboard: ['從剪貼簿貼上', '从剪贴板粘贴', 'Paste from clipboard', 'クリップボードから貼り付け'] as Quad,
  obSaveAndTest: ['儲存並測試', '保存并测试', 'Save & Test', '保存してテスト'] as Quad,
  obTesting: ['測試中...', '测试中...', 'Testing...', 'テスト中...'] as Quad,
  obTestSuccess: ['✓ API 連線成功', '✓ API 连接成功', '✓ API Connected', '✓ API 接続成功'] as Quad,
  obApiKeySaved: ['API Key 已儲存', 'API Key 已保存', 'API Key Saved', 'API Key 保存済み'] as Quad,
  obSkipKeyHint: [
    '還沒有 Key？可以先按「下一步」，之後到「設定 → AI 引擎」再填。',
    '还没有 Key？可以先按「下一步」，之后到「设置 → AI 引擎」再填。',
    'No key yet? Click "Next" and add it later in Settings → AI Engine.',
    'まだ Key がない場合は「次へ」を押し、後で「設定 → AI エンジン」で入力できます。',
  ] as Quad,
  obTestHint401: [
    '服務商拒絕這把 Key。檢查是否複製完整、前後有沒有多餘空白，或 Key 是否已被撤銷。',
    '服务商拒绝这个 Key。检查是否复制完整、前后有没有多余空格，或 Key 是否已被撤销。',
    'The provider rejected this key. Check that it is complete, has no extra spaces, and has not been revoked.',
    'プロバイダーがこの Key を拒否しました。コピー漏れ、余分な空白、失効していないかを確認してください。',
  ] as Quad,
  obTestHint402: [
    'Key 正確，但 {provider} 帳號沒有餘額。到服務商網站儲值後再按一次測試。',
    'Key 正确，但 {provider} 账号没有余额。到服务商网站充值后再按一次测试。',
    'The key works, but your {provider} account has no credit. Add credit on the provider site and test again.',
    'Key は正しいですが {provider} の残高がありません。チャージ後にもう一度テストしてください。',
  ] as Quad,
  obTestHintNetwork: [
    '連不到服務商。檢查網路、VPN 或防火牆設定後再試。',
    '连不上服务商。检查网络、VPN 或防火墙设置后再试。',
    'Could not reach the provider. Check your network, VPN or firewall and try again.',
    'プロバイダーに接続できません。ネットワーク、VPN、ファイアウォールを確認してください。',
  ] as Quad,
  obBlurbOpenRouter: ['一把 Key 用所有主流模型，可隨時換模型。最推薦。', '一个 Key 用所有主流模型，可随时换模型。最推荐。', 'One key for all major models, switch anytime. Most recommended.', '1 つの Key で主要モデルをすべて利用可能。最もおすすめ。'] as Quad,
  obBlurbOpenAI: ['GPT 系列，穩定可靠；價格略高。', 'GPT 系列，稳定可靠；价格略高。', 'GPT models, reliable; slightly pricier.', 'GPT シリーズ。安定していますがやや高め。'] as Quad,
  obBlurbDeepSeek: ['最便宜，中文品質好；尖峰時段偶爾變慢。', '最便宜，中文质量好；高峰时段偶尔变慢。', 'Cheapest, strong Chinese quality; occasionally slow at peak times.', '最安で中国語品質が高い。混雑時はやや遅くなることも。'] as Quad,
  obBlurbGroq: ['速度最快，有免費額度，適合先試用。', '速度最快，有免费额度，适合先试用。', 'Fastest, with a free tier — good for trying things out.', '最速で無料枠あり。まず試すのに最適。'] as Quad,
  obDoneTitle: ['可以開始了', '可以开始了', "You're ready", '準備完了'] as Quad,
  obDoneHotkey: [
    '在任何輸入框按 {hotkey} 開始說話，再按一次結束，整理好的文字會自動輸入。',
    '在任何输入框按 {hotkey} 开始说话，再按一次结束，整理好的文字会自动输入。',
    'In any text field press {hotkey} to start talking, press again to stop; the polished text is typed for you.',
    '任意の入力欄で {hotkey} を押して話し、もう一度押して終了。整えられたテキストが自動入力されます。',
  ] as Quad,
  obDoneSettings: [
    '系統匣（選單列）的 Saybit 圖示 → 設定，可以調整快捷鍵、AI 服務、語氣與字典。',
    '系统托盘（菜单栏）的 Saybit 图标 → 设置，可以调整快捷键、AI 服务、语气与字典。',
    'Saybit icon in the system tray (menu bar) → Settings to change the hotkey, AI service, tone and dictionary.',
    'システムトレイ（メニューバー）の Saybit アイコン → 設定でショートカット、AI サービス、口調、辞書を変更できます。',
  ] as Quad,
  obDoneOffline: [
    '想連語音辨識都離線？到「設定 → 一般 → 語音辨識」選 SenseVoice 並下載模型。',
    '想连语音识别都离线？到「设置 → 通用 → 语音识别」选 SenseVoice 并下载模型。',
    'Want speech recognition offline too? Choose SenseVoice in Settings → General → Speech Recognition and download the model.',
    '音声認識もオフラインにするには「設定 → 一般 → 音声認識」で SenseVoice を選びモデルをダウンロードします。',
  ] as Quad,
  obDoneNoKeyWarning: ['尚未設定 API Key：第一次使用時會提示你補上。', '尚未设置 API Key：第一次使用时会提示你补上。', 'No API key yet: Saybit will remind you the first time you use it.', 'API Key が未設定です。初回使用時に入力を促します。'] as Quad,
  obDoneServerHint: [
    '記得到「設定 → AI 引擎」填入 Ollama / LM Studio 的位址，否則第一次使用會失敗。',
    '记得到「设置 → AI 引擎」填入 Ollama / LM Studio 的地址，否则第一次使用会失败。',
    'Remember to enter the Ollama / LM Studio address in Settings → AI Engine, or the first use will fail.',
    '「設定 → AI エンジン」で Ollama / LM Studio のアドレスを入力してください。未設定だと初回使用に失敗します。',
  ] as Quad,
  obContinueTutorial: ['繼續教學', '继续教程', 'Continue to Tutorial', 'チュートリアルへ進む'] as Quad,

  // ---- 膠囊 ----
  ovListening: ['聆聽中', '聆听中', 'Listening', '待機中'] as Quad,
  ovProcessing: ['處理中', '处理中', 'Processing', '処理中'] as Quad,
  ovPreview: ['預覽', '预览', 'Preview', 'プレビュー'] as Quad,
  ovRefining: ['正在精煉...', '正在润色...', 'Refining...', '整形中...'] as Quad,
  ovInject: ['輸入', '输入', 'Inject', '入力'] as Quad,
  ovRegenerate: ['重新生成', '重新生成', 'Regenerate', '再生成'] as Quad,
  ovRetryHint: ['用剛才那段語音重試（不用再講一次）', '用刚才那段语音重试（不用再讲一次）', 'Retry with the same audio (no need to speak again)', '同じ音声で再試行（話し直す必要なし）'] as Quad,

  // ---- 系統匣選單 ----
  trayStartRecording: ['開始錄音（{hotkey}）', '开始录音（{hotkey}）', 'Start Recording ({hotkey})', '録音開始（{hotkey}）'] as Quad,
  trayStopRecording: ['停止錄音', '停止录音', 'Stop Recording', '録音停止'] as Quad,
  trayRecordWithMode: ['用語音模式錄音', '用语音模式录音', 'Record with Voice Mode', '音声モードで録音'] as Quad,
  traySettings: ['設定…', '设置…', 'Settings…', '設定…'] as Quad,
  trayQuit: ['結束 Saybit', '退出 Saybit', 'Quit Saybit', 'Saybit を終了'] as Quad,
  // ---- AI 引擎 / 快捷鍵 / 字典 補充 ----
  baseUrlInvalid: ['網址格式不正確', '网址格式不正确', 'Invalid URL', 'URL の形式が正しくありません'] as Quad,
  baseUrlInsecure: [
    '只有本機或區域網路位址（localhost、127.x、10.x、172.16–31.x、192.168.x、*.local）可以用 http://；其他端點請改用 https://，否則 API Key 會以明文傳送。',
    '只有本机或局域网地址（localhost、127.x、10.x、172.16–31.x、192.168.x、*.local）可以用 http://；其他端点请改用 https://，否则 API Key 会以明文传送。',
    'http:// is only allowed for local or LAN addresses (localhost, 127.x, 10.x, 172.16–31.x, 192.168.x, *.local). Use https:// for other endpoints, or your API key would be sent in plain text.',
    'http:// はローカルまたは LAN アドレス（localhost、127.x、10.x、172.16–31.x、192.168.x、*.local）のみ使用できます。それ以外は https:// を使用してください。API Key が平文で送信されてしまいます。',
  ] as Quad,
  baseUrlLocalHttpNote: [
    '這是本機 / 區網的 http:// 端點，API Key 不會加密傳送。',
    '这是本机 / 局域网的 http:// 端点，API Key 不会加密传送。',
    'This is a local/LAN http:// endpoint; the API key is not encrypted in transit.',
    'ローカル / LAN の http:// エンドポイントです。API Key は暗号化されずに送信されます。',
  ] as Quad,
  styleTypelessDesc: [
    '強調意圖理解、自動格式化清單、去贅詞/改口修正。適合一般文字輸入。',
    '强调意图理解、自动格式化列表、去赘词/改口修正。适合一般文字输入。',
    'Focuses on intent understanding, auto-formatting lists, and removing filler words. Best for general text input.',
    '意図の理解、リストの自動フォーマット、冗語の除去に重点を置きます。一般的なテキスト入力に最適です。',
  ] as Quad,
  styleWisprDesc: [
    '強調開發者功能（變數命名、CLI 命令）、Command Mode。適合程式開發。',
    '强调开发者功能（变量命名、CLI 命令）、Command Mode。适合程序开发。',
    'Focuses on developer features (variable naming, CLI commands) and Command Mode. Best for programming.',
    '開発者機能（変数命名、CLI コマンド）と Command Mode に重点を置きます。プログラミングに最適です。',
  ] as Quad,
  toneAutoDesc: [
    '「自動」會根據當前 App 推斷語調（Slack → 口語，Mail → 正式）',
    '「自动」会根据当前 App 推断语调（Slack → 口语，Mail → 正式）',
    '"Auto" infers tone from the current app (Slack → casual, Mail → formal)',
    '「自動」は現在のアプリからトーンを推定します（Slack → カジュアル、Mail → フォーマル）',
  ] as Quad,
  triggerToggleDesc: [
    '按一下開始錄音，再按一下停止；開啟「說完自動停止」時，靜音達設定秒數會自動結束',
    '按一下开始录音，再按一下停止；开启「说完自动停止」时，静音达到设定秒数会自动结束',
    'Tap to start, tap again to stop. With "Stop When I Stop Talking" on, recording ends after the configured silence',
    '1回タップで録音開始、もう一度で停止。「話し終えたら自動停止」がオンなら、設定した無音時間で自動終了',
  ] as Quad,
  triggerHoldDesc: ['按住開始錄音，放開停止', '按住开始录音，放开停止', 'Hold to record, release to stop', '押し続けて録音、離すと停止'] as Quad,
  triggerDoubleTapDesc: ['快速雙擊快捷鍵開始錄音，再雙擊停止', '快速双击快捷键开始录音，再双击停止', 'Double-tap to start, double-tap again to stop', 'ダブルタップで録音開始、もう一度ダブルタップで停止'] as Quad,
  hotkeyRecordingHint: [
    '點上面的按鈕，按住修飾鍵 (Ctrl / Alt / Shift / ⌘) 再按一個按鍵，按 Esc 取消',
    '点上面的按钮，按住修饰键 (Ctrl / Alt / Shift / ⌘) 再按一个按键，按 Esc 取消',
    'Click the button above, hold modifier keys (Ctrl / Alt / Shift / ⌘) then press a key. Press Esc to cancel.',
    '上のボタンをクリックし、修飾キー (Ctrl / Alt / Shift / ⌘) を押しながら別のキーを押してください。Esc でキャンセル。',
  ] as Quad,
  hotkeyBareWarning: [
    '沒有修飾鍵的單鍵快捷鍵極易誤觸，建議至少加上一個修飾鍵。',
    '没有修饰键的单键快捷键极易误触，建议至少加上一个修饰键。',
    'A single key without modifiers is easy to trigger by accident. Add at least one modifier.',
    '修飾キーなしの単独キーは誤操作しやすいため、修飾キーを1つ以上付けてください。',
  ] as Quad,
  dictDesc: [
    '辨識常出錯的詞：辨識完會直接換成偏好寫法，Whisper / SenseVoice 也會優先認出這些詞。按 Enter 新增。',
    '识别常出错的词：识别完会直接换成偏好写法，Whisper / SenseVoice 也会优先认出这些词。按 Enter 新增。',
    'Words that get misrecognized are replaced right after recognition, and Whisper / SenseVoice are biased toward them. Press Enter to add.',
    '誤認識されやすい語を認識直後に置換し、Whisper / SenseVoice でも優先されます。Enter で追加。',
  ] as Quad,
  dictOriginalTerm: ['原始詞', '原始词', 'Original Term', '元の語'] as Quad,
  dictPreferredForm: ['偏好寫法', '偏好写法', 'Preferred Form', '優先表記'] as Quad,
  dictEmpty: ['尚無字典項目', '尚无字典项目', 'No dictionary entries yet', '辞書エントリーがありません'] as Quad,
  skillDesc: [
    '說出觸發詞時，會載入對應的 Prompt 指令引導 LLM 處理後續語音內容',
    '说出触发词时，会载入对应的 Prompt 指令引导 LLM 处理后续语音内容',
    'When the trigger word is spoken, the corresponding prompt guides LLM to process the following speech',
    'トリガーワードを話すと、対応するプロンプト指示が LLM の処理を導きます',
  ] as Quad,
  skillTriggerWord: ['觸發詞（例：寫信）', '触发词（例：写信）', 'Trigger word (e.g. write email)', 'トリガーワード（例：メール作成）'] as Quad,
  skillPromptInstruction: ['Prompt 指令', 'Prompt 指令', 'Prompt Instruction', 'プロンプト指示'] as Quad,
  skillEmpty: ['尚無語音技能', '尚无语音技能', 'No voice skills yet', 'ボイススキルがありません'] as Quad,
  // ---- F1 錯誤訊息（services / hooks 以 tr(key, 預設字串) 取用）----
  errBaseUrlInsecure: [
    '端點不是 https，為避免 API Key 明文外送已停止傳送；請改用 https，或只對本機／區網位址使用 http',
    '端点不是 https，为避免 API Key 明文外送已停止发送；请改用 https，或只对本机／局域网地址使用 http',
    'The endpoint is not https, so the request was stopped to avoid sending your API key in plain text. Use https, or http only for local/LAN addresses',
    'エンドポイントが https ではないため、API Key の平文送信を避けて送信を中止しました。https を使うか、http はローカル／LAN アドレスのみにしてください',
  ] as Quad,
  errBaseUrlInvalid: ['端點網址格式錯誤', '端点网址格式错误', 'Invalid endpoint URL', 'エンドポイント URL の形式が正しくありません'] as Quad,
  errFileTranscribeFailed: ['檔案轉錄失敗', '文件转录失败', 'File transcription failed', 'ファイルの文字起こしに失敗しました'] as Quad,
  errInjectFailed: ['注入失敗', '注入失败', 'Failed to insert text', 'テキストの注入に失敗しました'] as Quad,
  errMicOpenFailed: ['麥克風開啟失敗', '麦克风打开失败', 'Failed to open the microphone', 'マイクを開けませんでした'] as Quad,
  errSenseVoiceFailed: ['SenseVoice 辨識失敗', 'SenseVoice 识别失败', 'SenseVoice recognition failed', 'SenseVoice の認識に失敗しました'] as Quad,
  errSenseVoiceNoSession: [
    'SenseVoice 沒有啟動成功，請重新錄音',
    'SenseVoice 没有启动成功，请重新录音',
    'SenseVoice did not start. Please record again',
    'SenseVoice を起動できませんでした。もう一度録音してください',
  ] as Quad,
  errSenseVoiceNotInstalled: [
    'SenseVoice 模型尚未下載，請到「設定 → 一般 → 語音辨識」下載模型（約 240 MB）',
    'SenseVoice 模型尚未下载，请到「设置 → 通用 → 语音识别」下载模型（约 240 MB）',
    'The SenseVoice model is not downloaded yet. Download it in Settings → General → Speech Recognition (about 240 MB)',
    'SenseVoice モデルが未ダウンロードです。「設定 → 一般 → 音声認識」でダウンロードしてください（約 240 MB）',
  ] as Quad,
  errSenseVoiceUnavailable: [
    '這個版本不支援 SenseVoice 離線辨識，請改用其他辨識引擎',
    '这个版本不支持 SenseVoice 离线识别，请改用其他识别引擎',
    'This build does not support SenseVoice offline recognition. Please choose another engine',
    'このバージョンは SenseVoice オフライン認識に対応していません。別の認識エンジンを選んでください',
  ] as Quad,
  errSenseVoiceUnsupportedPlatform: [
    '此平台不支援 SenseVoice 離線辨識，請改用其他辨識引擎',
    '此平台不支持 SenseVoice 离线识别，请改用其他识别引擎',
    'SenseVoice offline recognition is not supported on this platform. Please choose another engine',
    'このプラットフォームでは SenseVoice オフライン認識に対応していません。別の認識エンジンを選んでください',
  ] as Quad,
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

/// 帶參數的字串：模板裡的 `{name}` 換成 vars.name（原生版用 Swift 函式組字串，這裡用佔位符）。
export function tf(
  key: L10nKey,
  vars: Record<string, string | number>,
  lang: AppLanguage = currentLanguage
): string {
  return t(key, lang).replace(/\{(\w+)\}/g, (match, name: string) =>
    name in vars ? String(vars[name]) : match
  );
}

export type Translator = (key: L10nKey, vars?: Record<string, string | number>) => string;

/// 給 React 元件用：語言變動時重新算字串。可選的 vars 會代入 `{name}` 佔位符。
export function makeTranslator(lang: AppLanguage): Translator {
  return (key, vars) => (vars ? tf(key, vars, lang) : t(key, lang));
}
