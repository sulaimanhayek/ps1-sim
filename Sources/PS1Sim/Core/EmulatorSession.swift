import Foundation
import PS1SimKit
import AppKit

/// Owns the emulation thread, the core, and audio. Deliberately *not* main-actor
/// isolated: every method here runs on, or is safe to call from, the emulation
/// thread. UI-visible changes are reported through `events`.
final class EmulationRunner: @unchecked Sendable {

    enum Event {
        case message(String)
        case slotsChanged
        case discChanged(Int)
    }

    let input = InputState()
    let frameStore = FrameStore()

    private var core: LibretroCore?
    private let audio = AudioOutput()
    private var thread: Thread?
    private let gameID: UUID

    private let controlLock = NSLock()
    private var shouldStop = false
    private var isPaused = false
    private var fastForward = false
    private var pendingSaveSlot: Int?
    private var pendingLoadSlot: Int?
    private var pendingReset = false
    private var pendingDiscIndex: Int?

    /// Discs in the loaded playlist, read once after the game loads. A single-disc
    /// game reports 0 or 1 and the UI hides the tray entirely.
    private(set) var discCount = 0
    /// True when start() picked up where the last session left off.
    private(set) var resumed = false

    /// Delivered on the main queue.
    var onEvent: ((Event) -> Void)?

    init(gameID: UUID) {
        self.gameID = gameID
    }

    var coreDescription: String {
        guard let core else { return "" }
        return "\(core.libraryName) \(core.libraryVersion)"
    }

    // MARK: - Lifecycle

    /// Where the state written on a clean exit lives. Kept out of the eight numbered
    /// slots so it can never overwrite something the player saved deliberately.
    static func autoStateURL(gameID: UUID) -> URL {
        let directory = Paths.statesDirectory(for: gameID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("auto.state")
    }

    func start(discURL: URL, resuming: Bool) throws {
        let core = try LibretroCore(corePath: Paths.corePath)
        self.core = core

        core.onVideoFrame = { [frameStore] frame in frameStore.submit(frame) }
        core.onAudioSamples = { [audio] samples, frames in audio.enqueue(samples, frames: frames) }
        core.onInputPoll = {}
        core.onInputState = { [input] port, device, index, id in
            guard port == 0 else { return 0 }
            switch device {
            case 1: // RETRO_DEVICE_JOYPAD
                guard let button = PadButton(rawValue: id) else { return 0 }
                return input.isPressed(button) ? 1 : 0
            case 5: // RETRO_DEVICE_ANALOG
                return input.axisValue(index: index, axis: id)
            default:
                return 0
            }
        }
        core.onLog = { message in NSLog("PS1Sim core: %@", message) }

        do {
            try core.loadGame(path: discURL)
        } catch {
            core.shutdown()
            self.core = nil
            throw error
        }

        discCount = core.discCount

        // Restored before the emulation thread starts, while the core is idle and
        // nothing else can touch it.
        if resuming, let data = try? Data(contentsOf: Self.autoStateURL(gameID: gameID)) {
            resumed = core.restoreState(data)
        }

        audio.start(sampleRate: core.sampleRate)

        let thread = Thread { [weak self] in self?.emulationLoop() }
        thread.name = "PS1Sim.emulation"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 4 << 20
        self.thread = thread
        thread.start()
    }

    /// Stops the loop, then tears the core down. retro_unload_game is what flushes
    /// memory cards, so this must run before the process exits.
    func shutdown(writingAutoState: Bool) {
        controlLock.lock(); shouldStop = true; controlLock.unlock()
        while let thread, !thread.isFinished {
            usleep(2000)
        }
        thread = nil
        audio.stop()
        // The thread has stopped, so the core is idle and safe to touch from here.
        if writingAutoState, let core, let data = try? core.serializeState() {
            try? data.write(to: Self.autoStateURL(gameID: gameID), options: .atomic)
        }
        core?.shutdown()
        core = nil
    }

    // MARK: - Commands (safe from any thread)

    func setPaused(_ paused: Bool) {
        controlLock.lock(); isPaused = paused; controlLock.unlock()
        audio.volume = paused ? 0 : 1
    }

    func setFastForward(_ on: Bool) {
        controlLock.lock(); fastForward = on; controlLock.unlock()
    }

    func requestReset() {
        controlLock.lock(); pendingReset = true; controlLock.unlock()
    }

    func requestSave(slot: Int) {
        controlLock.lock(); pendingSaveSlot = slot; controlLock.unlock()
    }

    func requestLoad(slot: Int) {
        controlLock.lock(); pendingLoadSlot = slot; controlLock.unlock()
    }

    func requestDisc(_ index: Int) {
        controlLock.lock(); pendingDiscIndex = index; controlLock.unlock()
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [onEvent] in onEvent?(event) }
    }

