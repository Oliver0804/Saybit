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
                if settingsMatchesSearch(["字典", "dictionary", "詞彙", "词汇", "辞書", "新增", "add", "詞條"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            GlassSectionHeader(title: L10n.Dict.addEntry, icon: "plus.circle")

                            HStack(spacing: 8) {
                                TextField(L10n.Dict.originalTerm, text: $newTerm)
                                    .textFieldStyle(.roundedBorder)

                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)

                                TextField(L10n.Dict.preferredForm, text: $newPreferred)
                                    .textFieldStyle(.roundedBorder)

                                Button(L10n.Common.add) {
                                    addDictionaryEntry()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(newTerm.isEmpty || newPreferred.isEmpty)
                            }

                            Text(L10n.Dict.dictDesc)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // MARK: - 字典列表
                if settingsMatchesSearch(["字典", "dictionary", "詞彙", "词汇", "辞書", "列表", "list"], searchText: searchState.searchText) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            GlassSectionHeader(title: L10n.Dict.dictList, icon: "book")

                            if dictEntries.isEmpty {
                                HStack {
                                    Spacer()
                                    Text(L10n.Dict.emptyDict)
                                        .font(.title3)
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
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(entry.preferred ?? "")
                                            .fontWeight(.medium)
                                        Button {
                                            viewContext.delete(entry)
                                            try? viewContext.save()
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.title3)
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
                                .font(.title3)
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
                                        .font(.title3)
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
                                                .font(.title3)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Button {
                                            viewContext.delete(entry)
                                            try? viewContext.save()
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.title3)
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
                    && !settingsMatchesSearch(["字典", "dictionary", "詞彙", "词汇", "辞書", "新增", "add", "詞條"], searchText: searchState.searchText)
                    && !settingsMatchesSearch(["字典", "dictionary", "詞彙", "词汇", "辞書", "列表", "list"], searchText: searchState.searchText)
                    && !settingsMatchesSearch(["技能", "skill", "snippet", "觸發詞", "trigger", "觸發", "新增"], searchText: searchState.searchText)
                    && !settingsMatchesSearch(["技能", "skill", "snippet", "觸發詞", "trigger", "列表", "list"], searchText: searchState.searchText)
                {
                    Text(L10n.Common.noResults)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
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
