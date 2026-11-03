//
//  HistoryListView.swift
//  SaybitiOS
//

import CoreData
import SwiftUI

struct HistoryListView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \TranscriptionRecord.timestamp, ascending: false)],
        animation: .default
    )
    private var records: FetchedResults<TranscriptionRecord>

    @State private var searchText = ""
    @State private var showDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(records) { record in
                    NavigationLink {
                        HistoryDetailView(record: record)
                    } label: {
                        HistoryRow(record: record)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            UIPasteboard.general.string = record.processedText
                        } label: {
                            Label("複製", systemImage: "doc.on.doc")
                        }
                        .tint(.accentColor)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("刪除", systemImage: "trash", role: .destructive) {
                            delete(record)
                        }
                    }
                }
            }
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "還沒有紀錄" : "找不到符合的紀錄",
                        systemImage: searchText.isEmpty ? "clock" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "語音輸入的結果會保存在這裡" : "換個關鍵字試試")
                    )
                }
            }
            .searchable(text: $searchText, prompt: "搜尋內容")
            .onChange(of: searchText) { _, query in
                records.nsPredicate = query.isEmpty
                    ? nil
                    : NSPredicate(format: "processedText CONTAINS[cd] %@ OR rawTranscript CONTAINS[cd] %@", query, query)
            }
            .navigationTitle("歷史")
            .toolbar {
                if !records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("全部刪除", systemImage: "trash", role: .destructive) { showDeleteAll = true }
                    }
                }
            }
            .confirmationDialog("刪除所有紀錄？", isPresented: $showDeleteAll, titleVisibility: .visible) {
                Button("全部刪除", role: .destructive) {
                    try? PersistenceController.shared.deleteAllRecords()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所有語音紀錄都會被刪除，此動作無法復原。")
            }
        }
    }

    private func delete(_ record: TranscriptionRecord) {
        context.delete(record)
        try? context.save()
    }
}

private struct HistoryRow: View {
    @ObservedObject var record: TranscriptionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.processedText ?? "")
                .lineLimit(3)
            HStack(spacing: 6) {
                if let ts = record.timestamp {
                    Text(ts, format: .relative(presentation: .named))
                }
                if let app = record.appContext, !app.isEmpty {
                    Text("· \(app)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct HistoryDetailView: View {
    @ObservedObject var record: TranscriptionRecord
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text(record.processedText ?? "")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("AI 整理結果")
            }
            if let raw = record.rawTranscript, !raw.isEmpty, raw != record.processedText {
                Section {
                    Text(raw)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("原始轉錄")
                } footer: {
                    Text("語音辨識的原文，尚未經過 AI 潤飾。")
                }
            }
            Section("資訊") {
                if let ts = record.timestamp {
                    LabeledContent("時間", value: ts.formatted(date: .abbreviated, time: .shortened))
                }
                if record.duration > 0 {
                    LabeledContent("錄音長度", value: String(format: "%.1f 秒", record.duration))
                }
                if let model = record.modelName, !model.isEmpty {
                    LabeledContent("模型", value: model)
                }
                if record.totalTokens > 0 {
                    LabeledContent("Token 用量", value: "\(record.totalTokens)")
                }
            }
        }
        .navigationTitle("紀錄")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "已複製" : "複製", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = record.processedText
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                ShareLink(item: record.processedText ?? "")
            }
        }
    }
}
