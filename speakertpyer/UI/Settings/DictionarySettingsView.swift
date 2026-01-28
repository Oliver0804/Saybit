//
//  DictionarySettingsView.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import CoreData
import SwiftUI

struct DictionarySettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \PersonalDictionaryEntry.term, ascending: true)],
        animation: .default
    )
    private var dictEntries: FetchedResults<PersonalDictionaryEntry>

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SnippetEntry.trigger, ascending: true)],
        animation: .default
    )
    private var snippetEntries: FetchedResults<SnippetEntry>

    @State private var newTerm = ""
    @State private var newPreferred = ""
    @State private var newTrigger = ""
    @State private var newSnippetContent = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - 新增詞條
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "新增詞條", icon: "plus.circle")

                        HStack(spacing: 8) {
                            TextField("原始詞", text: $newTerm)
                                .textFieldStyle(.roundedBorder)

                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)

                            TextField("偏好寫法", text: $newPreferred)
                                .textFieldStyle(.roundedBorder)

                            Button("新增") {
                                addDictionaryEntry()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newTerm.isEmpty || newPreferred.isEmpty)
                        }

                        Text("語音辨識容易出錯的詞彙，LLM 會自動替換")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - 字典列表
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        GlassSectionHeader(title: "字典列表", icon: "book")

                        if dictEntries.isEmpty {
                            HStack {
                                Spacer()
                                Text("尚無字典項目")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        } else {
                            ForEach(dictEntries) { entry in
                                HStack {
                                    Text(entry.term ?? "")
                                        .font(.body)
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(entry.preferred ?? "")
                                        .fontWeight(.medium)
                                    Button {
                                        viewContext.delete(entry)
                                        try? viewContext.save()
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundStyle(.red.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 2)

                                if entry != dictEntries.last {
                                    Divider().opacity(0.2)
                                }
                            }
                        }
                    }
                }

                // MARK: - 新增 Snippet
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSectionHeader(title: "新增 Snippet", icon: "doc.badge.plus")

                        HStack(spacing: 8) {
                            TextField("觸發詞", text: $newTrigger)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)

                            Button("新增") {
                                addSnippetEntry()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newTrigger.isEmpty || newSnippetContent.isEmpty)
                        }

                        Text("Snippet 內容:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $newSnippetContent)
                            .font(.body)
                            .frame(minHeight: 50, maxHeight: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            )

                        Text("說出觸發詞時，LLM 會自動展開為完整內容")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Snippet 列表
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        GlassSectionHeader(title: "Snippet 列表", icon: "doc.text")

                        if snippetEntries.isEmpty {
                            HStack {
                                Spacer()
                                Text("尚無 Snippet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        } else {
                            ForEach(snippetEntries) { entry in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.trigger ?? "")
                                            .fontWeight(.medium)
                                        Text(entry.content ?? "")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Button {
                                        viewContext.delete(entry)
                                        try? viewContext.save()
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundStyle(.red.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 2)

                                if entry != snippetEntries.last {
                                    Divider().opacity(0.2)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Dictionary CRUD

    private func addDictionaryEntry() {
        let entry = PersonalDictionaryEntry(context: viewContext)
        entry.id = UUID()
        entry.term = newTerm
        entry.preferred = newPreferred
        try? viewContext.save()
        newTerm = ""
        newPreferred = ""
    }

    // MARK: - Snippet CRUD

    private func addSnippetEntry() {
        let entry = SnippetEntry(context: viewContext)
        entry.id = UUID()
        entry.trigger = newTrigger
        entry.content = newSnippetContent
        try? viewContext.save()
        newTrigger = ""
        newSnippetContent = ""
    }
}
