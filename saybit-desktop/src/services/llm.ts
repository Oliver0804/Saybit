// STT & LLM API Services

export interface LLMPayload {
  transcript: string;
  context: string;
  mode: 'dictation' | 'command' | 'edit';
  tone: string | null;
  language_preference: string;
  personal_dictionary: Record<string, string>;
  whisper_mode?: boolean;
  existing_text?: string;
}

// 語音轉文字：Whisper API
export async function transcribeAudio(
  audioBlob: Blob,
  apiKey: string,
  model = 'whisper-1',
  language = 'zh'
): Promise<string> {
  const formData = new FormData();
  // 將 Blob 封裝為 File 物件
  const file = new File([audioBlob], 'recording.wav', { type: 'audio/wav' });
  formData.append('file', file);
  formData.append('model', model);
  formData.append('language', language);

  const response = await fetch('https://api.openai.com/v1/audio/transcriptions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
    body: formData,
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Whisper API 錯誤: ${response.status} - ${errText}`);
  }

  const data = await response.json();
  return data.text || '';
}

// LLM 流式處理 (Server-Sent Events)
export async function refineTextStream(
  payload: LLMPayload,
  apiKey: string,
  baseUrl: string, // 例如 https://api.openai.com/v1
  model: string,
  systemPrompt: string,
  onChunk: (text: string) => void
): Promise<string> {
  const url = `${baseUrl.replace(/\/$/, '')}/chat/completions`;
  
  const userPrompt = `
原始語音轉錄內容："${payload.transcript}"
前景應用程式內容："${payload.context}"
操作模式："${payload.mode}"
選取文字內容："${payload.existing_text || ''}"
  `.trim();

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: model,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userPrompt },
      ],
      stream: true,
      temperature: 0.3,
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`LLM API 錯誤: ${response.status} - ${errText}`);
  }

  const reader = response.body?.getReader();
  if (!reader) {
    throw new Error('無法取得串流讀取器');
  }

  const decoder = new TextDecoder('utf-8');
  let accumulatedText = '';
  let buffer = '';

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    // 保留最後一個可能未完的 line 放入 buffer
    buffer = lines.pop() || '';

    for (const line of lines) {
      const cleanLine = line.trim();
      if (!cleanLine) continue;
      if (cleanLine.startsWith('data: [DONE]')) continue;

      if (cleanLine.startsWith('data: ')) {
        try {
          const jsonStr = cleanLine.substring(6);
          const parsed = JSON.parse(jsonStr);
          const chunkText = parsed.choices?.[0]?.delta?.content || '';
          if (chunkText) {
            accumulatedText += chunkText;
            onChunk(chunkText);
          }
        } catch (e) {
          // 忽略無效的 JSON chunk
        }
      }
    }
  }

  return accumulatedText;
}

// 兩階段意圖分類 (Stage 1)
export async function classifyIntent(
  transcript: string,
  apiKey: string,
  baseUrl: string,
  model: string
): Promise<{
  intent: 'dictation' | 'translate' | 'rewrite' | 'compose' | 'skill';
  language?: string;
  style?: string;
  format?: string;
  skill_name?: string;
  content: string;
}> {
  const url = `${baseUrl.replace(/\/$/, '')}/chat/completions`;
  const systemPrompt = `
你是一個意圖分類器。請根據使用者的原始轉錄內容，對使用者的意圖進行分類。
可用意圖：
- "dictation" (普通聽寫：無特殊命令)
- "translate" (翻譯：語氣中帶有翻譯指令，如"翻譯成英文...")
- "rewrite" (改寫：要求修改風格，如"改成口語語氣...")
- "compose" (撰寫：要求寫特定格式，如"寫一封郵件...")
- "skill" (語音技能：當觸發詞是 摘要、條列、代辦、修潤、寫信 時)

請回傳精準的 JSON 格式，不要包含任何額外說明或 Markdown 標記，格式如下：
{
  "intent": "dictation|translate|rewrite|compose|skill",
  "language": "en|ja|zh-TW",
  "style": "formal|casual|concise",
  "format": "email|letter|list",
  "skill_name": "觸發詞",
  "content": "被操作的具體文字內容"
}
  `.trim();

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: model,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: transcript },
      ],
      temperature: 0.1,
      response_format: { type: 'json_object' },
    }),
  });

  if (!response.ok) {
    // 逾時或出錯回退到普通聽寫
    return { intent: 'dictation', content: transcript };
  }

  const data = await response.json();
  try {
    const result = JSON.parse(data.choices[0].message.content);
    return result;
  } catch (e) {
    return { intent: 'dictation', content: transcript };
  }
}