    // MARK: - Emulation thread

    private func emulationLoop() {
        guard let core else { return }
        let frameDuration = 1.0 / core.fps
        var nextFrame = Date().timeIntervalSinceReferenceDate

        while true {
            controlLock.lock()
            let stop = shouldStop
            let pausedNow = isPaused
            let turbo = fastForward
            let saveSlot = pendingSaveSlot; pendingSaveSlot = nil
            let loadSlot = pendingLoadSlot; pendingLoadSlot = nil
            let reset = pendingReset; pendingReset = false
            let discIndex = pendingDiscIndex; pendingDiscIndex = nil
            controlLock.unlock()

            if stop { break }
            if reset { core.reset(); emit(.message("Reset")) }
            if let slot = saveSlot { performSave(core: core, slot: slot) }
            if let slot = loadSlot { performLoad(core: core, slot: slot) }
            if let index = discIndex {
                if core.selectDisc(index) {
                    emit(.discChanged(index))
                } else {
                    emit(.message("Could not change disc"))
                }
            }

            if pausedNow {
                Thread.sleep(forTimeInterval: 0.016)
                nextFrame = Date().timeIntervalSinceReferenceDate
                continue
            }

            core.run()

            if turbo {
                // Run flat out, but do not get so far ahead that audio overruns.
                if audio.fillRatio > 0.75 { Thread.sleep(forTimeInterval: 0.001) }
                nextFrame = Date().timeIntervalSinceReferenceDate
                continue
            }

            // Pace against the wall clock, nudged by how full the audio ring is, so
            // we stay locked to the sound card instead of drifting against it.
            var interval = frameDuration
            let fill = audio.fillRatio
            if fill > 0.60 { interval *= 1.01 } else if fill < 0.25 { interval *= 0.99 }

            nextFrame += interval
            let now = Date().timeIntervalSinceReferenceDate
            let delay = nextFrame - now
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            } else if delay < -0.25 {
                nextFrame = now  // fell far behind (window drag, display sleep) — resync
            }
        }
    }

    private func performSave(core: LibretroCore, slot: Int) {
        do {
            let data = try core.serializeState()
            try data.write(to: EmulationRunner.stateURL(gameID: gameID, slot: slot), options: .atomic)
            emit(.slotsChanged)
            emit(.message("Saved to slot \(slot)"))
        } catch {
            emit(.message("Save failed: \(error.localizedDescription)"))
        }
    }

    private func performLoad(core: LibretroCore, slot: Int) {
        let url = EmulationRunner.stateURL(gameID: gameID, slot: slot)
        guard let data = try? Data(contentsOf: url) else {
            emit(.message("Slot \(slot) is empty"))
            return
        }
        emit(.message(core.restoreState(data) ? "Loaded slot \(slot)"
                                              : "Slot \(slot) is incompatible"))
    }

    static func stateURL(gameID: UUID, slot: Int) -> URL {
        let directory = Paths.statesDirectory(for: gameID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("slot\(slot).state")
    }
}

/// Main-actor face of a running game: publishes state for SwiftUI and forwards
/// commands to the runner.
@MainActor
final class EmulatorSession: ObservableObject {

