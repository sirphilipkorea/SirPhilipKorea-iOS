import WebKit
import Foundation
import FirebaseMessaging

class SubscribeMessage {
    var topic  = ""
    var eventValue = ""
    var unsubscribe = false
    struct Keys {
        static var TOPIC = "topic"
        static var UNSUBSCRIBE = "unsubscribe"
        static var EVENTVALUE = "eventValue"
    }
    convenience init(dict: Dictionary<String,Any>) {
        self.init()
        if let topic = dict[Keys.TOPIC] as? String {
            self.topic = topic
        }
        if let unsubscribe = dict[Keys.UNSUBSCRIBE] as? Bool {
            self.unsubscribe = unsubscribe
        }
        if let eventValue = dict[Keys.EVENTVALUE] as? String {
            self.eventValue = eventValue
        }
    }
}

func handleSubscribeTouch(message: WKScriptMessage) {
  // [START subscribe_topic]
    let subscribeMessages = parseSubscribeMessage(message: message)
    if (subscribeMessages.count > 0){
        let _message = subscribeMessages[0]
        if (_message.unsubscribe) {
            Messaging.messaging().unsubscribe(fromTopic: _message.topic) { error in }
        }
        else {
            Messaging.messaging().subscribe(toTopic: _message.topic) { error in }
        }
    }
    

  // [END subscribe_topic]
}

func parseSubscribeMessage(message: WKScriptMessage) -> [SubscribeMessage] {
    var subscribeMessages = [SubscribeMessage]()
    if let objStr = message.body as? String {

        let data: Data = objStr.data(using: .utf8)!
        do {
            let jsObj = try JSONSerialization.jsonObject(with: data, options: .init(rawValue: 0))
            if let jsonObjDict = jsObj as? Dictionary<String, Any> {
                let subscribeMessage = SubscribeMessage(dict: jsonObjDict)
                subscribeMessages.append(subscribeMessage)
            } else if let jsonArr = jsObj as? [Dictionary<String, Any>] {
                for jsonObj in jsonArr {
                    let sMessage = SubscribeMessage(dict: jsonObj)
                    subscribeMessages.append(sMessage)
                }
            }
        } catch _ {
            
        }
    }
    return subscribeMessages
}

func returnPermissionResult(isGranted: Bool){
    DispatchQueue.main.async(execute: {
        if (isGranted){
            SirPhilipKorea.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('push-permission-request', { detail: 'granted' }))")
        }
        else {
            SirPhilipKorea.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('push-permission-request', { detail: 'denied' }))")
        }
    })
}
func returnPermissionState(state: String){
    DispatchQueue.main.async(execute: {
        SirPhilipKorea.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('push-permission-state', { detail: '\(state)' }))")
    })
}

func handlePushPermission() {
    UNUserNotificationCenter.current().getNotificationSettings () { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
                UNUserNotificationCenter.current().requestAuthorization(
                    options: authOptions,
                    completionHandler: { (success, error) in
                        if error == nil {
                            if success == true {
                                returnPermissionResult(isGranted: true)
                                DispatchQueue.main.async {
                                  UIApplication.shared.registerForRemoteNotifications()
                                }
                            }
                            else {
                                returnPermissionResult(isGranted: false)
                            }
                        }
                        else {
                            returnPermissionResult(isGranted: false)
                        }
                    }
                )
            case .denied:
                returnPermissionResult(isGranted: false)
            case .authorized, .ephemeral, .provisional:
                returnPermissionResult(isGranted: true)
            @unknown default:
                return;
            }
        }
}
func handlePushState() {
    UNUserNotificationCenter.current().getNotificationSettings () { settings in
        switch settings.authorizationStatus {
        case .notDetermined:
            returnPermissionState(state: "notDetermined")
        case .denied:
            returnPermissionState(state: "denied")
        case .authorized:
            returnPermissionState(state: "authorized")
        case .ephemeral:
            returnPermissionState(state: "ephemeral")
        case .provisional:
            returnPermissionState(state: "provisional")
        @unknown default:
            returnPermissionState(state: "unknown")
            return;
        }
    }
}

