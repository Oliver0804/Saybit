//
//  RecordsRepository.swift
//  speakertpyer
//
//  Core Data 讀寫的薄殼。集中個人字典、Snippets、TranscriptionRecord
//  的 fetch / save，避免在 VoicePipeline 散落 NSPersistentContainer 的細節。
//

import CoreData
import Foundation

struct RecordsRepository {
    let container: NSPersistentContainer

    init(container: NSPersistentContainer = PersistenceController.shared.container) {
        self.container = container
    }

    private var viewContext: NSManagedObjectContext { container.viewContext }

    // MARK: - Personal Dictionary

    /// 取出個人字典 [term → preferred]；空字典回 nil 方便 caller 用 `??` 串接。
    /// 讀 viewContext 必須在主執行緒，以 @MainActor 強制保證。
    @MainActor
    func loadPersonalDictionary() -> [String: String]? {
        let request = PersonalDictionaryEntry.fetchRequest()
        guard let entries = try? viewContext.fetch(request), !entries.isEmpty else {
            return nil
        }
        var dict: [String: String] = [:]
        for entry in entries {
            if let term = entry.term, let preferred = entry.preferred {
                dict[term] = preferred
            }
        }
        return dict.isEmpty ? nil : dict
    }

    /// 新增字典詞條；原始詞已存在時不覆蓋，回傳是否新增成功
    @MainActor
    @discardableResult
    func addDictionaryEntry(term: String, preferred: String) -> Bool {
        let request = PersonalDictionaryEntry.fetchRequest()
        request.predicate = NSPredicate(format: "term ==[c] %@", term)
        if let count = try? viewContext.count(for: request), count > 0 { return false }
        let entry = PersonalDictionaryEntry(context: viewContext)
        entry.id = UUID()
        entry.term = term
        entry.preferred = preferred
        do {
            try viewContext.save()
            return true
        } catch {
            viewContext.rollback()
            return false
        }
    }

    // MARK: - Snippets

    /// 取出 snippets [trigger → content]；空字典回 nil。
    @MainActor
    func loadSnippets() -> [String: String]? {
        let request = SnippetEntry.fetchRequest()
        guard let entries = try? viewContext.fetch(request), !entries.isEmpty else {
            return nil
        }
        var snippets: [String: String] = [:]
        for entry in entries {
            if let trigger = entry.trigger, let content = entry.content {
                snippets[trigger] = content
            }
        }
        return snippets.isEmpty ? nil : snippets
    }

    // MARK: - Transcription History

    /// 寫入一筆 TranscriptionRecord；失敗不 throw（caller 不會處理），由 logger 提供。
    func saveTranscription(
        rawTranscript: String,
        processedText: String,
        appName: String,
        durationSec: Double,
        modelName: String,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        mode: String = "auto",
        timestamp: Date = .init()
    ) {
        // 在 background context 非同步寫入，避免在主執行緒同步 save（含 WAL flush 磁碟 I/O）阻塞 UI。
        // viewContext 已開啟 automaticallyMergesChangesFromParent，儲存後 @FetchRequest 會自動更新。
        let context = container.newBackgroundContext()
        context.perform {
            let record = TranscriptionRecord(context: context)
            record.id = UUID()
            record.rawTranscript = rawTranscript
            record.processedText = processedText
            record.appContext = appName
            record.mode = mode
            record.timestamp = timestamp
            record.duration = durationSec
            record.modelName = modelName
            record.promptTokens = Int32(promptTokens)
            record.completionTokens = Int32(completionTokens)
            record.totalTokens = Int32(totalTokens)

            do {
                try context.save()
            } catch {
                AppLogger.shared.error("歷史記錄儲存失敗：\(error.localizedDescription)", category: "History")
            }
        }
    }
}
