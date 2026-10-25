// BlazieStream: streams one Mac app window to the Blazie iPad app and replays the iPad's input on it.
//
// A WebSocket server on 127.0.0.1:7778 (blazied proxies wss://mac.blazie.dev/stream to it, after
// checking the token). Per connection:
//   client -> {"start": {"app": "Figma", "view": {"w": 1366, "h": 974}}}  pick the app's main window, put it
//             on a virtual Retina display the size of the tab, start streaming
//             {"mouse": {"type": "down|up|move|drag", "x": 0..1, "y": 0..1, "button": 0|1, "clicks": 1}}
//             {"scroll": {"x": .., "y": .., "dx": px, "dy": px}}
//             {"key": {"code": macKeyCode, "down": true, "flags": ["cmd", "shift", "alt", "ctrl"]}}
//             {"view": {"w": points, "h": points}}           the iPad tab's size (sent with start, and on resize)
//             {"keyframe": true}
//   server -> {"window": {"title": .., "w": px, "h": px}} or {"error": ".."}
//             binary [1][0][u16 len][SPS][u16 len][PPS]      H.264 parameter sets
//             binary [2][1 if keyframe][AVCC frame]          H.264 frame, 4-byte length-prefixed NALs
//
// Needs Screen Recording (ScreenCaptureKit) and Accessibility (CGEvent, window resize) for this app.

import AppKit
import ApplicationServices
import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import VideoToolbox

let port: NWEndpoint.Port = 7778
func log(_ s: String) { FileHandle.standardError.write(("[stream] " + s + "\n").data(using: .utf8)!) }

// MARK: - connection

final class Client: NSObject, SCStreamOutput, SCStreamDelegate {
    let conn: NWConnection
    let queue = DispatchQueue(label: "blazie.stream.client")
    var stream: SCStream?
    var window: SCWindow?
    var app: NSRunningApplication?
    var encoder: VTCompressionSession?
    var size = CGSize.zero
    var viewSize = CGSize.zero  // the iPad tab, in points
    var onRetina = false
    var forceKeyframe = true
    var lastBuffer: CVPixelBuffer?
    var inflight = 0
    var frameTimer: DispatchSourceTimer?

    init(_ conn: NWConnection) {
        self.conn = conn
        super.init()
    }

    func start() {
        conn.start(queue: queue)
        receive()
    }

    func stop() {
        if onRetina {
            onRetina = false
            Retina.shared.release()
        }
        frameTimer?.cancel()
        frameTimer = nil
        stream?.stopCapture { _ in }
        stream = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
    }

