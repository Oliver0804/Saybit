//
//  SaybitIntents.swift
//  SaybitiOS
//
//  捷徑 / Siri / 動作按鈕整合。
//

import AppIntents
import CoreData
import UIKit

// MARK: - 開始語音輸入（動作按鈕 / 控制中心 / Siri）

struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "開始語音輸入"
    static let description = IntentDescription("打開 Saybit 並立刻開始錄音，結束後 AI 潤飾並複製到剪貼簿。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let pipeline = AppServices.shared.pipeline
        if !pipeline.isBusy {
            pipeline.startRecording(source: .shortcut)
        }
        return .result()
    }
}

// MARK: - 開啟鍵盤待命

struct StartKeyboardSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "啟動鍵盤待命"
    static let description = IntentDescription("讓 Saybit 鍵盤可以在任何 App 直接開始語音輸入（期間會保持麥克風）。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = AppServices.shared
        services.pipeline.keyboardSession.activate(minutes: services.mobileSettings.keyboardSessionMinutes)
        return .result()
    }
}

// MARK: - 用 Saybit 潤飾文字（可串在其他捷徑後面）

struct RefineTextIntent: AppIntent {
    static let title: LocalizedStringResource = "用 Saybit 潤飾文字"
    static let description = IntentDescription("把一段文字交給 AI 依你的 Saybit 設定（風格、字典、技能）處理後回傳。")
    static let openAppWhenRun = false

    @Parameter(title: "文字", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("用 Saybit 潤飾 \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await AppServices.shared.pipeline.refineStandalone(text)
        return .result(value: result)
    }
}

// MARK: - 取得最近一次結果

struct LastResultIntent: AppIntent {
    static let title: LocalizedStringResource = "取得最近一次 Saybit 結果"
    static let description = IntentDescription("回傳最近一筆語音輸入的 AI 處理結果。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = AppServices.shared.persistence.container.viewContext
        let request = TranscriptionRecord.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 1
        let text = (try? context.fetch(request).first?.processedText) ?? ""
        return .result(value: text)
    }
}

// MARK: - Shortcuts Provider

struct SaybitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "用 \(.applicationName) 語音輸入",
                "Start dictation with \(.applicationName)",
            ],
            shortTitle: "語音輸入",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StartKeyboardSessionIntent(),
            phrases: [
                "啟動 \(.applicationName) 鍵盤",
                "Start \(.applicationName) keyboard session",
            ],
            shortTitle: "鍵盤待命",
            systemImageName: "keyboard.badge.waveform"
        )
        AppShortcut(
            intent: RefineTextIntent(),
            phrases: [
                "用 \(.applicationName) 潤飾文字",
                "Refine text with \(.applicationName)",
            ],
            shortTitle: "潤飾文字",
            systemImageName: "wand.and.stars"
        )
    }
}
