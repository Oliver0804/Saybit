// 檔案轉錄：拖入音檔 / 影片（或貼上路徑）→ SenseVoice 本機轉逐字稿（附時間戳）→ 複製、存檔、AI 整理成筆記。
// 對應原生 UI/Transcribe/FileTranscriptionView.swift。
//
// 選檔：plugin-dialog 的 open()，或 webview 的 drag-drop 事件（HTML5 拖放拿不到真實路徑）；貼上路徑欄位留作備援。
// 存檔：不用 plugin 的 save()——Rust 的 write_text_file 只接受經 save_text_file_dialog 選出的路徑。
import { useEffect, useRef, useState } from 'react';
import { getCurrentWebview } from '@tauri-apps/api/webview';
import { invoke } from '@tauri-apps/api/core';
import { open } from '@tauri-apps/plugin-dialog';
import { writeText } from '@tauri-apps/plugin-clipboard-manager';
import { FileAudio, AlignLeft, Sparkles, AlertTriangle, XOctagon, Loader2 } from 'lucide-react';

import type { AppSettings } from '../services/settings';
import { transcribeFile, segmentsToText, summarizeToNotes, type Segment } from '../services/fileTranscription';
import { senseVoiceLanguageFor } from '../services/sherpaStt';
import type { Translator } from '../services/l10n';
import { Button, GlassCard, SettingDescription, TextField } from '../components/ui';
import { SherpaModelPanel } from './settings/SherpaModelPanel';

const EXTENSIONS = ['m4a', 'mp3', 'wav', 'aiff', 'aif', 'mp4', 'mov', 'flac'];

function baseName(path: string): string {
  const name = path.split(/[\\/]/).pop() ?? path;
  return name;
}

function stem(path: string): string {
  return baseName(path).replace(/\.[^.]+$/, '') || 'Saybit';
}

