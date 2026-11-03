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
    @EnvironmentObject var searchState: SettingsSearchState
    @EnvironmentObject var settingsStore: SettingsStore

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
    @State private var dictFilter = ""

    private static let dictKeys = ["字典", "dictionary", "詞彙", "词汇", "辞書", "新增", "add", "詞條", "列表", "list", "自動學習", "learn", "更正"]

    private var filteredDictEntries: [PersonalDictionaryEntry] {
        let q = dictFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(dictEntries) }
        return dictEntries.filter {
            ($0.term ?? "").lowercased().contains(q) || ($0.preferred ?? "").lowercased().contains(q)
        }
    }

    private var canAddDictionaryEntry: Bool {
        !newTerm.trimmingCharacters(in: .whitespaces).isEmpty
            && !newPreferred.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isDuplicateTerm: Bool {
        let t = newTerm.trimmingCharacters(in: .whitespaces).lowercased()
        return !t.isEmpty && dictEntries.contains { ($0.term ?? "").lowercased() == t }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // MARK: - 個人字典（新增 + 自動學習 + 列表）
                if settingsMatchesSearch(Self.dictKeys, searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                GlassSectionHeader(title: L10n.Dict.dictList, icon: "book")
                                if !dictEntries.isEmpty {
                                    Text("\(dictEntries.count)")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            // 新增
                            HStack(spacing: 8) {
                                TextField(L10n.Dict.originalTerm, text: $newTerm)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(addDictionaryEntryIfValid)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                TextField(L10n.Dict.preferredForm, text: $newPreferred)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(addDictionaryEntryIfValid)
                                Button(L10n.Common.add, action: addDictionaryEntryIfValid)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(!canAddDictionaryEntry)
                            }
                            if isDuplicateTerm {
                                Label("「\(newTerm.trimmingCharacters(in: .whitespaces))」已在字典裡，新增會覆蓋原本的寫法", systemImage: "info.circle")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            } else {
                                SettingDescription(L10n.Dict.dictDesc)
                            }

                            SettingDivider()

                            SettingToggle(
                                title: "自動學習更正",
                                description: "文字輸入後 30 秒內，你手動把某個詞改掉（例如「鄭」→「John」），Saybit 會把這組更正加進字典，學到時有提示音。只學單一短詞的修改。",
                                isOn: $settingsStore.enableAutoLearnDictionary
                            )

                            if !dictEntries.isEmpty {
                                SettingDivider()

                                if dictEntries.count > 8 {
                                    HStack(spacing: 6) {
                                        Image(systemName: "line.3.horizontal.decrease")
                                            .foregroundStyle(.tertiary)
                                        TextField("篩選詞條", text: $dictFilter)
                                            .textFieldStyle(.plain)
                                    }
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                                }

                                VStack(spacing: 0) {
                                    ForEach(filteredDictEntries) { entry in
                                        DictionaryEntryRow(entry: entry) {
                                            viewContext.delete(entry)
                                            try? viewContext.save()
                                        }
                                        if entry != filteredDictEntries.last {
                                            Divider().opacity(0.15)
                                        }
                                    }
                                }
                                if filteredDictEntries.isEmpty {
                                    SettingDescription("沒有符合「\(dictFilter)」的詞條")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                            } else {
                                VStack(spacing: 6) {
                                    Image(systemName: "character.book.closed")
                                        .font(.title)
                                        .foregroundStyle(.tertiary)
                                    Text(L10n.Dict.emptyDict)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                            }
                        }
                    }
                }

                // MARK: - 新增語音技能
                if settingsMatchesSearch(["技能", "skill", "snippet", "觸發詞", "trigger", "觸發", "新增"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.Dict.addSkill, icon: "sparkles")

                            HStack(spacing: 8) {
                                TextField(L10n.Dict.triggerWord, text: $newTrigger)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 200)

                                Button(L10n.Common.add) {
                                    addSnippetEntry()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(newTrigger.isEmpty || newSnippetContent.isEmpty)
                            }

                            Text(L10n.Dict.promptInstruction)
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $newSnippetContent)
                                .font(.body)
                                .frame(minHeight: 50, maxHeight: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                )

                            Text(L10n.Dict.skillDesc)
                                .font(.body)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.Dict.example)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                Text(L10n.Dict.exampleWrite)
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                Text(L10n.Dict.exampleSummary)
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // MARK: - 語音技能列表
                if settingsMatchesSearch(["技能", "skill", "snippet", "觸發詞", "trigger", "列表", "list"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            GlassSectionHeader(title: L10n.Dict.skillList, icon: "list.star")

                            if snippetEntries.isEmpty {
                                HStack {
                                    Spacer()
                                    Text(L10n.Dict.emptySkills)
                                        .font(.callout)
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
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Button {
                                            viewContext.delete(entry)
                                            try? viewContext.save()
                                        } label: {
                                            Image(systemName: "trash")
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

                if !searchState.searchText.isEmpty
                    && !settingsMatchesSearch(Self.dictKeys, searchText: searchState.searchText)
                    && !settingsMatchesSearch(["技能", "skill", "snippet", "觸發詞", "trigger", "觸發", "新增"], searchText: searchState.searchText)
                    && !settingsMatchesSearch(["技能", "skill", "snippet", "觸發詞", "trigger", "列表", "list"], searchText: searchState.searchText)
                {
                    SettingsNoResults()
                }
            }
            .padding(20)
        }
    }

    // MARK: - Dictionary CRUD

    private func addDictionaryEntryIfValid() {
        guard canAddDictionaryEntry else { return }
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        let preferred = newPreferred.trimmingCharacters(in: .whitespaces)
        // 同一個原始詞只留一筆（覆蓋舊的寫法）
        let existing = dictEntries.first { ($0.term ?? "").lowercased() == term.lowercased() }
        let entry = existing ?? PersonalDictionaryEntry(context: viewContext)
        if existing == nil { entry.id = UUID() }
        entry.term = term
        entry.preferred = preferred
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

// MARK: - 字典列

private struct DictionaryEntryRow: View {
    @ObservedObject var entry: PersonalDictionaryEntry
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.term ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(entry.preferred ?? "")
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .opacity(isHovered ? 1 : 0)
            .help(L10n.Common.delete)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
