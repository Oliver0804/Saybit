// 歷史紀錄、統計、日誌、關於、教學。與設定分區共用同一組視覺元件。
import { useEffect, useMemo, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { openUrl } from '@tauri-apps/plugin-opener';
import { getVersion } from '@tauri-apps/api/app';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  History as HistoryIcon,
  Trash2,
  TrendingUp,
  Clock,
  Award,
  Coins,
  Smartphone,
  FileText,
  Info,
  GraduationCap,
  Mic,
  Sparkles,
  Send,
} from 'lucide-react';

import { db, type HistoryRecord } from '../services/db';
import { formatUSD } from '../services/pricing';
import type { L10nKey } from '../services/l10n';
import { checkForUpdate, type CheckResult } from '../services/updateChecker';
import { GlassCard, Button, Hint } from '../components/ui';

interface PanelProps {
  tr: (key: L10nKey) => string;
}

// ---------------------------------------------------------------- 歷史紀錄

export function HistoryPanel({ tr }: PanelProps) {
  const history = useLiveQuery(() => db.history.orderBy('timestamp').reverse().toArray()) || [];
  const [selected, setSelected] = useState<HistoryRecord | null>(null);
  const [query, setQuery] = useState('');

  const filtered = useMemo(() => {
    if (!query.trim()) return history;
    const q = query.toLowerCase();
    return history.filter(
      (r) =>
        r.rawTranscript.toLowerCase().includes(q) ||
        r.processedText.toLowerCase().includes(q) ||
        (r.appName ?? '').toLowerCase().includes(q)
    );
  }, [history, query]);

  const clearAll = async () => {
    if (confirm('確定要清除所有語音輸入歷史紀錄嗎？')) {
      await db.history.clear();
      setSelected(null);
    }
  };

  return (
    <div className="flex h-full min-h-[480px] space-x-6">
      <div className="w-1/2 flex flex-col bg-slate-900/40 border border-white/5 rounded-2xl p-4 overflow-hidden">
        <div className="flex items-center justify-between pb-3 border-b border-white/5 gap-3">
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="搜尋…"
            className="flex-1 bg-slate-950 border border-white/10 rounded-lg px-3 py-1.5 text-xs focus:outline-none focus:border-emerald-500/50"
          />
          <span className="text-[10px] text-white/40 whitespace-nowrap">{filtered.length} 筆</span>
          {history.length > 0 && (
            <button
              type="button"
              onClick={clearAll}
              className="flex items-center space-x-1 text-xs text-red-400 hover:text-red-300 cursor-pointer"
            >
              <Trash2 className="w-3.5 h-3.5" />
            </button>
          )}
        </div>

        <div className="flex-grow overflow-y-auto mt-3 space-y-2 pr-1">
          {filtered.map((record) => (
            <div
              key={record.id}
              onClick={() => setSelected(record)}
              className={`p-3 rounded-xl border text-left transition-all cursor-pointer ${
                selected?.id === record.id
                  ? 'bg-emerald-500/10 border-emerald-500/30'
                  : 'bg-slate-950/40 border-white/5 hover:border-white/10'
              }`}
            >
              <div className="flex items-center justify-between gap-2">
                <span className="text-[10px] text-white/30 font-semibold">
                  {new Date(record.timestamp).toLocaleString()}
                </span>
                <span className="text-[9px] bg-white/5 text-white/50 px-1.5 py-0.5 rounded font-mono uppercase">
                  {record.intent ?? record.mode}
                </span>
              </div>
              <p className="text-xs text-white/80 truncate mt-1.5 font-medium">
                “{record.processedText}”
              </p>
              {record.appName && (
                <span className="text-[10px] text-emerald-400/70">{record.appName}</span>
              )}
            </div>
          ))}
          {filtered.length === 0 && (
            <div className="flex flex-col items-center justify-center h-48 text-white/20">
              <HistoryIcon className="w-10 h-10 mb-2 stroke-[1.5]" />
              <span className="text-xs">{tr('noData')}</span>
            </div>
          )}
        </div>
      </div>

      <div className="w-1/2 bg-slate-900/60 border border-white/5 rounded-2xl p-6 flex flex-col">
        <h3 className="text-sm font-bold border-b border-white/5 pb-3">歷程詳細紀錄</h3>
        {selected ? (
          <div className="flex-grow space-y-4 overflow-y-auto mt-4 pr-1 text-left">
            <div className="space-y-1">
              <span className="text-[10px] text-white/40 font-bold uppercase">原始轉錄</span>
              <div className="p-3 bg-slate-950 rounded-xl border border-white/5 text-xs text-white/60 leading-relaxed">
                “{selected.rawTranscript}”
              </div>
            </div>
            <div className="space-y-1">
              <span className="text-[10px] text-white/40 font-bold uppercase">精煉結果</span>
              <div className="p-3 bg-slate-950 rounded-xl border border-emerald-500/20 text-xs text-emerald-300 leading-relaxed font-semibold">
                “{selected.processedText}”
              </div>
            </div>
            <div className="grid grid-cols-2 gap-3 border-t border-white/5 pt-3 text-[11px] text-white/40">
              <Detail label="前景 App" value={selected.appName || selected.appContext} />
              <Detail label="錄音時長" value={`${selected.duration} 秒`} />
              <Detail label="意圖" value={selected.intent ?? selected.mode} />
              <Detail label="語氣" value={selected.tone ?? '自動'} />
              <Detail label="模型" value={selected.modelName} />
              <Detail
                label="Token"
                value={`${selected.promptTokens} + ${selected.completionTokens} = ${selected.totalTokens}`}
              />
              <Detail
                label="估計成本"
                value={
                  selected.costUsd == null ? '未知模型' : formatUSD(selected.costUsd)
                }
              />
              <Detail label="日期" value={new Date(selected.timestamp).toLocaleDateString()} />
            </div>
          </div>
        ) : (
          <div className="flex-grow flex items-center justify-center text-white/20">
            <span className="text-xs">請點選左側紀錄查看詳情</span>
          </div>
        )}
      </div>
    </div>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <span>{label}: </span>
      <span className="text-white/80 font-semibold break-all">{value}</span>
    </div>
  );
}

