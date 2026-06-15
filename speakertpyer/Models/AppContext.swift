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

        // Code Editors & IDEs
        if name.contains("cursor") || bundleID.contains("cursor") { return "cursor" }
        if name.contains("code") || bundleID.contains("vscode") { return "vscode" }
        if name.contains("windsurf") || bundleID.contains("windsurf") { return "windsurf" }
        if name.contains("xcode") || bundleID.contains("xcode") { return "xcode" }
        if name.contains("intellij") || bundleID.contains("intellij") { return "intellij" }
        if name.contains("pycharm") || bundleID.contains("pycharm") { return "pycharm" }
        if name.contains("android studio") || bundleID.contains("android-studio") { return "android-studio" }
        if name.contains("sublime") || bundleID.contains("sublimetext") { return "sublime" }
        if name.contains("fleet") || bundleID.contains("fleet") { return "fleet" }
        if name.contains("zed") || bundleID.contains("zed") { return "zed" }
        if name.contains("vim") || name.contains("neovim") { return "vim" }
        if name.contains("terminal") || bundleID.contains("terminal") { return "terminal" }
        if name.contains("iterm") || bundleID.contains("iterm") { return "terminal" }
        if name.contains("warp") || bundleID.contains("warp") { return "terminal" }

        // Chat & Messaging
        if name.contains("slack") || bundleID.contains("slack") { return "slack" }
        if name.contains("discord") || bundleID.contains("discord") { return "discord" }
        // 用 bundle ID 或精確 app 名比對，避免 Timeline / Streamline / Baseline 等被誤判為 LINE
        if bundleID.contains("naver.line") || bundleID.hasSuffix(".line") || name == "line" { return "line" }
        if name.contains("messages") || bundleID.contains("imessage") { return "imessage" }
        if name.contains("telegram") || bundleID.contains("telegram") { return "telegram" }
        if name.contains("wechat") || bundleID.contains("wechat") { return "wechat" }
        if name.contains("teams") || bundleID.contains("teams") { return "teams" }
        if name.contains("messenger") || bundleID.contains("messenger") { return "messenger" }
        if name.contains("zoom") || bundleID.contains("zoom") { return "zoom-chat" }

        // Email & Documents
        if name.contains("mail") || bundleID.contains("mail") { return "gmail" }
        if name.contains("outlook") || bundleID.contains("outlook") { return "outlook" }
        if name.contains("docs") || bundleID.contains("docs") { return "google-docs" }
        if name.contains("sheets") || bundleID.contains("sheets") { return "google-sheets" }
        if name.contains("word") || bundleID.contains("msword") { return "word" }

        // Note-taking
        if name.contains("obsidian") || bundleID.contains("obsidian") { return "obsidian" }
        if name.contains("notes") || bundleID.contains("notes") { return "notes" }
        if name.contains("notion") || bundleID.contains("notion") { return "notion" }

        // Design
        if name.contains("figma") || bundleID.contains("figma") { return "figma" }
        if name.contains("sketch") || bundleID.contains("sketch") { return "sketch" }

        // Project Management
        if name.contains("linear") || bundleID.contains("linear") { return "linear" }
        if name.contains("jira") || bundleID.contains("jira") { return "jira" }
        if name.contains("clickup") || bundleID.contains("clickup") { return "clickup" }
        if name.contains("asana") || bundleID.contains("asana") { return "asana" }

        // Browsers
        if name.contains("safari") || bundleID.contains("safari") { return "safari" }
        if name.contains("chrome") || bundleID.contains("chrome") { return "chrome" }
        if name.contains("firefox") || bundleID.contains("firefox") { return "firefox" }
        if name.contains("arc") || bundleID.contains("arc") { return "arc" }

        // AI Tools
        if name.contains("chatgpt") || bundleID.contains("chatgpt") { return "chatgpt" }
        if name.contains("claude") || bundleID.contains("claude") { return "claude" }

        return name
    }

    /// Context category for tone inference
    var contextCategory: ContextCategory {
        switch contextIdentifier {
        case "cursor", "vscode", "windsurf", "xcode", "intellij", "pycharm",
             "android-studio", "sublime", "fleet", "zed", "vim", "terminal":
            return .codeEditor
        case "slack", "discord", "line", "imessage", "telegram", "wechat",
             "teams", "messenger", "zoom-chat":
            return .chatMessaging
        case "gmail", "outlook", "word":
            return .emailDocument
        case "google-docs", "google-sheets":
            return .emailDocument
        case "obsidian", "notes", "notion":
            return .noteTaking
        case "figma", "sketch":
            return .design
        case "linear", "jira", "clickup", "asana":
            return .projectManagement
        case "safari", "chrome", "firefox", "arc":
            return .browser
        case "chatgpt", "claude":
            return .aiTool
        default:
            return .unknown
        }
    }

    enum ContextCategory: String, Codable {
        case codeEditor = "code_editor"
        case chatMessaging = "chat_messaging"
        case emailDocument = "email_document"
        case noteTaking = "note_taking"
        case design = "design"
        case projectManagement = "project_management"
        case browser = "browser"
        case aiTool = "ai_tool"
        case unknown = "unknown"
    }
}