func checkViewAndEvaluate(event: String, detail: String) {
    if (!SirPhilipKorea.webView.isHidden && !SirPhilipKorea.webView.isLoading ) {
        DispatchQueue.main.async(execute: {
            SirPhilipKorea.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('\(event)', { detail: \(detail) }))")
        })
    }
    else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            checkViewAndEvaluate(event: event, detail: detail)
        }
    }
}

// SPK Push Diagnostic/Fix v1.0.4
// Keeps normal push behavior unchanged. Adds native -> web diagnostic events so
// the WordPress Push Manager can show exactly where token delivery stops.
private func spkPushDiag(_ stage: String, _ extra: [String: Any] = [:]) {
    var payload = extra
    payload["stage"] = stage
    payload["time"] = ISO8601DateFormatter().string(from: Date())
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else { return }
    checkViewAndEvaluate(event: "spk-push-native-diagnostic", detail: json)
}

// SPK Push Fix v1.0.6
// Deliver the FCM token directly to the WordPress bridge function.
// The old `push-token` CustomEvent remains as a fallback for compatibility.
private func spkDeliverFCMTokenToWordPress(_ token: String, retry: Int = 0) {
    guard !token.isEmpty else { return }

    guard let tokenData = try? JSONSerialization.data(withJSONObject: token, options: [.fragmentsAllowed]),
          let tokenJSON = String(data: tokenData, encoding: .utf8) else {
        spkPushDiag("direct_token_json_encode_error")
        return
    }

    DispatchQueue.main.async {
        guard SirPhilipKorea.webView != nil else {
            spkPushDiag("direct_token_webview_nil")
            return
        }

        if SirPhilipKorea.webView.isLoading || SirPhilipKorea.webView.isHidden {
            if retry < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    spkDeliverFCMTokenToWordPress(token, retry: retry + 1)
                }
            } else {
                spkPushDiag("direct_token_webview_not_ready")
                checkViewAndEvaluate(event: "push-token", detail: tokenJSON)
            }
            return
        }

        let js = """
        (function(){
            try {
                var token = \(tokenJSON);
                try { window.localStorage.setItem('spk_fcm_token_native', token); } catch (_) {}
                if (typeof window.SPKPushReceiveToken === 'function') {
                    return window.SPKPushReceiveToken(token) ? 'direct-ok' : 'direct-rejected';
                }
                window.dispatchEvent(new CustomEvent('push-token', {detail: token}));
                return 'cached-event-fallback';
            } catch (e) {
                return 'error:' + String(e);
            }
        })();
        """

        SirPhilipKorea.webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                spkPushDiag("direct_token_js_error", ["error": error.localizedDescription])
                if retry < 12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        spkDeliverFCMTokenToWordPress(token, retry: retry + 1)
                    }
                } else {
                    checkViewAndEvaluate(event: "push-token", detail: tokenJSON)
                }
                return
            }

            let resultText = String(describing: result ?? "")
            spkPushDiag("direct_token_js_result", ["result": resultText, "token_length": token.count])

            // If the WP bridge was not ready yet, try again briefly.
            if resultText.contains("fallback") && retry < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    spkDeliverFCMTokenToWordPress(token, retry: retry + 1)
                }
            }
        }
    }
}

