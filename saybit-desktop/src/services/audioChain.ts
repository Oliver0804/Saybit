// 麥克風擷取鏈：裝置選擇 → AEC → 人聲帶通濾波 → PCM 擷取（含預錄環形緩衝）。
//
// 對應原生版的 SharedAudioEngine + VoiceBandpassFilter + PreBufferRing + AudioLevelMonitor。
//
// 為什麼不用 MediaRecorder：
//   1. 預錄緩衝需要「按下熱鍵之前」的音訊，WebM 串流沒辦法把前面的片段接回去
//      （只有第一個 chunk 帶檔頭），改存 Float32 PCM 環形緩衝就沒這問題。
//   2. 本地 whisper.cpp 本來就要 16kHz mono f32 PCM，先前是錄成 WebM 再用
//      OfflineAudioContext 解回 PCM，白繞一圈。
//   3. 帶通濾波要作用在「送去辨識的音訊」上，走 Web Audio graph 最直接。

const TARGET_SAMPLE_RATE = 16000; // Whisper 的原生取樣率

// AudioWorklet 以 Blob URL 載入，免得多一個要跟著打包的靜態檔案。
const WORKLET_SOURCE = `
class SaybitCaptureProcessor extends AudioWorkletProcessor {
  process(inputs) {
    const input = inputs[0];
    if (input && input[0] && input[0].length > 0) {
      // 複製一份再送出：input buffer 會被 render thread 重用
      this.port.postMessage(new Float32Array(input[0]));
    }
    return true;
  }
}
registerProcessor('saybit-capture', SaybitCaptureProcessor);
`;

export interface AudioChainOptions {
  deviceId: string;
  echoCancellation: boolean;
  bandpass: boolean;
  preBufferSeconds: number;
}

/// 錄音期間每收到一塊音訊就呼叫一次，給串流辨識即時往外推。
/// 收到的一律是已降頻到 16kHz 的 mono f32（由 IncrementalResampler 處理）。
export type LiveTap = (chunk: Float32Array) => void;

export interface CapturedAudio {
  /// 原始取樣率的單聲道 PCM
  pcm: Float32Array;
  sampleRate: number;
  /// 含預錄前綴的總長度（秒）
  durationSeconds: number;
}

export class AudioChain {
  private context: AudioContext | null = null;
  private stream: MediaStream | null = null;
  private analyser: AnalyserNode | null = null;
  private workletNode: AudioWorkletNode | null = null;
  private scriptNode: ScriptProcessorNode | null = null;
  private sourceNode: MediaStreamAudioSourceNode | null = null;

  /// 預錄環形緩衝（保留熱鍵按下之前的音訊，避免開頭吃字）
  private ring: Float32Array = new Float32Array(0);
  private ringWrite = 0;
  private ringFilled = 0;

  private capturing = false;
  private captureChunks: Float32Array[] = [];
  private captureLength = 0;

  private options: AudioChainOptions | null = null;
  private liveTap: LiveTap | null = null;
  private liveResampler: IncrementalResampler | null = null;

  /// 設定即時音訊回呼。傳 null 取消。
  setLiveTap(tap: LiveTap | null): void {
    this.liveTap = tap;
    // 每次重新掛載都要新的重採樣器，否則會沿用上一段錄音的相位與邊界樣本
    this.liveResampler =
      tap && this.sampleRate !== TARGET_SAMPLE_RATE
        ? new IncrementalResampler(this.sampleRate, TARGET_SAMPLE_RATE)
        : null;
  }

  get isRunning(): boolean {
    return this.stream !== null && this.stream.getAudioTracks().some((t) => t.readyState === 'live');
  }

  get sampleRate(): number {
    return this.context?.sampleRate ?? 48000;
  }

  getAnalyser(): AnalyserNode | null {
    return this.analyser;
  }

