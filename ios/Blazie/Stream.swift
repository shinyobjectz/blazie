import AVFoundation
import SwiftUI
import UIKit
import VideoToolbox

/// One Mac app window, streamed by BlazieStream on the Mac (H.264 over wss://mac.blazie.dev/stream)
/// and shown with the hardware decoder. Taps, drags, scrolls and hardware-keyboard presses go back
/// and are replayed on that window.
final class StreamSession: NSObject {
    let app: String
    let view = StreamView()
    var onTitle: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private var retry = 0.5
    private var closed = false

    init(app: String) {
        self.app = app
        super.init()
        view.session = self
        connect()
    }

    func connect() {
        guard task == nil, !closed else { return }
        let t = URLSession.shared.webSocketTask(with: Config.socket("/stream"))
        t.maximumMessageSize = 32 * 1024 * 1024
        task = t
        t.resume()
        waitingForKeyframe = true
        receive(t)
        if view.bounds.width > 0 { sendStart() }  // otherwise the first layout sends it
    }

    func close() {
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private var sentSize = CGSize.zero
    private var started = false

    /// The Mac puts the window on a virtual Retina display this size (points) and fills it.
    private func sendStart() {
        guard let task, task.state == .running || task.state == .suspended else { return }
        sentSize = view.bounds.size
        started = true
        send(["start": ["app": app, "view": ["w": Double(sentSize.width), "h": Double(sentSize.height)]]])
    }

    func viewResized() {
        let size = view.bounds.size
        guard size.width > 200, size.height > 200 else { return }
        if !started { sendStart(); return }
        guard abs(size.width - sentSize.width) > 4 || abs(size.height - sentSize.height) > 4 else { return }
        sentSize = size
        send(["view": ["w": Double(size.width), "h": Double(size.height)]])
    }

    func send(_ obj: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.task === t else { return }
                switch result {
                case .success(.data(let data)):
                    self.handle(data)
                    self.receive(t)
                case .success(.string(let text)):
                    if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                        if let w = obj["window"] as? [String: Any] {
                            self.retry = 0.5
                            self.view.message = nil
                            self.view.videoSize = CGSize(width: w["w"] as? Double ?? 1, height: w["h"] as? Double ?? 1)
                            if let title = w["title"] as? String, !title.isEmpty { self.onTitle?(title) }
                        }
                        if let e = obj["error"] as? String { self.view.message = e }
                    }
                    self.receive(t)
                case .success:
                    self.receive(t)
                case .failure:
                    self.task = nil
                    self.started = false
                    guard !self.closed else { return }
                    self.view.message = "Reconnecting…"
                    let delay = self.retry
                    self.retry = min(self.retry * 2, 10)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.connect() }
                }
            }
        }
    }

    /// [1][0][u16][SPS][u16][PPS] parameter sets, or [2][key][AVCC frame].
    private func handle(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 2 else { return }
        if bytes[0] == 1 {
            var sets: [[UInt8]] = []
            var i = 2
            while i + 2 <= bytes.count {
                let len = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                i += 2
                guard i + len <= bytes.count else { break }
                sets.append(Array(bytes[i..<i + len]))
                i += len
            }
            guard sets.count == 2 else { return }
            var fmt: CMVideoFormatDescription?
            sets[0].withUnsafeBufferPointer { sps in
                sets[1].withUnsafeBufferPointer { pps in
                    let ptrs = [sps.baseAddress!, pps.baseAddress!]
                    let sizes = [sps.count, pps.count]
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                        parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
                }
            }
            format = fmt
            return
        }
        let key = bytes[1] == 1
        if waitingForKeyframe && !key { return }
        guard let format else { return }
        waitingForKeyframe = false
        let payload = data.subdata(in: 2..<data.count)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: payload.count, flags: 0, blockBufferOut: &block)
        guard let block else { return }
        payload.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                              dataLength: payload.count)
        }
        var sample: CMSampleBuffer?
        var size = payload.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = view.display.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            waitingForKeyframe = true
            send(["keyframe": true])
            return
        }
        renderer.enqueue(sample)
    }
}

/// The video plus input. Coordinates go to the Mac normalized to the window (0...1).
final class StreamView: UIView {
    weak var session: StreamSession?
    let display = AVSampleBufferDisplayLayer()
    private let label = UILabel()
    private var dragging = false
    private var lastTap: (time: TimeInterval, point: CGPoint, clicks: Int) = (0, .zero, 0)
    private var lastScroll = CGPoint.zero
    private var lastHover: TimeInterval = 0

