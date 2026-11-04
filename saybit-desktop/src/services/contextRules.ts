// Per-app 語氣規則：依前景 App 覆寫語氣、附加額外指示。
// 對應原生版 Models/ContextRule.swift。

export type ToneOverride = 'auto' | 'casual' | 'formal' | 'technical' | 'neutral';

export interface ContextRule {
  id: string;
  /// 對應 appContext.ts 的 context identifier，例如 "slack"
  appIdentifier: string;
  toneOverride: ToneOverride | null;
  additionalPrompt: string | null;
  isEnabled: boolean;
}

export const AVAILABLE_TONES: ToneOverride[] = [
  'auto',
  'casual',
  'formal',
  'technical',
  'neutral',
];

export function toneDisplayName(tone: ToneOverride | null | undefined): string {
  switch (tone) {
    case 'casual':
      return '口語';
    case 'formal':
      return '正式';
    case 'technical':
      return '技術';
    case 'neutral':
      return '中性';
    default:
      return '自動';
  }
}

const rule = (
  appIdentifier: string,
  toneOverride: ToneOverride
): ContextRule => ({
  id: `default-${appIdentifier}`,
  appIdentifier,
  toneOverride,
  additionalPrompt: null,
  isEnabled: true,
});

export const DEFAULT_CONTEXT_RULES: ContextRule[] = [
  rule('slack', 'casual'),
  rule('discord', 'casual'),
  rule('line', 'casual'),
  rule('telegram', 'casual'),
  rule('gmail', 'formal'),
  rule('outlook', 'formal'),
  rule('cursor', 'technical'),
  rule('vscode', 'technical'),
  rule('terminal', 'technical'),
  rule('obsidian', 'neutral'),
  rule('notes', 'neutral'),
  rule('notion', 'neutral'),
];

// 規則本身跟著 AppSettings 一起持久化（見 settings.ts），這裡只放預設值與查詢邏輯，
// 避免同一份資料有兩個來源。

/// 找出某個 App 適用的啟用中規則。
export function matchContextRule(
  rules: ContextRule[],
  appIdentifier: string
): ContextRule | undefined {
  return rules.find((r) => r.appIdentifier === appIdentifier && r.isEnabled);
}