  /// 開啟麥克風並建立處理鏈。已在跑且設定相同時直接沿用（暖機重用）。
  async start(options: AudioChainOptions): Promise<void> {
    if (this.isRunning && this.sameOptions(options)) {
      // WebKit 會在閒置時 suspend AudioContext，重用前先 resume，
      // 否則波形凍住、靜音偵測讀到零值。
      if (this.context?.state === 'suspended') {
        await this.context.resume().catch(() => {});
      }
      return;
    }

    this.stop();
    this.options = options;

    const constraints: MediaTrackConstraints = {
      echoCancellation: options.echoCancellation,
      // 交給我們自己的帶通濾波處理，瀏覽器的 NS/AGC 會讓開頭音量爬升（前段吃字）
      noiseSuppression: false,
      autoGainControl: false,
      channelCount: 1,
    };
    if (options.deviceId) {
      constraints.deviceId = { exact: options.deviceId };
    }

    this.stream = await navigator.mediaDevices.getUserMedia({ audio: constraints });

    // ⚠️ 一定要用硬體預設取樣率，不要指定 sampleRate: 16000。
    // WebKit 的 createMediaStreamSource() 不會把 48kHz 的麥克風串流重採樣進
    // 不同取樣率的 AudioContext —— 它會直接輸出全零樣本（實測 peak 精確為
    // 0.0000）。降到 16k 一律由我們自己做：批次路徑用 resampleTo16k，
    // 串流路徑用 IncrementalResampler（跨區塊保留狀態，避免接縫）。
    const AudioContextCtor = window.AudioContext || (window as any).webkitAudioContext;
    const ctx: AudioContext = new AudioContextCtor();
    this.context = ctx;

    this.sourceNode = ctx.createMediaStreamSource(this.stream);

    // 人聲帶通：high-pass 80Hz + low-pass 8kHz，Butterworth Q = 1/√2。
    // 與原生版 VoiceBandpassFilter 的 RBJ cookbook 係數等價。
    let tail: AudioNode = this.sourceNode;
    if (options.bandpass) {
      const highpass = ctx.createBiquadFilter();
      highpass.type = 'highpass';
      highpass.frequency.value = 80;
      highpass.Q.value = 0.7071067;

      const lowpass = ctx.createBiquadFilter();
      lowpass.type = 'lowpass';
      lowpass.frequency.value = 8000;
      lowpass.Q.value = 0.7071067;

      tail.connect(highpass);
      highpass.connect(lowpass);
      tail = lowpass;
    }

    this.analyser = ctx.createAnalyser();
    this.analyser.fftSize = 512;
    tail.connect(this.analyser);

    this.allocateRing(options.preBufferSeconds, ctx.sampleRate);

    await this.attachCaptureNode(ctx, tail);
  }

  private sameOptions(next: AudioChainOptions): boolean {
    const prev = this.options;
    return (
      prev !== null &&
      prev.deviceId === next.deviceId &&
      prev.echoCancellation === next.echoCancellation &&
      prev.bandpass === next.bandpass &&
      prev.preBufferSeconds === next.preBufferSeconds
    );
  }

  private allocateRing(seconds: number, sampleRate: number): void {
    const size = Math.max(0, Math.floor(seconds * sampleRate));
    this.ring = new Float32Array(size);
    this.ringWrite = 0;
    this.ringFilled = 0;
  }

  /// 掛上 PCM 擷取節點。優先用 AudioWorklet（跑在 audio thread，不會被主執行緒卡住），
  /// 建立失敗才退回已棄用但相容性最好的 ScriptProcessorNode。
  private async attachCaptureNode(ctx: AudioContext, tail: AudioNode): Promise<void> {
    const onSamples = (samples: Float32Array) => this.consume(samples);

    try {
      const blob = new Blob([WORKLET_SOURCE], { type: 'application/javascript' });
      const url = URL.createObjectURL(blob);
      await ctx.audioWorklet.addModule(url);
      URL.revokeObjectURL(url);

      const node = new AudioWorkletNode(ctx, 'saybit-capture');
      node.port.onmessage = (event) => onSamples(event.data as Float32Array);
      tail.connect(node);
      // Worklet 沒有輸出，但部分瀏覽器需要接到 destination 才會被排程；
      // 接一個靜音 gain 避免真的把麥克風聲音播出來造成回授。
      const mute = ctx.createGain();
      mute.gain.value = 0;
      node.connect(mute);
      mute.connect(ctx.destination);
      this.workletNode = node;
      return;
    } catch {
      /* 落到 ScriptProcessor */
    }

    const node = ctx.createScriptProcessor(4096, 1, 1);
    node.onaudioprocess = (event) => {
      onSamples(new Float32Array(event.inputBuffer.getChannelData(0)));
    };
    tail.connect(node);
    const mute = ctx.createGain();
    mute.gain.value = 0;
    node.connect(mute);
    mute.connect(ctx.destination);
    this.scriptNode = node;
  }

