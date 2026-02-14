//
//  Persistence.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext

        // Sample data for previews
        let record = TranscriptionRecord(context: viewContext)
        record.id = UUID()
        record.rawTranscript = "嗯那個跟你說一下我今天下午那個會議可能要延後"
        record.processedText = "跟你說一下，今天下午的會議可能要延後。"
        record.appContext = "Slack"
        record.mode = "dictation"
        record.timestamp = Date()
        record.duration = 5.2

        let dictEntry = PersonalDictionaryEntry(context: viewContext)
        dictEntry.id = UUID()
        dictEntry.term = "openai"
        dictEntry.preferred = "OpenAI"

        let snippet = SnippetEntry(context: viewContext)
        snippet.id = UUID()
        snippet.trigger = "回覆確認"
        snippet.content = "您好，\n\n已收到您的來信，我會儘快回覆。\n\n謝謝。"

        do {
            try viewContext.save()
        } catch {
            AppLogger.shared.error("Preview Core Data 儲存失敗: \(error.localizedDescription)", category: "CoreData")
        }
        return result
    }()

    let container: NSPersistentContainer

    // MARK: - Batch Operations

    /// Delete all transcription records
    func deleteAllRecords() throws {
        let context = container.viewContext
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = TranscriptionRecord.fetchRequest()
        let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        batchDelete.resultType = .resultTypeObjectIDs
        let result = try context.execute(batchDelete) as? NSBatchDeleteResult
        if let objectIDs = result?.result as? [NSManagedObjectID] {
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                into: [context]
            )
        }
    }

    /// Delete records older than a given date
    func deleteRecords(olderThan date: Date) throws {
        let context = container.viewContext
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = TranscriptionRecord.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "timestamp < %@", date as NSDate)
        let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        batchDelete.resultType = .resultTypeObjectIDs
        let result = try context.execute(batchDelete) as? NSBatchDeleteResult
        if let objectIDs = result?.result as? [NSManagedObjectID] {
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: [NSDeletedObjectsKey: objectIDs],
                into: [context]
            )
        }
    }

    /// Count total transcription records
    func recordCount() -> Int {
        let context = container.viewContext
        let fetchRequest: NSFetchRequest<TranscriptionRecord> = TranscriptionRecord.fetchRequest()
        return (try? context.count(for: fetchRequest)) ?? 0
    }

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "speakertpyer")
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        // Enable lightweight migration for schema changes
        let description = container.persistentStoreDescriptions.first
        description?.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description?.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        let persistentContainer = container
        persistentContainer.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                AppLogger.shared.error("Core Data 載入失敗: \(error.localizedDescription) — 嘗試重建 store", category: "CoreData")
                // 嘗試刪除舊 store 並重建
                if let url = storeDescription.url {
                    try? FileManager.default.removeItem(at: url)
                    persistentContainer.loadPersistentStores { _, retryError in
                        if let retryError {
                            AppLogger.shared.error("Core Data 重建失敗: \(retryError.localizedDescription)", category: "CoreData")
                        }
                    }
                }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true

        if !inMemory {
            seedDefaultDictionaryIfNeeded()
            seedDefaultSkillsIfNeeded()
            seedDefaultSkillsV3IfNeeded()
            cleanupLegacySkills()
        }
    }

    // MARK: - Default Dictionary Seeding

    private static let hasSeededDefaultDictKey = "hasSeededDefaultDict_v1"

    private func seedDefaultDictionaryIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.hasSeededDefaultDictKey) else { return }

        let context = container.viewContext
        for item in Self.defaultDictionary {
            let entry = PersonalDictionaryEntry(context: context)
            entry.id = UUID()
            entry.term = item.term
            entry.preferred = item.preferred
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: Self.hasSeededDefaultDictKey)
        } catch {
            print("Failed to seed default dictionary: \(error)")
        }
    }

    private static let defaultDictionary: [(term: String, preferred: String)] = [
        ("openai", "OpenAI"),
        ("chatgpt", "ChatGPT"),
        ("github", "GitHub"),
        ("iphone", "iPhone"),
        ("macbook", "MacBook"),
        ("wifi", "Wi-Fi"),
        ("youtube", "YouTube"),
        ("line", "LINE"),
    ]

    // MARK: - Default Skills Seeding

    private static let hasSeededDefaultSkillsKey = "hasSeededDefaultSkills_v2"

    private func seedDefaultSkillsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.hasSeededDefaultSkillsKey) else { return }

        let context = container.viewContext
        for skill in Self.defaultSkills {
            let entry = SnippetEntry(context: context)
            entry.id = UUID()
            entry.trigger = skill.trigger
            entry.content = skill.prompt
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: Self.hasSeededDefaultSkillsKey)
        } catch {
            print("Failed to seed default skills: \(error)")
        }
    }

    // MARK: - Legacy Cleanup

    private static let hasCleanedLegacySkillsKey = "hasCleanedLegacySkills_v1"

    /// 移除 v1 預設技能中與 LLM 意圖分類衝突的項目（翻譯類由 LLM 自動處理）
    private func cleanupLegacySkills() {
        guard !UserDefaults.standard.bool(forKey: Self.hasCleanedLegacySkillsKey) else { return }

        let context = container.viewContext
        let request: NSFetchRequest<SnippetEntry> = SnippetEntry.fetchRequest()
        // 匹配 v1 時期的翻譯、郵件、改寫等技能
        let legacyPrefixes = ["翻譯", "正式", "口語", "改寫"]
        request.predicate = NSPredicate(
            format: "trigger BEGINSWITH %@ OR trigger BEGINSWITH %@ OR trigger BEGINSWITH %@ OR trigger BEGINSWITH %@",
            legacyPrefixes[0], legacyPrefixes[1], legacyPrefixes[2], legacyPrefixes[3]
        )

        if let entries = try? context.fetch(request), !entries.isEmpty {
            for entry in entries {
                context.delete(entry)
            }
            try? context.save()
            print("[Saybit] 已清理 \(entries.count) 個舊版技能")
        }

        UserDefaults.standard.set(true, forKey: Self.hasCleanedLegacySkillsKey)
    }

    private static let defaultSkills: [(trigger: String, prompt: String)] = [
        (
            trigger: "摘要",
            prompt: "將輸入內容濃縮為簡潔的摘要。保留關鍵資訊，去除冗餘內容。以條列式或短段落呈現，不超過原文的 1/3 長度。"
        ),
        (
            trigger: "條列",
            prompt: "將輸入內容整理為條列式（bullet points）。每個要點簡潔明確，使用 - 作為項目符號。自動偵測並分組相關內容。"
        ),
        (
            trigger: "代辦",
            prompt: "將輸入內容轉換為待辦事項清單。每個項目使用 - [ ] 格式（Markdown checkbox）。自動拆解複合任務為獨立項目，按邏輯順序排列。"
        ),
    ]

    // MARK: - Default Skills v3

    private static let hasSeededSkillsV3Key = "hasSeededDefaultSkills_v3"

    private func seedDefaultSkillsV3IfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.hasSeededSkillsV3Key) else { return }

        let context = container.viewContext
        // 檢查已存在的觸發詞避免重複
        let request: NSFetchRequest<SnippetEntry> = SnippetEntry.fetchRequest()
        let existingTriggers: Set<String>
        if let entries = try? context.fetch(request) {
            existingTriggers = Set(entries.compactMap { $0.trigger })
        } else {
            existingTriggers = []
        }

        for skill in Self.defaultSkills_v3 where !existingTriggers.contains(skill.trigger) {
            let entry = SnippetEntry(context: context)
            entry.id = UUID()
            entry.trigger = skill.trigger
            entry.content = skill.prompt
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: Self.hasSeededSkillsV3Key)
        } catch {
            print("Failed to seed default skills v3: \(error)")
        }
    }

    private static let defaultSkills_v3: [(trigger: String, prompt: String)] = [
        (
            trigger: "修潤",
            prompt: "潤飾輸入的文字，修正錯字、調整語句使其更通順自然。保留原意，不改變內容方向。"
        ),
        (
            trigger: "寫信",
            prompt: "請用正式商業書信格式撰寫，包含問候語與結尾敬語。語氣專業有禮。"
        ),
    ]
}
