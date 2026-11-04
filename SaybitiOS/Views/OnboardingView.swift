//
//  OnboardingView.swift
//  SaybitiOS
//
//  首次啟動：歡迎 → 麥克風／語音辨識權限 → AI 服務 → 鍵盤（含允許完整取用）→ 離線模型（可選）。
//

import AVFoundation
import Speech
import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, ai, keyboard, offline

        var title: String {
            switch self {
            case .welcome: "用說的，比打字更快"
            case .permissions: "允許麥克風與語音辨識"
            case .ai: "連接 AI 服務"
            case .keyboard: "在任何 App 用說的"
            case .offline: "離線辨識（可選）"
            }
        }
    }

    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var mobileSettings: MobileSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var step: Step = .welcome
    @State private var micStatus = AVAudioApplication.shared.recordPermission
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()

    private var hasAPIKey: Bool {
        let provider = settingsStore.selectedProvider
        return !provider.requiresAPIKey || KeychainHelper.loadAPIKey(for: provider.id) != nil
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $step) {
                welcome.tag(Step.welcome)
                permissions.tag(Step.permissions)
                ai.tag(Step.ai)
                keyboard.tag(Step.keyboard)
                offline.tag(Step.offline)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationTitle(step == .welcome ? "" : "第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .welcome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("上一步", systemImage: "chevron.left") {
                            withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("略過") { mobileSettings.hasCompletedOnboarding = true }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                micStatus = AVAudioApplication.shared.recordPermission
                speechStatus = SFSpeechRecognizer.authorizationStatus()
            }
        }
    }

    // MARK: - Page scaffold

    /// 每頁都放在 ScrollView 裡，放大字體時才不會被切掉。
    private func page<Content: View>(
        icon: String, title: String, subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let inner = content()
        return GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: icon)
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                    Text(title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    inner
                }
                .padding(28)
                // 內容短時置中、放大字體變長時可捲動
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func nextButton(_ title: String, to next: Step) -> some View {
        Button(title) { withAnimation { step = next } }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minHeight: 44)
    }

    // MARK: - Pages

    private var welcome: some View {
        page(icon: "waveform.and.mic", title: Step.welcome.title,
             subtitle: "Saybit 把你說的話變成乾淨、有標點、語氣合適的文字——去除「嗯、那個」，自動修正口誤。") {
            nextButton("開始設定", to: .permissions)
        }
    }

    private var permissions: some View {
        page(icon: "mic.circle", title: Step.permissions.title,
             subtitle: "錄音只在你按下麥克風或開啟鍵盤待命時進行，不會背景偷錄。") {
            VStack(spacing: 12) {
                permissionRow(
                    "麥克風",
                    detail: "錄下你說的話",
                    granted: micStatus == .granted,
                    denied: micStatus == .denied
                ) {
                    let granted = await AudioSessionManager.requestMicrophonePermission()
                    micStatus = granted ? .granted : .denied
                }
                permissionRow(
                    "語音辨識",
                    detail: "使用 Apple 語音辨識時需要；離線 SenseVoice 不需要",
                    granted: speechStatus == .authorized,
                    denied: speechStatus == .denied || speechStatus == .restricted
                ) {
                    let ok = await withCheckedContinuation { cont in
                        SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
                    }
                    speechStatus = ok ? .authorized : .denied
                }
                nextButton(micStatus == .granted ? "下一步" : "稍後再說", to: .ai)
                    .padding(.top, 8)
            }
        }
    }

    private func permissionRow(
        _ title: String,
        detail: String,
        granted: Bool,
        denied: Bool,
        request: @escaping () async -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label("已允許", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else if denied {
                Button("前往設定") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            } else {
                Button("允許") { Task { await request() } }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
        .multilineTextAlignment(.leading)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var ai: some View {
        page(icon: "key.fill", title: Step.ai.title,
             subtitle: "Saybit 把你說的話轉成文字後，交給 AI 去除贅字、補標點。這需要你自己的 API Key：一串像密碼的字串，代表你在服務商的帳號，只存在這支手機的鑰匙圈。") {
            VStack(spacing: 12) {
                if hasAPIKey {
                    Label("已設定 \(settingsStore.selectedProvider.name)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("到服務商網站註冊（免費），建立一把 API Key 並複製", systemImage: "1.circle")
                        Label("回到 Saybit 貼上並儲存，按「測試連線」確認", systemImage: "2.circle")
                        Label("OpenRouter / OpenAI / DeepSeek 要先儲值；Groq 有免費額度", systemImage: "3.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = settingsStore.selectedProvider.keyPortalURL {
                        Link("打開 \(settingsStore.selectedProvider.name) 的申請頁面", destination: url)
                            .font(.footnote)
                    }
                }
                NavigationLink("設定服務商與 API Key") { ProviderSettingsView() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(minHeight: 44)
                nextButton("下一步", to: .keyboard)
            }
        }
    }

    private var keyboard: some View {
        page(icon: "keyboard.badge.waveform", title: Step.keyboard.title,
             subtitle: "加入 Saybit 鍵盤後，在訊息、備忘錄、郵件等任何輸入框都能語音輸入。") {
            VStack(alignment: .leading, spacing: 14) {
                checklistRow("1", "設定 › 一般 › 鍵盤 › 鍵盤 › 新增鍵盤…，選「Saybit」")
                checklistRow("2", "點進 Saybit，開啟「允許完整取用」——鍵盤要靠這個權限才能和 Saybit App 交換文字")
                checklistRow("3", "在任何輸入框長按 🌐 切換到 Saybit 鍵盤")
                Button("打開系統設定") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 44)
                NavigationLink("看完整安裝說明") { KeyboardSetupView() }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, minHeight: 44)
                nextButton("下一步", to: .offline)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func checklistRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.subheadline.weight(.bold))
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var offline: some View {
        page(icon: "arrow.down.circle", title: Step.offline.title,
             subtitle: "SenseVoice 完全在 iPhone 上辨識：不需網路、速度快、中英夾雜也準。模型約 \(Self.modelSizeText)，之後也可以在設定裡下載。") {
            VStack(spacing: 12) {
                OnboardingModelDownloadRow()
                Button("開始使用 Saybit") { mobileSettings.hasCompletedOnboarding = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: 44)
            }
        }
    }

    static var modelSizeText: String {
        ByteCountFormatter.string(fromByteCount: SherpaModelManager.totalSize, countStyle: .file)
    }
}

// MARK: - 引導中的離線模型下載

private struct OnboardingModelDownloadRow: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var models = SherpaModelManager.shared

    var body: some View {
        VStack(spacing: 10) {
            switch models.state {
            case .notInstalled:
                Button("下載離線模型（\(OnboardingView.modelSizeText)）") { models.download() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(minHeight: 44)
                Text("建議在 Wi-Fi 下載，下載期間請保持 Saybit 在前景。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("下載中 \(progress.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.subheadline)
                }
                Button("取消下載", role: .cancel) { models.cancelDownload() }
                    .frame(minHeight: 44)
            case .installed:
                Label("離線模型已安裝", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("改用離線辨識（SenseVoice）") {
                    settingsStore.sttEngine = .sherpaSenseVoice
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .disabled(settingsStore.sttEngine == .sherpaSenseVoice)
            case .failed(let message):
                Label {
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                Button("重新下載") { models.download() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Keyboard Setup

struct KeyboardSetupView: View {
    @Environment(\.openURL) private var openURL

    private struct Step: Identifiable {
        let id: Int
        let icon: String
        let text: String
    }

    private let steps: [Step] = [
        Step(id: 1, icon: "gear", text: "打開「設定」App › 一般 › 鍵盤 › 鍵盤"),
        Step(id: 2, icon: "plus.circle", text: "點「新增鍵盤…」，選擇「Saybit」"),
        Step(id: 3, icon: "lock.open", text: "點進 Saybit，開啟「允許完整取用」。鍵盤需要這個權限才能和 Saybit App 交換文字，不會收集你的輸入"),
        Step(id: 4, icon: "globe", text: "在任何輸入框長按 🌐 切換到 Saybit 鍵盤"),
        Step(id: 5, icon: "mic.fill", text: "按鍵盤上的麥克風：第一次會跳到 Saybit 開始錄音，說完回到原本的 App，結果會自動輸入"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(step.id)")
                            .font(.headline)
                            .frame(width: 28, height: 28)
                            .background(Color.accentColor.opacity(0.15), in: Circle())
                        Label {
                            Text(step.text)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: step.icon).foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("安裝步驟")
            }
            Section {
                Button("打開 Saybit 的系統設定") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } footer: {
                Text("小技巧：在 Saybit 首頁啟動「鍵盤待命」後，鍵盤按麥克風就不必跳回 App。也可以把「Saybit 語音輸入」設定到動作按鈕。")
            }
        }
        .navigationTitle("安裝鍵盤")
    }
}
