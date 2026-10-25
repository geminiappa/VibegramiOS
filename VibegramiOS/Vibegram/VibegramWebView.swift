import SwiftUI
import WebKit
import SafariServices
import UIKit

struct VibegramWebView: UIViewRepresentable {
    let url: URL
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool
    @Binding var hasLoaded: Bool
    @Binding var hasError: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.backgroundColor = UIColor(red: 0.035, green: 0.045, blue: 0.085, alpha: 1)
        view.isOpaque = false
        view.scrollView.backgroundColor = view.backgroundColor
        view.scrollView.contentInsetAdjustmentBehavior = .automatic
        view.scrollView.alwaysBounceVertical = true
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator

        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(red: 0.55, green: 0.48, blue: 1, alpha: 1)
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.refreshPage(_:)), for: .valueChanged)
        view.scrollView.refreshControl = refresh

        context.coordinator.webView = view
        DispatchQueue.main.async {
            self.webView = view
        }
        view.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The WKWebView owns navigation state. Avoid reloading on ordinary SwiftUI redraws.
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: VibegramWebView
        weak var webView: WKWebView?

        init(parent: VibegramWebView) {
            self.parent = parent
        }

        @objc func refreshPage(_ sender: UIRefreshControl) {
            webView?.reload()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.hasError = false
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.hasLoaded = true
                self.parent.hasError = false
                webView.scrollView.refreshControl?.endRefreshing()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishWithError(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finishWithError(webView)
        }

        private func finishWithError(_ webView: WKWebView) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.hasError = true
                webView.scrollView.refreshControl?.endRefreshing()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let targetURL = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            let scheme = (targetURL.scheme ?? "").lowercased()
            let mainHost = (parent.url.host ?? "").lowercased()
            let targetHost = (targetURL.host ?? "").lowercased()

            if ["mailto", "tel", "sms"].contains(scheme) {
                UIApplication.shared.open(targetURL)
                decisionHandler(.cancel)
                return
            }

            if scheme == "https" && targetHost == mainHost {
                decisionHandler(.allow)
                return
            }

            if scheme == "https" && targetHost != mainHost {
                UIApplication.shared.open(targetURL)
                decisionHandler(.cancel)
                return
            }

            if scheme == "about" || scheme == "data" {
                decisionHandler(.allow)
                return
            }

            if scheme == "http" {
                // Upgrade a same-site HTTP URL to HTTPS rather than loading insecure content.
                if targetHost == mainHost, var components = URLComponents(url: targetURL, resolvingAgainstBaseURL: false) {
                    components.scheme = "https"
                    if let secureURL = components.url {
                        webView.load(URLRequest(url: secureURL))
                    }
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
            let mainHost = (parent.url.host ?? "").lowercased()
            if url.scheme?.lowercased() == "https", url.host?.lowercased() == mainHost {
                webView.load(URLRequest(url: url))
            } else {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(red: 0.55, green: 0.48, blue: 1, alpha: 1)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
