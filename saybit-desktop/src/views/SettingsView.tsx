import { useEffect, useMemo, useState } from 'react';
import {
  SlidersHorizontal,
  Key,
  Volume2,
  Sparkles,
  Keyboard,
  ArrowRightLeft,
  Layers,
  BookOpen,
  Cpu,
  History as HistoryIcon,
  TrendingUp,
  FileText,
  Info,
  GraduationCap,
  Flame,
} from 'lucide-react';
import { getVersion } from '@tauri-apps/api/app';

import { type useVoicePipeline } from '../hooks/useVoicePipeline';
import { makeTranslator, type L10nKey } from '../services/l10n';
import { checkForUpdateThrottled } from '../services/updateChecker';
import {
  GeneralSection,
  ApiSection,
  SpeechSection,
  PromptSection,
  HotkeySection,
  InjectionSection,
  ContextRulesSection,
  DictionarySection,
  SkillsSection,
  type SectionProps,
} from './settings/sections';
import { HistoryPanel, StatsPanel, LogsPanel, AboutPanel, TutorialPanel } from './panels';
import { OnboardingView } from './OnboardingView';

type TabId =
  | 'general'
  | 'api'
  | 'speech'
  | 'prompt'
  | 'hotkey'
  | 'injection'
  | 'contextRules'
  | 'dictionary'
  | 'skills'
  | 'history'
  | 'stats'
  | 'logs'
  | 'tutorial'
  | 'about';

const TABS: Array<{
  id: TabId;
  labelKey: L10nKey;
  icon: React.ComponentType<{ className?: string }>;
  group: 'settings' | 'data' | 'info';
}> = [
  { id: 'general', labelKey: 'navGeneral', icon: SlidersHorizontal, group: 'settings' },
  { id: 'api', labelKey: 'navApi', icon: Key, group: 'settings' },
  { id: 'speech', labelKey: 'navSpeech', icon: Volume2, group: 'settings' },
  { id: 'prompt', labelKey: 'navPrompt', icon: Sparkles, group: 'settings' },
  { id: 'hotkey', labelKey: 'navHotkey', icon: Keyboard, group: 'settings' },
  { id: 'injection', labelKey: 'navInjection', icon: ArrowRightLeft, group: 'settings' },
  { id: 'contextRules', labelKey: 'navContextRules', icon: Layers, group: 'settings' },
  { id: 'dictionary', labelKey: 'navDictionary', icon: BookOpen, group: 'data' },
  { id: 'skills', labelKey: 'navSkills', icon: Cpu, group: 'data' },
  { id: 'history', labelKey: 'navHistory', icon: HistoryIcon, group: 'data' },
  { id: 'stats', labelKey: 'navStats', icon: TrendingUp, group: 'data' },
  { id: 'logs', labelKey: 'navLogs', icon: FileText, group: 'info' },
  { id: 'tutorial', labelKey: 'navTutorial', icon: GraduationCap, group: 'info' },
  { id: 'about', labelKey: 'navAbout', icon: Info, group: 'info' },
];

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
  };

  if (!settings.hasCompletedOnboarding) {
    return (
      <OnboardingView
        settings={settings}
        update={updateSettings}
        reloadSecrets={reloadSecrets}
        onFinish={() => setActiveTab('general')}
      />
    );
  }

  const groups: Array<{ key: string; tabs: typeof TABS }> = [
    { key: 'settings', tabs: TABS.filter((t) => t.group === 'settings') },
    { key: 'data', tabs: TABS.filter((t) => t.group === 'data') },
    { key: 'info', tabs: TABS.filter((t) => t.group === 'info') },
  ];

  return (
    <div className="flex w-full h-screen bg-slate-950 text-white font-sans overflow-hidden">
      {/* 側邊導航欄 */}
      <div className="flex flex-col w-60 bg-slate-900/50 border-r border-white/5 p-3 flex-shrink-0 overflow-y-auto">
        <div className="flex items-center space-x-3 px-2 py-4 mb-4">
          <div className="flex items-center justify-center w-8 h-8 rounded-xl bg-gradient-to-tr from-emerald-500 to-teal-400 shadow-[0_0_15px_rgba(52,211,153,0.3)]">
            <Flame className="w-4 h-4 text-slate-950" />
          </div>
          <div>
            <h1 className="text-sm font-bold tracking-wider bg-gradient-to-r from-emerald-400 to-teal-200 bg-clip-text text-transparent">
              SAYBIT
            </h1>
            <p className="text-[10px] text-white/30 font-medium">跨平台語音 AI 助手</p>
          </div>
        </div>

        <nav className="flex-grow space-y-4">
          {groups.map((group) => (
            <div key={group.key} className="space-y-1">
              {group.tabs.map((tab) => {
                const Icon = tab.icon;
                const active = activeTab === tab.id;
                return (
                  <button
                    key={tab.id}
                    type="button"
                    onClick={() => setActiveTab(tab.id)}
                    className={`flex items-center space-x-3 w-full px-3 py-2.5 rounded-xl text-xs font-medium transition-all cursor-pointer ${
                      active
                        ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20'
                        : 'text-white/60 hover:text-white hover:bg-white/5 border border-transparent'
                    }`}
                  >
                    <Icon className={`w-4 h-4 ${active ? 'text-emerald-400' : 'text-white/40'}`} />
                    <span>{tr(tab.labelKey)}</span>
                    {tab.id === 'about' && settings.availableUpdateTag && (
                      <span className="ml-auto w-1.5 h-1.5 rounded-full bg-red-500" />
                    )}
                  </button>
                );
              })}
            </div>
          ))}
        </nav>

        <div className="px-2 py-3 border-t border-white/5 text-[10px] text-white/20 font-medium">
          Saybit Desktop v{version}
        </div>
      </div>

      {/* 主工作區 */}
      <div className="flex-grow p-8 overflow-y-auto bg-gradient-to-b from-slate-950 to-slate-900">
        {activeTab === 'general' && <GeneralSection {...sectionProps} />}
        {activeTab === 'api' && <ApiSection {...sectionProps} />}
        {activeTab === 'speech' && <SpeechSection {...sectionProps} />}
        {activeTab === 'prompt' && <PromptSection {...sectionProps} />}
        {activeTab === 'hotkey' && <HotkeySection {...sectionProps} />}
        {activeTab === 'injection' && <InjectionSection {...sectionProps} />}
        {activeTab === 'contextRules' && <ContextRulesSection {...sectionProps} />}
        {activeTab === 'dictionary' && <DictionarySection {...sectionProps} />}
        {activeTab === 'skills' && <SkillsSection {...sectionProps} />}
        {activeTab === 'history' && <HistoryPanel tr={tr} />}
        {activeTab === 'stats' && <StatsPanel tr={tr} />}
        {activeTab === 'logs' && <LogsPanel tr={tr} />}
        {activeTab === 'tutorial' && <TutorialPanel tr={tr} />}
        {activeTab === 'about' && <AboutPanel tr={tr} />}
      </div>
    </div>
  );
}
