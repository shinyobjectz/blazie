import Foundation
import SwiftUI

/// Where blazied is (mac.blazie.dev through Cloudflare Tunnel) and the token it wants.
/// Both are baked into Info.plist at build time by ios/build.sh.
enum Config {
    static let host = Bundle.main.object(forInfoDictionaryKey: "BlazieHost") as? String ?? "mac.blazie.dev"
    static let token = Bundle.main.object(forInfoDictionaryKey: "BlazieToken") as? String ?? ""

    static func socket(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents()
        c.scheme = "wss"
        c.host = host
        c.path = path
        c.queryItems = [URLQueryItem(name: "token", value: token)] + query.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
}

struct Tab: Identifiable, Codable, Equatable {
    enum Kind: Codable, Equatable {
        case terminal(session: String?)
        case web(url: URL, auth: Bool)
        case macApp(name: String)
    }

    var id = UUID().uuidString
    var kind: Kind
    var title: String
    var pushedID: String?  // the id blazied gave a pushed tab, so a replay doesn't open it twice

    var symbol: String {
        switch kind {
        case .terminal: "terminal"
        case .web: "globe"
        case .macApp: "macwindow"
        }
    }
}

/// The open tabs, saved across launches. Terminal tabs keep their blazied session id, so a relaunch
/// reattaches to the same shell.
@MainActor
final class TabStore: ObservableObject {
    @Published var tabs: [Tab] = [] { didSet { save() } }
    @Published var selected: String?
    private var seenPushes: Set<String> = []
    private let key = "tabs.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Tab].self, from: data), !saved.isEmpty {
            tabs = saved
            seenPushes = Set(saved.compactMap(\.pushedID))
        } else {
            tabs = [Tab(kind: .terminal(session: nil), title: "Mac mini")]
        }
        seenPushes.formUnion(UserDefaults.standard.stringArray(forKey: "seenPushes") ?? [])
        selected = tabs.first?.id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tabs) { UserDefaults.standard.set(data, forKey: key) }
    }

    func newTerminal() {
        let tab = Tab(kind: .terminal(session: nil), title: "Mac mini")
        tabs.append(tab)
        selected = tab.id
    }

    func newMacApp(_ name: String) {
        let tab = Tab(kind: .macApp(name: name), title: name)
        tabs.append(tab)
        selected = tab.id
    }

    func close(_ id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch tabs[i].kind {
        case .terminal: TerminalSessions.shared.close(id)
        case .macApp: StreamSessions.shared.close(id)
        case .web: break
        }
        tabs.remove(at: i)
        if tabs.isEmpty { newTerminal() }
        if selected == id { selected = tabs[min(i, tabs.count - 1)].id }
    }

    func setSession(_ session: String, for id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].kind != .terminal(session: session) else { return }
        tabs[i].kind = .terminal(session: session)
    }

    func setTitle(_ title: String, for id: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), !title.isEmpty, tabs[i].title != title else { return }
        tabs[i].title = title
    }

    /// A tab pushed by blazied (Claude or the blazie CLI on the Mac).
    func receive(_ push: [String: Any], select: Bool) {
        guard let pid = push["id"] as? String, !seenPushes.contains(pid) else { return }
        seenPushes.insert(pid)
        UserDefaults.standard.set(Array(seenPushes.suffix(200)), forKey: "seenPushes")
        let title = push["title"] as? String ?? "Tab"
        var tab: Tab
        if let app = push["mac_app"] as? String {
            tab = Tab(kind: .macApp(name: app), title: title)
        } else if let s = push["url"] as? String, let url = URL(string: s) {
            tab = Tab(kind: .web(url: url, auth: push["auth"] as? Bool ?? false), title: title)
        } else {
            return
        }
        tab.pushedID = pid
        tabs.append(tab)
        if select { selected = tab.id }
    }
}

/// Listens on blazied's /events socket for pushed tabs; reconnects whenever the app comes back.
@MainActor
final class EventsClient: ObservableObject {
    @Published var connected = false
    private var task: URLSessionWebSocketTask?
    private weak var store: TabStore?
    private var retry = 1.0

    func start(_ store: TabStore) {
        self.store = store
        guard task == nil else { return }
        let t = URLSession.shared.webSocketTask(with: Config.socket("/events"))
        task = t
        t.resume()
        listen(t)
    }

    func stop() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    private func listen(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(.string(let text)):
                    self.connected = true
                    self.retry = 1
                    if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                        if let tab = obj["tab"] as? [String: Any] { self.store?.receive(tab, select: true) }
                        // Replayed tabs from before this connection: only ones never seen, and don't jump to them.
                        for tab in obj["tabs"] as? [[String: Any]] ?? [] { self.store?.receive(tab, select: false) }
                    }
                    self.listen(t)
                case .success:
                    self.listen(t)
                case .failure:
                    self.connected = false
                    self.task = nil
                    let delay = self.retry
                    self.retry = min(self.retry * 2, 30)
                    try? await Task.sleep(for: .seconds(delay))
                    if let store = self.store, self.task == nil { self.start(store) }
                }
            }
        }
    }
}
