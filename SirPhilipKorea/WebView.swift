import UIKit
import WebKit
import SafariServices

private weak var spkKakaoPopupViewController: UIViewController?
private weak var spkReceiptPopupViewController: UIViewController?
private weak var spkReceiptPopupWebView: WKWebView?
private weak var spkPaymentPopupViewController: UIViewController?
private weak var spkPaymentPopupWebView: WKWebView?
private weak var spkMainWebView: WKWebView?

// SPK Build 132: Remember that a real-Safari card payment was started.
// This is used only to recover the app's checkout if the user comes back
// from a cancelled/abandoned external payment and the old Processing overlay
// is still frozen in the app WebView.
private let spkSafariCardPaymentPendingKey = "spk_safari_card_payment_pending_v131"
private let spkSafariCardPaymentURLKey = "spk_safari_card_payment_url_v131"

// SPK v6.0: Detect KG Inicis receipt / cash-receipt pages opened from order details.
// These pages use window.print() and popup navigation that do not work reliably in iOS WKWebView.
private func spkIsInicisReceiptURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
        return false
    }

    let host = (url.host ?? "").lowercased()
    let absolute = url.absoluteString.lowercased()

    guard host.contains("inicis") || host.contains("inipay") else {
        return false
    }

    let receiptTokens = [
        "receipt", "cashreceipt", "cash_receipt", "cash-receipt",
        "현금영수증", "영수증", "bill", "statement", "trade_receipt",
        "receiptview", "receipt_view", "viewreceipt", "receipt.jsp"
    ]

    return receiptTokens.contains { absolute.contains($0) }
}

// SPK v5.7: Keep CodeMShop SimplePay / KG Inicis HTTP(S) payment pages inside WKWebView.
// Only non-web URL schemes used by bank/card apps are opened externally.
private func spkIsInicisWebURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
        return false
    }

    let absolute = url.absoluteString.lowercased()
    let host = (url.host ?? "").lowercased()
    let path = url.path.lowercased()

    if host.contains("inicis") || host.contains("inipay") || host.contains("bankpay") {
        return true
    }

    if absolute.contains("payment_form") || absolute.contains("transaction_id=tinicis") || absolute.contains("inistdpay") {
        return true
    }

    if path.contains("payment_form") || path.contains("order-pay") || path.contains("wc-api") {
        return absolute.contains("tinicis") || absolute.contains("simplepay") || absolute.contains("payment")
    }

    return false
}


// SPK v5.9: Detect CodeMShop SimplePay / KG Inicis card-payment cancellation callback.
// The callback response calls window.top.jQuery.fn.payment_fail(), which does not reliably
// return to the WooCommerce checkout when Inicis has replaced the top WKWebView page.
private func spkIsInicisCancelCallback(_ url: URL) -> Bool {
    let absolute = url.absoluteString.lowercased()
    let path = url.path.lowercased()

    guard path.contains("wc-api/wc_gateway_inicis_stdcard") ||
          absolute.contains("wc_gateway_inicis_stdcard") else {
        return false
    }

    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let queryItems = components.queryItems else {
        return absolute.contains("type=cancel")
    }

    return queryItems.contains { item in
        item.name.lowercased() == "type" && item.value?.lowercased() == "cancel"
    }
}