// SPK Independent Native Diagnostic v1.1.0
// This diagnostic path intentionally does NOT depend on WKWebView, WordPress login,
// JS bridge, cookies, or nonce. It sends only stage/error metadata, never the FCM token.
func spkSendIndependentDiagnostic(_ stage: String, _ detail: [String: Any] = [:]) {
    guard let url = URL(string: "https://sirphilipkorea.com/wp-admin/admin-ajax.php") else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 12
    req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")

    let data = (try? JSONSerialization.data(withJSONObject: detail, options: [])) ?? Data()
    let detailText = String(data: data, encoding: .utf8) ?? "{}"
    var c = URLComponents()
    c.queryItems = [
        URLQueryItem(name: "action", value: "spk_push_native_boot_diag"),
        URLQueryItem(name: "diag_key", value: "9q66x9_VEpPgynb0HNwiZaIwkEdZQbu1"),
        URLQueryItem(name: "stage", value: stage),
        URLQueryItem(name: "detail", value: detailText)
    ]
    req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
    URLSession.shared.dataTask(with: req).resume()
}

// SPK Push Native Diagnostic v1.0.8
func spkSendNativeDiagnostic(_ stage: String, _ detail: [String: Any] = [:], retry: Int = 0) {
    DispatchQueue.main.async {
        guard SirPhilipKorea.webView != nil else { return }
        let js = "(function(){try{return window.SPKPushNativeConfig?JSON.stringify(window.SPKPushNativeConfig):'';}catch(e){return '';}})();"
        SirPhilipKorea.webView.evaluateJavaScript(js) { result, _ in
            guard let cfg=result as? String, !cfg.isEmpty,
                  let data=cfg.data(using:.utf8),
                  let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let ajax=obj["ajax"] as? String, let nonce=obj["nonce"] as? String,
                  let url=URL(string:ajax) else {
                if retry < 12 { DispatchQueue.main.asyncAfter(deadline:.now()+0.75){ spkSendNativeDiagnostic(stage,detail,retry:retry+1) } }
                return
            }
            SirPhilipKorea.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                var req=URLRequest(url:url); req.httpMethod="POST"; req.timeoutInterval=12
                req.setValue("application/x-www-form-urlencoded; charset=UTF-8",forHTTPHeaderField:"Content-Type")
                for (k,v) in HTTPCookie.requestHeaderFields(with:cookies){ req.setValue(v,forHTTPHeaderField:k) }
                let dd=(try? JSONSerialization.data(withJSONObject:detail)) ?? Data()
                let ds=String(data:dd,encoding:.utf8) ?? "{}"
                var c=URLComponents(); c.queryItems=[
                    URLQueryItem(name:"action",value:"spk_push_native_diag"),
                    URLQueryItem(name:"_ajax_nonce",value:nonce),
                    URLQueryItem(name:"stage",value:stage),
                    URLQueryItem(name:"detail",value:ds)]
                req.httpBody=c.percentEncodedQuery?.data(using:.utf8)
                URLSession.shared.dataTask(with:req).resume()
            }
        }
    }
}


// SPK Push Fix v1.0.7
// Secure native registration path:
// 1) Read WordPress AJAX URL + nonce from the authenticated WKWebView.
// 2) Copy the WKWebView login cookies.
// 3) POST the FCM token directly to admin-ajax.php.
// This does NOT depend on window.webkit.messageHandlers['push-token'].
private var spkLastNativeRegisteredToken: String = ""
private var spkNativeRegistrationInFlight = false

