//
//  HistoryView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import CoreData
import SwiftUI

struct HistoryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var settingsStore: SettingsStore

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \TranscriptionRecord.timestamp, ascending: false)],
        animation: .default
    )
    private var records: FetchedResults<TranscriptionRecord>

    @State private var selectedRecord: TranscriptionRecord?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteAllConfirmation = false
    @State private var showDeleteOlderConfirmation = false
    @State private var displayedCount = 50

    private let pageSize = 50

    var body: some View {
        HSplitView {
            // MARK: - List
            VStack(spacing: 0) {
                List(Array(records.prefix(displayedCount)), id: \.objectID, selection: $selectedRecord) { record in
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
                                Text(timestamp, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    .onAppear {
                        // Load more when reaching the last item
                        if record.objectID == records.prefix(displayedCount).last?.objectID,
                           displayedCount < records.count {
                            displayedCount += pageSize
                        }
                    }
                }

                // Bottom bar: record count + cleanup actions
                HStack(spacing: 8) {
                    Text("\(records.count) 筆紀錄")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if displayedCount < records.count {
                        Text("(顯示 \(min(displayedCount, records.count)) 筆)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Menu {
                        Button("刪除 7 天前的紀錄") {
                            showDeleteOlderConfirmation = true
                        }
                        Button("刪除 30 天前的紀錄") {
                            deleteRecordsOlderThan(days: 30)
                        }
                        Divider()
                        Button("清除全部紀錄", role: .destructive) {
                            showDeleteAllConfirmation = true
                        }
                    } label: {
                        Label("清理", systemImage: "trash.circle")
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
                                    GlassSectionHeader(title: "原始轉錄", icon: "mic")
                                    Text(record.rawTranscript ?? "-")
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            GlassCard {
                                VStack(alignment: .leading, spacing: 6) {
                                    GlassSectionHeader(title: "處理後文字", icon: "text.badge.checkmark")
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
                                            Label(String(format: "%.1f 秒", record.duration), systemImage: "timer")
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
                                            Label("輸入 \(record.promptTokens)", systemImage: "arrow.up.circle")
                                            Label("輸出 \(record.completionTokens)", systemImage: "arrow.down.circle")
                                            Spacer()
                                            Label("共 \(record.totalTokens) tokens", systemImage: "number")
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
                                    if let text = record.processedText {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(text, forType: .string)
                                    }
                                } label: {
                                    Label("複製結果", systemImage: "doc.on.doc")
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)

                                Button {
                                    if let text = record.rawTranscript {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(text, forType: .string)
                                    }
                                } label: {
                                    Label("複製原始", systemImage: "doc.on.clipboard")
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)

                                Spacer()

                                Button(role: .destructive) {
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("刪除", systemImage: "trash")
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
                        Text("選擇一筆紀錄查看詳情")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedRecord?.id)
        }
        .confirmationDialog("確定刪除此紀錄？", isPresented: $showDeleteConfirmation) {
            Button("刪除", role: .destructive) {
                if let record = selectedRecord {
                    viewContext.delete(record)
                    try? viewContext.save()
                    selectedRecord = nil
                }
            }
        } message: {
            Text("此操作無法復原。")
        }
        .confirmationDialog("確定清除全部紀錄？", isPresented: $showDeleteAllConfirmation) {
            Button("清除全部", role: .destructive) {
                deleteAllRecords()
            }
        } message: {
            Text("將刪除所有 \(records.count) 筆歷史紀錄，此操作無法復原。")
        }
        .confirmationDialog("確定刪除舊紀錄？", isPresented: $showDeleteOlderConfirmation) {
            Button("刪除 7 天前的紀錄", role: .destructive) {
                deleteRecordsOlderThan(days: 7)
            }
        } message: {
            Text("將刪除 7 天前的所有紀錄，此操作無法復原。")
        }
        .onAppear {
            performAutoCleanupIfNeeded()
        }
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
}