private func spkReturnToCheckoutAfterPaymentCancel(_ sourceWebView: WKWebView, presenter: UIViewController) {
    let checkoutURL = URL(string: "/checkout/", relativeTo: rootUrl)?.absoluteURL
        ?? rootUrl.appendingPathComponent("checkout/")

    sourceWebView.stopLoading()

    let restoreCheckout = {
        let targetWebView = spkMainWebView ?? sourceWebView
        targetWebView.stopLoading()
        targetWebView.load(URLRequest(url: checkoutURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    if sourceWebView === spkPaymentPopupWebView {
        spkPaymentPopupViewController?.dismiss(animated: true) {
            spkPaymentPopupWebView = nil
            spkPaymentPopupViewController = nil
            restoreCheckout()
        }
    } else {
        restoreCheckout()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
        let alert = UIAlertController(
            title: "Payment cancelled / 결제 취소",
            message: "결제가 취소되었습니다. 장바구니와 주문 정보를 확인한 후 다시 결제해 주세요.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))

        if presenter.presentedViewController == nil {
            presenter.present(alert, animated: true)
        }
    }
}


// SPK v6.8: Temporary remote diagnostic logger for the iOS Inicis flow.
// Query values and request bodies are intentionally not transmitted.
private let spkInicisDebugKey = "tUIQiVXAB0dBCkiIxaAwQ-ch1-CobgyA"

private func spkDebugWebViewName(_ webView: WKWebView?) -> String {
    guard let webView = webView else { return "unknown" }
    if webView === spkPaymentPopupWebView { return "payment-popup" }
    if webView === spkReceiptPopupWebView { return "receipt-popup" }
    if webView === spkMainWebView { return "main" }
    return "other"
}

private func spkDebugNavigationType(_ type: WKNavigationType) -> String {
    switch type {
    case .linkActivated: return "linkActivated"
    case .formSubmitted: return "formSubmitted"
    case .backForward: return "backForward"
    case .reload: return "reload"
    case .formResubmitted: return "formResubmitted"
    case .other: return "other"
    @unknown default: return "unknown"
    }
}

private func spkDebugURLSummary(_ url: URL?) -> [String: Any] {
    guard let url = url else { return ["present": false] }

    var queryNames: [String] = []
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
        queryNames = (components.queryItems ?? []).map { $0.name }
    }

    return [
        "present": true,
        "scheme": url.scheme?.lowercased() ?? "",
        "host": url.host?.lowercased() ?? "",
        "path": url.path,
        "query_names": Array(Set(queryNames)).sorted(),
        "absolute_length": url.absoluteString.count
    ]
}

private func spkSendInicisDiagnostic(_ event: String, _ details: [String: Any] = [:]) {
    guard let endpoint = URL(string: "/wp-json/spk-inicis-debug/v1/event", relativeTo: rootUrl)?.absoluteURL else {
        return
    }

    var payload: [String: Any] = [
        "event": event,
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "ios_version": UIDevice.current.systemVersion,
        "app_state": UIApplication.shared.applicationState == .active ? "active" :
                     (UIApplication.shared.applicationState == .inactive ? "inactive" : "background")
    ]

    details.forEach { payload[$0.key] = $0.value }

    guard JSONSerialization.isValidJSONObject(payload),
          let body = try? JSONSerialization.data(withJSONObject: payload) else {
        return
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(spkInicisDebugKey, forHTTPHeaderField: "X-SPK-Debug-Key")
    request.httpBody = body

    URLSession.shared.dataTask(with: request).resume()
}

private func spkOpenExternalPaymentApp(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
          !["http", "https", "about", "blob", "file"].contains(scheme) else {
        return false
    }

    let canOpen = UIApplication.shared.canOpenURL(url)

    spkSendInicisDiagnostic("external_scheme_detected", [
        "url": spkDebugURLSummary(url),
        "can_open": canOpen
    ])

    if canOpen {
        UIApplication.shared.open(url, options: [:]) { success in
            spkSendInicisDiagnostic("external_scheme_open_result", [
                "scheme": scheme,
                "success": success
            ])
        }
    } else {
        spkSendInicisDiagnostic("external_scheme_not_available", [
            "scheme": scheme
        ])
    }

    return true
}

func createWebView(container: UIView, WKSMH: WKScriptMessageHandler, WKND: WKNavigationDelegate, NSO: NSObject, VC: ViewController) -> WKWebView{

    let config = WKWebViewConfiguration()
    let userContentController = WKUserContentController()

    userContentController.add(WKSMH, name: "print")
    userContentController.add(WKSMH, name: "push-subscribe")
    userContentController.add(WKSMH, name: "push-permission-request")
    userContentController.add(WKSMH, name: "push-permission-state")
    userContentController.add(WKSMH, name: "push-token")

    config.userContentController = userContentController

    // SPK v6.6.1: Follow KG Inicis' official iOS WebView guidance.
    // Use the normal persistent WKWebView data store and do not modify the
    // User-Agent or private "standalone" preference.
    config.websiteDataStore = .default()
    config.limitsNavigationsToAppBoundDomains = false
    config.allowsInlineMediaPlayback = true
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    
    let webView = WKWebView(frame: calcWebviewFrame(webviewView: container, toolbarView: nil), configuration: config)
    spkMainWebView = webView
    setCustomCookie(webView: webView)

    // SPK Build 132:
    // When the user returns from Safari/card-app while the original checkout is
    // still sitting in a grey Processing state, do not silently reload it.
    // Instead, show a native recovery choice:
    //   - Return to Safari: continue the external payment flow.
    //   - I canceled payment: safely reload checkout and remove the frozen state.
    //
    // This keeps the successful Samsung/monimo flow untouched while giving
    // cancelled flows (e.g. Shinhan SOL) a safe way back to checkout.
    var spkPaymentRecoveryAlertVisible = false

    NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
    ) { [weak webView] _ in
        guard UserDefaults.standard.bool(forKey: spkSafariCardPaymentPendingKey),
              let webView = webView,
              let currentURL = webView.url else {
            return
        }

        let absolute = currentURL.absoluteString.lowercased()

        // A completed payment normally leaves checkout/order-pay and moves to
        // an order-received/orders page via the existing deep-link flow.
        // Never disturb those successful pages.
        guard absolute.contains("/checkout") || absolute.contains("order-pay") else {
            UserDefaults.standard.set(false, forKey: spkSafariCardPaymentPendingKey)
            UserDefaults.standard.removeObject(forKey: spkSafariCardPaymentURLKey)
            return
        }

        guard !spkPaymentRecoveryAlertVisible else { return }
        spkPaymentRecoveryAlertVisible = true

        // Give WKWebView a short moment to finish restoring its foreground state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard UserDefaults.standard.bool(forKey: spkSafariCardPaymentPendingKey),
                  let refreshedURL = webView.url else {
                spkPaymentRecoveryAlertVisible = false
                return
            }

            let refreshed = refreshedURL.absoluteString.lowercased()
            guard refreshed.contains("/checkout") || refreshed.contains("order-pay") else {
                UserDefaults.standard.set(false, forKey: spkSafariCardPaymentPendingKey)
                UserDefaults.standard.removeObject(forKey: spkSafariCardPaymentURLKey)
                spkPaymentRecoveryAlertVisible = false
                return
            }

            // SPK Build 132: Branded recovery card.
            // Payment-state logic is unchanged from Build 131; only the recovery UI is customized.
            let recoveryVC = UIViewController()
            recoveryVC.modalPresentationStyle = .overFullScreen
            recoveryVC.view.backgroundColor = UIColor.black.withAlphaComponent(0.42)

            let card = UIView()
            card.translatesAutoresizingMaskIntoConstraints = false
            card.backgroundColor = UIColor(red: 1.0, green: 0.985, blue: 0.93, alpha: 1.0)
            card.layer.cornerRadius = 24
            card.layer.borderWidth = 2
            card.layer.borderColor = UIColor(red: 0.88, green: 0.64, blue: 0.15, alpha: 1.0).cgColor
            card.layer.shadowColor = UIColor.black.cgColor
            card.layer.shadowOpacity = 0.24
            card.layer.shadowRadius = 18
            card.layer.shadowOffset = CGSize(width: 0, height: 8)

            let badge = UILabel()
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.text = "S.P"
            badge.textAlignment = .center
            badge.font = .systemFont(ofSize: 18, weight: .black)
            badge.textColor = UIColor(red: 0.08, green: 0.31, blue: 0.20, alpha: 1.0)
            badge.backgroundColor = UIColor(red: 0.96, green: 0.77, blue: 0.18, alpha: 1.0)
            badge.layer.cornerRadius = 24
            badge.layer.masksToBounds = true

            let titleLabel = UILabel()
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.numberOfLines = 0
            titleLabel.textAlignment = .center
            titleLabel.font = .systemFont(ofSize: 21, weight: .bold)
            titleLabel.textColor = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1.0)
            titleLabel.text = "Card payment\n카드결제"

            let messageLabel = UILabel()
            messageLabel.translatesAutoresizingMaskIntoConstraints = false
            messageLabel.numberOfLines = 0
            messageLabel.textAlignment = .center
            messageLabel.font = .systemFont(ofSize: 14.5, weight: .regular)
            messageLabel.textColor = UIColor(red: 0.30, green: 0.31, blue: 0.32, alpha: 1.0)
            messageLabel.text = "Payment may still be open in Safari.\nSafari에서 결제가 계속 진행 중일 수 있습니다.\n\nIf you canceled the payment, return safely to checkout.\n결제를 취소했다면 결제창으로 안전하게 돌아가 주세요."

            func makeRecoveryButton(_ title: String, background: UIColor, foreground: UIColor) -> UIButton {
                let button = UIButton(type: .system)
                button.translatesAutoresizingMaskIntoConstraints = false
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 16.5, weight: .bold)
                button.titleLabel?.numberOfLines = 2
                button.titleLabel?.textAlignment = .center
                button.setTitleColor(foreground, for: .normal)
                button.backgroundColor = background
                button.layer.cornerRadius = 13
                return button
            }

            let safariButton = makeRecoveryButton(
                "Return to Safari\nSafari로 돌아가기",
                background: UIColor(red: 0.08, green: 0.45, blue: 0.82, alpha: 1.0),
                foreground: .white
            )
            let cancelButton = makeRecoveryButton(
                "I canceled payment\n결제를 취소했습니다",
                background: UIColor(red: 1.0, green: 0.94, blue: 0.94, alpha: 1.0),
                foreground: UIColor(red: 0.82, green: 0.16, blue: 0.18, alpha: 1.0)
            )
            cancelButton.layer.borderWidth = 1
            cancelButton.layer.borderColor = UIColor(red: 0.95, green: 0.68, blue: 0.68, alpha: 1.0).cgColor

            let hintLabel = UILabel()
            hintLabel.translatesAutoresizingMaskIntoConstraints = false
            hintLabel.numberOfLines = 0
            hintLabel.textAlignment = .center
            hintLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
            hintLabel.textColor = UIColor(red: 0.45, green: 0.42, blue: 0.34, alpha: 1.0)
            hintLabel.text = "Sir Philip Korea · Secure payment\n써필립코리아 · 안전결제"

            recoveryVC.view.addSubview(card)
            [badge, titleLabel, messageLabel, safariButton, cancelButton, hintLabel].forEach { card.addSubview($0) }

            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: recoveryVC.view.leadingAnchor, constant: 24),
                card.trailingAnchor.constraint(equalTo: recoveryVC.view.trailingAnchor, constant: -24),
                card.centerYAnchor.constraint(equalTo: recoveryVC.view.centerYAnchor),

                badge.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
                badge.centerXAnchor.constraint(equalTo: card.centerXAnchor),
                badge.widthAnchor.constraint(equalToConstant: 48),
                badge.heightAnchor.constraint(equalToConstant: 48),

                titleLabel.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 13),
                titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
                titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

                messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 13),
                messageLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                messageLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),

                safariButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 22),
                safariButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
                safariButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
                safariButton.heightAnchor.constraint(equalToConstant: 58),

                cancelButton.topAnchor.constraint(equalTo: safariButton.bottomAnchor, constant: 10),
                cancelButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
                cancelButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
                cancelButton.heightAnchor.constraint(equalToConstant: 58),

                hintLabel.topAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: 14),
                hintLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
                hintLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
                hintLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
            ])

            safariButton.addAction(UIAction { _ in
                spkPaymentRecoveryAlertVisible = false
                recoveryVC.dismiss(animated: true) {
                    if let saved = UserDefaults.standard.string(forKey: spkSafariCardPaymentURLKey),
                       let safariURL = URL(string: saved) {
                        UIApplication.shared.open(safariURL, options: [:], completionHandler: nil)
                    }
                }
            }, for: .touchUpInside)

            cancelButton.addAction(UIAction { _ in
                spkPaymentRecoveryAlertVisible = false
                UserDefaults.standard.set(false, forKey: spkSafariCardPaymentPendingKey)
                UserDefaults.standard.removeObject(forKey: spkSafariCardPaymentURLKey)

                let checkoutURL = URL(string: "/checkout/", relativeTo: rootUrl)?.absoluteURL
                    ?? rootUrl.appendingPathComponent("checkout/")

                recoveryVC.dismiss(animated: true) {
                    webView.stopLoading()
                    webView.load(URLRequest(url: checkoutURL, cachePolicy: .reloadIgnoringLocalCacheData))
                }

                spkSendInicisDiagnostic("build132_cancelled_payment_checkout_recovered", [
                    "url": spkDebugURLSummary(refreshedURL)
                ])
            }, for: .touchUpInside)

            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
               let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {

                var presenter = root
                while let presented = presenter.presentedViewController {
                    presenter = presented
                }
                presenter.present(recoveryVC, animated: true)
            } else {
                spkPaymentRecoveryAlertVisible = false
            }
        }
    }

    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.isHidden = true;
    webView.navigationDelegate = WKND
    webView.uiDelegate = VC
    webView.scrollView.bounces = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    // SPK v5.6: Disable iOS swipe-back navigation to protect checkout/cart/payment flow.
    webView.allowsBackForwardNavigationGestures = false
    
    // Check if macCatalyst 16.4+ is available and if so, enable web inspector.
    // This allows the web app to be inspected using Safari Web Inspector. Supported on iOS 16.4+ and macOS 13.3+
    if #available(iOS 16.4, macOS 13.3, *) {
        webView.isInspectable = true
    }
    
    // SPK v6.6.1: Keep the native WKWebView User-Agent completely untouched.
    // KG Inicis warns that card-company ACS pages may reject an altered User-Agent.

    webView.addObserver(NSO, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: NSKeyValueObservingOptions.new, context: nil)
    
    #if DEBUG
    if #available(iOS 16.4, *) {
        webView.isInspectable = true
    }
    #endif
    
    return webView
}

