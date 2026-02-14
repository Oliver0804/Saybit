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
            let fileURL = self.todayLogFileURL

            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(line)
                    handle.closeFile()
                }
            } else {
                try? line.write(to: fileURL)
            }
        }
    }

    private func cleanOldLogs() {
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let cutoff = Calendar.current.date(byAdding: .day, value: -self.logRetentionDays, to: Date())!

            guard let files = try? fm.contentsOfDirectory(at: self.logDirectoryURL, includingPropertiesForKeys: [.creationDateKey]) else { return }

            for file in files {
                guard file.pathExtension == "jsonl",
                      let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let created = attrs[.creationDate] as? Date,
                      created < cutoff else { continue }
                try? fm.removeItem(at: file)
            }
        }
    }
}
