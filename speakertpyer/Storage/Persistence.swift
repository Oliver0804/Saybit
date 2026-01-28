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
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
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
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