// ---------------------------------------------------------------- 統計

export function StatsPanel({ tr }: PanelProps) {
  const history = useLiveQuery(() => db.history.toArray()) || [];

  const stats = useMemo(() => {
    const totalCount = history.length;
    const totalDuration = history.reduce((sum, r) => sum + r.duration, 0);
    const totalTokens = history.reduce((sum, r) => sum + (r.totalTokens || 0), 0);
    // 只有算得出價格的紀錄才計入，避免未知模型被當成 0 元誤導
    const priced = history.filter((r) => r.costUsd != null);
    const totalCost = priced.reduce((sum, r) => sum + (r.costUsd || 0), 0);

    const appCounts: Record<string, number> = {};
    for (const r of history) {
      const key = r.appName || r.appContext || 'unknown';
      appCounts[key] = (appCounts[key] || 0) + 1;
    }
    const topApps = Object.entries(appCounts)
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 5);

    const intentCounts: Record<string, number> = {};
    for (const r of history) {
      const key = r.intent || r.mode || 'dictation';
      intentCounts[key] = (intentCounts[key] || 0) + 1;
    }
    const byIntent = Object.entries(intentCounts)
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count);

    return {
      totalCount,
      avgDuration: totalCount > 0 ? (totalDuration / totalCount).toFixed(1) : '0',
      totalTokens,
      totalCost,
      pricedCount: priced.length,
      topApps,
      byIntent,
    };
  }, [history]);

  const cards = [
    { label: tr('totalCount'), value: String(stats.totalCount), icon: Award, color: 'text-emerald-400' },
    { label: tr('avgDuration'), value: `${stats.avgDuration}s`, icon: Clock, color: 'text-blue-400' },
    {
      label: tr('totalTokens'),
      value: stats.totalTokens.toLocaleString(),
      icon: TrendingUp,
      color: 'text-violet-400',
    },
    {
      label: tr('totalCost'),
      value: formatUSD(stats.totalCost),
      icon: Coins,
      color: 'text-amber-400',
    },
  ];

  return (
    <div className="max-w-3xl space-y-6 text-left">
      <div className="grid grid-cols-4 gap-4">
        {cards.map((card, i) => {
          const Icon = card.icon;
          return (
            <div
              key={i}
              className="bg-slate-900/60 border border-white/5 rounded-2xl p-4 flex flex-col justify-between backdrop-blur-md"
            >
              <div className="flex items-center justify-between">
                <span className="text-[10px] text-white/40 font-bold uppercase tracking-wider">
                  {card.label}
                </span>
                <Icon className={`w-4 h-4 ${card.color}`} />
              </div>
              <span className="text-2xl font-bold font-mono tracking-tight mt-3">{card.value}</span>
            </div>
          );
        })}
      </div>

      {stats.pricedCount < stats.totalCount && (
        <Hint>
          ⓘ 成本僅統計得到已知價目的 {stats.pricedCount} / {stats.totalCount} 筆；
          自訂端點或本地模型不列入。
        </Hint>
      )}

      <GlassCard title={tr('topApps')} icon={Smartphone}>
        <BarList items={stats.topApps} emptyText={tr('noData')} />
      </GlassCard>

      <GlassCard title={tr('byIntent')} icon={TrendingUp}>
        <BarList items={stats.byIntent} emptyText={tr('noData')} />
      </GlassCard>
    </div>
  );
}

