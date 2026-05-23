import React, { useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { 
  Settings, 
  History, 
  BookOpen, 
  Flame, 
  Volume2, 
  Key, 
  Cpu, 
  Clock, 
  Trash2, 
  Plus, 
  Check, 
  ArrowRight,
  TrendingUp,
  Award,
  Smartphone,
  Eye,
  EyeOff
} from 'lucide-react';
import { db, type HistoryRecord } from '../services/db';
import { type useVoicePipeline } from '../hooks/useVoicePipeline';

interface SettingsViewProps {
  pipeline: ReturnType<typeof useVoicePipeline>;
}

export function SettingsView({ pipeline }: SettingsViewProps) {
  const { settings, updateSettings } = pipeline;
  const [activeTab, setActiveTab] = useState<'settings' | 'history' | 'dictionary' | 'skills' | 'stats'>('settings');

  // API 金鑰顯示隱藏
  const [showSttKey, setShowSttKey] = useState(false);
  const [showLlmKey, setShowLlmKey] = useState(false);

  // 1. 字典狀態
  const dictionary = useLiveQuery(() => db.dictionary.toArray()) || [];
  const [newWord, setNewWord] = useState('');
  const [newReplacement, setNewReplacement] = useState('');

  const handleAddDict = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newWord.trim() || !newReplacement.trim()) return;
    await db.dictionary.add({ word: newWord.trim(), replacement: newReplacement.trim() });
    setNewWord('');
    setNewReplacement('');
  };

  const handleDeleteDict = async (id: number) => {
    await db.dictionary.delete(id);
  };

  // 2. 技能狀態
  const skills = useLiveQuery(() => db.skills.toArray()) || [];
  const [newTrigger, setNewTrigger] = useState('');
  const [newPrompt, setNewPrompt] = useState('');

  const handleAddSkill = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newTrigger.trim() || !newPrompt.trim()) return;
    await db.skills.add({ triggerWord: newTrigger.trim(), prompt: newPrompt.trim() });
    setNewTrigger('');
    setNewPrompt('');
  };

  const handleDeleteSkill = async (id: number) => {
    await db.skills.delete(id);
  };

  // 3. 歷史紀錄狀態
  const history = useLiveQuery(() => db.history.orderBy('timestamp').reverse().toArray()) || [];
  const [selectedRecord, setSelectedRecord] = useState<HistoryRecord | null>(null);

  const handleClearHistory = async () => {
    if (confirm('確定要清除所有語音輸入歷史紀錄嗎？')) {
      await db.history.clear();
      setSelectedRecord(null);
    }
  };

  // 4. 統計計算
  const totalCount = history.length;
  const totalDuration = history.reduce((sum, r) => sum + r.duration, 0);
  const avgDuration = totalCount > 0 ? (totalDuration / totalCount).toFixed(1) : '0';
  
  // App 排行榜計算
  const appCounts = history.reduce((acc, curr) => {
    acc[curr.appContext] = (acc[curr.appContext] || 0) + 1;
    return acc;
  }, {} as Record<string, number>);

  const sortedApps = Object.entries(appCounts)
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 5);

  return (
    <div className="flex w-full h-screen bg-slate-950 text-white font-sans overflow-hidden">
      {/* 側邊導航欄 Sidebar */}
      <div className="flex flex-col w-64 bg-slate-900/50 border-r border-white/5 p-4 flex-shrink-0">
        <div className="flex items-center space-x-3 px-2 py-4 mb-6">
          <div className="flex items-center justify-center w-8 h-8 rounded-xl bg-gradient-to-tr from-emerald-500 to-teal-400 shadow-[0_0_15px_rgba(52,211,153,0.3)]">
            <Flame className="w-4 h-4 text-slate-950 font-bold" />
          </div>
          <div>
            <h1 className="text-sm font-bold tracking-wider bg-gradient-to-r from-emerald-400 to-teal-200 bg-clip-text text-transparent">SAYBIT</h1>
            <p className="text-[10px] text-white/30 font-medium">跨平台語音 AI 助手</p>
          </div>
        </div>

        <nav className="flex-grow space-y-1">
          {[
            { id: 'settings', label: '核心設定', icon: Settings },
            { id: 'history', label: '歷史紀錄', icon: History },
            { id: 'dictionary', label: '個人字典', icon: BookOpen },
            { id: 'skills', label: '自訂技能', icon: Cpu },
            { id: 'stats', label: '數據統計', icon: TrendingUp },
          ].map((tab) => {
            const Icon = tab.icon;
            const active = activeTab === tab.id;
            return (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id as any)}
                className={`
                  flex items-center space-x-3 w-full px-4 py-3 rounded-xl text-sm font-medium transition-all cursor-pointer
                  ${active 
                    ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 shadow-[inset_0_1px_0_rgba(255,255,255,0.05)]' 
                    : 'text-white/60 hover:text-white hover:bg-white/5 border border-transparent'
                  }
                `}
              >
                <Icon className={`w-4.5 h-4.5 ${active ? 'text-emerald-400' : 'text-white/40'}`} />
                <span>{tab.label}</span>
              </button>
            );
          })}
        </nav>

        <div className="px-2 py-4 border-t border-white/5 text-[10px] text-white/20 font-medium">
          Saybit Desktop v0.1.0 (Beta)
        </div>
      </div>

      {/* 右側主工作區 Main Content Area */}
      <div className="flex-grow p-8 overflow-y-auto bg-gradient-to-b from-slate-950 to-slate-900">
        
        {/* 1. 核心設定分頁 */}
        {activeTab === 'settings' && (
          <div className="max-w-2xl space-y-6 animate-fade-in">
            <div>
              <h2 className="text-xl font-bold">核心功能設定</h2>
              <p className="text-xs text-white/40 mt-1">配置您的語音辨識、LLM 服務商與全局觸發行為。</p>
            </div>

            {/* API 金鑰設定卡片 */}
            <div className="bg-slate-900/60 border border-white/5 rounded-2xl p-6 space-y-4 backdrop-blur-md">
              <div className="flex items-center space-x-2 border-b border-white/5 pb-3">
                <Key className="w-4 h-4 text-emerald-400" />
                <h3 className="text-sm font-bold">API 金鑰配置</h3>
              </div>

              <div className="space-y-4">
                <div className="flex flex-col space-y-1.5">
                  <label className="text-xs text-white/50 font-medium">OpenAI API Key (Whisper 語音轉文字)</label>
                  <div className="relative">
                    <input
                      type={showSttKey ? 'text' : 'password'}
                      value={settings.sttApiKey}
                      onChange={(e) => updateSettings({ sttApiKey: e.target.value })}
                      placeholder="sk-..."
                      className="w-full bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2.5 text-sm font-mono text-emerald-400 focus:outline-none focus:border-emerald-500/50"
                    />
                    <button 
                      onClick={() => setShowSttKey(!showSttKey)}
                      className="absolute right-3 top-3 text-white/40 hover:text-white cursor-pointer"
                    >
                      {showSttKey ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                    </button>
                  </div>
                </div>

                <div className="flex flex-col space-y-1.5">
                  <label className="text-xs text-white/50 font-medium">LLM API Key (意圖分類與精煉，留空則複用上述金鑰)</label>
                  <div className="relative">
                    <input
                      type={showLlmKey ? 'text' : 'password'}
                      value={settings.llmApiKey}
                      onChange={(e) => updateSettings({ llmApiKey: e.target.value })}
                      placeholder="sk-... 或 OpenRouter Key"
                      className="w-full bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2.5 text-sm font-mono text-emerald-400 focus:outline-none focus:border-emerald-500/50"
                    />
                    <button 
                      onClick={() => setShowLlmKey(!showLlmKey)}
                      className="absolute right-3 top-3 text-white/40 hover:text-white cursor-pointer"
                    >
                      {showLlmKey ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                    </button>
                  </div>
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <div className="flex flex-col space-y-1.5">
                    <label className="text-xs text-white/50 font-medium">LLM Endpoint Base URL</label>
                    <input
                      type="text"
                      value={settings.llmBaseUrl}
                      onChange={(e) => updateSettings({ llmBaseUrl: e.target.value })}
                      className="bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2.5 text-sm focus:outline-none focus:border-emerald-500/50"
                    />
                  </div>
                  <div className="flex flex-col space-y-1.5">
                    <label className="text-xs text-white/50 font-medium">LLM 精煉模型</label>
                    <input
                      type="text"
                      value={settings.llmModel}
                      onChange={(e) => updateSettings({ llmModel: e.target.value })}
                      className="bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2.5 text-sm focus:outline-none focus:border-emerald-500/50"
                    />
                  </div>
                </div>
              </div>
            </div>

            {/* 錄音與自動停止卡片 */}
            <div className="bg-slate-900/60 border border-white/5 rounded-2xl p-6 space-y-4 backdrop-blur-md">
              <div className="flex items-center space-x-2 border-b border-white/5 pb-3">
                <Volume2 className="w-4 h-4 text-emerald-400" />
                <h3 className="text-sm font-bold">錄音與靜音偵測</h3>
              </div>

              <div className="space-y-4">
                <div className="flex items-center justify-between">
                  <div>
                    <label className="text-sm font-semibold text-white/90">啟用靜音自動停止</label>
                    <p className="text-[11px] text-white/30 mt-0.5">當您說完話停止發聲時，自動結束錄音並送出處理。</p>
                  </div>
                  <input
                    type="checkbox"
                    checked={settings.enableSilenceStop}
                    onChange={(e) => updateSettings({ enableSilenceStop: e.target.checked })}
                    className="w-9 h-5 rounded-full bg-slate-950 border border-white/10 accent-emerald-500 cursor-pointer"
                  />
                </div>

                {settings.enableSilenceStop && (
                  <div className="grid grid-cols-2 gap-4 animate-slide-down">
                    <div className="flex flex-col space-y-1.5">
                      <label className="text-xs text-white/50 font-medium">語後靜音逾時時間 (秒)</label>
                      <input
                        type="number"
                        min="0.5"
                        max="5.0"
                        step="0.5"
                        value={settings.silenceTimeout}
                        onChange={(e) => updateSettings({ silenceTimeout: parseFloat(e.target.value) })}
                        className="bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2 text-sm focus:outline-none"
                      />
                    </div>
                    <div className="flex flex-col space-y-1.5">
                      <label className="text-xs text-white/50 font-medium">麥克風輸入靈敏度倍率</label>
                      <input
                        type="number"
                        min="0.5"
                        max="5.0"
                        step="0.5"
                        value={settings.sttGain}
                        onChange={(e) => updateSettings({ sttGain: parseFloat(e.target.value) })}
                        className="bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2 text-sm focus:outline-none"
                      />
                    </div>
                  </div>
                )}
              </div>
            </div>

            {/* 注入與智慧確認卡片 */}
            <div className="bg-slate-900/60 border border-white/5 rounded-2xl p-6 space-y-4 backdrop-blur-md">
              <div className="flex items-center space-x-2 border-b border-white/5 pb-3">
                <Clock className="w-4 h-4 text-emerald-400" />
                <h3 className="text-sm font-bold">注入與智慧傳送</h3>
              </div>

              <div className="space-y-4">
                <div className="flex items-center justify-between">
                  <div>
                    <label className="text-sm font-semibold text-white/90">啟用注入前預覽確認</label>
                    <p className="text-[11px] text-white/30 mt-0.5">精煉完成後，在懸浮膠囊上提供確認/重新生成按鈕。</p>
                  </div>
                  <input
                    type="checkbox"
                    checked={settings.enablePreview}
                    onChange={(e) => updateSettings({ enablePreview: e.target.checked })}
                    className="w-9 h-5 rounded-full bg-slate-950 border border-white/10 accent-emerald-500 cursor-pointer"
                  />
                </div>

                <div className="flex items-center justify-between">
                  <div>
                    <label className="text-sm font-semibold text-white/90">啟用 Smart Send (自動 Enter 送出)</label>
                    <p className="text-[11px] text-white/30 mt-0.5">注入成功後進行倒數計時，倒數結束自動按下 Enter 鍵送出。</p>
                  </div>
                  <input
                    type="checkbox"
                    checked={settings.enableSmartSend}
                    onChange={(e) => updateSettings({ enableSmartSend: e.target.checked })}
                    className="w-9 h-5 rounded-full bg-slate-950 border border-white/10 accent-emerald-500 cursor-pointer"
                  />
                </div>

                {settings.enableSmartSend && (
                  <div className="flex flex-col space-y-1.5 animate-slide-down">
                    <label className="text-xs text-white/50 font-medium">Smart Send 倒數秒數</label>
                    <input
                      type="number"
                      min="1"
                      max="10"
                      value={settings.smartSendCountdown}
                      onChange={(e) => updateSettings({ smartSendCountdown: parseInt(e.target.value) })}
                      className="w-32 bg-slate-950/80 border border-white/10 rounded-xl px-4 py-2 text-sm focus:outline-none"
                    />
                  </div>
                )}
              </div>
            </div>
          </div>
        )}

        {/* 2. 歷史紀錄分頁 */}
        {activeTab === 'history' && (
          <div className="flex h-full min-h-[480px] space-x-6 animate-fade-in">
            {/* 左側列表 */}
            <div className="w-1/2 flex flex-col bg-slate-900/40 border border-white/5 rounded-2xl p-4 overflow-hidden">
              <div className="flex items-center justify-between pb-3 border-b border-white/5">
                <span className="text-xs font-bold text-white/60">歷史輸入清單 ({history.length} 筆)</span>
                {history.length > 0 && (
                  <button 
                    onClick={handleClearHistory}
                    className="flex items-center space-x-1 text-xs text-red-400 hover:text-red-300 font-medium cursor-pointer"
                  >
                    <Trash2 className="w-3.5 h-3.5" />
                    <span>清除全部</span>
                  </button>
                )}
              </div>

              <div className="flex-grow overflow-y-auto mt-3 space-y-2 pr-1">
                {history.map((record) => (
                  <div
                    key={record.id}
                    onClick={() => setSelectedRecord(record)}
                    className={`
                      p-3 rounded-xl border text-left transition-all cursor-pointer
                      ${selectedRecord?.id === record.id 
                        ? 'bg-emerald-500/10 border-emerald-500/30' 
                        : 'bg-slate-950/40 border-white/5 hover:border-white/10'
                      }
                    `}
                  >
                    <div className="flex items-center justify-between">
                      <span className="text-[10px] text-white/30 font-semibold">{new Date(record.timestamp).toLocaleTimeString()}</span>
                      <span className="text-[9px] bg-white/5 text-white/50 px-1.5 py-0.5 rounded font-mono uppercase">{record.mode}</span>
                    </div>
                    <p className="text-xs text-white/80 truncate mt-1.5 font-medium">"{record.processedText}"</p>
                  </div>
                ))}
                {history.length === 0 && (
                  <div className="flex flex-col items-center justify-center h-48 text-white/20">
                    <History className="w-10 h-10 mb-2 stroke-[1.5]" />
                    <span className="text-xs">尚無任何輸入歷史紀錄</span>
                  </div>
                )}
              </div>
            </div>

            {/* 右側詳細資料 */}
            <div className="w-1/2 bg-slate-900/60 border border-white/5 rounded-2xl p-6 flex flex-col">
              <h3 className="text-sm font-bold border-b border-white/5 pb-3">歷程詳細紀錄</h3>
              {selectedRecord ? (
                <div className="flex-grow space-y-4 overflow-y-auto mt-4 pr-1 text-left">
                  <div className="space-y-1">
                    <span className="text-[10px] text-white/40 font-bold uppercase">原始語音轉錄內容</span>
                    <div className="p-3 bg-slate-950 rounded-xl border border-white/5 text-xs text-white/60 leading-relaxed font-medium">
                      "{selectedRecord.rawTranscript}"
                    </div>
                  </div>

                  <div className="space-y-1">
                    <span className="text-[10px] text-white/40 font-bold uppercase">AI 精煉注入結果</span>
                    <div className="p-3 bg-slate-950 rounded-xl border border-emerald-500/20 text-xs text-emerald-300 leading-relaxed font-semibold">
                      "{selectedRecord.processedText}"
                    </div>
                  </div>

                  <div className="grid grid-cols-2 gap-4 border-t border-white/5 pt-3 text-[11px] text-white/40 font-medium">
                    <div>
                      <span>擷取上下文: </span>
                      <span className="text-white/80 font-semibold">{selectedRecord.appContext}</span>
                    </div>
                    <div>
                      <span>錄音時長: </span>
                      <span className="text-white/80 font-semibold">{selectedRecord.duration} 秒</span>
                    </div>
                    <div>
                      <span>使用模型: </span>
                      <span className="text-white/80 font-semibold truncate block max-w-xs">{selectedRecord.modelName}</span>
                    </div>
                    <div>
                      <span>日期標籤: </span>
                      <span className="text-white/80 font-semibold">{new Date(selectedRecord.timestamp).toLocaleDateString()}</span>
                    </div>
                  </div>
                </div>
              ) : (
                <div className="flex-grow flex items-center justify-center text-white/20">
                  <span className="text-xs">請點選左側紀錄查看詳情</span>
                </div>
              )}
            </div>
          </div>
        )}

        {/* 3. 個人字典分頁 */}
        {activeTab === 'dictionary' && (
          <div className="max-w-2xl space-y-6 animate-fade-in text-left">
            <div>
              <h2 className="text-xl font-bold">個人字典管理器</h2>
              <p className="text-xs text-white/40 mt-1">自訂核心縮寫或偏好拼寫，精煉時 LLM 將自動參考過濾。</p>
            </div>

            {/* 新增項目 Form */}
            <form onSubmit={handleAddDict} className="flex gap-3 bg-slate-900/40 border border-white/5 p-4 rounded-xl">
              <input
                type="text"
                value={newWord}
                onChange={(e) => setNewWord(e.target.value)}
                placeholder="原始詞彙 (例如: wifi)"
                className="flex-1 bg-slate-950 border border-white/10 rounded-lg px-3 py-2 text-xs focus:outline-none focus:border-emerald-500/50"
              />
              <ArrowRight className="w-4 h-4 text-white/30 self-center" />
              <input
                type="text"
                value={newReplacement}
                onChange={(e) => setNewReplacement(e.target.value)}
                placeholder="偏好寫法 (例如: Wi-Fi)"
                className="flex-1 bg-slate-950 border border-white/10 rounded-lg px-3 py-2 text-xs focus:outline-none focus:border-emerald-500/50"
              />
              <button 
                type="submit"
                className="flex items-center space-x-1 px-4 py-2 bg-emerald-500 hover:bg-emerald-600 text-slate-950 rounded-lg text-xs font-bold cursor-pointer transition-all"
              >
                <Plus className="w-3.5 h-3.5" />
                <span>新增</span>
              </button>
            </form>

            {/* 詞彙對照清單 */}
            <div className="bg-slate-900/60 border border-white/5 rounded-2xl p-6 space-y-4">
              <h3 className="text-xs font-bold text-white/50 uppercase tracking-wider">詞彙對照表</h3>
              <div className="grid grid-cols-2 gap-3">
                {dictionary.map((entry) => (
                  <div key={entry.id} className="flex items-center justify-between p-3 bg-slate-950/60 border border-white/5 rounded-xl">
                    <div className="flex items-center space-x-2 text-xs min-w-0">
                      <span className="text-white/40 truncate max-w-[80px] font-mono">{entry.word}</span>
                      <ArrowRight className="w-3.5 h-3.5 text-emerald-400 flex-shrink-0" />
                      <span className="text-white font-bold truncate max-w-[120px]">{entry.replacement}</span>
                    </div>
                    <button 
                      onClick={() => handleDeleteDict(entry.id!)}
                      className="text-white/35 hover:text-red-400 p-1 cursor-pointer transition-all"
                    >
                      <Trash2 className="w-3.5 h-3.5" />
                    </button>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}

        {/* 4. 語音技能分頁 */}
        {activeTab === 'skills' && (
          <div className="max-w-2xl space-y-6 animate-fade-in text-left">
            <div>
              <h2 className="text-xl font-bold">自訂語音技能 (Snippets)</h2>
              <p className="text-xs text-white/40 mt-1">設定語音關鍵觸發詞，說出時載入自訂指令 Prompt 引導處理。</p>
            </div>

            {/* 新增技能 Form */}
            <form onSubmit={handleAddSkill} className="flex flex-col gap-3 bg-slate-900/40 border border-white/5 p-4 rounded-xl">
              <div className="flex gap-3">
                <input
                  type="text"
                  value={newTrigger}
                  onChange={(e) => setNewTrigger(e.target.value)}
                  placeholder="觸發詞 (例如: 翻譯)"
                  className="w-1/3 bg-slate-950 border border-white/10 rounded-lg px-3 py-2 text-xs focus:outline-none focus:border-emerald-500/50"
                />
                <input
                  type="text"
                  value={newPrompt}
                  onChange={(e) => setNewPrompt(e.target.value)}
                  placeholder="自訂引導指令 (例如: 請將後續發音翻譯成乾淨的英文書信...)"
                  className="flex-1 bg-slate-950 border border-white/10 rounded-lg px-3 py-2 text-xs focus:outline-none focus:border-emerald-500/50"
                />
              </div>
              <button 
                type="submit"
                className="flex items-center justify-center space-x-1.5 py-2 bg-emerald-500 hover:bg-emerald-600 text-slate-950 rounded-lg text-xs font-bold cursor-pointer transition-all"
              >
                <Plus className="w-3.5 h-3.5" />
                <span>新增語音技能</span>
              </button>
            </form>

            {/* 技能項目列表 */}
            <div className="space-y-3">
              {skills.map((skill) => (
                <div key={skill.id} className="flex items-start justify-between p-4 bg-slate-900/60 border border-white/5 rounded-xl">
                  <div className="space-y-1.5 max-w-[90%]">
                    <span className="px-2 py-0.5 bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 text-[10px] font-bold rounded-full">
                      觸發詞: {skill.triggerWord}
                    </span>
                    <p className="text-xs text-white/70 leading-relaxed font-medium">Prompt: {skill.prompt}</p>
                  </div>
                  <button 
                    onClick={() => handleDeleteSkill(skill.id!)}
                    className="text-white/35 hover:text-red-400 p-1 cursor-pointer transition-all self-center"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* 5. 數據統計分頁 */}
        {activeTab === 'stats' && (
          <div className="max-w-2xl space-y-6 animate-fade-in text-left">
            <div>
              <h2 className="text-xl font-bold">數據分析統計</h2>
              <p className="text-xs text-white/40 mt-1">直觀分析您的語音輸入習慣與統計指標。</p>
            </div>

            {/* 4 大指標卡片 */}
            <div className="grid grid-cols-4 gap-4">
              {[
                { label: '累積使用次數', val: totalCount, sub: '今日語音活躍', icon: Award, color: 'text-emerald-400' },
                { label: '平均錄音時長', val: `${avgDuration}s`, sub: '適中錄音區間', icon: Clock, color: 'text-blue-400' },
                { label: '儲存歷史空間', val: `${(totalCount * 0.2).toFixed(1)} KB`, sub: '本地高效儲存', icon: BookOpen, color: 'text-violet-400' },
                { label: '智慧注入比例', val: '100%', sub: '模擬強健貼上', icon: Check, color: 'text-amber-400' }
              ].map((card, i) => {
                const Icon = card.icon;
                return (
                  <div key={i} className="bg-slate-900/60 border border-white/5 rounded-2xl p-4 flex flex-col justify-between backdrop-blur-md">
                    <div className="flex items-center justify-between">
                      <span className="text-[10px] text-white/40 font-bold uppercase tracking-wider">{card.label}</span>
                      <Icon className={`w-4 h-4 ${card.color}`} />
                    </div>
                    <div className="mt-3">
                      <span className="text-2xl font-bold font-mono tracking-tight">{card.val}</span>
                      <span className="text-[9px] text-white/30 block mt-0.5">{card.sub}</span>
                    </div>
                  </div>
                );
              })}
            </div>

            {/* 常見應用排行榜 */}
            <div className="bg-slate-900/60 border border-white/5 rounded-2xl p-6">
              <div className="flex items-center space-x-2 border-b border-white/5 pb-3">
                <Smartphone className="w-4 h-4 text-emerald-400" />
                <h3 className="text-xs font-bold text-white/50 uppercase tracking-wider">常用聚焦應用程式 (Top 5)</h3>
              </div>

              <div className="space-y-4 mt-4">
                {sortedApps.map((app, index) => {
                  const maxCount = sortedApps[0].count;
                  const ratio = maxCount > 0 ? (app.count / maxCount) * 100 : 0;
                  return (
                    <div key={index} className="space-y-1.5">
                      <div className="flex justify-between text-xs font-semibold">
                        <span className="text-white/80">{app.name}</span>
                        <span className="text-emerald-400 font-mono">{app.count} 次</span>
                      </div>
                      <div className="w-full bg-slate-950 rounded-full h-2 overflow-hidden border border-white/5">
                        <div 
                          className="h-full bg-gradient-to-r from-emerald-500 to-teal-400 rounded-full"
                          style={{ width: `${ratio}%` }}
                        />
                      </div>
                    </div>
                  );
                })}

                {sortedApps.length === 0 && (
                  <div className="text-center py-6 text-white/20 text-xs">
                    尚無任何應用程式輸入統計
                  </div>
                )}
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
