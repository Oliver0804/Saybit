//
//  AppleOnDeviceLLM.swift
//  speakertpyer
//
//  Apple Intelligence 本機語言模型（FoundationModels）當 AI 服務：完全離線、免費、免 API Key。
//  搭配 SenseVoice 離線辨識時，整條「說話 → 潤飾」流程都不連網。
//  由 OpenRouterClient 依 provider.id 分流過來，對上層（TextRefiner）介面完全相同。
//

import Foundation
import FoundationModels

enum AppleOnDeviceLLM {
    static let providerID = "apple-on-device"
    /// 顯示用的模型名稱（Apple 模型沒有可選版本）
    static let modelName = "apple-on-device"

    enum LLMError: LocalizedError {
        case unavailable(String)
        case generation(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .generation(let msg): return msg
            }
        }
    }

    /// nil 代表可用；否則回傳給使用者看的原因
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "這台裝置不支援 Apple Intelligence 本機模型"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "請先到「系統設定 › Apple Intelligence 與 Siri」開啟 Apple Intelligence"
        case .unavailable(.modelNotReady):
            return "Apple Intelligence 模型仍在下載中，請稍後再試"
        case .unavailable:
            return "Apple Intelligence 本機模型目前無法使用"
        }
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// 串流產生；每個 chunk 是「新增的文字」（與雲端 SSE 一致）
    static func stream(
        systemPrompt: String,
        userMessage: String,
        temperature: Double,
        maxTokens: Int?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if let reason = unavailableReason {
                    continuation.finish(throwing: LLMError.unavailable(reason))
                    return
                }
                // 潤飾 / 翻譯使用者自己的文字 → 用較寬鬆的內容轉換護欄，避免一般內容被誤擋
                let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                let session = LanguageModelSession(model: model, instructions: systemPrompt)
                let options = GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
                do {
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: userMessage, options: options) {
                        // snapshot.content 是累積的完整字串，轉成增量
                        let full = snapshot.content
                        if full.count > emitted.count {
                            continuation.yield(String(full.dropFirst(emitted.count)))
                            emitted = full
                        }
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: LLMError.generation(Self.describe(error)))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "內容太長，超過 Apple 本機模型的上限，請分段說或改用雲端模型"
        case .guardrailViolation:
            return "Apple 本機模型拒絕處理這段內容，請改用雲端模型"
        case .unsupportedLanguageOrLocale:
            return "Apple 本機模型不支援這個語言，請到系統設定確認 Apple Intelligence 語言"
        case .assetsUnavailable:
            return "Apple Intelligence 模型尚未就緒，請稍後再試"
        case .rateLimited:
            return "Apple 本機模型忙碌中，請稍後再試"
        default:
            return "Apple 本機模型處理失敗：\(error.localizedDescription)"
        }
    }
}
