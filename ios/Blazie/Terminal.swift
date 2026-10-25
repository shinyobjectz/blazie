import SwiftTerm
import SwiftUI
import UIKit

/// One shell on the Mac: a SwiftTerm view wired to blazied's /pty socket. It reconnects on its own
/// (network change, iPad sleep, tunnel blip) and reattaches to the same session, which replays
/// recent output, so nothing running on the Mac is lost.
final class TerminalSession: NSObject, TerminalViewDelegate {
    let view: TerminalView
    var onSession: ((String) -> Void)?
    var onTitle: ((String) -> Void)?
    var onState: ((Bool) -> Void)?

    private var session: String?
    private var task: URLSessionWebSocketTask?
    private var retry = 0.5
    private var closed = false
    private var cols = 100, rows = 30

    init(session: String?) {
        self.session = session
        view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular))
        super.init()
        view.terminalDelegate = self
        view.nativeBackgroundColor = UIColor(red: 0.07, green: 0.06, blue: 0.06, alpha: 1)
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.caretColor = UIColor(red: 1, green: 0.55, blue: 0.2, alpha: 1)
        view.optionAsMetaKey = true
        // Hardware keyboard first: no SwiftTerm shortcut bar, no on-screen function-key panel, and no
        // iPadOS shortcut/predictive bar along the bottom.
        view.inputAccessoryView = nil
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        // Taps stay local (focus, selection); only scrolls go to the program, and only as chosen in
        // Settings. tmux runs with mouse on, so wheel scrolls reach the app or open tmux history.
        view.allowMouseReporting = false
        applyKeyboardSetting()
        setUpScrolling()
        connect()
    }

    // MARK: scrolling

    private lazy var touchScroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
    private lazy var pointerScroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
    private var scrollRemainder: CGFloat = 0

    private func setUpScrolling() {
        touchScroll.maximumNumberOfTouches = 1
        touchScroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pointerScroll.allowedScrollTypesMask = .all
        pointerScroll.allowedTouchTypes = []
        for g in [touchScroll, pointerScroll] {
            g.delegate = self
            view.addGestureRecognizer(g)
        }
        // A trackpad or mouse wheel goes to the app first; when that's off it scrolls locally.
        view.panGestureRecognizer.require(toFail: pointerScroll)
        applyScrollSettings()
    }

    func applyScrollSettings() {
        let touchToApp = Settings.Scroll.current(Settings.touchScrollKey) == .app
        touchScroll.isEnabled = touchToApp
        // One finger goes to the app, so two fingers scroll Blazie's scrollback.
        view.panGestureRecognizer.minimumNumberOfTouches = touchToApp ? 2 : 1
        pointerScroll.isEnabled = Settings.Scroll.current(Settings.mouseScrollKey) == .app
    }

    /// Turns drag distance into wheel clicks (SGR mouse reports, which tmux asks for), one per text line.
    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            let cell = max(view.bounds.height / CGFloat(max(rows, 1)), 1)
            scrollRemainder += g.translation(in: view).y
            g.setTranslation(.zero, in: view)
            let lines = Int(scrollRemainder / cell)
            guard lines != 0 else { return }
            scrollRemainder -= CGFloat(lines) * cell
            let p = g.location(in: view)
            let col = min(max(Int(p.x / max(view.bounds.width / CGFloat(max(cols, 1)), 1)) + 1, 1), cols)
            let row = min(max(Int((p.y - view.contentOffset.y) / cell) + 1, 1), rows)
            // Content follows the finger: dragging down shows earlier lines, i.e. wheel up (64).
            let button = lines > 0 ? 64 : 65
            let report = "\u{1b}[<\(button);\(col);\(row)M"
            task?.send(.data(Data(String(repeating: report, count: min(abs(lines), 20)).utf8))) { _ in }
        default:
            scrollRemainder = 0
        }
    }

    /// "Off" swaps the on-screen keyboard for an empty view, so it never appears. "Automatic" leaves
    /// it to iPadOS, which already hides it while a hardware keyboard is connected.
    func applyKeyboardSetting() {
        let off = UserDefaults.standard.string(forKey: Settings.keyboardKey) == Settings.Keyboard.off.rawValue
        view.inputView = off ? UIView(frame: .zero) : nil
        if view.isFirstResponder { view.reloadInputViews() }
    }

    func connect() {
        guard task == nil, !closed else { return }
        var query = ["cols": String(cols), "rows": String(rows)]
        if let session { query["session"] = session }
        let t = URLSession.shared.webSocketTask(with: Config.socket("/pty", query))
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()
        receive(t)
    }

    func close() {
        closed = true
        task?.send(.string(#"{"close":true}"#)) { _ in }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.task === t else { return }
                switch result {
                case .success(.data(let data)):
                    self.view.feed(byteArray: ArraySlice([UInt8](data)))
                    self.receive(t)
                case .success(.string(let text)):
                    if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                       let sid = obj["session"] as? String {
                        if sid != self.session {
                            self.session = sid
                            self.onSession?(sid)
                        } else {
                            // Reattached: blazied replays the scrollback, so start from a clean screen.
                            self.view.feed(text: "\u{1b}c")  // RIS: full reset
                        }
                        self.retry = 0.5
                        self.onState?(true)
                        self.sendResize()
                    }
                    self.receive(t)
                case .success:
                    self.receive(t)
                case .failure:
                    self.task = nil
                    self.onState?(false)
                    guard !self.closed else { return }
                    let delay = self.retry
                    self.retry = min(self.retry * 2, 10)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.connect() }
                }
            }
        }
    }

    private func sendResize() {
        task?.send(.string(#"{"resize":[\#(cols),\#(rows)]}"#)) { _ in }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        task?.send(.data(Data(data))) { _ in }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        cols = newCols
        rows = newRows
        sendResize()
    }

    func setTerminalTitle(source: TerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }
    func clipboardRead(source: TerminalView) -> Data? { UIPasteboard.general.string?.data(using: .utf8) }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

extension TerminalSession: UIGestureRecognizerDelegate {
    // The two-finger scrollback pan and selection keep working alongside the one-finger app scroll.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === touchScroll && other !== view.panGestureRecognizer
    }
}

/// Sessions live as long as their tab, not their SwiftUI view, so switching tabs keeps the shell.
@MainActor
final class TerminalSessions {
    static let shared = TerminalSessions()
    private var sessions: [String: TerminalSession] = [:]

    func session(for tab: Tab, store: TabStore) -> TerminalSession {
        if let s = sessions[tab.id] { return s }
        guard case .terminal(let sid) = tab.kind else { fatalError("not a terminal tab") }
        let s = TerminalSession(session: sid)
        s.onSession = { [weak store] sid in store?.setSession(sid, for: tab.id) }
        s.onTitle = { [weak store] title in store?.setTitle(title, for: tab.id) }
        sessions[tab.id] = s
        return s
    }

    func close(_ id: String) {
        sessions.removeValue(forKey: id)?.close()
    }

    func reconnectAll() {
        sessions.values.forEach { $0.connect() }
    }

    func applyKeyboardSetting() {
        sessions.values.forEach { $0.applyKeyboardSetting() }
    }

    func applyScrollSettings() {
        sessions.values.forEach { $0.applyScrollSettings() }
    }
}

struct TerminalTabView: UIViewRepresentable {
    let tab: Tab
    let active: Bool
    @EnvironmentObject var store: TabStore

    func makeUIView(context: Context) -> TerminalView {
        TerminalSessions.shared.session(for: tab, store: store).view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        DispatchQueue.main.async {
            if active, !view.isFirstResponder {
                _ = view.becomeFirstResponder()
            } else if !active, view.isFirstResponder {
                _ = view.resignFirstResponder()
            }
        }
    }
}