function BarList({
  items,
  emptyText,
}: {
  items: Array<{ name: string; count: number }>;
  emptyText: string;
}) {
  if (items.length === 0) {
    return <div className="text-center py-6 text-white/20 text-xs">{emptyText}</div>;
  }
  const max = items[0].count;
  return (
    <div className="space-y-4">
      {items.map((item, index) => (
        <div key={index} className="space-y-1.5">
          <div className="flex justify-between text-xs font-semibold">
            <span className="text-white/80">{item.name}</span>
            <span className="text-emerald-400 font-mono">{item.count} 次</span>
          </div>
          <div className="w-full bg-slate-950 rounded-full h-2 overflow-hidden border border-white/5">
            <div
              className="h-full bg-gradient-to-r from-emerald-500 to-teal-400 rounded-full"
              style={{ width: `${max > 0 ? (item.count / max) * 100 : 0}%` }}
            />
          </div>
        </div>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------- 日誌

export function LogsPanel({ tr }: PanelProps) {
  const [kind, setKind] = useState<'frontend' | 'startup'>('frontend');
  const [content, setContent] = useState('');
  const [error, setError] = useState('');

  const load = (which: 'frontend' | 'startup') => {
    setError('');
    invoke<string>('read_log', { kind: which, maxLines: 500 })
      .then(setContent)
      .catch((e) => setError(String(e)));
  };

  useEffect(() => {
    load(kind);
  }, [kind]);

  return (
    <div className="max-w-4xl space-y-4 text-left">
      <GlassCard title={tr('navLogs')} icon={FileText}>
        <div className="flex items-center gap-2">
          <Button onClick={() => setKind('frontend')} variant={kind === 'frontend' ? 'primary' : 'secondary'}>
            frontend.log
          </Button>
          <Button onClick={() => setKind('startup')} variant={kind === 'startup' ? 'primary' : 'secondary'}>
            startup.log
          </Button>
          <div className="flex-1" />
          <Button onClick={() => load(kind)}>{tr('refresh')}</Button>
          <Button
            variant="danger"
            onClick={async () => {
              await invoke('clear_log', { kind }).catch(() => {});
              load(kind);
            }}
          >
            清空
          </Button>
        </div>
        {error && <Hint>⚠️ {error}</Hint>}
        <pre className="bg-slate-950 border border-white/5 rounded-xl p-4 text-[11px] font-mono text-white/60 leading-relaxed overflow-auto max-h-[480px] whitespace-pre-wrap">
          {content || '（沒有內容）'}
        </pre>
      </GlassCard>
    </div>
  );
}

// ---------------------------------------------------------------- 關於

export function AboutPanel({ tr }: PanelProps) {
  const [version, setVersion] = useState('');
  const [checking, setChecking] = useState(false);
  const [result, setResult] = useState<CheckResult | null>(null);
  const [error, setError] = useState('');

  useEffect(() => {
    getVersion().then(setVersion).catch(() => {});
  }, []);

  const runCheck = async () => {
    setChecking(true);
    setError('');
    try {
      setResult(await checkForUpdate());
    } catch (e: any) {
      setError(String(e?.message || e));
    } finally {
      setChecking(false);
    }
  };

  return (
    <div className="max-w-2xl space-y-6 text-left">
      <GlassCard title={tr('navAbout')} icon={Info}>
        <div className="flex items-center gap-4">
          <div className="flex items-center justify-center w-14 h-14 rounded-2xl bg-gradient-to-tr from-emerald-500 to-teal-400">
            <Mic className="w-7 h-7 text-slate-950" />
          </div>
          <div>
            <h2 className="text-lg font-bold">Saybit Desktop</h2>
            <p className="text-xs text-white/40">版本 {version || '…'}</p>
          </div>
        </div>
        <Hint>
          智慧語音輸入助手：把語音轉成精準文字並注入你正在使用的任何應用程式。
          支援聽寫、指令與編輯模式，可用雲端 Whisper 或完全離線的本地 whisper.cpp。
        </Hint>

        <div className="flex items-center gap-3">
          <Button onClick={runCheck} disabled={checking}>
            {checking ? '檢查中…' : '檢查更新'}
          </Button>
          <Button onClick={() => openUrl('https://github.com/Oliver0804/Saybit').catch(() => {})}>
            GitHub
          </Button>
        </div>

        {result?.kind === 'newer' && (
          <Hint>
            🎉 有新版本 {result.latest.tagName}（目前 {result.current}）—{' '}
            <button
              type="button"
              onClick={() => openUrl(result.latest.htmlUrl).catch(() => {})}
              className="text-emerald-300 underline cursor-pointer"
            >
              前往下載
            </button>
          </Hint>
        )}
        {result?.kind === 'upToDate' && <Hint>✓ 已是最新版本（{result.current}）</Hint>}
        {result?.kind === 'ahead' && (
          <Hint>目前版本 {result.current} 比已發佈的 {result.latest} 新（開發版）。</Hint>
        )}
        {error && <Hint>⚠️ {error}</Hint>}
      </GlassCard>
    </div>
  );
}

// ---------------------------------------------------------------- 教學

const TUTORIAL_STEPS = [
  {
    icon: Mic,
    title: '按下快捷鍵開始說話',
    body: '預設是 Ctrl+Alt+Space。膠囊會浮出來顯示波形。你也可以改成「按住說話」，放開就送出。',
  },
  {
    icon: Sparkles,
    title: '語音會先被辨識，再被精煉',
    body: '第一步把聲音轉成逐字稿，第二步由 LLM 去掉贅詞、補標點、依你所在的 App 調整語氣。在 Slack 會比較口語，在 Gmail 會比較正式。',
  },
  {
    icon: Send,
    title: '結果直接打進正在用的視窗',
    body: '不需要複製貼上。開啟「智慧傳送」後還會自動按 Enter，聊天室情境完全免手動。',
  },
  {
    icon: GraduationCap,
    title: '選取文字後說話 = 用嘴巴改字',
    body: '先選一段文字再按快捷鍵，說「翻譯成日文」或「改成正式語氣」，選取的內容會被直接改寫。',
  },
];

export function TutorialPanel({ tr }: PanelProps) {
  return (
    <div className="max-w-2xl space-y-4 text-left">
      <h2 className="text-xl font-bold">{tr('navTutorial')}</h2>
      {TUTORIAL_STEPS.map((step, index) => {
        const Icon = step.icon;
        return (
          <div
            key={index}
            className="flex gap-4 bg-slate-900/60 border border-white/5 rounded-2xl p-5"
          >
            <div className="flex items-center justify-center w-10 h-10 rounded-xl bg-emerald-500/10 border border-emerald-500/20 flex-shrink-0">
              <Icon className="w-5 h-5 text-emerald-400" />
            </div>
            <div>
              <h3 className="text-sm font-bold text-white/90">
                {index + 1}. {step.title}
              </h3>
              <p className="text-xs text-white/50 mt-1 leading-relaxed">{step.body}</p>
            </div>
          </div>
        );
      })}
    </div>
  );
}
