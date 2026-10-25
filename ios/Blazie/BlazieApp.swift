import SwiftUI

enum Theme {
    static let background = Color(red: 0.07, green: 0.06, blue: 0.06)
    static let bar = Color(red: 0.11, green: 0.09, blue: 0.08)
    static let ember = Color(red: 1, green: 0.47, blue: 0.16)
}

@main
struct BlazieApp: App {
    @StateObject private var store = TabStore()
    @StateObject private var events = EventsClient()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(events)
                .preferredColorScheme(.dark)
                .onAppear { events.start(store) }
                .onChange(of: phase) { _, now in
                    if now == .active {
                        events.start(store)
                        TerminalSessions.shared.reconnectAll()
                        StreamSessions.shared.reconnectAll()
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: TabStore
    @EnvironmentObject var events: EventsClient

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
            ZStack {
                // Every tab stays alive underneath, so shells and pages keep their state between switches.
                ForEach(store.tabs) { tab in
                    let active = tab.id == store.selected
                    content(tab, active: active)
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(active)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    @ViewBuilder
    private func content(_ tab: Tab, active: Bool) -> some View {
        switch tab.kind {
        case .terminal:
            TerminalTabView(tab: tab, active: active)
                .padding(.horizontal, 6)
                .background(Theme.background)
        case .web(let url, let auth):
            WebTabView(url: url, auth: auth)
        case .macApp(let name):
            MacAppTabView(tab: tab, name: name, active: active)
        }
    }
}

struct TabStrip: View {
    @EnvironmentObject var store: TabStore
    @EnvironmentObject var events: EventsClient
    @State private var askingApp = false
    @State private var appName = ""

    var body: some View {
        HStack(spacing: 6) {
            Text("🔥")
                .font(.system(size: 18))
                .padding(.leading, 12)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(events.connected ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                        .offset(x: 3, y: 1)
                }
                .accessibilityLabel(events.connected ? "Connected to the Mac mini" : "Connecting to the Mac mini")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == store.selected)
                    }
                }
                .padding(.vertical, 6)
            }
            Menu {
                Button("New terminal", systemImage: "terminal") { store.newTerminal() }
                Button("Mac app…", systemImage: "macwindow") { askingApp = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 30)
            } primaryAction: {
                store.newTerminal()
            }
            .accessibilityLabel("New tab")
            .alert("Open a Mac app", isPresented: $askingApp) {
                TextField("App name, e.g. Figma", text: $appName)
                Button("Open") {
                    let name = appName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { store.newMacApp(name) }
                    appName = ""
                }
                Button("Cancel", role: .cancel) { appName = "" }
            }
            Button("") { store.newTerminal() }
                .keyboardShortcut("t", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            SettingsMenu()
                .padding(.trailing, 8)
        }
        .foregroundStyle(.white.opacity(0.9))
        .background(Theme.bar)
    }
}

struct TabChip: View {
    let tab: Tab
    let selected: Bool
    @EnvironmentObject var store: TabStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
            Text(tab.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Button {
                store.close(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .accessibilityLabel("Close \(tab.title)")
            .opacity(selected ? 0.8 : 0.4)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: 220)
        .background(selected ? Theme.ember.opacity(0.22) : Color.white.opacity(0.05), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.ember.opacity(0.6) : .clear))
        .contentShape(.rect)
        .onTapGesture { store.selected = tab.id }
    }
}