/// 拖進來的路徑可能帶引號（Finder「拷貝路徑」、Windows「複製為路徑」都會加）
function cleanPath(raw: string): string {
  return raw.trim().replace(/^['"]|['"]$/g, '');
}

interface Props {
  settings: AppSettings;
  tr: Translator;
  /// 這個分頁目前是否顯示中；拖放只在看得到時接收，避免在別的分頁誤觸發
  active: boolean;
}

export function FileTranscriptionView({ settings, tr, active }: Props) {
  const [modelInstalled, setModelInstalled] = useState<boolean | null>(null);
  const [filePath, setFilePath] = useState<string | null>(null);
  const [pathDraft, setPathDraft] = useState('');
  const [dropTargeted, setDropTargeted] = useState(false);

  const [transcribing, setTranscribing] = useState(false);
  const [progress, setProgress] = useState(0);
  const [elapsed, setElapsed] = useState(0);
  const [segments, setSegments] = useState<Segment[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [stopped, setStopped] = useState(false);
  const [showTimestamps, setShowTimestamps] = useState(true);

  const [notes, setNotes] = useState('');
  const [summarizing, setSummarizing] = useState(false);
  const [notesError, setNotesError] = useState<string | null>(null);
  const [copiedKey, setCopiedKey] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);

  const abortRef = useRef<AbortController | null>(null);
  const notesAbortRef = useRef<AbortController | null>(null);
  const startedAtRef = useRef(0);
  const activeRef = useRef(active);
  activeRef.current = active;
  const installedRef = useRef(modelInstalled);
  installedRef.current = modelInstalled;
  const startRef = useRef<(path: string) => void>(() => {});

  // 轉錄中每 0.5 秒更新經過秒數
  useEffect(() => {
    if (!transcribing) return;
    const id = setInterval(() => setElapsed((Date.now() - startedAtRef.current) / 1000), 500);
    return () => clearInterval(id);
  }, [transcribing]);

  // Tauri drag-drop：webview 層的事件才帶得到檔案的真實路徑
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    getCurrentWebview()
      .onDragDropEvent((event) => {
        if (!activeRef.current) return;
        const payload = event.payload;
        if (payload.type === 'enter' || payload.type === 'over') setDropTargeted(true);
        else if (payload.type === 'leave') setDropTargeted(false);
        else if (payload.type === 'drop') {
          setDropTargeted(false);
          const first = payload.paths[0];
          if (first && installedRef.current) startRef.current(first);
        }
      })
      .then((fn) => {
        unlisten = fn;
      })
      .catch(() => {});
    return () => unlisten?.();
  }, []);

  // 卸載（關掉設定視窗）時把進行中的工作停掉
  useEffect(
    () => () => {
      abortRef.current?.abort();
      notesAbortRef.current?.abort();
    },
    []
  );

  const start = async (rawPath: string) => {
    const path = cleanPath(rawPath);
    if (!path) return;
    abortRef.current?.abort();
    notesAbortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;

    setFilePath(path);
    setSegments([]);
    setNotes('');
    setNotesError(null);
    setError(null);
    setStopped(false);
    setProgress(0);
    setElapsed(0);
    startedAtRef.current = Date.now();
    setTranscribing(true);

    try {
      const result = await transcribeFile(path, senseVoiceLanguageFor(settings.whisperLanguage), {
        signal: controller.signal,
        onProgress: (p) => {
          if (abortRef.current === controller) setProgress(p);
        },
        onSegment: (seg) => {
          if (abortRef.current === controller) setSegments((prev) => [...prev, seg]);
        },
      });
      if (abortRef.current !== controller) return;
      setSegments(result);
      setProgress(1);
    } catch (e: any) {
      if (abortRef.current !== controller) return;
      if (controller.signal.aborted) setStopped(true);
      else setError(String(e?.message || e));
    } finally {
      if (abortRef.current === controller) {
        setElapsed((Date.now() - startedAtRef.current) / 1000);
        setTranscribing(false);
      }
    }
  };
  startRef.current = start;

  const stop = () => {
    abortRef.current?.abort();
  };

  const summarize = async () => {
    notesAbortRef.current?.abort();
    const controller = new AbortController();
    notesAbortRef.current = controller;
    setNotes('');
    setNotesError(null);
    setSummarizing(true);
    try {
      // prompt 要求重點附時間戳，所以一律帶時間戳送
      for await (const chunk of summarizeToNotes(segmentsToText(segments, true), settings, {
        signal: controller.signal,
      })) {
        if (notesAbortRef.current !== controller) return;
        setNotes((prev) => prev + chunk);
      }
    } catch (e: any) {
      if (!controller.signal.aborted && notesAbortRef.current === controller) {
        setNotesError(tr('trSummarizeFailed', { msg: String(e?.message || e) }));
      }
    } finally {
      if (notesAbortRef.current === controller) setSummarizing(false);
    }
  };

  const copy = async (key: string, text: string) => {
    try {
      await writeText(text);
      setCopiedKey(key);
      setTimeout(() => setCopiedKey((k) => (k === key ? null : k)), 1500);
    } catch {
      /* 剪貼簿權限失敗時不擋操作 */
    }
  };

  const chooseFile = async () => {
    try {
      const picked = await open({
        multiple: false,
        directory: false,
        filters: [{ name: 'Audio/Video', extensions: EXTENSIONS }],
      });
      if (typeof picked === 'string' && picked) start(picked);
    } catch (e: any) {
      setError(String(e?.message || e));
    }
  };

  const saveFile = async (defaultName: string, content: string, ext: 'txt' | 'md') => {
    setSaveError(null);
    try {
      const path = await invoke<string | null>('save_text_file_dialog', {
        defaultName,
        filters: [ext === 'md' ? { name: 'Markdown', extensions: ['md'] } : { name: 'Text', extensions: ['txt'] }],
      });
      if (!path) return; // 使用者取消
      await invoke('write_text_file', { path, content });
    } catch (e: any) {
      setSaveError(tr('saveFailed') + `：${String(e?.message || e)}`);
    }
  };

  const transcript = segmentsToText(segments, showTimestamps);
  const fileStem = filePath ? stem(filePath) : 'Saybit';
  const canStart = modelInstalled === true && !transcribing;

  return (
    <div className="max-w-2xl space-y-6">
      <div className="space-y-1">
        <h2 className="text-xl font-bold">{tr('trTitle')}</h2>
        <SettingDescription>{tr('trSubtitle')}</SettingDescription>
      </div>

      {modelInstalled === false && (
        <GlassCard>
          <div className="flex items-start gap-2 text-sm text-amber-300">
            <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" />
            <span>{tr('trModelMissing')}</span>
          </div>
        </GlassCard>
      )}
      {/* 模型面板同時負責查詢安裝狀態；沒裝時可以直接在這裡下載 */}
      <div className={modelInstalled === false ? '' : 'hidden'}>
        <GlassCard>
          <SherpaModelPanel tr={tr} onStatusChange={setModelInstalled} />
        </GlassCard>
      </div>

      <div
        className={`flex flex-col items-center gap-3 p-6 rounded-2xl border-2 border-dashed transition-colors ${
          dropTargeted && modelInstalled ? 'border-emerald-400 bg-emerald-500/5' : 'border-white/15'
        } ${modelInstalled ? '' : 'opacity-50'}`}
      >
        <FileAudio className={`w-9 h-9 ${dropTargeted ? 'text-emerald-400' : 'text-white/40'}`} />
        <div className="text-sm font-semibold">{filePath ? baseName(filePath) : tr('trDropHint')}</div>
        <div className="text-[11px] text-white/40">{EXTENSIONS.join(' · ')}</div>
        <Button variant="primary" onClick={chooseFile} disabled={!canStart}>
          {tr('trChooseFile')}
        </Button>
        <form
          className="flex w-full gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            if (canStart) start(pathDraft);
          }}
        >
          <TextField
            value={pathDraft}
            onChange={setPathDraft}
            placeholder={tr('trPathPlaceholder')}
            mono
            className="flex-1 text-xs"
          />
          {transcribing ? (
            <Button variant="danger" onClick={stop}>
              {tr('trStop')}
            </Button>
          ) : (
            <Button disabled={!canStart || !pathDraft.trim()} onClick={() => start(pathDraft)}>
              {tr('trStart')}
            </Button>
          )}
        </form>
      </div>

      {(transcribing || segments.length > 0 || error || stopped) && (
        <GlassCard title={tr('trTranscript')} icon={AlignLeft}>
          <div className="flex items-center justify-between gap-3">
            <div className="text-xs text-white/50">
              {transcribing
                ? tr('trProgress', { p: Math.round(progress * 100), s: Math.floor(elapsed) })
                : error
                  ? null
                  : stopped
                    ? tr('trStopped')
                    : tr('trFinished', { n: segments.length, s: elapsed.toFixed(1) })}
            </div>
            <label className="flex items-center gap-1.5 text-xs text-white/70 cursor-pointer">
              <input
                type="checkbox"
                checked={showTimestamps}
                onChange={(e) => setShowTimestamps(e.target.checked)}
                className="accent-emerald-500"
              />
              {tr('trTimestamps')}
            </label>
          </div>

          {transcribing && (
            <div className="w-full h-1.5 bg-white/5 rounded-full overflow-hidden">
              <div className="h-full bg-emerald-500 transition-all duration-200" style={{ width: `${progress * 100}%` }} />
            </div>
          )}
          {error && (
            <div className="flex items-start gap-2 text-xs text-red-400">
              <XOctagon className="w-4 h-4 flex-shrink-0" /> <span className="break-all">{error}</span>
            </div>
          )}

          {transcript && (
            <div className="max-h-80 overflow-y-auto p-3 bg-slate-950/60 border border-white/5 rounded-xl text-sm text-white/85 leading-relaxed whitespace-pre-wrap select-text">
              {transcript}
            </div>
          )}

          {!transcribing && segments.length > 0 && (
            <div className="flex items-center gap-2">
              <Button onClick={() => copy('transcript', transcript)}>
                {copiedKey === 'transcript' ? tr('copied') : tr('copy')}
              </Button>
              <Button onClick={() => saveFile(`${fileStem}-${tr('trTranscriptSuffix')}.txt`, transcript, 'txt')}>
                {tr('trSaveText')}
              </Button>
              <div className="flex-1" />
              <Button variant="primary" onClick={summarize} disabled={summarizing}>
                <span className="flex items-center gap-1.5">
                  <Sparkles className="w-3.5 h-3.5" /> {tr('trSummarize')}
                </span>
              </Button>
            </div>
          )}
          {saveError && <p className="text-xs text-red-400 break-all">{saveError}</p>}
        </GlassCard>
      )}

      {(notes || summarizing || notesError) && (
        <GlassCard title={tr('trNotes')} icon={Sparkles}>
          {summarizing && !notes && <Loader2 className="w-4 h-4 animate-spin text-white/50" />}
          {notesError && <p className="text-xs text-red-400">{notesError}</p>}
          {saveError && !segments.length && <p className="text-xs text-red-400 break-all">{saveError}</p>}
          {notes && (
            <div className="p-3 bg-slate-950/60 border border-white/5 rounded-xl text-sm text-white/85 leading-relaxed whitespace-pre-wrap select-text">
              {notes}
            </div>
          )}
          {!summarizing && notes && (
            <div className="flex items-center gap-2">
              <Button onClick={() => copy('notes', notes)}>{copiedKey === 'notes' ? tr('copied') : tr('copy')}</Button>
              <Button
                onClick={() => saveFile(`${fileStem}-${tr('trNotesSuffix')}.md`, notes, 'md')}
              >
                {tr('trSaveMarkdown')}
              </Button>
            </div>
          )}
        </GlassCard>
      )}
    </div>
  );
}
