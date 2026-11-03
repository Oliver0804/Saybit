//
//  SpeakerTyperShortcuts.swift
//  speakertpyer
//
//  Created by 顏國明 on 2026/1/28.
//

import AppIntents
import AppKit

// MARK: - App Shortcuts Provider

struct SpeakerTyperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "開始語音輸入 \(.applicationName)",
                "Start dictation with \(.applicationName)"
            ],
            shortTitle: "開始語音輸入",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopDictationIntent(),
            phrases: [
                "停止語音輸入 \(.applicationName)",
                "Stop dictation with \(.applicationName)"
            ],
            shortTitle: "停止語音輸入",
            systemImageName: "mic.slash.fill"
        )
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "切換語音輸入 \(.applicationName)",
                "Toggle dictation with \(.applicationName)"
            ],
            shortTitle: "切換語音輸入",
            systemImageName: "mic.badge.plus"
        )
    }
}

// MARK: - Errors

enum DictationIntentError: Error, CustomLocalizedStringResourceConvertible {
    case externalControlDisabled

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .externalControlDisabled:
            return "Saybit 目前不允許其他 App 控制錄音（設定中已停用，或尚未完成初次設定）"
        }
    }
}

/// 與 saybit:// 共用「允許其他 App 控制」開關與引導檢查；不允許時回 nil
@MainActor
private func controllablePipeline(source: String) -> VoicePipeline? {
    guard let appDelegate = NSApp.delegate as? AppDelegate,
          appDelegate.allowsExternalRecordingControl(source: source) else { return nil }
    return appDelegate.voicePipeline
}

@MainActor
private func isRecording(_ pipeline: VoicePipeline) -> Bool {
    if case .recording = pipeline.session.state { return true }
    return false
}

// MARK: - Start Dictation Intent

struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "開始語音輸入"
    static var description = IntentDescription("開始 Saybit 語音錄音")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let allowed = await MainActor.run { () -> Bool in
            guard let pipeline = controllablePipeline(source: "捷徑：開始語音輸入") else { return false }
            // 走與快捷鍵相同的入口（含所有 STT 引擎的靜音自動停止）
            if !isRecording(pipeline) { pipeline.toggleRecording(mode: nil) }
            return true
        }
        guard allowed else { throw DictationIntentError.externalControlDisabled }
        return .result()
    }
}

// MARK: - Stop Dictation Intent

struct StopDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "停止語音輸入"
    static var description = IntentDescription("停止 Saybit 語音錄音並處理文字")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let allowed = await MainActor.run { () -> Bool in
            guard let pipeline = controllablePipeline(source: "捷徑：停止語音輸入") else { return false }
            if isRecording(pipeline) { pipeline.stopRecordingAndProcess() }
            return true
        }
        guard allowed else { throw DictationIntentError.externalControlDisabled }
        return .result()
    }
}

// MARK: - Toggle Dictation Intent

struct ToggleDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "切換語音輸入"
    static var description = IntentDescription("切換 Saybit 語音輸入狀態（開始/停止）")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let allowed = await MainActor.run { () -> Bool in
            guard let pipeline = controllablePipeline(source: "捷徑：切換語音輸入") else { return false }
            pipeline.toggleRecording(mode: nil)
            return true
        }
        guard allowed else { throw DictationIntentError.externalControlDisabled }
        return .result()
    }
}

// MARK: - Set Tone Style Intent

struct SetToneStyleIntent: AppIntent {
    static var title: LocalizedStringResource = "設定語氣風格"
    static var description = IntentDescription("設定 Saybit 的語氣風格")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "語氣風格")
    var style: ToneStyleEntity

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
            if let tone = ToneStyle(rawValue: style.id) {
                appDelegate.settingsStore.toneStyle = tone
            }
        }
        return .result()
    }
}

// MARK: - Tone Style Entity (for Shortcuts parameter)

struct ToneStyleEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "語氣風格")
    static var defaultQuery = ToneStyleQuery()

    var id: String
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    static let allStyles: [ToneStyleEntity] = [
        .init(id: "auto", displayName: "自動"),
        .init(id: "formal", displayName: "正式"),
        .init(id: "casual", displayName: "輕鬆"),
        .init(id: "very_casual", displayName: "非常輕鬆"),
    ]
}

struct ToneStyleQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ToneStyleEntity] {
        ToneStyleEntity.allStyles.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ToneStyleEntity] {
        ToneStyleEntity.allStyles
    }
}
