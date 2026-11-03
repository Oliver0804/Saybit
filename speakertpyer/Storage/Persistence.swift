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
        if inMemory, let firstDescription = container.persistentStoreDescriptions.first {
            firstDescription.url = URL(fileURLWithPath: "/dev/null")
        }
        // Enable lightweight migration for schema changes
        let description = container.persistentStoreDescriptions.first
        description?.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description?.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        // loadPersistentStores 對預設（非 async）description 是同步回呼。
        let firstError = Self.loadStores(container)
        if let firstError {
            AppLogger.shared.error("Core Data 載入失敗: \(firstError.localizedDescription) (code \(firstError.code))", category: "CoreData")
            if !inMemory, let storeURL = container.persistentStoreDescriptions.first?.url {
                Self.recoverFromLoadFailure(container: container, storeURL: storeURL, error: firstError)
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true

        // 只在真的 SQLite store 上播種；退回記憶體 store 時播種會把旗標設成 true 卻沒存到檔案
        let usingSQLiteStore = container.persistentStoreCoordinator.persistentStores.first?.type == NSSQLiteStoreType
        if !inMemory && usingSQLiteStore {
            seedDefaultDictionaryIfNeeded()
            seedDefaultSkillsIfNeeded()
            seedDefaultSkillsV3IfNeeded()
            cleanupLegacySkills()
        }
    }

    // MARK: - Load Failure Recovery

    /// 啟動時 store 載入失敗、已把原檔搬去備份並重建空庫時發出；`object` 為備份資料夾 URL。
    /// UI 可監聽此通知（或讀 `lastRecoveryBackupPathKey`）告知使用者。
    static let storeRecoveredNotification = Notification.Name("PersistenceStoreRecovered")
    /// 載入失敗但判定不是損毀（未動原檔），本次執行改用記憶體 store 時發出。
    static let storeUnavailableNotification = Notification.Name("PersistenceStoreUnavailable")
    /// 最近一次復原的備份資料夾路徑（String）。UI 告知使用者後可自行移除此 key。
    static let lastRecoveryBackupPathKey = "coreDataLastRecoveryBackupPath"
    /// 載入階段發生在任何 UI 觀察者註冊之前，通知會被錯過；這裡另外留一份待顯示的訊息，
    /// 由 AppDelegate 啟動後讀取並彈窗（讀過後清掉）。
    nonisolated(unsafe) static var pendingUserNotice: (title: String, message: String)?

    private final class ErrorBox { var error: NSError? }

    @discardableResult
    private static func loadStores(_ container: NSPersistentContainer) -> NSError? {
        let box = ErrorBox()
        container.loadPersistentStores { _, error in
            if let error = error as NSError?, box.error == nil { box.error = error }
        }
        return box.error
    }

    /// 載入失敗時絕不刪檔：把 store 三個檔（.sqlite / -wal / -shm）整組搬到
    /// `Application Support/Saybit/corrupt-<yyyyMMdd-HHmmss>/`，再於原位置建立空庫並清 seed 旗標。
    /// 若搬移失敗（例如權限或磁碟問題），原檔保持原狀，改用記憶體 store 讓 App 仍可運作。
    private static func recoverFromLoadFailure(container: NSPersistentContainer, storeURL: URL, error: NSError) {
        guard shouldBackUpAndRebuild(for: error) else {
            // 非損毀類錯誤（磁碟滿、權限、暫時 I/O、舊版 App 開新版資料庫…）：原檔不動，
            // 本次改用記憶體 store，修好環境 / 換回新版後下次啟動就能讀回原資料。
            AppLogger.shared.error("Core Data 錯誤非資料庫損毀，保留原檔、本次改用記憶體 store（資料不會保存）", category: "CoreData")
            fallBackToInMemory(container)
            pendingUserNotice = (
                "歷史紀錄資料庫暫時無法開啟",
                "原因：\(error.localizedDescription)\n\n資料庫檔案沒有被更動。這次執行的歷史紀錄不會保存，個人字典與語音技能也會是預設值；排除問題（例如磁碟空間）後重新啟動 Saybit 即可讀回原本的資料。"
            )
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: storeUnavailableNotification, object: nil)
            }
            return
        }
        let fm = FileManager.default
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fallBackToInMemory(container)
            return
        }
        let backupDir = appSupport
            .appendingPathComponent("Saybit", isDirectory: true)
            .appendingPathComponent("corrupt-\(df.string(from: Date()))", isDirectory: true)

        let candidates = ["", "-wal", "-shm"].map { URL(fileURLWithPath: storeURL.path + $0) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard !candidates.isEmpty else {
            // 原位置根本沒有 store 檔（例如目錄無法建立），不是資料損毀；不重建以免掩蓋問題。
            AppLogger.shared.error("Core Data store 檔不存在仍載入失敗，改用記憶體 store（本次資料不會保存）", category: "CoreData")
            fallBackToInMemory(container)
            return
        }

        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            var moved: [(from: URL, to: URL)] = []
            do {
                for src in candidates {
                    let dst = backupDir.appendingPathComponent(src.lastPathComponent)
                    try fm.moveItem(at: src, to: dst)
                    moved.append((src, dst))
                }
            } catch {
                // 部分搬移失敗：把已搬走的搬回去，保持原狀
                for m in moved { try? fm.moveItem(at: m.to, to: m.from) }
                throw error
            }
        } catch let moveError {
            AppLogger.shared.error("Core Data 備份搬移失敗（原檔未變動）: \(moveError.localizedDescription)；改用記憶體 store", category: "CoreData")
            fallBackToInMemory(container)
            return
        }

        AppLogger.shared.error("Core Data 原資料庫已備份至 \(backupDir.path)，將建立新的空資料庫", category: "CoreData")

        if let retryError = loadStores(container) {
            AppLogger.shared.error("Core Data 重建失敗: \(retryError.localizedDescription)；改用記憶體 store", category: "CoreData")
            fallBackToInMemory(container)
        } else {
            // 新庫是空的：清 seed 旗標，讓預設字典 / 技能重新播種
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: hasSeededDefaultDictKey)
            defaults.removeObject(forKey: hasSeededDefaultSkillsKey)
            defaults.removeObject(forKey: hasSeededSkillsV3Key)
        }

        UserDefaults.standard.set(backupDir.path, forKey: lastRecoveryBackupPathKey)
        pendingUserNotice = (
            "歷史紀錄資料庫已重建",
            "原本的資料庫無法開啟，已完整備份到：\n\(backupDir.path)\n\n歷史紀錄、個人字典與語音技能已重設為預設值。若需要協助還原，請保留該備份資料夾。"
        )
        let url = backupDir
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: storeRecoveredNotification, object: url)
        }
    }

    /// 只有確定是資料庫損毀或遷移失敗才搬檔重建；檔案系統 / 暫時性錯誤一律不動原檔。
    private static func shouldBackUpAndRebuild(for error: NSError) -> Bool {
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        for e in [error, underlying].compactMap({ $0 }) {
            if e.domain == NSSQLiteErrorDomain, [11, 26].contains(e.code) { return true } // SQLITE_CORRUPT / SQLITE_NOTADB
            if e.domain == NSCocoaErrorDomain, e.code == NSFileReadCorruptFileError { return true }
        }
        guard error.domain == NSCocoaErrorDomain else { return false }
        switch error.code {
        case NSMigrationMissingSourceModelError:
            // 找不到來源模型：多半是舊版 App 開到新版資料庫，不能清掉
            return false
        case NSPersistentStoreIncompatibleVersionHashError,
             NSMigrationError, NSMigrationConstraintViolationError, NSMigrationCancelledError,
             NSMigrationMissingMappingModelError, NSMigrationManagerSourceStoreError,
             NSMigrationManagerDestinationStoreError, NSEntityMigrationPolicyError,
             NSPersistentStoreIncompatibleSchemaError, NSPersistentStoreInvalidTypeError,
             NSPersistentStoreTypeMismatchError:
            return true
        default:
            return false
        }
    }

    private static func fallBackToInMemory(_ container: NSPersistentContainer) {
        guard container.persistentStoreCoordinator.persistentStores.isEmpty else { return }
        let desc = NSPersistentStoreDescription()
        desc.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [desc]
        if let err = loadStores(container) {
            AppLogger.shared.error("Core Data 記憶體 store 也載入失敗: \(err.localizedDescription)", category: "CoreData")
        }
    }

    /// 儲存失敗時 rollback，避免殘留的髒物件在下次 save 再次失敗。
    private func saveOrRollback(_ context: NSManagedObjectContext, what: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            AppLogger.shared.error("Core Data \(what) 儲存失敗: \(error.localizedDescription)", category: "CoreData")
            return false
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

        if saveOrRollback(context, what: "預設字典播種") {
            UserDefaults.standard.set(true, forKey: Self.hasSeededDefaultDictKey)
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

        if saveOrRollback(context, what: "預設技能播種") {
            UserDefaults.standard.set(true, forKey: Self.hasSeededDefaultSkillsKey)
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

        let entries: [SnippetEntry]
        do {
            entries = try context.fetch(request)
        } catch {
            // fetch 失敗不標完成，下次啟動再試
            AppLogger.shared.error("Core Data 舊版技能查詢失敗: \(error.localizedDescription)", category: "CoreData")
            return
        }
        if !entries.isEmpty {
            for entry in entries {
                context.delete(entry)
            }
            guard saveOrRollback(context, what: "舊版技能清理") else { return }
            AppLogger.shared.info("已清理 \(entries.count) 個舊版技能", category: "CoreData")
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
        do {
            existingTriggers = Set(try context.fetch(request).compactMap { $0.trigger })
        } catch {
            // 查不到既有觸發詞就不播種，避免重複插入；下次啟動再試
            AppLogger.shared.error("Core Data 技能查詢失敗: \(error.localizedDescription)", category: "CoreData")
            return
        }

        for skill in Self.defaultSkills_v3 where !existingTriggers.contains(skill.trigger) {
            let entry = SnippetEntry(context: context)
            entry.id = UUID()
            entry.trigger = skill.trigger
            entry.content = skill.prompt
        }

        if saveOrRollback(context, what: "預設技能 v3 播種") {
            UserDefaults.standard.set(true, forKey: Self.hasSeededSkillsV3Key)
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
