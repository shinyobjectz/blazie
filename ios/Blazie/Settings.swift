import GameController
import SwiftUI

enum Settings {
    static let keyboardKey = "keyboard"

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
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 30)
        }
        .accessibilityLabel("Settings")
        .onChange(of: keyboard) { _, _ in TerminalSessions.shared.applyKeyboardSetting() }
    }
}
