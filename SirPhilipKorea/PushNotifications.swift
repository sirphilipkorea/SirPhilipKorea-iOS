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

// SPK Push Fix v1.0.6
// Deliver the FCM token directly to the WordPress bridge function.
// The old `push-token` CustomEvent remains as a fallback for compatibility.
private func spkDeliverFCMTokenToWordPress(_ token: String, retry: Int = 0) {
    guard !token.isEmpty else { return }

    guard let tokenData = try? JSONSerialization.data(withJSONObject: token, options: [.fragmentsAllowed]),
          let tokenJSON = String(data: tokenData, encoding: .utf8) else {
        return
    }

    DispatchQueue.main.async {
        guard SirPhilipKorea.webView != nil else {
            return
        }

        if SirPhilipKorea.webView.isLoading || SirPhilipKorea.webView.isHidden {
            if retry < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    spkDeliverFCMTokenToWordPress(token, retry: retry + 1)
                }
            } else {
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

            // If the WP bridge was not ready yet, try again briefly.
            if resultText.contains("fallback") && retry < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    spkDeliverFCMTokenToWordPress(token, retry: retry + 1)
                }
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
            request.timeoutInterval = 6
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                             forHTTPHeaderField: "Content-Type")
            for (key, value) in HTTPCookie.requestHeaderFields(with: siteCookies) {
                request.setValue(value, forHTTPHeaderField: key)
            }

            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "action", value: "spk_register_fcm_token_native"),
                URLQueryItem(name: "token", value: token)
            ]
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

            URLSession.shared.dataTask(with: request) { data, response, _ in
                defer { spkNativeRegistrationInFlight = false }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if status == 200 && body.contains("\"success\":true") && body.contains("\"stored\":true") {
                    spkLastNativeRegisteredToken = token
                }
            }.resume()
        }
    }
}

func handleFCMToken(){
    Messaging.messaging().token { token, error in
        if let error = error {
            print("Error fetching FCM registration token: \(error)")
            return
        }
        guard let token = token, !token.isEmpty else {
            print("FCM registration token is empty")
            return
        }
        print("FCM registration token ready")
        spkRegisterFCMTokenDirectly(token)
    }
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

// SPK Push Deep Link v1.0
// Keep push navigation native and generic. WordPress may change the destination
// path later without another App Store build, as long as the URL remains on the
// sirphilipkorea.com HTTPS origin.
private let spkPendingPushURLKey = "spk_pending_push_url_v1"

private func spkPushTargetURL(from userInfo: [AnyHashable: Any]) -> URL? {
    var raw: String? = userInfo["url"] as? String

    // Be tolerant of providers that wrap custom fields in a data dictionary.
    if (raw == nil || raw?.isEmpty == true),
       let data = userInfo["data"] as? [String: Any] {
        raw = data["url"] as? String
    }

    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty,
          let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          let host = url.host?.lowercased(),
          scheme == "https",
          host == "sirphilipkorea.com" || host.hasSuffix(".sirphilipkorea.com") else {
        return nil
    }
    return url
}

func spkConsumePendingPushTargetIfPossible() {
    DispatchQueue.main.async {
        guard SirPhilipKorea.webView != nil,
              !SirPhilipKorea.webView.isLoading else { return }
        guard let raw = UserDefaults.standard.string(forKey: spkPendingPushURLKey),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "https",
              host == "sirphilipkorea.com" || host.hasSuffix(".sirphilipkorea.com") else {
            UserDefaults.standard.removeObject(forKey: spkPendingPushURLKey)
            return
        }

        UserDefaults.standard.removeObject(forKey: spkPendingPushURLKey)
        SirPhilipKorea.webView.load(
            URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        )
    }
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

    // Preserve the existing web CustomEvent for backward compatibility.
    checkViewAndEvaluate(event: "push-notification-click", detail: json)

    // Also handle the URL natively. If the app was cold-started and WKWebView
    // is not ready yet, ViewController.didFinish will consume the saved URL.
    if let target = spkPushTargetURL(from: userInfo) {
        UserDefaults.standard.set(target.absoluteString, forKey: spkPendingPushURLKey)
        spkConsumePendingPushTargetIfPossible()
    }
}
