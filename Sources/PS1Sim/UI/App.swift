import SwiftUI
import AppKit

@main
struct PS1SimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library = GameLibrary()
    @StateObject private var settings = Settings()
    @StateObject private var installer = CoreInstaller()

    var body: some Scene {
        Window("PS1Sim", id: "main") {
            RootView()
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(installer)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About PS1Sim") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Switches between the library and a running game.
struct RootView: View {
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var settings: Settings
    @State private var session: EmulatorSession?

    var body: some View {
        ZStack {
            if let session {
                EmulatorView(session: session, onExit: { endSession() })
                    .transition(.opacity)
            } else {
                LibraryView(onLaunch: launch)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: session == nil)
        .background(Theme.background)
    }

    private func launch(_ game: Game) {
        let session = EmulatorSession(game: game, settings: settings)
        session.start()
        self.session = session
    }

    private func endSession() {
        guard let session else { return }
        let seconds = session.shutdown()
        library.recordSession(gameID: session.game.id, seconds: seconds)
        self.session = nil
    }
}

enum Theme {
    static let background = Color(nsColor: NSColor(calibratedWhite: 0.09, alpha: 1))
    static let surface = Color(nsColor: NSColor(calibratedWhite: 0.14, alpha: 1))
    static let accent = Color(red: 0.36, green: 0.60, blue: 0.98)
    static let secondaryText = Color.white.opacity(0.55)
}
