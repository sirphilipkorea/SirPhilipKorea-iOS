import UIKit
import WebKit
import AuthenticationServices
import SafariServices

private weak var spkKakaoPopupViewController: UIViewController?

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

private func spkOpenExternalPaymentApp(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), !["http", "https", "about", "blob"].contains(scheme) else {
        return false
    }

    if UIApplication.shared.canOpenURL(url) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    } else {
        // Let iOS handle unavailable app schemes gracefully without replacing the checkout page.
        let alert = UIAlertController(
            title: "Payment app required / 결제 앱 필요",
            message: "해당 카드사 또는 은행 앱을 설치한 후 다시 시도해 주세요.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController?
            .present(alert, animated: true)
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

    config.limitsNavigationsToAppBoundDomains = false;
    config.allowsInlineMediaPlayback = true
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    config.preferences.setValue(true, forKey: "standalone")
    
    let webView = WKWebView(frame: calcWebviewFrame(webviewView: container, toolbarView: nil), configuration: config)
    setCustomCookie(webView: webView)

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
    
    let deviceModel = UIDevice.current.model
    let osVersion = UIDevice.current.systemVersion
    webView.configuration.applicationNameForUserAgent = "Safari/604.1"
    webView.customUserAgent = "Mozilla/5.0 (\(deviceModel); CPU \(deviceModel) OS \(osVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(osVersion) Mobile/15E148 Safari/604.1 PWAShell"

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

        // SPK v5.7: Keep KG Inicis/SimplePay payment in the main WKWebView so login,
        // cart, coupon and checkout sessions remain the same.
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

    @objc func spkDismissKakaoPopup() {
        spkKakaoPopupViewController?.dismiss(animated: true, completion: nil)
        spkKakaoPopupViewController = nil
    }


    func webViewDidClose(_ webView: WKWebView) {
        spkKakaoPopupViewController?.dismiss(animated: true, completion: nil)
        spkKakaoPopupViewController = nil
    }
    // restrict navigation to target host, open external links in 3rd party apps
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if (navigationAction.request.url?.scheme == "about") {
            return decisionHandler(.allow)
        }
        if (navigationAction.shouldPerformDownload || navigationAction.request.url?.scheme == "blob") {
            return decisionHandler(.download)
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

        // SPK v5.7: Keep Inicis/SimplePay HTTP(S) pages inside the same WKWebView.
        if let requestUrl = navigationAction.request.url, spkIsInicisWebURL(requestUrl) {
            decisionHandler(.allow)
            return
        }

        // Open only card/bank application schemes outside the app.
        if let requestUrl = navigationAction.request.url, spkOpenExternalPaymentApp(requestUrl) {
            decisionHandler(.cancel)
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
                    // no error here, fake warning
                    (navigationAction.sourceFrame != nil)
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