func setAppStoreAsReferrer(contentController: WKUserContentController) {
    let scriptSource = "document.referrer = `app-info://platform/ios-store`;"
    let script = WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    contentController.addUserScript(script);
}

func setCustomCookie(webView: WKWebView) {
    let _platformCookie = HTTPCookie(properties: [
        .domain: rootUrl.host!,
        .path: "/",
        .name: platformCookie.name,
        .value: platformCookie.value,
        .secure: "FALSE",
        .expires: NSDate(timeIntervalSinceNow: 31556926)
    ])!

    webView.configuration.websiteDataStore.httpCookieStore.setCookie(_platformCookie)

    // SPK v6.3: App-only marker used by the WordPress payment compatibility plugin.
    // Safari/Chrome do not receive this cookie, so app_scheme is added only for
    // checkout requests originating from the Sir Philip Korea iOS app.
    let spkIOSAppCookie = HTTPCookie(properties: [
        .domain: rootUrl.host!,
        .path: "/",
        .name: "spk_ios_app",
        .value: "1",
        .secure: "TRUE",
        .expires: NSDate(timeIntervalSinceNow: 31556926)
    ])!

    webView.configuration.websiteDataStore.httpCookieStore.setCookie(spkIOSAppCookie)

}

func calcWebviewFrame(webviewView: UIView, toolbarView: UIToolbar?) -> CGRect{
    if ((toolbarView) != nil) {
        return CGRect(x: 0, y: toolbarView!.frame.height, width: webviewView.frame.width, height: webviewView.frame.height - toolbarView!.frame.height)
    }
    else {
        let winScene = UIApplication.shared.connectedScenes.first
        let windowScene = winScene as! UIWindowScene
        var statusBarHeight = windowScene.statusBarManager?.statusBarFrame.height ?? 0

        switch displayMode {
        case "fullscreen":
            #if targetEnvironment(macCatalyst)
                if let titlebar = windowScene.titlebar {
                    titlebar.titleVisibility = .hidden
                    titlebar.toolbar = nil
                }
            #endif
            return CGRect(x: 0, y: 0, width: webviewView.frame.width, height: webviewView.frame.height)
        default:
            #if targetEnvironment(macCatalyst)
            statusBarHeight = 29
            #endif
            let windowHeight = webviewView.frame.height - statusBarHeight
            return CGRect(x: 0, y: statusBarHeight, width: webviewView.frame.width, height: windowHeight)
        }
    }
}

