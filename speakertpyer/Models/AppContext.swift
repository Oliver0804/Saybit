//
//  AppContext.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/27.
//

import Foundation

struct AppContext {
    let appName: String
    let bundleIdentifier: String?
    let selectedText: String?

    static let empty = AppContext(appName: "", bundleIdentifier: nil, selectedText: nil)

    /// Infer context identifier for the LLM prompt (e.g., "cursor", "slack", "gmail")
    var contextIdentifier: String {
        let name = appName.lowercased()
        let bundleID = (bundleIdentifier ?? "").lowercased()

        if name.contains("cursor") || bundleID.contains("cursor") { return "cursor" }
        if name.contains("code") || bundleID.contains("vscode") { return "vscode" }
        if name.contains("terminal") || bundleID.contains("terminal") { return "terminal" }
        if name.contains("slack") || bundleID.contains("slack") { return "slack" }
        if name.contains("discord") || bundleID.contains("discord") { return "discord" }
        if name.contains("line") || bundleID.contains("line") { return "line" }
        if name.contains("messages") || bundleID.contains("imessage") { return "imessage" }
        if name.contains("mail") || bundleID.contains("mail") { return "gmail" }
        if name.contains("outlook") || bundleID.contains("outlook") { return "outlook" }
        if name.contains("docs") || bundleID.contains("docs") { return "google-docs" }
        if name.contains("obsidian") || bundleID.contains("obsidian") { return "obsidian" }
        if name.contains("notes") || bundleID.contains("notes") { return "notes" }
        if name.contains("windsurf") || bundleID.contains("windsurf") { return "windsurf" }
        if name.contains("xcode") || bundleID.contains("xcode") { return "xcode" }

        return name
    }
}
