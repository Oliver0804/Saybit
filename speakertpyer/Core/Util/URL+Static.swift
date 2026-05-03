//
//  URL+Static.swift
//  speakertpyer
//
//  常數 URL 字面量包裝。`URL(string: "...")!` 一旦字面量打錯就 runtime crash，
//  且看不到出錯的位置。改用 `URL(staticString:)` 會在 precondition 失敗時印出
//  原字串、檔名與行號，方便定位。
//

import Foundation

extension URL {
    /// 從編譯期字面量建立 URL；解析失敗時 precondition 報明確訊息。
    init(staticString: StaticString, file: StaticString = #file, line: UInt = #line) {
        let str = "\(staticString)"
        guard let url = URL(string: str) else {
            preconditionFailure("Invalid URL literal: \(str)", file: file, line: line)
        }
        self = url
    }
}
