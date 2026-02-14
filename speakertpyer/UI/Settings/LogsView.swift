//
//  LogsView.swift
//  speakertpyer
//
//  Created by Claude on 2026/2/14.
//

import SwiftUI
import UniformTypeIdentifiers

struct LogsView: View {
    private let logger = AppLogger.shared

    @State private var selectedLevel: LogLevel? = nil
    @State private var selectedCategory: String? = nil
    @State private var searchText = ""
    @State private var autoScroll = true

    private var categories: [String] {
        let allCategories = Set(logger.entries.map(\.category))
        return allCategories.sorted()
    }

    private var filteredEntries: [LogEntry] {
        logger.entries.filter { entry in
            if let level = selectedLevel, entry.level != level {
                return false
            }
            if let category = selectedCategory, entry.category != category {
                return false
            }
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let matchesMessage = entry.message.lowercased().contains(query)
                let matchesCategory = entry.category.lowercased().contains(query)
                if !matchesMessage && !matchesCategory {
                    return false
                }
            }
            return true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassSectionHeader(title: L10n.Settings.logs, icon: "doc.text.magnifyingglass")

                // 篩選列
                filterBar

                // 日誌列表
                GlassCard {
                    logList
                }
            }
            .padding(20)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        GlassCard {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    // 等級篩選
                    HStack(spacing: 4) {
                        Text(L10n.Settings.logLevel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        levelFilterButtons
                    }

                    Divider().frame(height: 20)

                    // 分類篩選
                    HStack(spacing: 4) {
                        Text(L10n.Settings.logCategory)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        categoryPicker
                    }

                    Spacer()

                    // 自動捲動
                    Toggle(isOn: $autoScroll) {
                        Text(L10n.Settings.logAutoScroll)
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                }

                HStack(spacing: 8) {
                    // 搜尋
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                        TextField(L10n.Settings.logSearch, text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.06))
                    )

                    Spacer()

                    // 計數
                    Text("\(filteredEntries.count) / \(logger.entries.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    // 操作按鈕
                    Button {
                        exportLogs()
                    } label: {
                        Label(L10n.Settings.logExport, systemImage: "square.and.arrow.up")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        logger.clear()
                    } label: {
                        Label(L10n.Settings.logClear, systemImage: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Level Filter Buttons

    private var levelFilterButtons: some View {
        HStack(spacing: 2) {
            levelButton(nil, label: L10n.Common.all)
            ForEach(LogLevel.allCases, id: \.self) { level in
                levelButton(level, label: level.rawValue)
            }
        }
    }

    private func levelButton(_ level: LogLevel?, label: String) -> some View {
        Button {
            selectedLevel = level
        } label: {
            Text(label)
                .font(.system(size: 10, weight: selectedLevel == level ? .bold : .regular, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selectedLevel == level ? levelColor(level).opacity(0.2) : Color.clear)
                )
                .foregroundStyle(selectedLevel == level ? levelColor(level) : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Category Picker

    private var categoryPicker: some View {
        Picker("", selection: $selectedCategory) {
            Text(L10n.Common.all).tag(Optional<String>.none)
            ForEach(categories, id: \.self) { category in
                Text(category).tag(Optional(category))
            }
        }
        .pickerStyle(.menu)
        .frame(width: 120)
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            LazyVStack(alignment: .leading, spacing: 1) {
                if filteredEntries.isEmpty {
                    HStack {
                        Spacer()
                        Text(L10n.Settings.logEmpty)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 40)
                        Spacer()
                    }
                } else {
                    ForEach(filteredEntries) { entry in
                        logRow(entry)
                            .id(entry.id)
                    }
                }
            }
            .onChange(of: logger.entries.count) { _, _ in
                if autoScroll, let lastEntry = filteredEntries.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 300)
    }

    // MARK: - Log Row

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // 時間戳
            Text(formatTime(entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 75, alignment: .leading)

            // 等級標籤
            Text(entry.level.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 42, alignment: .center)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(levelColor(entry.level).opacity(0.1))
                )

            // 分類
            Text(entry.category)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.8))
                .frame(width: 70, alignment: .leading)

            // 訊息
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(entry.level == .error ? .red : .primary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            entry.level == .error
                ? Color.red.opacity(0.05)
                : Color.clear
        )
    }

    // MARK: - Helpers

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private func levelColor(_ level: LogLevel?) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        case nil: return .primary
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "saybit-logs.txt"
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content = filteredEntries
            .map(\.formatted)
            .joined(separator: "\n")

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            AppLogger.shared.info("日誌已匯出到 \(url.lastPathComponent)", category: "App")
        } catch {
            AppLogger.shared.error("日誌匯出失敗: \(error.localizedDescription)", category: "App")
        }
    }
}
