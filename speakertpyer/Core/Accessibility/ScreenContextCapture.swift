//
//  ScreenContextCapture.swift
//  speakertpyer
//
//  錄音開始時截取「目前前景 App 的視窗」並 OCR，把畫面上的文字當 screen_context 給 AI 參考
//  （回覆對象的名字、專有名詞拼法、正在討論的內容）。全程在本機處理，截圖不存檔。
//  需要「螢幕錄製」權限。
//

#if os(macOS)
import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

enum ScreenContextCapture {
    /// 給 AI 的文字上限（避免 prompt 過長）
    static let maxCharacters = 2000

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 跳出系統授權（第一次會引導到系統設定）
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// 擷取前景 App 最上層視窗並 OCR；沒權限或失敗回 nil
    static func captureFrontWindowText() async -> String? {
        guard hasPermission,
              let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontPID != ProcessInfo.processInfo.processIdentifier else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == frontPID && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150
            }
            // SCShareableContent 依前後順序排列，第一個通常是最上層視窗
            guard let window = candidates.first else { return nil }

            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config
            )
            let text = try recognizeText(in: image)
            return text.isEmpty ? nil : String(text.suffix(maxCharacters))
        } catch {
            AppLogger.shared.error("螢幕上下文擷取失敗: \(error.localizedDescription)", category: "Context")
            return nil
        }
    }

    private static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hant", "zh-Hans", "en-US", "ja-JP"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
#endif
