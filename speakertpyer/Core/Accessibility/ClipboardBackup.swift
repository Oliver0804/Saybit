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

    /// 快照目前剪貼簿所有 item 的所有型別。
    static func snapshot(_ pasteboard: NSPasteboard = .general) -> Snapshot {
        pasteboard.pasteboardItems?.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        } ?? []
    }

    /// 還原先前的快照（會先清空現有內容）。
    static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.compactMap { dict in
            guard !dict.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
