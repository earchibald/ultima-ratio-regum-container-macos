import AppKit
import SwiftUI
import WebKit

/// The game: the container's noVNC viewer page in a web view. The page posts
/// {event: "size" | "connect" | "disconnect" | "error"} messages back.
struct GameWebView: NSViewRepresentable {
    let url: URL
    let onMessage: ([String: Any]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "urr")
        let view = GameKeyWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: url))
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "urr")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onMessage: ([String: Any]) -> Void
        init(onMessage: @escaping ([String: Any]) -> Void) { self.onMessage = onMessage }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { onMessage(body) }
        }
    }
}

/// Keeps keyboard focus on the game and stops the web view beeping at keys
/// it doesn't handle itself.
final class GameKeyWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

/// The developer's blog (the URR Blog Reader page, bundled). Links open in
/// the default browser.
struct NewsWebView: NSViewRepresentable {
    let page: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, url.scheme == "https" || url.scheme == "http",
               action.navigationType == .linkActivated || action.targetFrame == nil {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// Gives SwiftUI code access to its hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
    }
}
