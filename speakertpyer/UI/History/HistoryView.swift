//
//  HistoryView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import AppKit
import CoreData
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var settingsStore: SettingsStore

    @FetchRequest(fetchRequest: HistoryView.makeFetchRequest(), animation: .default)
    private var records: FetchedResults<TranscriptionRecord>

    @State private var selectedRecord: TranscriptionRecord?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteAllConfirmation = false
    @State private var showDeleteOlderConfirmation = false
    @State private var deleteOlderDays = 7
    @State private var searchText = ""
    @State private var displayedCount = 50
    /// 搜尋結果快取：只在搜尋字串或紀錄增減時重算，不在每列 onAppear / 每次 body 重算
    @State private var searchResults: [TranscriptionRecord] = []

    private let pageSize = 50

    /// 分批載入：沒有搜尋時清單只碰前 displayedCount 筆，其餘保持 fault
    private static func makeFetchRequest() -> NSFetchRequest<TranscriptionRecord> {
        let request = NSFetchRequest<TranscriptionRecord>(entityName: "TranscriptionRecord")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \TranscriptionRecord.timestamp, ascending: false)]
        request.fetchBatchSize = 50
        return request
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 依搜尋字串過濾（原文、結果、App 名稱）後的總筆數
    private var filteredCount: Int {
        searchQuery.isEmpty ? records.count : searchResults.count
    }

    /// 目前清單顯示的紀錄（分頁）
    private var visibleRecords: [TranscriptionRecord] {
        searchQuery.isEmpty
            ? Array(records.prefix(displayedCount))
            : Array(searchResults.prefix(displayedCount))
    }

    private func recomputeSearchResults() {
        let q = searchQuery
        guard !q.isEmpty else {
            searchResults = []
            return
        }
        searchResults = records.filter {
            ($0.processedText ?? "").lowercased().contains(q)
                || ($0.rawTranscript ?? "").lowercased().contains(q)
                || ($0.appContext ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        HSplitView {
            // MARK: - List
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField(L10n.History.searchPlaceholder, text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.Common.clearSearch)
                        .accessibilityLabel(L10n.Common.clearSearch)
                    }
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                .padding(8)

                if records.isEmpty {
                    ContentUnavailableView(L10n.History.emptyTitle, systemImage: "waveform",
                                           description: Text(L10n.History.emptyDesc))
                } else if filteredCount == 0 {
                    ContentUnavailableView.search(text: searchText)
                } else {
                let visible = visibleRecords
                List(visible, id: \.objectID, selection: $selectedRecord) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.processedText ?? record.rawTranscript ?? "")
                            .lineLimit(2)
                            .font(.body)

                        HStack(spacing: 6) {
                            Text(record.appContext ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            if let timestamp = record.timestamp {
                                Text(Self.shortTime(timestamp))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    // List 的 id 是 objectID，selection 是 TranscriptionRecord，要明確 tag 型別才對得上
                    .tag(record)
                    .contextMenu {
                        Button(L10n.History.copyResult) { copy(record.processedText ?? record.rawTranscript) }
                        Button(L10n.History.copyRaw) { copy(record.rawTranscript) }
                        Divider()
                        Button(L10n.Common.delete, role: .destructive) {
                            selectedRecord = record
                            showDeleteConfirmation = true
                        }
                    }
                    .onAppear {
                        // Load more when reaching the last item
                        if record.objectID == visible.last?.objectID,
                           displayedCount < filteredCount {
                            displayedCount += pageSize
                        }
                    }
                }
                }

                // Bottom bar: record count + cleanup actions
                HStack(spacing: 8) {
                    Text(L10n.History.recordCount(records.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if displayedCount < records.count {
                        Text(L10n.History.showing(displayedCount, records.count))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Menu {
                        Button(L10n.Export.asJSON) { exportRecords(format: .json) }
                        Button(L10n.Export.asMarkdown) { exportRecords(format: .markdown) }
                        Button(L10n.Export.asCSV) { exportRecords(format: .csv) }
                    } label: {
                        Label(L10n.Export.menuLabel, systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Menu {
                        Button(L10n.History.deleteOlder7) {
                            deleteOlderDays = 7
                            showDeleteOlderConfirmation = true
                        }
                        Button(L10n.History.deleteOlder30) {
                            deleteOlderDays = 30
                            showDeleteOlderConfirmation = true
                        }
                        Divider()
                        Button(L10n.History.deleteAll, role: .destructive) {
                            showDeleteAllConfirmation = true
                        }
                    } label: {
                        Label(L10n.History.cleanup, systemImage: "trash.circle")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .frame(minWidth: 220)

            // MARK: - Detail
            Group {
                if let record = selectedRecord {
                    ScrollView {
                        VStack(spacing: 12) {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 6) {
                                    GlassSectionHeader(title: L10n.History.rawTranscript, icon: "mic")
                                    Text(record.rawTranscript ?? "-")
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            GlassCard {
                                VStack(alignment: .leading, spacing: 6) {
                                    GlassSectionHeader(title: L10n.History.processedText, icon: "text.badge.checkmark")
                                    Text(record.processedText ?? "-")
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            GlassCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    // Row 1: App & Duration
                                    HStack(spacing: 16) {
                                        Label(record.appContext ?? "-", systemImage: "app")
                                        if record.duration > 0 {
                                            Spacer()
                                            Label(String(format: "%.1fs", record.duration), systemImage: "timer")
                                        }
                                    }

                                    Divider()

                                    // Row 2: Model
                                    if let modelName = record.modelName, !modelName.isEmpty {
                                        Label(modelName, systemImage: "cpu")
                                    }

                                    // Row 3: Token usage
                                    if record.totalTokens > 0 {
                                        HStack(spacing: 12) {
                                            Label(L10n.History.inputTokens(record.promptTokens), systemImage: "arrow.up.circle")
                                            Label(L10n.History.outputTokens(record.completionTokens), systemImage: "arrow.down.circle")
                                            Spacer()
                                            Label(L10n.History.totalTokensLabel(record.totalTokens), systemImage: "number")
                                        }
                                        if let cost = ModelPricingTable.cost(
                                            model: record.modelName ?? "",
                                            promptTokens: Int(record.promptTokens),
                                            completionTokens: Int(record.completionTokens)
                                        ) {
                                            Label(L10n.Cost.perRecord(ModelPricingTable.formatUSD(cost)), systemImage: "dollarsign.circle")
                                        }
                                    }

                                    // Row 4: Timestamp
                                    if let timestamp = record.timestamp {
                                        Label(timestamp.formatted(.dateTime.year().month().day().hour().minute().second()), systemImage: "calendar")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 8) {
                                Button {
                                    copy(record.processedText)
                                } label: {
                                    Label(L10n.History.copyResult, systemImage: "doc.on.doc")
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)

                                Button {
                                    copy(record.rawTranscript)
                                } label: {
                                    Label(L10n.History.copyRaw, systemImage: "doc.on.clipboard")
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)

                                Spacer()

                                Button(role: .destructive) {
                                    showDeleteConfirmation = true
                                } label: {
                                    Label(L10n.Common.delete, systemImage: "trash")
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                            .padding(.top, 4)
                        }
                        .padding(16)
                    }
                    .frame(minWidth: 260)
                    .transition(.opacity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary.opacity(0.4))
                        Text(L10n.History.selectRecord)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedRecord?.id)
        }
        .confirmationDialog(L10n.History.confirmDelete, isPresented: $showDeleteConfirmation) {
            Button(L10n.Common.delete, role: .destructive) {
                if let record = selectedRecord {
                    viewContext.delete(record)
                    try? viewContext.save()
                    selectedRecord = nil
                }
            }
        } message: {
            Text(L10n.History.cannotUndo)
        }
        .confirmationDialog(L10n.History.confirmDeleteAll, isPresented: $showDeleteAllConfirmation) {
            Button(L10n.History.deleteAll, role: .destructive) {
                deleteAllRecords()
            }
        } message: {
            Text(L10n.History.deleteAllMessage(records.count))
        }
        .confirmationDialog(L10n.History.confirmDeleteOlder, isPresented: $showDeleteOlderConfirmation) {
            Button(deleteOlderDays == 30 ? L10n.History.deleteOlder30 : L10n.History.deleteOlder7, role: .destructive) {
                deleteRecordsOlderThan(days: deleteOlderDays)
            }
        } message: {
            Text(L10n.History.cannotUndo)
        }
        .onAppear {
            performAutoCleanupIfNeeded()
            recomputeSearchResults()
        }
        .onChange(of: searchText) { _, _ in
            displayedCount = pageSize
            recomputeSearchResults()
        }
        .onChange(of: records.count) { _, _ in recomputeSearchResults() }
    }

    /// 今天顯示「15:49」、昨天「昨天 15:49」、更早「11/2 15:49」，跨年才加年份
    static func shortTime(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return time }
        if cal.isDateInYesterday(date) { return "\(L10n.History.yesterday) \(time)" }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        let day = sameYear
            ? date.formatted(.dateTime.month(.defaultDigits).day())
            : date.formatted(.dateTime.year().month(.defaultDigits).day())
        return "\(day) \(time)"
    }

    private func copy(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Cleanup Actions

    private func deleteAllRecords() {
        selectedRecord = nil
        try? PersistenceController.shared.deleteAllRecords()
        displayedCount = pageSize
    }

    private func deleteRecordsOlderThan(days: Int) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        if selectedRecord?.timestamp ?? Date() < cutoff {
            selectedRecord = nil
        }
        try? PersistenceController.shared.deleteRecords(olderThan: cutoff)
    }

    private func performAutoCleanupIfNeeded() {
        guard settingsStore.enableHistoryAutoCleanup else { return }
        let days = settingsStore.historyRetentionDays
        guard days > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        try? PersistenceController.shared.deleteRecords(olderThan: cutoff)
    }

    // MARK: - Export

    private enum ExportFormat {
        case json, markdown, csv

        var ext: String {
            switch self {
            case .json: return "json"
            case .markdown: return "md"
            case .csv: return "csv"
            }
        }

        var contentType: UTType {
            switch self {
            case .json: return .json
            case .markdown: return UTType(filenameExtension: "md") ?? .plainText
            case .csv: return UTType(filenameExtension: "csv") ?? .commaSeparatedText
            }
        }
    }

    private func exportRecords(format: ExportFormat) {
        let snapshot = Array(records)
        let panel = NSSavePanel()
        panel.title = L10n.Export.savePanelTitle
        panel.allowedContentTypes = [format.contentType]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "saybit-history-\(stamp).\(format.ext)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data: Data
                switch format {
                case .json:     data = Self.encodeJSON(snapshot)
                case .markdown: data = Self.encodeMarkdown(snapshot).data(using: .utf8) ?? Data()
                case .csv:      data = Self.encodeCSV(snapshot).data(using: .utf8) ?? Data()
                }
                try data.write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private static func encodeJSON(_ records: [TranscriptionRecord]) -> Data {
        let isoFormatter = ISO8601DateFormatter()
        let arr: [[String: Any]] = records.map { r in
            [
                "id": r.id?.uuidString ?? "",
                "timestamp": r.timestamp.map { isoFormatter.string(from: $0) } ?? "",
                "appContext": r.appContext ?? "",
                "mode": r.mode ?? "",
                "rawTranscript": r.rawTranscript ?? "",
                "processedText": r.processedText ?? "",
                "duration": r.duration,
                "modelName": r.modelName ?? "",
                "promptTokens": Int(r.promptTokens),
                "completionTokens": Int(r.completionTokens),
                "totalTokens": Int(r.totalTokens),
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: arr,
                                            options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private static func encodeMarkdown(_ records: [TranscriptionRecord]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = "# \(L10n.History.mdTitle)\n\n"
        out += "\(L10n.History.mdCount(records.count))\n\n---\n\n"
        for r in records {
            let ts = r.timestamp.map(formatter.string(from:)) ?? "-"
            out += "## \(ts)\n\n"
            if let app = r.appContext, !app.isEmpty { out += "- App: `\(app)`\n" }
            if let model = r.modelName, !model.isEmpty { out += "- Model: `\(model)`\n" }
            if r.totalTokens > 0 {
                out += "- Tokens: \(L10n.History.mdTokens(r.promptTokens, r.completionTokens, r.totalTokens))\n"
            }
            out += "- \(L10n.History.mdDuration): \(String(format: "%.1f", r.duration))s\n\n"
            if let raw = r.rawTranscript, !raw.isEmpty {
                out += "**\(L10n.History.mdRaw)**\n\n> \(raw.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
            }
            if let processed = r.processedText, !processed.isEmpty {
                out += "**\(L10n.History.mdProcessed)**\n\n\(processed)\n\n"
            }
            out += "---\n\n"
        }
        return out
    }

    private static func encodeCSV(_ records: [TranscriptionRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        let header = "timestamp,app,mode,model,duration_s,prompt_tokens,completion_tokens,total_tokens,raw,processed\n"
        func esc(_ s: String?) -> String {
            var v = s ?? ""
            // 防 CSV 公式注入：以 = + - @ Tab CR 開頭的欄位前置單引號，Excel / Numbers 才不會當公式執行
            if let first = v.first, "=+-@\t\r".contains(first) { v = "'" + v }
            v = v.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(v)\""
        }
        var rows = header
        for r in records {
            let ts = r.timestamp.map(formatter.string(from:)) ?? ""
            rows += [
                esc(ts),
                esc(r.appContext),
                esc(r.mode),
                esc(r.modelName),
                String(format: "%.2f", r.duration),
                String(Int(r.promptTokens)),
                String(Int(r.completionTokens)),
                String(Int(r.totalTokens)),
                esc(r.rawTranscript),
                esc(r.processedText),
            ].joined(separator: ",") + "\n"
        }
        return rows
    }
}
