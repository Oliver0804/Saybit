//
//  KeyboardViewController.swift
//  SaybitKeyboard
//
//  Saybit 自訂鍵盤。鍵盤 extension 無法使用麥克風，所以：
//    1. 主 App 鍵盤待命 session 活著 → 透過 KeyboardBridge 直接下指令錄音
//    2. 沒活著 → 打開主 App（saybit://dictate?source=keyboard）開始錄音，
//       使用者回到原 App 後，鍵盤收到結果再插入文字
//

import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var model: KeyboardModel!
    private var hostingController: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        model = KeyboardModel(
            hasFullAccess: { [weak self] in self?.hasFullAccess ?? false },
            proxy: { [weak self] in self?.textDocumentProxy },
            openURL: { [weak self] url in self?.openContainingApp(url) ?? false },
            advanceToNextInputMode: { [weak self] in self?.advanceToNextInputMode() }
        )

        let root = KeyboardView(
            model: model,
            needsGlobe: needsInputModeSwitchKey,
            globeAction: { [weak self] view, event in
                self?.handleInputModeList(from: view, with: event)
            }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.sizingOptions = [.intrinsicContentSize]
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.heightAnchor.constraint(equalToConstant: 270),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.activate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.deactivate()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.refreshReturnKey()
    }

    // MARK: - Open containing app

    /// 鍵盤 extension 不能呼叫 UIApplication.shared.open，
    /// 這裡沿 responder chain 找到 UIApplication 實例，透過 runtime 呼叫 open(_:options:completionHandler:)。
    private func openContainingApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let r = responder {
            if let app = r as? UIApplication, app.responds(to: selector) {
                typealias OpenFn = @convention(c) (AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any], ((Bool) -> Void)?) -> Void
                let imp = app.method(for: selector)
                let fn = unsafeBitCast(imp, to: OpenFn.self)
                fn(app, selector, url, [:], nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}
