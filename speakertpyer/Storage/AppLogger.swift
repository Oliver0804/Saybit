//
//  AppLogger.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

// MARK: - Log Level

enum LogLevel: String, Codable, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

// MARK: - Log Entry

struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String

    init(level: LogLevel, category: String, message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
    }

    var formatted: String {
        "[\(Self.timeFormatter.string(from: timestamp))] [\(level.rawValue)] [\(category)] \(message)"
    }

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()
}

// MARK: - App Logger

@Observable
class AppLogger {
    static let shared = AppLogger()

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 500
    private let queue = DispatchQueue(label: "com.bashcat.speakertpyer.logger")
    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let logRetentionDays = 7

    // 常開的當日寫入 handle（僅在 serial queue 上存取），跨日才 rotate，
    // 避免每條 log 都 open→seek→write→close 一輪 syscall（LLM 串流期間尤其密集）。
    private var fileHandle: FileHandle?
    private var openedDateString = ""

    var logDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Saybit/logs", isDirectory: true)
    }

    private static let fileDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    var todayLogFileURL: URL {
        let filename = "saybit-\(Self.fileDateFormatter.string(from: Date())).jsonl"
        return logDirectoryURL.appendingPathComponent(filename)
    }

    init() {
        ensureLogDirectory()
        cleanOldLogs()
    }

    func info(_ message: String, category: String = "App") {
        append(LogEntry(level: .info, category: category, message: message))
    }

    func warn(_ message: String, category: String = "App") {
        append(LogEntry(level: .warn, category: category, message: message))
    }

    func error(_ message: String, category: String = "App") {
        append(LogEntry(level: .error, category: category, message: message))
    }

    func debug(_ message: String, category: String = "App") {
        append(LogEntry(level: .debug, category: category, message: message))
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }

    private func append(_ entry: LogEntry) {
        print(entry.formatted)
        // 在主執行緒更新 entries，確保 SwiftUI @Observable 安全
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
        persistToDisk(entry)
    }

    // MARK: - Disk Persistence

    private func ensureLogDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDirectoryURL.path) {
            try? fm.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func persistToDisk(_ entry: LogEntry) {
        queue.async { [weak self] in
            guard let self,
                  let data = try? self.jsonEncoder.encode(entry) else { return }
            let line = data + Data("\n".utf8)

            let today = Self.fileDateFormatter.string(from: Date())
            if self.openedDateString != today {
                // 跨日：關閉舊 handle，改寫當日新檔
                try? self.fileHandle?.close()
                self.fileHandle = nil
                self.openedDateString = today
            }
            if self.fileHandle == nil {
                let fileURL = self.logDirectoryURL.appendingPathComponent("saybit-\(today).jsonl")
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                self.fileHandle = try? FileHandle(forWritingTo: fileURL)
                _ = try? self.fileHandle?.seekToEnd()
            }
            guard let handle = self.fileHandle else { return }
            do {
                try handle.write(contentsOf: line)
            } catch {
                // 寫入失敗：重置 handle，下次重開
                try? handle.close()
                self.fileHandle = nil
            }
        }
    }

    private func cleanOldLogs() {
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let cutoff = Calendar.current.date(byAdding: .day, value: -self.logRetentionDays, to: Date())!

            guard let files = try? fm.contentsOfDirectory(at: self.logDirectoryURL, includingPropertiesForKeys: nil) else { return }

            for file in files {
                guard file.pathExtension == "jsonl" else { continue }
                // 從檔名解析日期（saybit-yyyy-MM-dd.jsonl），不依賴 creationDate
                // （Time Machine 還原 / 複製會重置 creationDate，導致清理失效或誤刪）
                let name = file.deletingPathExtension().lastPathComponent
                let dateStr = name.replacingOccurrences(of: "saybit-", with: "")
                guard let fileDate = Self.fileDateFormatter.date(from: dateStr),
                      fileDate < cutoff else { continue }
                try? fm.removeItem(at: file)
            }
        }
    }
}
