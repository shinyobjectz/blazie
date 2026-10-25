import SwiftUI
import WebKit

/// A web page on the Mac (a localhost dev server shared through mac-PORT.blazie.dev) or anywhere.
struct WebTabView: UIViewRepresentable {
    let url: URL
    let auth: Bool

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak web, weak refresh] _ in
            web?.reload()
            refresh?.endRefreshing()
        }, for: .valueChanged)
        web.scrollView.refreshControl = refresh
        web.load(URLRequest(url: auth ? signIn(url) : url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    /// blazied sets its preview cookie at /__blazie/auth and redirects to the page.
    private func signIn(_ url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let next = c.path.isEmpty ? "/" : c.path + (c.query.map { "?" + $0 } ?? "")
        c.path = "/__blazie/auth"
        c.queryItems = [URLQueryItem(name: "t", value: Config.token), URLQueryItem(name: "next", value: next)]
        return c.url!
    }
}
