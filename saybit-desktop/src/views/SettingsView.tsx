import { useEffect, useMemo, useState } from 'react';
import {
  Settings as SettingsIcon,
  Cpu,
  Keyboard,
  BookOpen,
  FileAudio,
  History as HistoryIcon,
  BarChart3,
  FileSearch,
  Flame,
} from 'lucide-react';
import { getVersion } from '@tauri-apps/api/app';

import { type useVoicePipeline } from '../hooks/useVoicePipeline';
import { makeTranslator, type L10nKey } from '../services/l10n';
import { checkForUpdateThrottled } from '../services/updateChecker';
import { ApiSection, HotkeySection, DictionarySkillsSection, type SectionProps } from './settings/sections';
import { GeneralSection } from './settings/GeneralSection';
import { HistoryPanel, StatsPanel, LogsPanel, AboutPanel, TutorialPanel } from './panels';
import { OnboardingView } from './OnboardingView';
import { FileTranscriptionView } from './FileTranscriptionView';

/// rawValue 與原生 SettingsTab 相同，saybit://settings?tab=<id> 兩邊通用。
/// tutorial / about 不在側欄（原生版也沒有），從「一般 → 系統」進入。
type TabId =
  | 'general'
  | 'api'
  | 'hotkey'
  | 'dictionary'
  | 'transcribe'
  | 'history'
  | 'statistics'
  | 'logs'
  | 'tutorial'
  | 'about';

type SidebarGroup = 'settings' | 'tools' | 'data';

const TABS: Array<{
  id: TabId;
  labelKey: L10nKey;
  icon: React.ComponentType<{ className?: string }>;
  color: string;
  group: SidebarGroup;
}> = [
  { id: 'general', labelKey: 'navGeneral', icon: SettingsIcon, color: 'text-slate-300', group: 'settings' },
  { id: 'api', labelKey: 'tabAi', icon: Cpu, color: 'text-purple-400', group: 'settings' },
  { id: 'hotkey', labelKey: 'navHotkey', icon: Keyboard, color: 'text-orange-400', group: 'settings' },
  { id: 'dictionary', labelKey: 'tabDictionary', icon: BookOpen, color: 'text-blue-400', group: 'settings' },
  { id: 'transcribe', labelKey: 'tabTranscribe', icon: FileAudio, color: 'text-teal-400', group: 'tools' },
  { id: 'history', labelKey: 'tabHistory', icon: HistoryIcon, color: 'text-green-400', group: 'data' },
  { id: 'statistics', labelKey: 'tabStatistics', icon: BarChart3, color: 'text-pink-400', group: 'data' },
  { id: 'logs', labelKey: 'tabLogs', icon: FileSearch, color: 'text-amber-600', group: 'data' },
];

const GROUPS: Array<{ id: SidebarGroup; labelKey: L10nKey }> = [
  { id: 'settings', labelKey: 'groupSettings' },
  { id: 'tools', labelKey: 'groupTools' },
  { id: 'data', labelKey: 'groupData' },
];

const ALL_TAB_IDS: TabId[] = [...TABS.map((t) => t.id), 'tutorial', 'about'];

/// 舊版 / 別名分頁名稱也接受（例如 saybit://settings?tab=stats）
function resolveTab(raw: string | undefined): TabId | null {
  if (!raw) return null;
  const id = raw.trim().toLowerCase();
  const alias: Record<string, TabId> = { stats: 'statistics', ai: 'api', skills: 'dictionary', transcription: 'transcribe' };
  const resolved = (alias[id] ?? id) as TabId;
  return ALL_TAB_IDS.includes(resolved) ? resolved : null;
}

interface Props {
  pipeline: ReturnType<typeof useVoicePipeline>;
}