    private func receive() {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { self.conn.cancel(); return }
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.handle(obj)
            }
            self.receive()
        }
    }

    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        conn.send(content: data, contentContext: .init(identifier: "t", metadata: [meta]), isComplete: true,
                  completion: .contentProcessed { _ in })
    }

    func send(binary: Data) {
        inflight += 1
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        conn.send(content: binary, contentContext: .init(identifier: "b", metadata: [meta]), isComplete: true,
                  completion: .contentProcessed { [weak self] _ in self?.queue.async { self?.inflight -= 1 } })
    }

    // MARK: messages

    func handle(_ m: [String: Any]) {
        if let s = m["start"] as? [String: Any], let name = s["app"] as? String {
            viewSize = Client.size(s["view"])
            Task { await self.begin(app: name) }
        } else if let e = m["mouse"] as? [String: Any] {
            mouse(e)
        } else if let e = m["scroll"] as? [String: Any] {
            scroll(e)
        } else if let e = m["key"] as? [String: Any] {
            key(e)
        } else if m["view"] != nil || m["fit"] != nil {
            viewSize = Client.size(m["view"] ?? m["fit"])
            Task { await self.placeOnRetina() }
        } else if m["keyframe"] != nil {
            requestKeyframe()
        }
    }

    static func size(_ any: Any?) -> CGSize {
        let d = any as? [String: Any] ?? [:]
        return CGSize(width: d["w"] as? Double ?? 0, height: d["h"] as? Double ?? 0)
    }

    func requestKeyframe() {
        forceKeyframe = true
        if let lastBuffer { encode(lastBuffer) }  // the window may be idle: re-send what it shows now
    }

    // MARK: capture

    func begin(app name: String) async {
        stop()
        do {
            let running = try await runningApp(name)
            app = running
            guard let win = try await mainWindow(of: running) else {
                send(json: ["error": "\(name) has no window on screen. Open one on the Mac, then reopen this tab."])
                return
            }
            window = win
            await placeOnRetina()
            if let moved = try await mainWindow(of: running) { window = moved }
            try await capture(window!)
            watchWindow()
        } catch {
            send(json: ["error": "\(error.localizedDescription)"])
            log("start \(name): \(error)")
        }
    }

    func runningApp(_ name: String) async throws -> NSRunningApplication {
        func find() -> NSRunningApplication? {
            NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame || $0.bundleIdentifier == name
            }
        }
        if let a = find() { return a }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", name]
        try open.run()
        open.waitUntilExit()
        for _ in 0..<40 {
            if let a = find() { return a }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NSError(domain: "blazie", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't find or open \(name) on the Mac."])
    }

    func mainWindow(of app: NSRunningApplication) async throws -> SCWindow? {
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let wins = content.windows.filter {
                $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0
                    && $0.frame.width > 80 && $0.frame.height > 80
            }
            if let best = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return best
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    func pixelSize(for frame: CGRect) -> CGSize {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &display, &count)
        var scale = 1.0
        if count > 0, let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 {
            scale = Double(mode.pixelWidth) / Double(mode.width)
        }
        var w = frame.width * scale, h = frame.height * scale
        let cap = 4096.0  // H.264 level 5.2
        if w > cap { h *= cap / w; w = cap }
        if h > cap { w *= cap / h; h = cap }
        return CGSize(width: Int(w) & ~1, height: Int(h) & ~1)
    }

    func capture(_ win: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        size = pixelSize(for: win.frame)
        cfg.width = Int(size.width)
        cfg.height = Int(size.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 4
        cfg.ignoreShadowsSingleWindow = true
        makeEncoder()
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        send(json: ["window": ["title": win.title ?? app?.localizedName ?? "", "w": size.width, "h": size.height,
                               "app": app?.localizedName ?? ""]])
        log("streaming \(app?.localizedName ?? "?") \(Int(size.width))x\(Int(size.height))")
    }

    /// Follow the window when it is resized (new stream size) or closed (pick the next one).
    func watchWindow() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, let win = self.window, let app = self.app else { return }
            Task {
                let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let now = content?.windows.first { $0.windowID == win.windowID }
                if now == nil {
                    if let next = try? await self.mainWindow(of: app) {
                        self.window = next
                        self.stream?.stopCapture { _ in }
                        try? await self.capture(next)
                    }
                } else if let now, self.pixelSize(for: now.frame) != self.size {
                    self.window = now
                    self.stream?.stopCapture { _ in }
                    try? await self.capture(now)
                } else if let now {
                    self.window = now
                }
            }
        }
        t.resume()
        frameTimer = t
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error)")
        send(json: ["error": "Capture stopped: \(error.localizedDescription)"])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastBuffer = pb
        encode(pb)
    }

    // MARK: encode

    func makeEncoder() {
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
                                   codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                   imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { log("no encoder"); return }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: 20_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 5,
        ]
        for (k, v) in props { VTSessionSetProperty(session, key: k, value: v as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
        forceKeyframe = true
    }

    func encode(_ pb: CVPixelBuffer) {
        guard let encoder else { return }
        if inflight > 8 {  // the network is behind: drop this frame and resync on a keyframe
            forceKeyframe = true
            return
        }
        let opts: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: opts, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.queue.async { self.emit(sb) }
        }
    }

    func emit(_ sb: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if key, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var config = Data([1, 0])
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var len = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                   parameterSetSizeOut: &len, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                guard let ptr else { return }
                config.append(UInt8(len >> 8))
                config.append(UInt8(len & 0xff))
                config.append(ptr, count: len)
            }
            send(binary: config)
        }
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var frame = Data([2, key ? 1 : 0])
        let len = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: len)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: &bytes)
        frame.append(contentsOf: bytes)
        send(binary: frame)
    }

    // MARK: input

    /// Global, top-left-origin point for a normalized point in the window (what CGEvent expects).
    func point(_ e: [String: Any]) -> CGPoint? {
        guard let f = window?.frame else { return nil }
        let x = e["x"] as? Double ?? 0, y = e["y"] as? Double ?? 0
        return CGPoint(x: f.minX + x * f.width, y: f.minY + y * f.height)
    }

    func bringForward() {
        guard let app, !app.isActive else { return }
        app.activate()
        usleep(60_000)
    }

    func mouse(_ e: [String: Any]) {
        guard let p = point(e) else { return }
        let right = (e["button"] as? Int ?? 0) == 1
        let type: CGEventType
        switch e["type"] as? String {
        case "down": bringForward(); type = right ? .rightMouseDown : .leftMouseDown
        case "up": type = right ? .rightMouseUp : .leftMouseUp
        case "drag": type = right ? .rightMouseDragged : .leftMouseDragged
        default: type = .mouseMoved
        }
        let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: right ? .right : .left)
        ev?.setIntegerValueField(.mouseEventClickState, value: Int64(e["clicks"] as? Int ?? 1))
        ev?.post(tap: .cghidEventTap)
    }

    func scroll(_ e: [String: Any]) {
        guard let p = point(e) else { return }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: Int32(e["dy"] as? Double ?? 0), wheel2: Int32(e["dx"] as? Double ?? 0), wheel3: 0)
        ev?.post(tap: .cghidEventTap)
    }

    func key(_ e: [String: Any]) {
        guard let code = e["code"] as? Int else { return }
        let down = e["down"] as? Bool ?? true
        if down { bringForward() }
        var flags = CGEventFlags()
        for f in e["flags"] as? [String] ?? [] {
            switch f {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
        ev?.flags = flags
        ev?.post(tap: .cghidEventTap)
    }

    /// Size the Blazie display to the iPad tab and move the app's window onto it, filling it, so the
    /// window renders at 2x and maps 1:1 onto the iPad's pixels.
    func placeOnRetina() async {
        guard let app, viewSize.width > 200, viewSize.height > 200 else { return }
        if !onRetina {
            onRetina = true
            Retina.shared.retain()
        }
        guard let bounds = Retina.shared.ensure(points: viewSize) else { return }
        try? await Task.sleep(for: .milliseconds(300))  // let WindowServer add the display
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = axWindow(ax) else { return }
        var origin = bounds.origin
        var size = bounds.size
        if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v) }
        try? await Task.sleep(for: .milliseconds(250))
        log("placed \(app.localizedName ?? "?") on the Blazie display \(Int(size.width))x\(Int(size.height)) pt")
    }

    /// The AX window matching the streamed window's frame, else the main window.
    func axWindow(_ ax: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
           let wins = value as? [AXUIElement], let target = window?.frame {
            for w in wins {
                var pv: CFTypeRef?, sv: CFTypeRef?
                var pos = CGPoint.zero, size = CGSize.zero
                if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
                   AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success {
                    AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
                    AXValueGetValue(sv as! AXValue, .cgSize, &size)
                    if abs(pos.x - target.minX) < 2, abs(pos.y - target.minY) < 2, abs(size.width - target.width) < 2 {
                        return w
                    }
                }
            }
        }
        guard AXUIElementCopyAttributeValue(ax, kAXMainWindowAttribute as CFString, &value) == .success,
              let main = value else { return nil }
        return (main as! AXUIElement)
    }
}

