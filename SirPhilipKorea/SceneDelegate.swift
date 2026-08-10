import UIKit

@available(iOS 13.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    // If our app is launched with a universal link, we'll store it in this variable
    static var universalLinkToLaunch: URL? = nil; 
    static var shortcutLinkToLaunch: URL? = nil


    // SPK v7.0 TEST helper: custom payment return callback.
    private func spkWebURL(from schemeURL: URL) -> URL? {
        guard schemeURL.scheme?.lowercased() == "sirphilipkorea" else { return nil }
        let c = URLComponents(url: schemeURL, resolvingAgainstBaseURL: false)
        if (c?.host ?? "").lowercased() == "payment-complete" {
            if let raw = c?.queryItems?.first(where: { $0.name == "url" })?.value,
               let u = URL(string: raw), let h = u.host?.lowercased(),
               ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
               h == "sirphilipkorea.com" || h.hasSuffix(".sirphilipkorea.com") { return u }
            // v7.1: payment-complete is a deep-link signal, not a payment page.
            // Open WooCommerce Orders directly inside the app WebView.
            // This preserves the app's WKWebView login cookies/session.
            var t = URLComponents(url: rootUrl, resolvingAgainstBaseURL: false)
            t?.path = "/my-account/orders/"
            t?.query = nil
            t?.fragment = nil
            return t?.url
        }
        var legacy = c; legacy?.scheme = "https"; return legacy?.url
    }

    // This function is called when your app launches.
    // Check to see if we were launched via a universal link or a shortcut.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // See if our app is being launched via universal link.
        // If so, store that link so we can navigate to it once our webView is initialized.
        for userActivity in connectionOptions.userActivities {
            if let universalLink = userActivity.webpageURL {
                SceneDelegate.universalLinkToLaunch = universalLink;
                break
            }
        }

        // See if we were launched via shortcut
        if let shortcutUrl = connectionOptions.shortcutItem?.type {            
            SceneDelegate.shortcutLinkToLaunch = URL.init(string: shortcutUrl)
        }
        
        // See if we were launched via scheme URL
        if let schemeUrl = connectionOptions.urlContexts.first?.url {
            if let url = spkWebURL(from: schemeUrl) {
                SceneDelegate.universalLinkToLaunch = url;
            }
        }
    }
    
    // This function is called when our app is already running and the user clicks a custom scheme URL
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let scheme = URLContexts.first?.url {
            if let url = spkWebURL(from: scheme) {
                // Handle it inside our web view in a SPA-friendly way.
                SirPhilipKorea.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            }
        }
    }

    // This function is called when our app is already running and the user clicks a universal link.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        // Handle universal links into our app when the app is already running.
        // This allows your PWA to open links to your domain, rather than opening in a browser tab.
        // For more info about universal links, see https://developer.apple.com/documentation/xcode/supporting-universal-links-in-your-app
        
        // Ensure we're trying to launch a link.
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
            let universalLink = userActivity.webpageURL else {
            return
        }

        // Handle it inside our web view in a SPA-friendly way.
        SirPhilipKorea.webView.evaluateJavaScript("location.href = '\(universalLink)'")
    }

    // This function is called if our app is already loaded and the user activates the app via shortcut
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        if let shortcutUrl = URL.init(string: shortcutItem.type) {
            SirPhilipKorea.webView.evaluateJavaScript("location.href = '\(shortcutUrl)'");
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not neccessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }


}

