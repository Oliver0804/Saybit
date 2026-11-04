//
//  ClipboardBackup.swift
//  speakertpyer
//
//  完整備份／還原 NSPasteboard，保留所有 item 的所有型別（含圖片、RTF 等二進位資料）。
//  舊實作只還原 .string 型別，會在 Cmd+C / Cmd+V 流程後靜默清空使用者的圖片或 RTF 剪貼簿。
//

import AppKit

enum ClipboardBackup {
    /// 每個 item 一個 [型別: 資料] 字典；保留原始二進位資料，不轉成字串。
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    /// nspasteboard.org 慣例：剪貼簿管理器看到這個型別就不記錄這次變更
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// 檔案承諾（promise）類型：讀取會要求來源 App 同步產生檔案，可能卡住或產生大檔，不備份。
    private static let skippedTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name"),
        NSPasteboard.PasteboardType("NSPromiseContentsPboardType"),
        NSPasteboard.PasteboardType("Apple files promise pasteboard type"),
    ]

    /// 快照總大小上限：超過的型別不備份（lazy 提供的大型資料只會在第一次讀取時 materialize，避免再複製一份）
    private static let maxSnapshotBytes = 32 * 1024 * 1024

    /// 快照目前剪貼簿所有 item 的所有型別。
    static func snapshot(_ pasteboard: NSPasteboard = .general) -> Snapshot {
        var totalBytes = 0
        return pasteboard.pasteboardItems?.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types where !skippedTypes.contains(type) {
                guard totalBytes < maxSnapshotBytes else { break }
                if let data = item.data(forType: type) {
                    guard totalBytes + data.count <= maxSnapshotBytes else { continue }
                    totalBytes += data.count
                    dict[type] = data
                }
            }
            return dict
        } ?? []
    }

    /// 還原先前的快照（會先清空現有內容）。
    /// 還原的內容標上 TransientType，剪貼簿管理器不會把它當成新的一筆複製。
    static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.compactMap { dict in
            guard !dict.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            item.setData(Data(), forType: transientType)
            return item
        }
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
