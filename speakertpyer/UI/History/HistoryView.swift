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

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \TranscriptionRecord.timestamp, ascending: false)],
        animation: .default
    )
    private var records: FetchedResults<TranscriptionRecord>

    @State private var selectedRecord: TranscriptionRecord?
    @State private var showDeleteConfirmation = false

    var body: some View {
        HSplitView {
            // MARK: - List
            List(records, selection: $selectedRecord) { record in
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
    }

}