private func spkRegisterFCMTokenDirectly(_ token: String) {
    guard !token.isEmpty else { return }

    // v1.1.3 stability: one request only. No retry loop and no JavaScript evaluation.
    if spkNativeRegistrationInFlight || spkLastNativeRegisteredToken == token { return }
    spkNativeRegistrationInFlight = true

    guard let url = URL(string: "https://sirphilipkorea.com/wp-admin/admin-ajax.php") else {
        spkNativeRegistrationInFlight = false
        return
    }

    DispatchQueue.main.async {
        guard SirPhilipKorea.webView != nil else {
            spkNativeRegistrationInFlight = false
            return
        }

        SirPhilipKorea.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let siteCookies = cookies.filter {
                let domain = $0.domain.lowercased()
                return domain == "sirphilipkorea.com" || domain.hasSuffix(".sirphilipkorea.com")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                             forHTTPHeaderField: "Content-Type")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            for (key, value) in HTTPCookie.requestHeaderFields(with: siteCookies) {
                request.setValue(value, forHTTPHeaderField: key)
            }

            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "action", value: "spk_register_fcm_token_native"),
                URLQueryItem(name: "token", value: token)
            ]
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

            URLSession.shared.dataTask(with: request) { data, response, error in
                defer { spkNativeRegistrationInFlight = false }

                if let error = error {
                    spkSendIndependentDiagnostic("token_register_native_network_error", [
                        "error": error.localizedDescription
                    ])
                    return
                }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let stored = status == 200 &&
                             body.contains("\"success\":true") &&
                             body.contains("\"stored\":true")

                if stored {
                    spkLastNativeRegisteredToken = token
                    spkSendIndependentDiagnostic("token_register_stored", [
                        "http_status": status,
                        "token_length": token.count
                    ])
                } else {
                    // One diagnostic only; do not retry automatically.
                    spkSendIndependentDiagnostic("token_register_native_rejected", [
                        "http_status": status,
                        "response_length": body.count,
                        "cookie_count": siteCookies.count
                    ])
                }
            }.resume()
        }
    }
}

func handleFCMToken(){
    spkPushDiag("handle_fcm_token_called")
    spkSendIndependentDiagnostic("handle_fcm_token_called", ["remote_registered": UIApplication.shared.isRegisteredForRemoteNotifications])
    spkSendNativeDiagnostic("handle_fcm_token_called", ["remote_registered": UIApplication.shared.isRegisteredForRemoteNotifications])
    DispatchQueue.main.async(execute: {
        Messaging.messaging().token { token, error in
            if let error = error {
                print("Error fetching FCM registration token: \(error)")
                spkPushDiag("fcm_token_error", ["error": error.localizedDescription])
                spkSendIndependentDiagnostic("fcm_token_error", ["error": error.localizedDescription])
                spkSendNativeDiagnostic("fcm_token_error", ["error": error.localizedDescription])
                checkViewAndEvaluate(event: "push-token", detail: "ERROR GET TOKEN")
            } else if let token = token, !token.isEmpty {
                print("FCM registration token: \(token)")
                spkPushDiag("fcm_token_ready", ["token_length": token.count])
                spkSendIndependentDiagnostic("fcm_token_ready", ["token_length": token.count])
                spkSendNativeDiagnostic("fcm_token_ready", ["token_length": token.count])

                // Primary v1.0.7 path: native HTTPS POST with WKWebView login cookies.
                spkRegisterFCMTokenDirectly(token)
                spkPushDiag("native_ajax_registration_started", ["token_length": token.count])

                // Keep v1.0.6 JS/localStorage delivery only as a compatibility fallback.
                spkDeliverFCMTokenToWordPress(token)
                spkPushDiag("direct_token_delivery_started", ["token_length": token.count])
            } else {
                spkPushDiag("fcm_token_empty")
                spkSendIndependentDiagnostic("fcm_token_empty")
                spkSendNativeDiagnostic("fcm_token_empty")
                checkViewAndEvaluate(event: "push-token", detail: "ERROR EMPTY TOKEN")
            }
        }
    })
}

func sendPushToWebView(userInfo: [AnyHashable: Any]){
    var json = "";
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: userInfo)
        json = String(data: jsonData, encoding: .utf8)!
    } catch {
        print("ERROR: userInfo parsing problem")
        return
    }
    checkViewAndEvaluate(event: "push-notification", detail: json)
}

func sendPushClickToWebView(userInfo: [AnyHashable: Any]){
    var json = "";
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: userInfo)
        json = String(data: jsonData, encoding: .utf8)!
    } catch {
        print("ERROR: userInfo parsing problem")
        return
    }
    checkViewAndEvaluate(event: "push-notification-click", detail: json)
}