export function SettingsView({ pipeline }: Props) {
  const { settings, updateSettings, secrets, reloadSecrets } = pipeline;
  const [activeTab, setActiveTab] = useState<TabId>('general');
  const [version, setVersion] = useState('');

  const tr = useMemo(() => makeTranslator(settings.appLanguage), [settings.appLanguage]);

  useEffect(() => {
    getVersion().then(setVersion).catch(() => {});
  }, []);

  // saybit://settings?tab=…：pipeline（main 視窗）解析後放進 settingsTabRequest，這裡只負責切分頁
  const tabRequest = pipeline.settingsTabRequest;
  useEffect(() => {
    if (!tabRequest) return;
    const tab = resolveTab(tabRequest.tab ?? undefined);
    setActiveTab(tab ?? 'general');
  }, [tabRequest]);

  // 每日最多檢查一次更新，結果存進設定供選單顯示紅點
  useEffect(() => {
    if (!settings.enableAutoUpdateCheck) return;
    checkForUpdateThrottled(settings.lastUpdateCheckAt).then((result) => {
      if (!result) return;
      if (result.kind === 'newer') {
        updateSettings({
          lastUpdateCheckAt: Date.now(),
          availableUpdateTag: result.latest.tagName,
          availableUpdateUrl: result.latest.htmlUrl,
        });
      } else {
        updateSettings({
          lastUpdateCheckAt: Date.now(),
          availableUpdateTag: '',
          availableUpdateUrl: '',
        });
      }
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [settings.enableAutoUpdateCheck]);

  const sectionProps: SectionProps = {
    settings,
    update: updateSettings,
    tr,
    secrets,
    reloadSecrets,
    openTab: (tab) => {
      const resolved = resolveTab(tab);
      if (resolved) setActiveTab(resolved);
    },
  };

  if (!settings.hasCompletedOnboarding) {
    return (
      <OnboardingView
        settings={settings}
        update={updateSettings}
        reloadSecrets={reloadSecrets}
        tr={tr}
        onFinish={(startTutorial) => setActiveTab(startTutorial ? 'tutorial' : 'general')}
      />
    );
  }

  return (
    <div className="flex w-full h-screen bg-slate-950 text-white font-sans overflow-hidden">
      {/* 側邊導航欄 */}
      <div className="flex flex-col w-52 bg-slate-900/50 border-r border-white/5 p-3 flex-shrink-0 overflow-y-auto">
        <div className="flex items-center space-x-3 px-2 py-3 mb-2">
          <div className="flex items-center justify-center w-8 h-8 rounded-xl bg-gradient-to-tr from-emerald-500 to-teal-400 shadow-[0_0_15px_rgba(52,211,153,0.3)]">
            <Flame className="w-4 h-4 text-slate-950" />
          </div>
          <div>
            <h1 className="text-sm font-bold tracking-wider bg-gradient-to-r from-emerald-400 to-teal-200 bg-clip-text text-transparent">
              SAYBIT
            </h1>
            <p className="text-[10px] text-white/30 font-medium">{tr('appTagline')}</p>
          </div>
        </div>

        <nav className="flex-grow">
          {GROUPS.map((group, gi) => (
            <div key={group.id} className={gi === 0 ? 'space-y-0.5' : 'space-y-0.5 mt-3'}>
              <div className="px-2.5 pb-1 text-[11px] font-medium text-white/30">{tr(group.labelKey)}</div>
              {TABS.filter((t) => t.group === group.id).map((tab) => {
                const Icon = tab.icon;
                const active = activeTab === tab.id;
                return (
                  <button
                    key={tab.id}
                    type="button"
                    onClick={() => setActiveTab(tab.id)}
                    className={`flex items-center gap-2.5 w-full px-2 py-1.5 rounded-lg text-[13px] transition-colors cursor-pointer ${
                      active ? 'bg-emerald-500/10 text-white' : 'text-white/60 hover:text-white hover:bg-white/5'
                    }`}
                  >
                    <span
                      className={`flex items-center justify-center w-[22px] h-[22px] rounded-md ${
                        active ? 'bg-white/10' : ''
                      }`}
                    >
                      <Icon className={`w-[14px] h-[14px] ${active ? tab.color : 'text-white/40'}`} />
                    </span>
                    <span>{tr(tab.labelKey)}</span>
                  </button>
                );
              })}
            </div>
          ))}
        </nav>

        <button
          type="button"
          onClick={() => setActiveTab('about')}
          className="flex items-center gap-1.5 px-2 py-3 border-t border-white/5 text-[10px] text-white/25 hover:text-white/50 font-medium cursor-pointer"
        >
          Saybit Desktop v{version}
          {settings.availableUpdateTag && <span className="w-1.5 h-1.5 rounded-full bg-red-500" />}
        </button>
      </div>

      {/* 主工作區 */}
      <div className="flex-grow p-8 overflow-y-auto bg-gradient-to-b from-slate-950 to-slate-900">
        {activeTab === 'general' && <GeneralSection {...sectionProps} />}
        {activeTab === 'api' && <ApiSection {...sectionProps} />}
        {activeTab === 'hotkey' && <HotkeySection {...sectionProps} />}
        {activeTab === 'dictionary' && <DictionarySkillsSection {...sectionProps} />}
        {/* 檔案轉錄一直掛著，切到其他分頁再回來不會遺失進度或結果（原生版把狀態放在 SettingsView 同理） */}
        <div className={activeTab === 'transcribe' ? '' : 'hidden'}>
          <FileTranscriptionView settings={settings} tr={tr} active={activeTab === 'transcribe'} />
        </div>
        {activeTab === 'history' && <HistoryPanel tr={tr} />}
        {activeTab === 'statistics' && <StatsPanel tr={tr} />}
        {activeTab === 'logs' && <LogsPanel tr={tr} />}
        {activeTab === 'tutorial' && <TutorialPanel tr={tr} />}
        {activeTab === 'about' && <AboutPanel tr={tr} />}
      </div>
    </div>
  );
}
