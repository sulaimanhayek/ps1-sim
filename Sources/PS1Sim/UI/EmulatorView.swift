import SwiftUI
import AppKit

/// The in-game screen: Metal surface, an auto-hiding control bar, and the
/// keyboard monitor that feeds the virtual DualShock.
struct EmulatorView: View {
    @ObservedObject var session: EmulatorSession
    let onExit: () -> Void

    @EnvironmentObject private var settings: Settings
    @State private var monitor: Any?
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showStateMenu = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            switch session.status {
            case .failed(let message):
                failureView(message)
            case .starting:
                ProgressView("Starting \(session.game.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .running, .paused:
                VideoSurface(store: session.frameStore,
                             smoothScaling: settings.smoothScaling,
                             integerScaling: settings.integerScaling,
                             scanlines: settings.crtScanlines)
                    .ignoresSafeArea()
            }

            if showControls, session.status != .starting { controlBar.transition(.move(edge: .top).combined(with: .opacity)) }

            if session.paused { pausedOverlay }
        }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .onAppear { installKeyMonitor(); scheduleHide() }
        .onDisappear { removeKeyMonitor() }
        .onContinuousHover { phase in
            if case .active = phase { reveal() }
        }
    }

    // MARK: - Chrome

    private var controlBar: some View {
        HStack(spacing: 10) {
            Button(action: exit) { Label("Library", systemImage: "chevron.left") }
                .help("Return to the library (⌘W)")

            Text(session.game.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)

            Spacer()

            Button { session.togglePause() } label: {
                Image(systemName: session.paused ? "play.fill" : "pause.fill")
            }
            .help(session.paused ? "Resume (P)" : "Pause (P)")

            Menu {
                Section("Save to slot") {
                    ForEach(1...8, id: \.self) { slot in
                        Button(slotLabel(slot, saving: true)) { session.saveState(slot: slot) }
                    }
                }
                Section("Load from slot") {
                    ForEach(1...8, id: \.self) { slot in
                        Button(slotLabel(slot, saving: false)) { session.loadState(slot: slot) }
                            .disabled(!session.occupiedSlots.contains(slot))
                    }
                }
            } label: {
                Label("States", systemImage: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 92)
            .help("Save states — ⌘S saves slot 1, ⌘L loads it")

            Button { session.requestReset() } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Reset the console")

            Button { toggleFullScreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Full screen (⌘F)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .padding(12)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private func slotLabel(_ slot: Int, saving: Bool) -> String {
        let occupied = session.occupiedSlots.contains(slot)
        if saving { return occupied ? "Slot \(slot) — overwrite" : "Slot \(slot) — empty" }
        return occupied ? "Slot \(slot)" : "Slot \(slot) — empty"
    }

    private var pausedOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "pause.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.85))
            Text("Paused").font(.system(size: 15, weight: .medium))
            Text("Press P to resume").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var toast: some View {
        if let message = session.toast {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 28)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.18), value: session.toast)
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon").font(.system(size: 40)).foregroundStyle(.orange)
            Text("\(session.game.title) could not start").font(.system(size: 15, weight: .medium))
            Text(message)
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Back to Library") { onExit() }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Behaviour

    private func exit() {
        removeKeyMonitor()
        onExit()
    }

    private func reveal() {
        showControls = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { showControls = false }
        }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    /// Local monitor so gameplay keys never reach the menu bar or beep.
    private func installKeyMonitor() {
        guard monitor == nil else { return }
        settings.apply(to: session.input)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        session.input.releaseAll()
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Let the system own anything with Command held, except our own hotkeys.
        if event.modifierFlags.contains(.command) {
            guard event.type == .keyDown else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": session.saveState(slot: 1); return true
            case "l": session.loadState(slot: 1); return true
            case "r": session.requestReset(); return true
            case "w": exit(); return true
            default: return false
            }
        }

        switch event.type {
        case .keyDown where !event.isARepeat:
            switch event.keyCode {
            case 53: // Escape
                if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
                    toggleFullScreen()
                } else {
                    exit()
                }
                return true
            case 35: // P
                session.togglePause()
                return true
            case 48: // Tab — hold to fast-forward
                session.setFastForward(true)
                return true
            default: break
            }
        case .keyUp where event.keyCode == 48:
            session.setFastForward(false)
            return true
        default: break
        }

        guard event.type == .keyDown || event.type == .keyUp,
              session.input.isBound(event.keyCode) else { return false }
        session.input.setKey(event.keyCode, down: event.type == .keyDown)
        return true
    }
}
