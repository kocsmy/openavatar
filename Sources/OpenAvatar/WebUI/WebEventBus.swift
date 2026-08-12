#if canImport(WebKit)
import Combine
import Foundation
import WebKit

/// Swift → JS push. The host owns the truth; instead of shipping diffs across
/// the boundary we tell every live web surface *that* something changed and it
/// refetches. One coarse signal beats a dozen fine-grained ones that can each
/// go stale on their own — and a redundant fetch over a message handler costs
/// microseconds.
@MainActor
final class WebEventBus {
    static let shared = WebEventBus()

    enum Topic: String {
        case state, transcript, meetings, followups, errors
    }

    private struct WeakView {
        weak var view: WKWebView?
    }

    private var views: [WeakView] = []
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    /// Every web surface registers itself; closed windows drop out on the next
    /// emit because the references are weak.
    func register(_ webView: WKWebView) {
        views.append(WeakView(view: webView))
        start()
    }

    /// Observe the app's own change publishers once, throttled: during a live
    /// call AppState publishes on every transcript segment.
    private func start() {
        guard !started else { return }
        started = true
        AppState.shared.objectWillChange
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { _ in
                Task { @MainActor in WebEventBus.shared.emit(.state) }
            }
            .store(in: &cancellables)
        SettingsStore.shared.objectWillChange
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { _ in
                Task { @MainActor in WebEventBus.shared.emit(.state) }
            }
            .store(in: &cancellables)
    }

    func emit(_ topic: Topic) {
        views.removeAll { $0.view == nil }
        guard !views.isEmpty else { return }
        let js = "window.__avatarEvent && window.__avatarEvent('\(topic.rawValue)')"
        for box in views {
            box.view?.evaluateJavaScript(js)
        }
    }

    /// The one case that carries data rather than a "refetch" nudge: an answer
    /// being written. Refetching can't express a token, and waiting for the
    /// whole reply is exactly what streaming exists to avoid. Keyed by a
    /// caller-supplied id so a page can tell its own stream from another
    /// window's.
    func emit(stream id: String, _ payload: [String: JSONValue]) {
        views.removeAll { $0.view == nil }
        guard !views.isEmpty else { return }
        var object = payload
        object["id"] = .string(id)
        guard let json = String(data: JSONValue.object(object).encodedData(), encoding: .utf8) else { return }
        let js = "window.__avatarStream && window.__avatarStream(\(json))"
        for box in views {
            box.view?.evaluateJavaScript(js)
        }
    }
}
#endif
