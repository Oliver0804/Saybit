//
//  SettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Combine
import SwiftUI

// MARK: - Search State

class SettingsSearchState: ObservableObject {
    @Published var searchText = ""
}

// MARK: - Navigation

/// 設定視窗目前的分頁；讓選單列、膠囊右鍵、saybit://settings?tab= 都能直接跳到指定分頁
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
}

// MARK: - Search Helper

func settingsMatchesSearch(_ keywords: [String], searchText: String) -> Bool {
    guard !searchText.isEmpty else { return true }
    let query = searchText.lowercased()
    return keywords.contains { $0.lowercased().contains(query) }
}

// MARK: - Settings Tab

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, api, hotkey, dictionary, transcribe, history, statistics, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.Tabs.general
        case .api: return L10n.Tabs.ai
        case .hotkey: return L10n.Tabs.hotkey
        case .dictionary: return L10n.Tabs.dictionary
        case .transcribe: return "檔案轉錄"
        case .history: return L10n.Tabs.history
        case .statistics: return L10n.Tabs.statistics
        case .logs: return L10n.Tabs.logs
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .api: return "cpu"
        case .hotkey: return "keyboard"
        case .dictionary: return "book"
        case .transcribe: return "waveform.badge.plus"
        case .history: return "clock"
        case .statistics: return "chart.bar.fill"
        case .logs: return "doc.text.magnifyingglass"
        }
    }

    /// 側邊欄分組
    enum SidebarGroup: String, CaseIterable {
        case settings, tools, data
        var title: String {
            switch self {
            case .settings: return L10n.Tabs.groupSettings
            case .tools: return L10n.Tabs.groupTools
            case .data: return L10n.Tabs.groupData
            }
        }
    }

    var group: SidebarGroup {
        switch self {
        case .general, .api, .hotkey, .dictionary: return .settings
        case .transcribe: return .tools
        case .history, .statistics, .logs: return .data
        }
    }

    /// 跨分頁搜尋用的關鍵字（分頁內各卡片仍各自過濾）
    var searchKeywords: [String] {
        switch self {
        case .general:
            return GeneralSettingsView.searchKeywords
        case .api:
            return ["AI", "API", "provider", "模型", "model", "服務商", "服务商", "OpenRouter", "Ollama", "LM Studio",
                    "自訂", "custom", "key", "金鑰", "密钥", "連線", "connection", "測試", "prompt", "風格", "style",
                    "提示詞", "語氣", "tone", "語調", "进阶", "進階", "advanced", "max_tokens", "參數", "apple", "本機", "離線"]
        case .hotkey:
            return ["快捷鍵", "hotkey", "shortcut", "快捷键", "鍵盤", "keyboard", "觸發", "trigger", "toggle", "hold",
                    "按住", "雙擊", "double tap", "語音模式", "模式", "mode", "email", "翻譯", "url", "raycast", "捷徑", "說明"]
        case .dictionary:
            return ["字典", "dictionary", "詞彙", "词汇", "辞書", "詞條", "自動學習", "learn", "更正", "技能", "skill",
                    "snippet", "觸發詞"]
        case .transcribe:
            return ["檔案", "转录", "轉錄", "transcribe", "file", "音檔", "影片", "會議", "逐字稿", "字幕", "srt"]
        case .history:
            return ["歷史", "历史", "history", "紀錄", "記錄"]
        case .statistics:
            return ["統計", "统计", "statistics", "stats", "用量", "費用", "cost"]
        case .logs:
            return ["日誌", "日志", "logs", "log", "除錯", "debug"]
        }
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || settingsMatchesSearch(searchKeywords + [title], searchText: query)
    }

    var iconColor: Color {
        switch self {
        case .general: return .gray
        case .api: return .purple
        case .hotkey: return .orange
        case .dictionary: return .blue
        case .transcribe: return .teal
        case .history: return .green
        case .statistics: return .pink
        case .logs: return .brown
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @StateObject private var searchState = SettingsSearchState()
    @ObservedObject private var navigation = SettingsNavigation.shared
    private var selectedTab: SettingsTab { navigation.tab }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    TextField(L10n.Common.searchSettings, text: $searchState.searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !searchState.searchText.isEmpty {
                        Button {
                            searchState.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Tab list
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsTab.SidebarGroup.allCases, id: \.self) { group in
                        Text(group.title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, group == .settings ? 4 : 12)
                            .padding(.bottom, 2)
                        ForEach(SettingsTab.allCases.filter { $0.group == group }) { tab in
                            SidebarRow(
                                tab: tab,
                                isSelected: selectedTab == tab
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    navigation.tab = tab
                                }
                            }
                            .opacity(tab.matches(searchState.searchText) ? 1 : 0.35)
                        }
                    }
                }
                .padding(.horizontal, 8)

                Spacer()

                // Version info
                Text("Saybit v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .padding(.bottom, 12)
            }
            .frame(width: 200)
            .background(Color(.windowBackgroundColor).opacity(0.4))

            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            // Detail content
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView()
                        .environmentObject(searchState)
                case .api:
                    APISettingsView()
                        .environmentObject(searchState)
                case .hotkey:
                    HotKeySettingsView()
                        .environmentObject(searchState)
                case .dictionary:
                    DictionarySettingsView()
                        .environmentObject(searchState)
                case .transcribe:
                    FileTranscriptionView()
                case .history:
                    HistoryView()
                case .statistics:
                    StatisticsView()
                case .logs:
                    LogsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 搜尋時若目前分頁沒有符合項目，自動跳到第一個有符合的分頁
        .onChange(of: searchState.searchText) { _, query in
            guard !query.isEmpty, !selectedTab.matches(query),
                  let first = SettingsTab.allCases.first(where: { $0.matches(query) }) else { return }
            navigation.tab = first
        }
        .frame(minWidth: 1000, idealWidth: 1000, maxWidth: .infinity,
               minHeight: 600, idealHeight: 800, maxHeight: .infinity)
        .id(settingsStore.languagePreference)
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? tab.iconColor : .secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? tab.iconColor.opacity(0.15) : .clear)
                    )

                Text(tab.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.12)
                        : isHovered ? Color.primary.opacity(0.04) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Glass Card Style

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.3), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
    }
}

// MARK: - Setting Rows

/// 設定列：左邊標題 + 說明，右邊控制項（開關、按鈕、選單）。
/// 所有設定頁共用，讓開關統一靠右、說明文字統一字級。
struct SettingRow<Trailing: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let description, !description.isEmpty {
                    SettingDescription(description)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 2)
    }
}

/// 開關列
struct SettingToggle: View {
    let title: String
    var description: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, description: description) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// 滑桿列：標題 + 目前數值，下方滑桿
struct SettingSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var description: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            if let description { SettingDescription(description) }
        }
    }
}

struct SettingDescription: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingDivider: View {
    var body: some View { Divider().opacity(0.3) }
}

/// 子設定（開關打開後才出現的細項）往內縮
struct SettingIndent<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 2)
            }
    }
}

/// 沒有符合搜尋的項目
struct SettingsNoResults: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(L10n.Common.noResults)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

struct GlassSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .padding(.bottom, 8)
    }
}
