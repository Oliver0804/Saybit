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
        // NSWorkspace / NSScreen 是 AppKit 狀態，必須在主執行緒讀
        let front: (pid: pid_t, bundleID: String?)? = await MainActor.run {
            guard hasPermission, let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            return (app.processIdentifier, app.bundleIdentifier)
        }
        guard let front else { return nil }
        let frontPID = front.pid

        // 密碼管理員、終端機、遠端桌面等不擷取
        if SensitiveApps.matches(front.bundleID, patterns: SensitiveApps.screenCapturePatterns) {
            AppLogger.shared.info("螢幕上下文：前景 App 在排除清單，略過", category: "Context")
            return nil
        }
        // 焦點在密碼欄位時不擷取（AX 呼叫可能卡住，放到背景）
        let isSecure = await Task.detached(priority: .userInitiated) {
            SensitiveApps.focusedElementIsSecure(pid: frontPID)
        }.value
        if isSecure {
            AppLogger.shared.info("螢幕上下文：焦點在密碼欄位，略過", category: "Context")
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == frontPID && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150
            }
            // SCShareableContent 依前後順序排列，第一個通常是最上層視窗
            guard let window = candidates.first else { return nil }
            let frame = window.frame

            let config = SCStreamConfiguration()
            let scale = await MainActor.run { backingScale(forCGRect: frame) }
            config.width = Int(frame.width * scale)
            config.height = Int(frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config
            )
            let text = try await Task.detached(priority: .userInitiated) {
                try recognizeText(in: image)
            }.value
            return text.isEmpty ? nil : String(text.suffix(maxCharacters))
        } catch {
            AppLogger.shared.error("螢幕上下文擷取失敗: \(error.localizedDescription)", category: "Context")
            return nil
        }
    }

    /// 視窗所在螢幕的 backing scale。SCWindow.frame 是 CG 全域座標（左上原點），
    /// 用 CGDisplayBounds（同一座標系）比對，不能直接拿 NSScreen.frame（左下原點）比。
    private static func backingScale(forCGRect rect: CGRect) -> CGFloat {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            if CGDisplayBounds(CGDirectDisplayID(number.uint32Value)).contains(center) {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    nonisolated private static func recognizeText(in image: CGImage) throws -> String {
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
