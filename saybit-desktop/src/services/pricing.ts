// 常見模型的概略單價（USD per 1K tokens），移植自原生版 Core/LLM/ModelPricing.swift。
// 實際費用以服務商當下定價為準，僅作粗估顯示。

export interface ModelPricing {
  inputPer1K: number;
  outputPer1K: number;
}

// 比對方式見 priceFor()：去掉 `provider/` 前綴後做前綴比對（含邊界）。
// 第一個命中的採用，故順序由「具體 → 通用」排列。
const TABLE: Array<[string, ModelPricing]> = [
  // OpenAI
  ['gpt-4.1-nano', { inputPer1K: 0.0001, outputPer1K: 0.0004 }],
  ['gpt-4.1-mini', { inputPer1K: 0.0004, outputPer1K: 0.0016 }],
  ['gpt-4.1', { inputPer1K: 0.002, outputPer1K: 0.008 }],
  ['gpt-4o-mini', { inputPer1K: 0.00015, outputPer1K: 0.0006 }],
  ['gpt-4o', { inputPer1K: 0.0025, outputPer1K: 0.01 }],
  ['o1-mini', { inputPer1K: 0.003, outputPer1K: 0.012 }],
  ['o1', { inputPer1K: 0.015, outputPer1K: 0.06 }],

  // Anthropic
  ['claude-haiku-4-5', { inputPer1K: 0.001, outputPer1K: 0.005 }],
  ['claude-sonnet-4-7', { inputPer1K: 0.003, outputPer1K: 0.015 }],
  ['claude-sonnet-4-6', { inputPer1K: 0.003, outputPer1K: 0.015 }],
  ['claude-sonnet-4', { inputPer1K: 0.003, outputPer1K: 0.015 }],
  // Opus 4.5 起降價為 $5 / $25 per 1M；4.0 / 4.1 仍為 $15 / $75
  ['claude-opus-4-7', { inputPer1K: 0.005, outputPer1K: 0.025 }],
  ['claude-opus-4-6', { inputPer1K: 0.005, outputPer1K: 0.025 }],
  ['claude-opus-4-5', { inputPer1K: 0.005, outputPer1K: 0.025 }],
  ['claude-opus-4', { inputPer1K: 0.015, outputPer1K: 0.075 }],

  // Google
  ['gemini-2.5-flash', { inputPer1K: 0.000075, outputPer1K: 0.0003 }],
  ['gemini-2.5-pro', { inputPer1K: 0.00125, outputPer1K: 0.01 }],
  ['gemini-2.0-flash', { inputPer1K: 0.0001, outputPer1K: 0.0004 }],

  // DeepSeek
  ['deepseek-v4-flash', { inputPer1K: 0.00014, outputPer1K: 0.00028 }],
  ['deepseek-v4-pro', { inputPer1K: 0.00055, outputPer1K: 0.00219 }],
  ['deepseek-reasoner', { inputPer1K: 0.00055, outputPer1K: 0.00219 }],
  ['deepseek-chat', { inputPer1K: 0.00014, outputPer1K: 0.00028 }],
  ['deepseek-flash', { inputPer1K: 0.00007, outputPer1K: 0.00028 }],
  ['deepseek-pro', { inputPer1K: 0.00055, outputPer1K: 0.00219 }],
  ['deepseek-v3', { inputPer1K: 0.00014, outputPer1K: 0.00028 }],

  // Groq（隨方案變動，僅參考）
  ['llama-3.3-70b', { inputPer1K: 0.00059, outputPer1K: 0.00079 }],
  ['llama-3.1-70b', { inputPer1K: 0.00059, outputPer1K: 0.00079 }],
  ['llama-3.1-8b', { inputPer1K: 0.00005, outputPer1K: 0.00008 }],
  ['gemma2-9b-it', { inputPer1K: 0.0002, outputPer1K: 0.0002 }],

  // Together AI
  ['qwen2.5-72b', { inputPer1K: 0.0012, outputPer1K: 0.0012 }],
];

/// 去掉 `provider/` 前綴與 `:tag` 後綴，`.` 視同 `-`。
function normalizeModel(model: string): string {
  let lower = model.toLowerCase().trim();
  const slash = lower.lastIndexOf('/');
  if (slash >= 0) lower = lower.slice(slash + 1);
  const colon = lower.indexOf(':');
  if (colon >= 0) lower = lower.slice(0, colon);
  return lower.replace(/\./g, '-');
}

/// 前綴比對且要求邊界（下一字元非英數），避免 `sao10k/...` 被 `o1` 之類的子字串誤配（審查 L1）。
export function priceFor(model: string): ModelPricing | null {
  const name = normalizeModel(model);
  if (!name) return null;
  for (const [pattern, price] of TABLE) {
    const p = normalizeModel(pattern);
    if (!name.startsWith(p)) continue;
    const next = name.charAt(p.length);
    if (next && /[a-z0-9]/.test(next)) continue;
    return price;
  }
  return null;
}

/// 計算成本（USD）。本地服務（local/ ollama/ 前綴、本地 STT）視為 0；未知模型回 null。
export function costFor(
  model: string,
  promptTokens: number,
  completionTokens: number
): number | null {
  const lower = model.toLowerCase();
  if (!lower) return null;
  if (lower.startsWith('local/') || lower.startsWith('ollama/')) return 0;
  // OpenRouter 免費版模型（`…:free`）
  if (lower.endsWith(':free')) return 0;
  const p = priceFor(model);
  if (!p) return null;
  return (promptTokens / 1000) * p.inputPer1K + (completionTokens / 1000) * p.outputPer1K;
}

export function formatUSD(cost: number): string {
  if (cost === 0) return '$0';
  if (cost < 0.0001) return '<$0.0001';
  return `$${cost.toFixed(4)}`;
}
