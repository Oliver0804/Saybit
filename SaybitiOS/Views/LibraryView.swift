//
//  LibraryView.swift
//  SaybitiOS
//
//  個人字典（專有名詞校正）與技能（自訂處理指令）。
//

import CoreData
import SwiftUI

struct LibraryView: View {
    enum Category: String, CaseIterable, Identifiable {
        case dictionary = "個人字典"
        case skills = "技能"
        var id: String { rawValue }
    }

    @State private var category: Category = .dictionary
    @State private var editingDictionary: PersonalDictionaryEntry?
    @State private var editingSkill: SnippetEntry?
    @State private var showNewDictionary = false
    @State private var showNewSkill = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("類別", selection: $category) {
                    ForEach(Category.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch category {
                case .dictionary:
                    DictionaryList(
                        onEdit: { editingDictionary = $0 },
                        onAdd: { showNewDictionary = true }
                    )
                case .skills:
                    SkillList(
                        onEdit: { editingSkill = $0 },
                        onAdd: { showNewSkill = true }
                    )
                }
            }
            .navigationTitle("詞庫")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(category == .dictionary ? "新增字詞" : "新增技能", systemImage: "plus") {
                        if category == .dictionary { showNewDictionary = true } else { showNewSkill = true }
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $showNewDictionary) { DictionaryEditor(entry: nil) }
            .sheet(item: $editingDictionary) { DictionaryEditor(entry: $0) }
            .sheet(isPresented: $showNewSkill) { SkillEditor(entry: nil) }
            .sheet(item: $editingSkill) { SkillEditor(entry: $0) }
        }
    }
}

// MARK: - Dictionary

private struct DictionaryList: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \PersonalDictionaryEntry.term, ascending: true)])
    private var entries: FetchedResults<PersonalDictionaryEntry>
    let onEdit: (PersonalDictionaryEntry) -> Void
    let onAdd: () -> Void

    @State private var pendingDelete: PersonalDictionaryEntry?

    var body: some View {
        List {
            SwiftUI.Section {
                ForEach(entries) { entry in
                    Button { onEdit(entry) } label: {
                        HStack {
                            Text(entry.term ?? "").foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(entry.preferred ?? "").foregroundStyle(.primary)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("刪除", systemImage: "trash", role: .destructive) {
                            pendingDelete = entry
                        }
                    }
                }
            } footer: {
                if !entries.isEmpty {
                    Text("AI 潤飾時會把左邊的詞統一寫成右邊的寫法，適合人名、品牌、專有名詞。")
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("還沒有字詞", systemImage: "character.book.closed")
                } description: {
                    Text("把常被聽錯的人名、品牌或專有名詞加進來，AI 潤飾時就會統一寫成你要的寫法。")
                } actions: {
                    Button("新增字詞", action: onAdd)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .confirmationDialog(
            "刪除「\(pendingDelete?.term ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除字詞", role: .destructive) {
                if let entry = pendingDelete {
                    context.delete(entry)
                    try? context.save()
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("刪除後 AI 就不會再自動替換這個詞。")
        }
    }
}

private struct DictionaryEditor: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    let entry: PersonalDictionaryEntry?
    @State private var term = ""
    @State private var preferred = ""

    private var canSave: Bool {
        !term.trimmingCharacters(in: .whitespaces).isEmpty
            && !preferred.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    TextField("聽到的詞（例如 open ai）", text: $term)
                        .textInputAutocapitalization(.never)
                    TextField("正確寫法（例如 OpenAI）", text: $preferred)
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("辨識到左邊的說法時，會換成右邊的寫法。英文詞只在整個單字相符時替換。")
                }
            }
            .navigationTitle(entry == nil ? "新增字詞" : "編輯字詞")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        let target = entry ?? PersonalDictionaryEntry(context: context)
                        if entry == nil { target.id = UUID() }
                        target.term = term.trimmingCharacters(in: .whitespaces)
                        target.preferred = preferred.trimmingCharacters(in: .whitespaces)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                term = entry?.term ?? ""
                preferred = entry?.preferred ?? ""
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Skills

private struct SkillList: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SnippetEntry.trigger, ascending: true)])
    private var entries: FetchedResults<SnippetEntry>
    let onEdit: (SnippetEntry) -> Void
    let onAdd: () -> Void

    @State private var pendingDelete: SnippetEntry?

    var body: some View {
        List {
            SwiftUI.Section {
                ForEach(entries) { entry in
                    Button { onEdit(entry) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.trigger ?? "").font(.headline).foregroundStyle(.primary)
                            Text(entry.content ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("刪除", systemImage: "trash", role: .destructive) {
                            pendingDelete = entry
                        }
                    }
                }
            } footer: {
                if !entries.isEmpty {
                    Text("說話時提到技能名稱（例如「幫我條列這段：…」），AI 會套用對應的處理指令。")
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("還沒有技能", systemImage: "wand.and.stars")
                } description: {
                    Text("技能是你自己寫的處理指令，例如「整理成會議紀錄」。說話時提到技能名稱就會套用。")
                } actions: {
                    Button("新增技能", action: onAdd)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .confirmationDialog(
            "刪除「\(pendingDelete?.trigger ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除技能", role: .destructive) {
                if let entry = pendingDelete {
                    context.delete(entry)
                    try? context.save()
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("此動作無法復原。")
        }
    }
}

private struct SkillEditor: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    let entry: SnippetEntry?
    @State private var trigger = ""
    @State private var content = ""

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("技能名稱") {
                    TextField("例如：會議紀錄", text: $trigger)
                }
                SwiftUI.Section {
                    TextEditor(text: $content)
                        .frame(minHeight: 160)
                } header: {
                    Text("處理指令")
                } footer: {
                    Text("用自然語言寫清楚你要的結果，例如「整理成條列式的會議紀錄，開頭寫出日期與參與者」。")
                }
            }
            .navigationTitle(entry == nil ? "新增技能" : "編輯技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        let target = entry ?? SnippetEntry(context: context)
                        if entry == nil { target.id = UUID() }
                        target.trigger = trigger.trimmingCharacters(in: .whitespaces)
                        target.content = content
                        try? context.save()
                        dismiss()
                    }
                    .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || content.isEmpty)
                }
            }
            .onAppear {
                trigger = entry?.trigger ?? ""
                content = entry?.content ?? ""
            }
        }
    }
}
