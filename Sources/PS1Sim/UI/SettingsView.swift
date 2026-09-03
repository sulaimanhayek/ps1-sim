import SwiftUI
import GameController
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var installer: CoreInstaller
    @State private var tab = Tab.setup
    @State private var biosFiles = BIOS.installed
    @State private var capturing: Capture?
    @State private var cards = MemoryCard.allCards()
    @State private var cardNotice: String?
    @State private var connectedPads = SettingsView.currentPads()

    static func currentPads() -> [String] {
        GCController.controllers().compactMap { $0.vendorName ?? "Controller" }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case setup = "Setup"
        case controls = "Controls"
        case video = "Video"
        case cards = "Memory Cards"
        var id: String { rawValue }
    }

    /// Which binding row is waiting for a keypress.
    enum Capture: Equatable {
        case button(PadButton)
        case axis(PadAxis)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case .setup: setupTab
                    case .controls: controlsTab
                    case .video: videoTab
                    case .cards: cardsTab
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 620, height: 520)
        .background(KeyCaptureView(isActive: capturing != nil) { keyCode in
            guard let capturing else { return }
            switch capturing {
            case .button(let button): settings.bind(key: keyCode, to: button)
            case .axis(let axis): settings.bind(key: keyCode, to: axis)
            }
            self.capturing = nil
        })
    }

    // MARK: - Setup

    private var setupTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Emulator core",
                    detail: "PS1Sim runs games through the pcsx_rearmed libretro core. It is not bundled — install it once and it is remembered.") {
                HStack(spacing: 10) {
                    statusDot(installer.isInstalled)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coreStatusTitle).font(.system(size: 12, weight: .medium))
                        Text(Paths.corePath.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("Download Core") { installer.downloadFromBuildbot() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(isWorking)
                    Button("Choose Core File…") { chooseCore() }.disabled(isWorking)
                    if isWorking { ProgressView().controlSize(.small) }
                }
                Text("Downloads pcsx_rearmed_libretro.dylib from buildbot.libretro.com, the official libretro build server.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
            }

            section("PlayStation BIOS",
                    detail: "A BIOS image dumped from a console you own. Sony's firmware cannot be distributed, so you must supply it. Put scph5501.bin (US), scph5502.bin (EU) or scph5500.bin (JP) here.") {
                HStack(spacing: 10) {
                    statusDot(!biosFiles.isEmpty)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(biosFiles.isEmpty ? "No BIOS installed"
                                               : biosFiles.joined(separator: ", "))
                            .font(.system(size: 12, weight: .medium))
                        Text(Paths.system.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("Add BIOS File…") { chooseBIOS() }
                    Button("Open System Folder") { NSWorkspace.shared.open(Paths.system) }
                }
            }

            section("Data", detail: "Memory cards, save states and your library live here.") {
                HStack(spacing: 8) {
                    Button("Open Memory Cards") { NSWorkspace.shared.open(Paths.saves) }
                    Button("Open Save States") { NSWorkspace.shared.open(Paths.states) }
                }
            }
        }
    }

    private var coreStatusTitle: String {
        switch installer.state {
        case .installed(let name): return "Installed — \(name)"
        case .missing: return "Not installed"
        case .working(let message): return message
        case .failed(let message): return message
        }
    }

    private var isWorking: Bool {
        if case .working = installer.state { return true }
        return false
    }

    // MARK: - Controls

    private var controlsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Click a binding, then press the key you want.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Restore Defaults") { settings.resetControls() }.controlSize(.small)
            }

            bindingGrid(title: "Buttons", rows: PadButton.displayOrder.map { button in
                (button.label, settings.key(for: button), Capture.button(button))
            })

            bindingGrid(title: "Analog sticks", rows: PadAxis.allCases.map { axis in
                (axis.label, settings.key(for: axis), Capture.axis(axis))
            })

            section("Controller", detail: """
            A DualSense, DualShock 4 or Xbox pad works as soon as macOS pairs it — \
            no mapping needed, and it can be used alongside the keyboard. Face \
            buttons follow their physical position, so the bottom button is Cross.
            """) {
                HStack(spacing: 7) {
                    statusDot(!connectedPads.isEmpty)
                    Text(connectedPads.isEmpty ? "No controller connected"
                                               : connectedPads.joined(separator: ", "))
                        .font(.system(size: 11.5))
                    Spacer()
                    Button("Check Again") { connectedPads = SettingsView.currentPads() }
                        .controlSize(.small)
                }
            }

            section("Hotkeys", detail: nil) {
                hotkeyRow("Pause / resume", "P")
                hotkeyRow("Fast-forward", "Hold Tab")
                hotkeyRow("Save state to slot 1", "⌘S")
                hotkeyRow("Load state from slot 1", "⌘L")
                hotkeyRow("Reset console", "⌘R")
                hotkeyRow("Full screen", "⌘F")
                hotkeyRow("Back to library", "Esc or ⌘W")
            }
        }
    }

    private func bindingGrid(title: String,
                             rows: [(String, UInt16?, Capture)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0).font(.system(size: 11.5))
                        Spacer()
                        Button {
                            capturing = row.2
                        } label: {
                            Text(capturing == row.2 ? "Press a key…"
                                                    : row.1.map(KeyCode.name(for:)) ?? "Unbound")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .frame(minWidth: 78)
                        }
                        .controlSize(.small)
                        .tint(capturing == row.2 ? Theme.accent : nil)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func hotkeyRow(_ name: String, _ key: String) -> some View {
        HStack {
            Text(name).font(.system(size: 11.5))
            Spacer()
            Text(key).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - Video

    private var videoTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Scaling", detail: nil) {
                Toggle("Smooth scaling", isOn: $settings.smoothScaling)
                Text("Bilinear filtering. Turn off for sharp, blocky pixels.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
                Toggle("Integer scaling", isOn: $settings.integerScaling)
                Text("Snaps the picture to whole multiples of the native resolution.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
            }
            section("Effects", detail: nil) {
                Toggle("CRT scanlines", isOn: $settings.crtScanlines)
                Text("Darkens alternate lines, the way a CRT television did.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
            }
            section("Sessions", detail: nil) {
                Toggle("Resume where I left off", isOn: $settings.resumeOnLaunch)
                Text("""
                Saves a state when you leave a game and restores it next time you \
                open it. Separate from the eight numbered slots, which are never \
                touched by this.
                """)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Memory cards

    private var cardsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Cards", detail: """
            One card per game, written by the emulator in the same format DuckStation \
            and ePSXe use. A card appears here once a game has saved to it.
            """) {
                if cards.isEmpty {
                    Text("No memory cards yet. They are created the first time a game saves.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                } else {
                    ForEach(cards, id: \.url) { card in cardRow(card) }
                }
                HStack {
                    Button("Refresh") { cards = MemoryCard.allCards() }
                    Button("Show in Finder") { NSWorkspace.shared.open(Paths.saves) }
                    if let cardNotice {
                        Text(cardNotice).font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    private func cardRow(_ card: MemoryCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(card.url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Text("\(card.usedBlocks) of 15 blocks used")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
                Button("Back Up") {
                    do {
                        let copy = try card.backUp()
                        cardNotice = "Backed up to \(copy.lastPathComponent)"
                    } catch {
                        cardNotice = "Backup failed: \(error.localizedDescription)"
                    }
                }
                .controlSize(.small)
            }
            // A block gauge, the way the console's own card browser showed it.
            HStack(spacing: 2) {
                ForEach(0..<15, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index < card.usedBlocks ? Theme.accent : Color.white.opacity(0.12))
                        .frame(height: 6)
                }
            }
            ForEach(card.saves) { save in
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 8)).foregroundStyle(Theme.secondaryText)
                    Text(save.title).font(.system(size: 11))
                    Text(save.filename)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Text("\(save.blocks) block\(save.blocks == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Helpers

    private func section(_ title: String, detail: String?,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }

    private func statusDot(_ ok: Bool) -> some View {
        Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
    }

    private func chooseCore() {
        let panel = NSOpenPanel()
        panel.message = "Choose a libretro core (.dylib)"
        panel.allowedContentTypes = [UTType(filenameExtension: "dylib") ?? .data]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { installer.install(from: url) }
    }

    private func chooseBIOS() {
        let panel = NSOpenPanel()
        panel.message = "Choose a PlayStation BIOS image you dumped from your own console"
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            try? BIOS.install(from: url)
            biosFiles = BIOS.installed
        }
    }
}

/// Invisible first responder used to capture a single keystroke for rebinding.
struct KeyCaptureView: NSViewRepresentable {
    let isActive: Bool
    let onKey: (UInt16) -> Void

    final class Catcher: NSView {
        var onKey: ((UInt16) -> Void)?
        var isActive = false
        override var acceptsFirstResponder: Bool { isActive }
        override func keyDown(with event: NSEvent) {
            guard isActive else { return super.keyDown(with: event) }
            onKey?(event.keyCode)
        }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.onKey = onKey
        view.isActive = isActive
        if isActive { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
    }
}
