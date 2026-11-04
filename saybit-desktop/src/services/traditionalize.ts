// 簡體 → 繁體（台灣用詞）。SenseVoice 對中文常輸出簡體，原生 iOS 版用系統的
// ICU transform；webview 沒有，改用 opencc-js 的 cn → twp 字典。
//
// opencc-js 的 cn2t 字典約 1.1 MB，用動態 import 拆成獨立 chunk，第一次用到才載入；
// 載入失敗就原樣回傳（寧可留簡體也不要讓辨識整個失敗）。

type Converter = (text: string) => string;

let converterPromise: Promise<Converter | null> | null = null;

function loadConverter(): Promise<Converter | null> {
  if (!converterPromise) {
    converterPromise = import('opencc-js/cn2t')
      .then((mod) => {
        const build = mod.Converter ?? (mod as unknown as { default: typeof mod }).default?.Converter;
        return build({ from: 'cn', to: 'twp' }) as Converter;
      })
      .catch((e) => {
        console.warn('[Saybit] opencc-js 載入失敗，SenseVoice 輸出保留簡體:', e);
        return null;
      });
  }
  return converterPromise;
}

/// 預先載入字典（例如開始用 SenseVoice 錄音時），避免第一句 partial 等字典載入。
export function preloadTraditionalizer(): void {
  void loadConverter();
}

export async function toTraditional(text: string): Promise<string> {
  if (!text) return text;
  const convert = await loadConverter();
  if (!convert) return text;
  try {
    return convert(text);
  } catch {
    return text;
  }
}