  /// 每個 audio callback 都會進來：先寫環形緩衝，錄音中的話另外累積。
  private consume(samples: Float32Array): void {
    if (this.ring.length > 0) {
      const ring = this.ring;
      for (let i = 0; i < samples.length; i++) {
        ring[this.ringWrite] = samples[i];
        this.ringWrite = (this.ringWrite + 1) % ring.length;
      }
      this.ringFilled = Math.min(this.ringFilled + samples.length, ring.length);
    }

    if (this.capturing) {
      this.captureChunks.push(samples);
      this.captureLength += samples.length;

      // 串流辨識即時推送。context 跑在硬體取樣率，這裡要先降到 16k 才送出去。
      // 包在 try 裡：推送失敗（連線斷了）不能拖垮錄音本身，使用者至少還能
      // 拿到錄完整段後的結果。
      if (this.liveTap) {
        try {
          const resampled = this.liveResampler
            ? this.liveResampler.process(samples)
            : samples;
          if (resampled.length > 0) this.liveTap(resampled);
        } catch {
          /* 串流推送失敗不影響錄音 */
        }
      }
    }
  }

  /// 開始錄音。此刻環形緩衝的內容會成為錄音的前綴。
  /// feedPrefixToTap：把預錄前綴也送進 live tap（SenseVoice 要整段音訊，否則開頭的字會掉）。
  beginCapture(opts: { feedPrefixToTap?: boolean } = {}): void {
    this.captureChunks = [];
    this.captureLength = 0;
    // 先把環形緩衝的內容取出當前綴（依寫入順序，最舊到最新）
    const prefix = this.snapshotRing();
    if (prefix.length > 0) {
      this.captureChunks.push(prefix);
      this.captureLength += prefix.length;
      if (opts.feedPrefixToTap && this.liveTap) {
        try {
          const resampled = this.liveResampler ? this.liveResampler.process(prefix) : prefix;
          if (resampled.length > 0) this.liveTap(resampled);
        } catch {
          /* 推送失敗不影響錄音 */
        }
      }
    }
    this.capturing = true;
  }

  private snapshotRing(): Float32Array {
    const ring = this.ring;
    if (ring.length === 0 || this.ringFilled === 0) return new Float32Array(0);
    const out = new Float32Array(this.ringFilled);
    const start = (this.ringWrite - this.ringFilled + ring.length) % ring.length;
    for (let i = 0; i < this.ringFilled; i++) {
      out[i] = ring[(start + i) % ring.length];
    }
    return out;
  }

  /// 結束錄音並取回完整 PCM（含預錄前綴）。
  endCapture(): CapturedAudio {
    this.capturing = false;
    const pcm = new Float32Array(this.captureLength);
    let offset = 0;
    for (const chunk of this.captureChunks) {
      pcm.set(chunk, offset);
      offset += chunk.length;
    }
    this.captureChunks = [];
    this.captureLength = 0;
    // 錄完清空環形緩衝，下次錄音才不會把上一段的尾巴接進來
    this.ringFilled = 0;
    this.ringWrite = 0;

    const sampleRate = this.sampleRate;
    return { pcm, sampleRate, durationSeconds: pcm.length / sampleRate };
  }

  /// 目前音量（RMS，0–1）。直接讀 analyser，不經 React state。
  currentLevel(gain = 1): number {
    const analyser = this.analyser;
    if (!analyser) return 0;
    const buffer = new Uint8Array(analyser.frequencyBinCount);
    analyser.getByteTimeDomainData(buffer);
    let sum = 0;
    for (let i = 0; i < buffer.length; i++) {
      const v = (buffer[i] - 128) / 128;
      sum += v * v;
    }
    const rms = Math.sqrt(sum / buffer.length) * gain;
    return Math.min(rms, 1);
  }

  stop(): void {
    if (this.workletNode) {
      this.workletNode.port.onmessage = null;
      this.workletNode.disconnect();
      this.workletNode = null;
    }
    if (this.scriptNode) {
      this.scriptNode.onaudioprocess = null;
      this.scriptNode.disconnect();
      this.scriptNode = null;
    }
    if (this.sourceNode) {
      this.sourceNode.disconnect();
      this.sourceNode = null;
    }
    this.analyser = null;
    if (this.stream) {
      this.stream.getTracks().forEach((t) => t.stop());
      this.stream = null;
    }
    if (this.context) {
      this.context.close().catch(() => {});
      this.context = null;
    }
    this.capturing = false;
    this.captureChunks = [];
    this.captureLength = 0;
    this.ringFilled = 0;
    this.ringWrite = 0;
    this.options = null;
  }
}