    enum Status: Equatable {
        case starting
        case running
        case paused
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var coreName = ""
    @Published var toast: String?
    /// Slots 1-8 that currently hold a save state.
    @Published private(set) var occupiedSlots: Set<Int> = []
    /// One entry per disc in the playlist; empty for a single-disc game.
    @Published private(set) var discs: [String] = []
    @Published private(set) var currentDisc = 0
    /// Name of a connected controller, if any.
    @Published private(set) var gamepadName: String?

    let game: Game
    private let runner: EmulationRunner
    private let resumeOnLaunch: Bool
    private var startedAt = Date()
    private var toastTask: Task<Void, Never>?
    private let gamepad: GamepadBridge

    var frameStore: FrameStore { runner.frameStore }
    var input: InputState { runner.input }

    init(game: Game, settings: Settings) {
        self.game = game
        self.resumeOnLaunch = settings.resumeOnLaunch
        self.runner = EmulationRunner(gameID: game.id)
        self.gamepad = GamepadBridge(input: runner.input)
        settings.apply(to: runner.input)
        gamepad.onConnectionChange = { [weak self] name in
            guard let self else { return }
            self.gamepadName = name
            if let name { self.show("\(name) connected") }
        }
        runner.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .message(let text): self.show(text)
            case .slotsChanged: self.refreshSlots()
            case .discChanged(let index):
                self.currentDisc = index
                self.show("Inserted \(self.discs.indices.contains(index) ? self.discs[index] : "disc \(index + 1)")")
            }
        }
        refreshSlots()
    }

    func start() {
        guard case .starting = status else { return }
        do {
            try runner.start(discURL: game.url, resuming: resumeOnLaunch)
            if runner.resumed { show("Resumed where you left off") }
            gamepad.start()
            coreName = runner.coreDescription
            discs = runner.discCount > 1 ? Playlist.labels(for: game.url, count: runner.discCount) : []
            startedAt = Date()
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Tears everything down and returns how long the game ran, in seconds.
    @discardableResult
    func shutdown() -> Double {
        gamepad.stop()
        runner.shutdown(writingAutoState: resumeOnLaunch)
        toastTask?.cancel()
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Controls

    var paused: Bool {
        if case .paused = status { return true }
        return false
    }

    func togglePause() {
        guard status == .running || status == .paused else { return }
        let next = !paused
        runner.setPaused(next)
        status = next ? .paused : .running
    }

    func setFastForward(_ on: Bool) { runner.setFastForward(on) }
    func requestReset() { runner.requestReset() }

    func saveState(slot: Int) { runner.requestSave(slot: slot) }

    func selectDisc(_ index: Int) {
        guard index != currentDisc, discs.indices.contains(index) else { return }
        runner.requestDisc(index)
    }

    func loadState(slot: Int) {
        guard occupiedSlots.contains(slot) else {
            show("Slot \(slot) is empty")
            return
        }
        runner.requestLoad(slot: slot)
    }

    func refreshSlots() {
        var found = Set<Int>()
        for slot in 1...8 {
            let url = EmulationRunner.stateURL(gameID: game.id, slot: slot)
            if FileManager.default.fileExists(atPath: url.path) { found.insert(slot) }
        }
        occupiedSlots = found
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

/// Hands frames from the emulation thread to the renderer.
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels = [UInt8]()
    private var width = 0
    private var height = 0
    private var aspect: Float = 4.0 / 3.0
    private var generation: UInt64 = 0

    func submit(_ frame: VideoFrame) {
        lock.lock()
        pixels = frame.pixels
        width = frame.width
        height = frame.height
        aspect = frame.aspect
        generation &+= 1
        lock.unlock()
    }

    /// Hands the newest frame to `body` only if it is newer than `lastSeen`.
    func withLatest(since lastSeen: inout UInt64,
                    _ body: (UnsafeRawPointer, Int, Int, Float) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard generation != lastSeen, width > 0, height > 0 else { return }
        lastSeen = generation
        pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            body(base, width, height, aspect)
        }
    }
}

/// Reads the disc names out of an .m3u so the tray menu can show "Disc 2" rather
/// than an index. The core's v0 disc interface reports no labels of its own.
