import Foundation

/// Everything the app owns on disk lives under ~/Library/Application Support/PS1Sim.
enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PS1Sim", isDirectory: true)
    }()

    static var cores: URL { root.appendingPathComponent("cores", isDirectory: true) }
    /// The core's "system" directory — BIOS images go here.
    static var system: URL { root.appendingPathComponent("system", isDirectory: true) }
    /// Memory cards and SRAM, written by the core.
    static var saves: URL { root.appendingPathComponent("saves", isDirectory: true) }
    /// Our own save states, one subdirectory per game.
    static var states: URL { root.appendingPathComponent("states", isDirectory: true) }
    static var artwork: URL { root.appendingPathComponent("artwork", isDirectory: true) }
    static var generatedCues: URL { root.appendingPathComponent("cues", isDirectory: true) }

    static var libraryFile: URL { root.appendingPathComponent("library.json") }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }

    static var corePath: URL { cores.appendingPathComponent("pcsx_rearmed_libretro.dylib") }

    static func statesDirectory(for gameID: UUID) -> URL {
        states.appendingPathComponent(gameID.uuidString, isDirectory: true)
    }

    static func createDirectories() {
        for dir in [root, cores, system, saves, states, artwork, generatedCues] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
