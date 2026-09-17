import SwiftUI
@preconcurrency import WebKit

/// Reports a `WKWebView`'s navigation state back to SwiftUI. Not `@Binding`:
/// `WKNavigationDelegate` callbacks arrive through `WebView.Coordinator`,
/// which isn't itself actor-isolated (WebKit calls it, not SwiftUI), so the
/// only things that can safely cross into a MainActor-isolated mutation are
/// plain `Sendable` values - a reference to this object is one (the same
/// pattern already used for `Networking/BonjourAdvertiser.swift`'s
/// `NetServiceDelegate` adoption), a `Binding` capturing arbitrary get/set
/// closures is not guaranteed to be.
@MainActor
@Observable
final class WebViewLoadState {
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    func reset() {
        isLoading = true
        errorMessage = nil
    }

    func finishedLoading() {
        isLoading = false
    }

    func failed(_ message: String) {
        isLoading = false
        errorMessage = message
    }
}

/// A minimal in-app browser for previewing the running server's own
/// endpoint without leaving iServe or typing the address into Safari. Not a
/// general-purpose browser - no address bar, no history, no bookmarks; it
/// always shows (and can only reload) exactly the URL it's given.
struct InAppBrowserSheet: View {
    let url: URL
    /// The session's own HTTP Basic Authentication password (v0.3,
    /// `docs/adr/0002-http-basic-authentication.md`), if password
    /// protection is on — `nil` otherwise. `WKWebView` never shows any
    /// native credential prompt of its own for an HTTP Basic challenge
    /// (unlike Safari), so without this the preview was just a blank
    /// page: the server's own `401`/`WWW-Authenticate` challenge had
    /// nothing responding to it. Since iServe already knows this
    /// password — it's the same session that set it — the right fix is
    /// answering the challenge automatically, not prompting the user to
    /// re-type a password they just typed into this same app.
    let password: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var loadState = WebViewLoadState()
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            ZStack {
                WebView(url: url, password: password, reloadToken: reloadToken, loadState: loadState)
                if let errorMessage = loadState.errorMessage {
                    ContentUnavailableView(
                        "Couldn't Load Page",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                }
            }
            .navigationTitle(url.host ?? "Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if loadState.isLoading {
                        ProgressView()
                    }
                    Button("Reload", systemImage: "arrow.clockwise") { reloadToken += 1 }
                    Button("Open in Safari", systemImage: "safari") { openURL(url) }
                }
            }
        }
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL
    let password: String?
    let reloadToken: Int
    let loadState: WebViewLoadState

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastReloadToken != reloadToken else { return }
        context.coordinator.lastReloadToken = reloadToken
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator(password: password, loadState: loadState) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let password: String?
        private let loadState: WebViewLoadState
        var lastReloadToken = 0

        init(password: String?, loadState: WebViewLoadState) {
            self.password = password
            self.loadState = loadState
        }

        /// Answers the server's own HTTP Basic challenge with its own
        /// known password — see `InAppBrowserSheet.password`'s doc
        /// comment for why this must happen here rather than relying on
        /// `WKWebView` to prompt. The username is never checked
        /// server-side (`ServerCredentials`), so any non-empty
        /// placeholder is fine. Bails to default handling (which fails
        /// the navigation) after a wrong-credential retry, rather than
        /// re-sending the same password forever, and for any challenge
        /// this server never issues (e.g. server trust).
        nonisolated func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
                  let password, challenge.previousFailureCount == 0 else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(user: "iserve", password: password, persistence: .forSession))
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in loadState.reset() }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in loadState.finishedLoading() }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let message = error.localizedDescription
            Task { @MainActor in loadState.failed(message) }
        }

        nonisolated func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            let message = error.localizedDescription
            Task { @MainActor in loadState.failed(message) }
        }
    }
}