/// 跨區塊保留狀態的線性內插重採樣器。
///
/// 串流時音訊是一塊一塊進來的，每塊各自獨立重採樣會在邊界產生相位跳動與
/// 取樣點遺漏（可聽見的破音，也會讓辨識變差）。這裡把小數位置與前一塊的
/// 最後一個樣本帶到下一次呼叫，接縫處就跟連續處理同一條長訊號一樣。
class IncrementalResampler {
  private readonly ratio: number;
  /// 下一個輸出點在「這一塊」座標系裡的位置，可能是負的（落在前一塊尾端）
  private position = 0;
  /// 前一塊的最後一個樣本，供 position 為負時內插用
  private previous = 0;

  constructor(sourceRate: number, targetRate: number) {
    this.ratio = sourceRate / targetRate;
  }

  process(input: Float32Array): Float32Array {
    if (input.length === 0) return input;

    const out: number[] = [];
    let position = this.position;

    for (;;) {
      const index = Math.floor(position);
      // 內插需要 index 與 index+1 兩點，後者要等下一塊才有
      if (index + 1 >= input.length) break;
      const left = index < 0 ? this.previous : input[index];
      const right = input[index + 1];
      out.push(left + (right - left) * (position - index));
      position += this.ratio;
    }

    this.previous = input[input.length - 1];
    this.position = position - input.length;
    return Float32Array.from(out);
  }
}

// ---------------------------------------------------------------- 格式轉換

/// 線性內插重採樣到 16kHz。Whisper 系列一律吃 16k mono。
export function resampleTo16k(pcm: Float32Array, sourceRate: number): Float32Array {
  if (sourceRate === TARGET_SAMPLE_RATE || pcm.length === 0) return pcm;
  const ratio = sourceRate / TARGET_SAMPLE_RATE;
  const outLength = Math.floor(pcm.length / ratio);
  const out = new Float32Array(outLength);
  for (let i = 0; i < outLength; i++) {
    const pos = i * ratio;
    const idx = Math.floor(pos);
    const frac = pos - idx;
    const a = pcm[idx] ?? 0;
    const b = pcm[idx + 1] ?? a;
    out[i] = a + (b - a) * frac;
  }
  return out;
}

/// f32 PCM → 16-bit little-endian PCM bytes。串流辨識的兩家服務商都吃這個格式。
export function pcmToInt16Bytes(pcm: Float32Array): Uint8Array {
  const out = new Uint8Array(pcm.length * 2);
  const view = new DataView(out.buffer);
  for (let i = 0; i < pcm.length; i++) {
    const clamped = Math.max(-1, Math.min(1, pcm[i]));
    view.setInt16(i * 2, clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff, true);
  }
  return out;
}

/// 把 16kHz mono f32 PCM 包成 16-bit WAV，供 Whisper 相容 API 上傳。
export function pcmToWavBlob(pcm: Float32Array, sampleRate = TARGET_SAMPLE_RATE): Blob {
  const bytesPerSample = 2;
  const buffer = new ArrayBuffer(44 + pcm.length * bytesPerSample);
  const view = new DataView(buffer);

  const writeString = (offset: number, text: string) => {
    for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i));
  };

  const dataSize = pcm.length * bytesPerSample;
  writeString(0, 'RIFF');
  view.setUint32(4, 36 + dataSize, true);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  view.setUint32(16, 16, true); // PCM chunk size
  view.setUint16(20, 1, true); // format = PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * bytesPerSample, true); // byte rate
  view.setUint16(32, bytesPerSample, true); // block align
  view.setUint16(34, 16, true); // bits per sample
  writeString(36, 'data');
  view.setUint32(40, dataSize, true);

  let offset = 44;
  for (let i = 0; i < pcm.length; i++) {
    const clamped = Math.max(-1, Math.min(1, pcm[i]));
    view.setInt16(offset, clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff, true);
    offset += bytesPerSample;
  }

  return new Blob([buffer], { type: 'audio/wav' });
}

/// 列出可用的音訊輸入裝置。需要已授權麥克風才拿得到 label。
export async function listInputDevices(): Promise<MediaDeviceInfo[]> {
  try {
    const devices = await navigator.mediaDevices.enumerateDevices();
    return devices.filter((d) => d.kind === 'audioinput');
  } catch {
    return [];
  }
}
