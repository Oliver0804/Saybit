//
//  ContextRule.swift
//  speakertpyer
//
//  Created by Claude on 2026/2/14.
//

import Foundation

struct ContextRule: Codable, Identifiable {
    let id: UUID
    var appIdentifier: String
    var toneOverride: String?
    var additionalPrompt: String?
    var isEnabled: Bool

    static let defaultRules: [ContextRule] = [
        ContextRule(
            id: UUID(),
            appIdentifier: "slack",
            toneOverride: "casual",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "discord",
            toneOverride: "casual",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "line",
            toneOverride: "casual",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "telegram",
            toneOverride: "casual",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "gmail",
            toneOverride: "formal",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "outlook",
            toneOverride: "formal",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "cursor",
            toneOverride: "technical",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "vscode",
            toneOverride: "technical",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "terminal",
            toneOverride: "technical",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "obsidian",
            toneOverride: "neutral",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "notes",
            toneOverride: "neutral",
            additionalPrompt: nil,
            isEnabled: true
        ),
        ContextRule(
            id: UUID(),
            appIdentifier: "notion",
            toneOverride: "neutral",
            additionalPrompt: nil,
            isEnabled: true
        ),
    ]

    /// Available tone options for UI picker
    static let availableTones = ["auto", "casual", "formal", "technical", "neutral"]

    /// Display name for tone
    static func toneDisplayName(_ tone: String?) -> String {
        switch tone {
        case "casual": return "口語"
        case "formal": return "正式"
        case "technical": return "技術"
        case "neutral": return "中性"
        default: return "自動"
        }
    }
}
