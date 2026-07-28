// Whisper 幻覺（hallucination）過濾。
//
// whisper 系列模型的訓練資料含大量 YouTube 字幕檔，餵進靜音或純音樂時，
// 它不會輸出空字串，而是吐出訓練資料裡的字幕檔殘留，例如：
//   「字幕:CM 李宗盛」「請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目」
//   「由 Amara.org 社群提供的字幕」「Thanks for watching!」
// 這些會被當成真的轉錄結果送去精煉並貼進使用者的視窗。
//
// 兩道防線：
//   1. 送去辨識前先看音量（見 `hasAudibleSpeech`）—— 治本
//   2. 辨識回來後比對已知的幻覺樣式 —— 治漏網的
//
// 原生 macOS 版沒有這段，因為它預設走 Apple Speech，遇到靜音是回空結果。

/// 整段轉錄「只有」這些內容時視為幻覺。用完整比對而不是包含比對，
/// 避免使用者真的說了「感謝觀看」被誤刪。
const EXACT_ARTIFACTS = new Set([
  '謝謝',
  '謝謝你',
  '謝謝您',
  '感謝觀看',
  '謝謝觀看',
  '謝謝大家',
  '謝謝收看',
  '下次再見',
  '請訂閱',
  '再見',
  '好',
  '嗯',
  '哦',
  'thank you',
  'thank you.',
  'thanks for watching',
  'thanks for watching!',
  'you',
  'bye',
  'bye.',
  'bye bye',
  '.',
  '。',
]);

/// 開頭或內含這些片段就幾乎確定是字幕檔殘留。
const ARTIFACT_PATTERNS: RegExp[] = [
  /^字幕/,
  /字幕(by|製作|提供|翻譯)/i,
  /^subtitles?\s+by/i,
  /amara\.org/i,
  /明鏡與點點欄目/,
  /不吝點贊/,
  /打賞支持/,
  /^ming\s*pin\s*tv$/i,
  /^[（(]?(音樂|背景音樂|掌聲|笑聲|music|applause)[）)]?$/i,
];

/// 去掉標點與空白後再比對，避免「感謝觀看。」這種變體漏掉。
function normalize(text: string): string {
  return text
    .trim()
    .toLowerCase()
    .replace(/[\s　]+/g, ' ')
    .replace(/[，。！？、：；「」『』…—～,!?;:"'()（）]/g, '')
    .trim();
}

/// 這段轉錄看起來是不是 whisper 對靜音產生的幻覺。
export function isLikelyHallucination(text: string): boolean {
  const raw = text.trim();
  if (!raw) return false;

  const normalized = normalize(raw);
  if (!normalized) return true; // 只剩標點

  if (EXACT_ARTIFACTS.has(normalized)) return true;
  return ARTIFACT_PATTERNS.some((pattern) => pattern.test(raw) || pattern.test(normalized));
}

// ---------------------------------------------------------------- 音量閘

// 門檻用實測資料校準（同一支麥克風、同一段測試）：
//   背景音樂外洩、沒說話          peak 0.012  → 要擋（會產生「字幕:CM 李宗盛」）
//   短促雜訊，沒有真的說話         peak 0.033  → 要擋（會產生「謝謝。」）
//   正常音量說「一二三測試」        peak 0.251  → 要放行
// 取 0.06 落在雜訊與人聲之間，離兩邊都有足夠餘裕。
const PEAK_FLOOR = 0.06;
/// 另一條獨立的放行路徑：峰值不高但整段能量足夠（講話平穩、離麥克風較遠）。
const RMS_FLOOR = 0.02;

export interface AudioEnergy {
  peak: number;
  rms: number;
}

export function measureEnergy(pcm: Float32Array): AudioEnergy {
  let peak = 0;
  let sumSquares = 0;
  for (let i = 0; i < pcm.length; i++) {
    const sample = pcm[i];
    const magnitude = Math.abs(sample);
    if (magnitude > peak) peak = magnitude;
    sumSquares += sample * sample;
  }
  const rms = pcm.length > 0 ? Math.sqrt(sumSquares / pcm.length) : 0;
  return { peak, rms };
}

/// 這段音訊裡有沒有值得送去辨識的人聲。
/// 兩個門檻都要低於才判定為無聲 —— 只擋確定是靜音的情況，
/// 小聲說話（peak 低但 RMS 夠）仍然會送出去。
export function hasAudibleSpeech(energy: AudioEnergy): boolean {
  return energy.peak >= PEAK_FLOOR || energy.rms >= RMS_FLOOR;
}