extension ViewController: WKUIDelegate, WKDownloadDelegate {
    // redirect new tabs to popup webviews when needed
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else {
            return nil
        }

        // SPK v5.9: Handle Inicis cancellation before creating/loading another page.
        if let requestUrl = navigationAction.request.url, spkIsInicisCancelCallback(requestUrl) {
            spkReturnToCheckoutAfterPaymentCancel(webView, presenter: self)
            return nil
        }

        // SPK v5.3: Printable recipe pages must open in the real Safari app.
        // WKWebView does not reliably support window.print().
        if let requestUrl = navigationAction.request.url,
           let components = URLComponents(url: requestUrl, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            let isSPKPrintPage = queryItems.contains(where: { $0.name == "spk_recipe_print" })
            let asksForSafari = queryItems.contains(where: { $0.name == "spk_app_open_safari" && $0.value == "1" })

            if isSPKPrintPage || asksForSafari {
                var cleanComponents = components
                let cleanedItems = queryItems.filter { $0.name != "spk_app_open_safari" }
                cleanComponents.queryItems = cleanedItems.isEmpty ? nil : cleanedItems
                let safariUrl = cleanComponents.url ?? requestUrl
                UIApplication.shared.open(safariUrl, options: [:], completionHandler: nil)
                return nil
            }
        }

        // SPK v6.0: Open Inicis receipt pages in a dedicated in-app popup with
        // native Close and Print buttons so iPhone users cannot become trapped.
        if let requestUrl = navigationAction.request.url, spkIsInicisReceiptURL(requestUrl) {
            return spkPresentReceiptPopup(request: navigationAction.request, configuration: configuration)
        }

        // SPK v6.8 A/B TEST:
        // Match the latest PWABuilder template's window.open() behavior for Inicis.
        // Instead of creating a dedicated child WKWebView, load the original
        // navigationAction.request into the current WebView and return nil.
        // No other payment behavior is changed in this test.
        if let requestUrl = navigationAction.request.url, spkIsInicisWebURL(requestUrl) {
            webView.load(navigationAction.request)
            return nil
        }

        // Card/bank app schemes are opened externally, while the checkout stays alive.
        if let requestUrl = navigationAction.request.url, spkOpenExternalPaymentApp(requestUrl) {
            return nil
        }

        // SPK v5.2/v5.3: Kakao/Daum postcode must stay in a real popup WKWebView.
        // Loading it into the main webView breaks the callback to the checkout page.
        if let requestUrl = navigationAction.request.url,
           let requestHost = requestUrl.host,
           requestHost.contains("postcode.map.kakao.com") || requestHost.contains("postcode.map.daum.net") {
            let popupViewController = UIViewController()
            popupViewController.view.backgroundColor = .white
            popupViewController.navigationItem.title = "Address Search 주소검색"
            popupViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(spkDismissKakaoPopup)
            )

            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            popupWebView.translatesAutoresizingMaskIntoConstraints = false
            popupWebView.navigationDelegate = self
            popupWebView.uiDelegate = self
            popupWebView.scrollView.bounces = false
            popupWebView.scrollView.contentInsetAdjustmentBehavior = .never