// MARK: - the Blazie display

/// A virtual Retina display shaped like the iPad tab (CoreGraphics' CGVirtualDisplay SPI). It exists
/// while something is streaming; when it goes away, macOS moves its windows back to the real display.
final class Retina {
    static let shared = Retina()
    private var display: CGVirtualDisplay?
    private var points = CGSize.zero
    private var users = 0
    private var teardown: DispatchWorkItem?

    func retain() {
        DispatchQueue.main.async {
            self.users += 1
            self.teardown?.cancel()
        }
    }

    /// Kept for a minute after the last viewer leaves, so an iPad waking up finds its windows in place.
    func release() {
        DispatchQueue.main.async {
            self.users -= 1
            guard self.users <= 0 else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.users <= 0 else { return }
                self.display = nil
                self.points = .zero
                log("Blazie display removed")
            }
            self.teardown = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
        }
    }

    /// The display's bounds in global points, created or resized to `points` at 2x.
    func ensure(points want: CGSize) -> CGRect? {
        DispatchQueue.main.sync {
            let w = Int(want.width.rounded()), h = Int(want.height.rounded())
            if display == nil {
                let d = CGVirtualDisplayDescriptor()
                d.queue = .main
                d.name = "Blazie iPad"
                d.maxPixelsWide = 2 * 1366
                d.maxPixelsHigh = 2 * 1366  // either orientation
                d.sizeInMillimeters = CGSize(width: 262, height: 196)
                d.vendorID = 0xB1A2
                d.productID = 0xB1A2
                d.serialNum = 1
                d.terminationHandler = { _, _ in log("Blazie display terminated") }
                display = CGVirtualDisplay(descriptor: d)
            }
            guard let display else { log("could not create the Blazie display"); return nil }
            if points != CGSize(width: w, height: h) {
                let settings = CGVirtualDisplaySettings()
                settings.hiDPI = 1
                settings.modes = [CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60)]
                guard display.apply(settings) else { log("display settings rejected for \(w)x\(h)"); return nil }
                points = CGSize(width: w, height: h)
                selectHiDPI(display.displayID, w: w, h: h)
            }
            return CGDisplayBounds(display.displayID)
        }
    }

    /// Pick the w x h point mode with 2x pixels (the display comes up in its 1x mode).
    private func selectHiDPI(_ id: CGDirectDisplayID, w: Int, h: Int) {
        for _ in 0..<20 {
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] ?? []
            if let mode = modes.first(where: { $0.width == w && $0.height == h && $0.pixelWidth == 2 * w }) {
                var config: CGDisplayConfigRef?
                CGBeginDisplayConfiguration(&config)
                CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
                CGCompleteDisplayConfiguration(config, .forSession)
                log("Blazie display \(w)x\(h) pt at 2x")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        log("no 2x mode for \(w)x\(h); staying at 1x")
    }
}

// MARK: - server

final class Server {
    let listener: NWListener
    var clients: [ObjectIdentifier: Client] = [:]

    init() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            let c = Client(conn)
            let id = ObjectIdentifier(c)
            self?.clients[id] = c
            conn.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled:
                    c.stop()
                    DispatchQueue.main.async { self?.clients[id] = nil }
                default: break
                }
            }
            c.start()
        }
        listener.stateUpdateHandler = { log("listener \($0)") }
        listener.start(queue: .main)
    }
}

// Ask for both permissions up front so the prompts appear once, at install, not mid-stream.
if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
    log("waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)")
}
log("screen recording: \(CGPreflightScreenCaptureAccess()), accessibility: \(AXIsProcessTrusted())")
// Report grants as they happen (System Settings applies them live or on relaunch; KeepAlive relaunches).
var lastGrants = (CGPreflightScreenCaptureAccess(), AXIsProcessTrusted())
Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
    let now = (CGPreflightScreenCaptureAccess(), AXIsProcessTrusted())
    if now != lastGrants {
        lastGrants = now
        log("screen recording: \(now.0), accessibility: \(now.1)")
    }
}

let server = try Server()
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