    var videoSize = CGSize(width: 16, height: 9)
    var message: String? {
        didSet {
            label.text = message
            label.isHidden = message == nil
        }
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0.07, green: 0.06, blue: 0.06, alpha: 1)
        display.videoGravity = .resizeAspect
        layer.addSublayer(display)
        label.textColor = UIColor(white: 0.8, alpha: 1)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "Connecting…"
        addSubview(label)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        long.minimumPressDuration = 0.5
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        drag.maximumNumberOfTouches = 1
        drag.allowedScrollTypesMask = []
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        scroll.minimumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all  // trackpad and mouse-wheel scrolling too
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered))
        [tap, long, drag, scroll, hover].forEach(addGestureRecognizer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.frame = bounds
        CATransaction.commit()
        label.frame = bounds.insetBy(dx: 40, dy: 40)
        session?.viewResized()
    }

    private var videoRect: CGRect { AVMakeRect(aspectRatio: videoSize, insideRect: bounds) }

    private func normalized(_ p: CGPoint) -> [String: Double]? {
        let r = videoRect
        guard r.width > 0, r.contains(p) else { return nil }
        return ["x": Double((p.x - r.minX) / r.width), "y": Double((p.y - r.minY) / r.height)]
    }

    private func mouse(_ type: String, _ p: CGPoint, button: Int = 0, clicks: Int = 1) {
        guard var e = normalized(p) as [String: Any]? else { return }
        e["type"] = type
        e["button"] = button
        e["clicks"] = clicks
        session?.send(["mouse": e])
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        let now = Date.timeIntervalSinceReferenceDate
        let near = hypot(p.x - lastTap.point.x, p.y - lastTap.point.y) < 12
        let clicks = (now - lastTap.time < 0.35 && near) ? min(lastTap.clicks + 1, 3) : 1
        lastTap = (now, p, clicks)
        mouse("down", p, clicks: clicks)
        mouse("up", p, clicks: clicks)
        _ = becomeFirstResponder()
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: self)
        mouse("down", p, button: 1)
        mouse("up", p, button: 1)
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            dragging = true
            mouse("down", p)
        case .changed:
            mouse("drag", p)
        default:
            if dragging { mouse("up", p) }
            dragging = false
        }
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        if g.state == .began { lastScroll = .zero }
        let dx = t.x - lastScroll.x, dy = t.y - lastScroll.y
        lastScroll = t
        guard var e = normalized(g.location(in: self)) as [String: Any]? else { return }
        e["dx"] = Double(dx)
        e["dy"] = Double(dy)
        session?.send(["scroll": e])
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastHover > 1.0 / 30 else { return }
        lastHover = now
        mouse("move", g.location(in: self))
    }

    // MARK: hardware keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !sendKeys(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !sendKeys(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    private func sendKeys(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key, let code = MacKeys.code(for: key.keyCode) else { continue }
            var flags: [String] = []
            if key.modifierFlags.contains(.command) { flags.append("cmd") }
            if key.modifierFlags.contains(.shift) { flags.append("shift") }
            if key.modifierFlags.contains(.alternate) { flags.append("alt") }
            if key.modifierFlags.contains(.control) { flags.append("ctrl") }
            session?.send(["key": ["code": code, "down": down, "flags": flags]])
            handled = true
        }
        return handled
    }
}

/// iPad hardware-keyboard HID usages to macOS virtual key codes.
enum MacKeys {
    static func code(for usage: UIKeyboardHIDUsage) -> Int? { table[usage.rawValue] }

    private static let table: [Int: Int] = {
        var t: [Int: Int] = [:]
        let letters: [Character: Int] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
                                         "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31,
                                         "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
        for (i, ch) in "abcdefghijklmnopqrstuvwxyz".enumerated() { t[4 + i] = letters[ch] }
        let digits = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]  // 1 2 3 4 5 6 7 8 9 0
        for (i, c) in digits.enumerated() { t[30 + i] = c }
        let rest: [Int: Int] = [
            40: 36, 41: 53, 42: 51, 43: 48, 44: 49, 45: 27, 46: 24, 47: 33, 48: 30, 49: 42, 51: 41, 52: 39,
            53: 50, 54: 43, 55: 47, 56: 44, 57: 57,
            58: 122, 59: 120, 60: 99, 61: 118, 62: 96, 63: 97, 64: 98, 65: 100, 66: 101, 67: 109, 68: 103, 69: 111,
            74: 115, 75: 116, 76: 117, 77: 119, 78: 121, 79: 124, 80: 123, 81: 125, 82: 126,
        ]
        t.merge(rest) { $1 }
        return t
    }()
}

/// Streams live as long as their tab.
@MainActor
final class StreamSessions {
    static let shared = StreamSessions()
    private var sessions: [String: StreamSession] = [:]

    func session(for tab: Tab, app: String, store: TabStore) -> StreamSession {
        if let s = sessions[tab.id] { return s }
        let s = StreamSession(app: app)
        s.onTitle = { [weak store] title in store?.setTitle(title, for: tab.id) }
        sessions[tab.id] = s
        return s
    }

    func close(_ id: String) { sessions.removeValue(forKey: id)?.close() }
    func reconnectAll() { sessions.values.forEach { $0.connect() } }
    func session(_ id: String) -> StreamSession? { sessions[id] }
}

struct MacAppTabView: View {
    let tab: Tab
    let name: String
    let active: Bool

    var body: some View {
        StreamRepresentable(tab: tab, name: name, active: active)
    }
}

private struct StreamRepresentable: UIViewRepresentable {
    let tab: Tab
    let name: String
    let active: Bool
    @EnvironmentObject var store: TabStore

    func makeUIView(context: Context) -> StreamView {
        StreamSessions.shared.session(for: tab, app: name, store: store).view
    }

    func updateUIView(_ view: StreamView, context: Context) {
        DispatchQueue.main.async {
            if active, !view.isFirstResponder { _ = view.becomeFirstResponder() }
        }
    }
}