            popupViewController.view.addSubview(popupWebView)
            NSLayoutConstraint.activate([
                popupWebView.leadingAnchor.constraint(equalTo: popupViewController.view.leadingAnchor),
                popupWebView.trailingAnchor.constraint(equalTo: popupViewController.view.trailingAnchor),
                popupWebView.topAnchor.constraint(equalTo: popupViewController.view.safeAreaLayoutGuide.topAnchor),
                popupWebView.bottomAnchor.constraint(equalTo: popupViewController.view.bottomAnchor)
            ])

            let navigationController = UINavigationController(rootViewController: popupViewController)
            navigationController.modalPresentationStyle = .fullScreen
            spkKakaoPopupViewController = navigationController

            self.present(navigationController, animated: true, completion: nil)
            return popupWebView
        }

        // SPK v5.7: For non-address popups, keep PWABuilder's same-WebView flow.
        // Payment HTTP(S) URLs are handled above inside the app.
        webView.load(navigationAction.request)
        return nil
    }

    private func spkPresentPaymentPopup(configuration: WKWebViewConfiguration) -> WKWebView {
        // Close any stale payment popup before creating a new one.
        if spkPaymentPopupViewController != nil {
            spkPaymentPopupViewController?.dismiss(animated: false)
            spkPaymentPopupViewController = nil
            spkPaymentPopupWebView = nil
        }

        let popupViewController = UIViewController()
        popupViewController.view.backgroundColor = .white
        popupViewController.navigationItem.title = "Secure Payment / 안전결제"
        popupViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Close / 닫기",
            style: .plain,
            target: self,
            action: #selector(spkDismissPaymentPopup)
        )

        // IMPORTANT: Use the exact WKWebViewConfiguration supplied by WebKit.
        // It contains the opener relationship, process pool, website data store,
        // preferences and other state created for this window.open() request.
        let popupWebView = WKWebView(frame: .zero, configuration: configuration)
        popupWebView.translatesAutoresizingMaskIntoConstraints = false
        popupWebView.navigationDelegate = self
        popupWebView.uiDelegate = self
        popupWebView.scrollView.bounces = false
        popupWebView.scrollView.contentInsetAdjustmentBehavior = .never
        popupWebView.allowsBackForwardNavigationGestures = false

        popupViewController.view.addSubview(popupWebView)
        NSLayoutConstraint.activate([
            popupWebView.leadingAnchor.constraint(equalTo: popupViewController.view.leadingAnchor),
            popupWebView.trailingAnchor.constraint(equalTo: popupViewController.view.trailingAnchor),
            popupWebView.topAnchor.constraint(equalTo: popupViewController.view.safeAreaLayoutGuide.topAnchor),
            popupWebView.bottomAnchor.constraint(equalTo: popupViewController.view.bottomAnchor)
        ])

        let navigationController = UINavigationController(rootViewController: popupViewController)
        navigationController.modalPresentationStyle = .fullScreen

        spkPaymentPopupViewController = navigationController
        spkPaymentPopupWebView = popupWebView

        self.present(navigationController, animated: true)

        // Do not call popupWebView.load(...) here.
        // WebKit automatically loads the original navigationAction request,
        // including any POST body, into the WKWebView returned by this delegate.
        return popupWebView
    }

    @objc func spkDismissPaymentPopup() {
        guard let paymentWebView = spkPaymentPopupWebView else {
            spkPaymentPopupViewController?.dismiss(animated: true)
            spkPaymentPopupViewController = nil
            return
        }

        spkReturnToCheckoutAfterPaymentCancel(paymentWebView, presenter: self)
    }

    private func spkPresentReceiptPopup(request: URLRequest, configuration: WKWebViewConfiguration) -> WKWebView {
        let popupViewController = UIViewController()
        popupViewController.view.backgroundColor = .white
        popupViewController.navigationItem.title = "Receipt / 영수증"

        popupViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Close / 닫기",
            style: .plain,
            target: self,
            action: #selector(spkDismissReceiptPopup)
        )

        popupViewController.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Print / 인쇄",
            style: .plain,
            target: self,
            action: #selector(spkPrintReceiptPopup)
        )

        let popupWebView = WKWebView(frame: .zero, configuration: configuration)
        popupWebView.translatesAutoresizingMaskIntoConstraints = false
        popupWebView.navigationDelegate = self
        popupWebView.uiDelegate = self
        popupWebView.scrollView.bounces = false
        popupWebView.scrollView.contentInsetAdjustmentBehavior = .never
        popupWebView.allowsBackForwardNavigationGestures = false

        popupViewController.view.addSubview(popupWebView)
        NSLayoutConstraint.activate([
            popupWebView.leadingAnchor.constraint(equalTo: popupViewController.view.leadingAnchor),
            popupWebView.trailingAnchor.constraint(equalTo: popupViewController.view.trailingAnchor),
            popupWebView.topAnchor.constraint(equalTo: popupViewController.view.safeAreaLayoutGuide.topAnchor),
            popupWebView.bottomAnchor.constraint(equalTo: popupViewController.view.bottomAnchor)
        ])

        let navigationController = UINavigationController(rootViewController: popupViewController)
        navigationController.modalPresentationStyle = .fullScreen

        spkReceiptPopupViewController = navigationController
        spkReceiptPopupWebView = popupWebView

        self.present(navigationController, animated: true) {
            popupWebView.load(request)
        }

        return popupWebView
    }

    @objc func spkDismissReceiptPopup() {
        spkReceiptPopupWebView?.stopLoading()
        spkReceiptPopupViewController?.dismiss(animated: true, completion: nil)
        spkReceiptPopupWebView = nil
        spkReceiptPopupViewController = nil
    }

    @objc func spkPrintReceiptPopup() {
        guard let receiptWebView = spkReceiptPopupWebView else { return }

        let printController = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.outputType = .general
        printInfo.jobName = "Sir Philip Korea Receipt / 써필립코리아 영수증"
        printController.printInfo = printInfo
        printController.printFormatter = receiptWebView.viewPrintFormatter()
        printController.present(animated: true, completionHandler: nil)
    }

    @objc func spkDismissKakaoPopup() {
        spkKakaoPopupViewController?.dismiss(animated: true, completion: nil)
        spkKakaoPopupViewController = nil
    }


    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        spkSendInicisDiagnostic("navigation_started", [
            "webview": spkDebugWebViewName(webView),
            "url": spkDebugURLSummary(webView.url)
        ])
    }





    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        spkSendInicisDiagnostic("navigation_failed", [
            "webview": spkDebugWebViewName(webView),
            "url": spkDebugURLSummary(webView.url),
            "error_domain": nsError.domain,
            "error_code": nsError.code,
            "error_description": nsError.localizedDescription
        ])
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === spkPaymentPopupWebView {
            spkReturnToCheckoutAfterPaymentCancel(webView, presenter: self)
            return
        }

        if webView === spkReceiptPopupWebView {
            spkDismissReceiptPopup()
            return
        }

        spkKakaoPopupViewController?.dismiss(animated: true, completion: nil)
        spkKakaoPopupViewController = nil
    }
    // restrict navigation to target host, open external links in 3rd party apps
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        spkSendInicisDiagnostic("navigation_action", [
            "webview": spkDebugWebViewName(webView),
            "navigation_type": spkDebugNavigationType(navigationAction.navigationType),
            "http_method": navigationAction.request.httpMethod ?? "",
            "has_http_body": navigationAction.request.httpBody != nil,
            "target_frame_is_nil": navigationAction.targetFrame == nil,
            "target_frame_is_main": navigationAction.targetFrame?.isMainFrame ?? false,
            "source_frame_is_main": navigationAction.sourceFrame.isMainFrame,
            "url": spkDebugURLSummary(navigationAction.request.url)
        ])

        // SPK v6.6.1: KG Inicis official order of handling plus remote diagnostics.
        // External card/bank app schemes must be processed before any host,
        // popup, callback or allowed-origin routing.
        if let requestURL = navigationAction.request.url,
           spkOpenExternalPaymentApp(requestURL) {
            decisionHandler(.cancel)
            return
        }

        if (navigationAction.request.url?.scheme == "about") {
            return decisionHandler(.allow)
        }
        if (navigationAction.shouldPerformDownload || navigationAction.request.url?.scheme == "blob") {
            return decisionHandler(.download)
        }

        // SPK v5.9: Intercept the SimplePay/Inicis cancel callback.
        // Do not render its window.top.payment_fail() response in the Inicis page;
        // return the same WKWebView to WooCommerce checkout instead.
        if let requestUrl = navigationAction.request.url, spkIsInicisCancelCallback(requestUrl) {
            UserDefaults.standard.set(false, forKey: spkSafariCardPaymentPendingKey)
            UserDefaults.standard.removeObject(forKey: spkSafariCardPaymentURLKey)
            decisionHandler(.cancel)
            spkReturnToCheckoutAfterPaymentCancel(webView, presenter: self)
            return
        }

        // SPK v5.1: Open SPK printable recipe pages in the real Safari app.
        // WKWebView does not reliably support window.print(), so printable recipe pages must leave the app.
        if let requestUrl = navigationAction.request.url,
           let components = URLComponents(url: requestUrl, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            let isSPKPrintPage = queryItems.contains(where: { $0.name == "spk_recipe_print" })
            let asksForSafari = queryItems.contains(where: { $0.name == "spk_app_open_safari" && $0.value == "1" })

            if isSPKPrintPage || asksForSafari {
                var cleanComponents = components
                let cleanedItems = queryItems.filter { $0.name != "spk_app_open_safari" }
                cleanComponents.queryItems = cleanedItems.isEmpty ? nil : cleanedItems
                let safariUrl = cleanComponents.url ?? requestUrl
                decisionHandler(.cancel)
                UIApplication.shared.open(safariUrl, options: [:], completionHandler: nil)
                return
            }
        }

        // SPK v6.9 TEST: Hand the CodeMShop -> KG Inicis payment entry to the real Safari app.
        //
        // The diagnostic log confirmed this exact navigation occurs in the MAIN WKWebView:
        // payment.codemshop.com/.../pg/inicis/proxy/payment_form
        //
        // IMPORTANT:
        // - Intercept here in WKNavigationDelegate, before spkIsInicisWebURL() allows it.
        // - Only intercept the CodeMShop Inicis proxy payment_form entry.
        // - Do NOT intercept mobile.inicis.com or card-company ACS URLs here.
        // - This is intentionally a narrow A/B diagnostic test.
        if let requestUrl = navigationAction.request.url {
            let host = (requestUrl.host ?? "").lowercased()
            let path = requestUrl.path.lowercased()

            let isCodeMShopInicisPaymentEntry =
                host == "payment.codemshop.com" &&
                path.contains("/pg/inicis/proxy/payment_form")

            if isCodeMShopInicisPaymentEntry {
                spkSendInicisDiagnostic("safari_payment_entry_intercepted", [
                    "webview": spkDebugWebViewName(webView),
                    "navigation_type": spkDebugNavigationType(navigationAction.navigationType),
                    "http_method": navigationAction.request.httpMethod ?? "",
                    "has_http_body": navigationAction.request.httpBody != nil,
                    "url": spkDebugURLSummary(requestUrl)
                ])

                decisionHandler(.cancel)

                // SPK Build 131: Safari card-payment handoff + compact guide + foreground stuck-checkout recovery.
                // Payment handoff/deep-link logic is intentionally unchanged from Build 118.
                let alert = UIAlertController(
                    title: "Card payment guide\n카드결제 안내",
                    message: "English\n\n❶ Complete payment in Safari.\n→ Tap the button below.\n\n❷ After payment, find Safari.\n→ Home Screen? Swipe up and select Safari.\n\n❸ Return to Sir Philip Korea.\n→ Tap ‘Open Sir Philip Korea App’.\n\nIf you cancel payment, tap Cancel once more to return to Sir Philip Korea.\nTo change the payment method, return to Sir Philip Korea and start again.\n\n────────────\n\n한국어\n\n❶ Safari에서 결제를 완료합니다.\n→ 아래 버튼을 눌러주세요.\n\n❷ 결제 후 Safari를 찾아주세요.\n→ 바탕화면이면 아래에서 위로 밀어 Safari를 선택합니다.\n\n❸ 써필립코리아로 돌아옵니다.\n→ ‘써필립코리아 앱 열기’를 눌러주세요.\n\n결제를 취소한 경우 취소 버튼을 한 번 더 눌러 써필립코리아로 돌아와 주세요.\n다른 결제수단을 이용하려면 써필립코리아로 돌아와 다시 결제해 주세요.",
                    preferredStyle: .alert
                )

                // Warm ivory card + stronger gold outline for clear separation from checkout.
                alert.view.backgroundColor = UIColor(red: 1.00, green: 0.975, blue: 0.88, alpha: 1.0)
                alert.view.layer.cornerRadius = 24
                alert.view.layer.borderWidth = 2.0
                alert.view.layer.borderColor = UIColor(red: 0.92, green: 0.64, blue: 0.10, alpha: 1.0).cgColor
                alert.view.layer.shadowColor = UIColor.black.cgColor
                alert.view.layer.shadowOpacity = 0.22
                alert.view.layer.shadowRadius = 14
                alert.view.layer.shadowOffset = CGSize(width: 0, height: 7)

                if let title = alert.title {
                    let titleText = NSMutableAttributedString(string: title)
                    let titleParagraph = NSMutableParagraphStyle()
                    titleParagraph.alignment = .center
                    titleParagraph.lineSpacing = 3
                    titleText.addAttributes([
                        .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                        .foregroundColor: UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1.0),
                        .paragraphStyle: titleParagraph
                    ], range: NSRange(location: 0, length: titleText.length))
                    alert.setValue(titleText, forKey: "attributedTitle")
                }

                if let message = alert.message {
                    let ns = message as NSString
                    let styled = NSMutableAttributedString(string: message)
                    let p = NSMutableParagraphStyle()
                    p.alignment = .left
                    p.lineSpacing = 2
                    p.paragraphSpacing = 3
                    styled.addAttributes([
                        .font: UIFont.systemFont(ofSize: 12.2),
                        .foregroundColor: UIColor(red: 0.38, green: 0.38, blue: 0.38, alpha: 1),
                        .paragraphStyle: p
                    ], range: NSRange(location: 0, length: styled.length))

                    let green = UIColor(red: 0.08, green: 0.39, blue: 0.25, alpha: 1)
                    let dark = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
                    for heading in ["English", "한국어"] {
                        let r = ns.range(of: heading)
                        if r.location != NSNotFound {
                            styled.addAttributes([.font:UIFont.systemFont(ofSize:14.5,weight:.bold), .foregroundColor:green], range:r)
                        }
                    }
                    let steps = [
                        "❶ Complete payment in Safari.",
                        "❷ After payment, find Safari.",
                        "❸ Return to Sir Philip Korea.",
                        "❶ Safari에서 결제를 완료합니다.",
                        "❷ 결제 후 Safari를 찾아주세요.",
                        "❸ 써필립코리아로 돌아옵니다."
                    ]
                    for s in steps {
                        let r = ns.range(of:s)
                        if r.location != NSNotFound {
                            styled.addAttributes([.font:UIFont.systemFont(ofSize:13.6,weight:.bold), .foregroundColor:dark], range:r)
                            styled.addAttributes([.font:UIFont.systemFont(ofSize:15.5,weight:.bold), .foregroundColor:green], range:NSRange(location:r.location,length:1))
                        }
                    }
                    let divider = ns.range(of:"────────────")
                    if divider.location != NSNotFound {
                        styled.addAttribute(.foregroundColor, value: UIColor(red:0.76,green:0.55,blue:0.12,alpha:1), range:divider)
                    }
                    alert.setValue(styled, forKey:"attributedMessage")
                }

                alert.addAction(UIAlertAction(title: "Cancel / 취소", style: .cancel) { _ in
                    spkSendInicisDiagnostic("safari_payment_entry_user_cancelled", [
                        "host": host,
                        "path": path
                    ])

                    // Build 131: Do not force-reload checkout here.
                    // Preserve the original KG Inicis / CodeMShop cancellation flow so the user
                    // can finish cancelling in the PG screen and return through the existing
                    // payment-cancel callback (spkIsInicisCancelCallback).
                })

                alert.addAction(UIAlertAction(title: "Continue to Safari\nSafari에서 결제", style: .default) { _ in
                    // Build 131: remember the real Safari payment URL and mark the
                    // external payment as pending only after the user explicitly continues.
                    UserDefaults.standard.set(true, forKey: spkSafariCardPaymentPendingKey)
                    UserDefaults.standard.set(requestUrl.absoluteString, forKey: spkSafariCardPaymentURLKey)

                    spkSendInicisDiagnostic("safari_payment_entry_user_confirmed", [
                        "host": host,
                        "path": path
                    ])
                    UIApplication.shared.open(requestUrl, options: [:]) { success in
                        spkSendInicisDiagnostic("safari_payment_entry_open_result", [
                            "host": host,
                            "path": path,
                            "success": success
                        ])
                    }
                })

                self.present(alert, animated: true)
                return
            }
        }

        // SPK v5.7: Keep all other Inicis/SimplePay HTTP(S) pages inside the same WKWebView.
        if let requestUrl = navigationAction.request.url, spkIsInicisWebURL(requestUrl) {
            decisionHandler(.allow)
            return
        }

        if let requestUrl = navigationAction.request.url{
            if let requestHost = requestUrl.host {
                // SPK v5.2: Keep Kakao/Daum postcode popup pages inside WKWebView.
                // Opening them in SFSafariViewController breaks the address callback to the checkout page.
                if requestHost.contains("postcode.map.kakao.com") || requestHost.contains("postcode.map.daum.net") {
                    decisionHandler(.allow)
                    return
                }

                // NOTE: Match auth origin first, because host origin may be a subset of auth origin and may therefore always match
                let matchingAuthOrigin = authOrigins.first(where: { requestHost.range(of: $0) != nil })
                if (matchingAuthOrigin != nil) {
                    decisionHandler(.allow)
                    if (toolbarView.isHidden) {
                        toolbarView.isHidden = false
                        webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: toolbarView)
                    }
                    return
                }

                let matchingHostOrigin = allowedOrigins.first(where: { requestHost.range(of: $0) != nil })
                if (matchingHostOrigin != nil) {
                    // Open in main webview
                    decisionHandler(.allow)
                    if (!toolbarView.isHidden) {
                        toolbarView.isHidden = true
                        webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: nil)
                    }
                    return
                }
                if (navigationAction.navigationType == .other &&
                    navigationAction.value(forKey: "syntheticClickType") as! Int == 0 &&
                    (navigationAction.targetFrame != nil) &&
                    navigationAction.sourceFrame.isMainFrame
                ) {
                    decisionHandler(.allow)
                    return
                }
                else {
                    decisionHandler(.cancel)
                }


                if ["http", "https"].contains(requestUrl.scheme?.lowercased() ?? "") {
                    // Can open with SFSafariViewController
                    let safariViewController = SFSafariViewController(url: requestUrl)
                    self.present(safariViewController, animated: true, completion: nil)
                } else {
                    // Scheme is not supported or no scheme is given, use openURL
                    if (UIApplication.shared.canOpenURL(requestUrl)) {
                        UIApplication.shared.open(requestUrl)
                    }
                }
            } else {
                decisionHandler(.cancel)
                if (navigationAction.request.url?.scheme == "tel" || navigationAction.request.url?.scheme == "mailto" ){
                    if (UIApplication.shared.canOpenURL(requestUrl)) {
                        UIApplication.shared.open(requestUrl)
                    }
                }
                else {
                    if requestUrl.isFileURL {
                        // not tested
                        downloadAndOpenFile(url: requestUrl.absoluteURL)
                    }
                    // if (requestUrl.absoluteString.contains("base64")){
                    //     downloadAndOpenBase64File(base64String: requestUrl.absoluteString)
                    // }
                }
            }
        }
        else {
            decisionHandler(.cancel)
        }

    }
    // SPK v6.0: Support JavaScript window.print() from the Inicis receipt popup.
    // The native navigation-bar Print button remains available even when the page does not call this API.
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // Handle javascript: `window.alert(message: String)`
    func webView(_ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .alert
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler
                completionHandler()
            }
        )
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }
    // Handle javascript: `window.confirm(message: String)`
    func webView(_ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .alert
        )

        // Add a confirmation action “Cancel”
        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel,
            handler: { _ in
                // Call completionHandler
                completionHandler(false)
            }
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler
                completionHandler(true)
            }
        )
        alert.addAction(cancelAction)
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }
    // Handle javascript: `window.prompt(prompt: String, defaultText: String?)`
    func webView(_ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: prompt,
            preferredStyle: .alert
        )

        // Add a confirmation action “Cancel”
        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel,
            handler: { _ in
                // Call completionHandler
                completionHandler(nil)
            }
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler with Alert input
                if let input = alert.textFields?.first?.text {
                    completionHandler(input)
                }
            }
        )

        alert.addTextField { textField in
            textField.placeholder = defaultText
        }
        alert.addAction(cancelAction)
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }

    func downloadAndOpenFile(url: URL){

        let destinationFileUrl = url
        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig)
        let request = URLRequest(url:url)
        let task = session.downloadTask(with: request) { (tempLocalUrl, response, error) in
            if let tempLocalUrl = tempLocalUrl, error == nil {
                if let statusCode = (response as? HTTPURLResponse)?.statusCode {
                    print("Successfully download. Status code: \(statusCode)")
                }
                do {
                    try FileManager.default.copyItem(at: tempLocalUrl, to: destinationFileUrl)
                    self.openFile(url: destinationFileUrl)
                } catch (let writeError) {
                    print("Error creating a file \(destinationFileUrl) : \(writeError)")
                }
            } else {
                print("Error took place while downloading a file. Error description: \(error?.localizedDescription ?? "N/A") ")
            }
        }
        task.resume()
    }

    // func downloadAndOpenBase64File(base64String: String) {
    //     // Split the base64 string to extract the data and the file extension
    //     let components = base64String.components(separatedBy: ";base64,")

    //     // Make sure the base64 string has the correct format
    //     guard components.count == 2, let format = components.first?.split(separator: "/").last else {
    //         print("Invalid base64 string format")
    //         return
    //     }

    //     // Remove the data type prefix to get the base64 data
    //     let dataString = components.last!

    //     if let imageData = Data(base64Encoded: dataString) {
    //         let documentsUrl: URL  =  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    //         let destinationFileUrl = documentsUrl.appendingPathComponent("image.\(format)")

    //         do {
    //             try imageData.write(to: destinationFileUrl)
    //             self.openFile(url: destinationFileUrl)
    //         } catch {
    //             print("Error writing image to file url: \(destinationFileUrl): \(error)")
    //         }
    //     }
    // }

    func openFile(url: URL) {
        self.documentController = UIDocumentInteractionController(url: url)
        self.documentController?.delegate = self
        self.documentController?.presentPreview(animated: true)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                suggestedFilename: String,
                completionHandler: @escaping (URL?) -> Void) {

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(suggestedFilename)

        // Remove existing file if it exists, otherwise it may show an old file/content just by having the same name.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        self.openFile(url: fileURL)
        completionHandler(fileURL)
    }
}
