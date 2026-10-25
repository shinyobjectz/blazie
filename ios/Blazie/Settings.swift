import GameController
import SwiftUI

enum Settings {
    static let keyboardKey = "keyboard"
    static let touchScrollKey = "touchScroll"
    static let mouseScrollKey = "mouseScroll"

    /// What a scroll in a terminal moves.
    enum Scroll: String, CaseIterable, Identifiable {
        case app, scrollback
        var id: String { rawValue }
        var label: String {
            switch self {
            case .app: "Send to app"
            case .scrollback: "Blazie scrollback"
            }
        }
        static func current(_ key: String) -> Scroll {
            Scroll(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .app
        }
    }

    enum Keyboard: String, CaseIterable, Identifiable {
        case automatic, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: "Automatic"
            case .off: "Off"
            }
        }
    }
}

/// Whether a hardware keyboard (Bluetooth, Smart Keyboard, Magic Keyboard) is connected right now.
@MainActor
final class HardwareKeyboard: ObservableObject {
    @Published private(set) var connected = GCKeyboard.coalesced != nil

    init() {
        let center = NotificationCenter.default
        center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.connected = true }
        }
        center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.connected = GCKeyboard.coalesced != nil }
        }
    }
}

/// The gear in the tab strip.
struct SettingsMenu: View {
    @AppStorage(Settings.keyboardKey) private var keyboard = Settings.Keyboard.automatic.rawValue
    @AppStorage(Settings.touchScrollKey) private var touchScroll = Settings.Scroll.app.rawValue
    @AppStorage(Settings.mouseScrollKey) private var mouseScroll = Settings.Scroll.app.rawValue
    @StateObject private var hardware = HardwareKeyboard()

    var body: some View {
        Menu {
            Picker("On-screen keyboard", selection: $keyboard) {
                ForEach(Settings.Keyboard.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Section {
                Label(hardware.connected ? "Keyboard connected" : "No keyboard connected",
                      systemImage: hardware.connected ? "keyboard.fill" : "keyboard")
            } footer: {
                Text("Automatic hides the on-screen keyboard while a keyboard is connected. Off never shows it.")
            }
            Picker("Touch scroll", selection: $touchScroll) {
                ForEach(Settings.Scroll.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            Picker("Mouse & trackpad scroll", selection: $mouseScroll) {
                ForEach(Settings.Scroll.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            Section {} footer: {
                Text("Send to app scrolls the program (vim, less, Claude Code) or the shell's full history on the Mac. Blazie scrollback scrolls what this iPad has shown. With Send to app, two fingers still scroll Blazie scrollback.")
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 30)
        }
        .accessibilityLabel("Settings")
        .onChange(of: keyboard) { _, _ in TerminalSessions.shared.applyKeyboardSetting() }
        .onChange(of: touchScroll) { _, _ in TerminalSessions.shared.applyScrollSettings() }
    }
}
