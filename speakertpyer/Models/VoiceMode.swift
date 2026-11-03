//
//  VoiceMode.swift
//  speakertpyer
//
//  語音模式：每個模式有自己的指令（例如「寫成 email」「翻譯成英文」）與獨立快捷鍵。
//  用模式快捷鍵錄音時跳過意圖判斷，直接照模式指令處理。
//

import Foundation

struct VoiceMode: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// 給 AI 的指令；描述要把說的話變成什麼
    var instructions: String
    /// 快捷鍵（nil = 沒設定，只能從 URL scheme 觸發）
    var keyCode: Int?
    var modifiers: UInt64 = 0

    var hasHotkey: Bool { keyCode != nil && modifiers != 0 }

    static let presets: [VoiceMode] = [
        VoiceMode(
            name: "Email",
            instructions: "把內容寫成一封完整、有禮貌的 email：開頭問候、分段清楚的正文、結尾致謝與署名留白。保留所有事實與數字，不要自行補充內容。"
        ),
        VoiceMode(
            name: "翻譯成英文",
            instructions: "把內容翻譯成自然、道地的英文。若有選取文字，則翻譯選取的文字。只輸出譯文。"
        ),
        VoiceMode(
            name: "條列筆記",
            instructions: "把內容整理成精簡的條列式筆記：先一行重點摘要，再用「- 」列出要點，有待辦事項時另外列在最後並加上「☐」。"
        ),
    ]
}
