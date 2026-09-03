import Foundation

/// Obtains the libretro core the app runs games on.
///
/// The core is not bundled: it is GPL/mixed-licence software with its own release
/// cadence, so the app either uses one shipped alongside it, one the user points
/// at, or one downloaded on request from the official libretro buildbot.
@MainActor
final class CoreInstaller: ObservableObject {

    enum State: Equatable {
        case missing
        case installed(name: String)
        case working(String)
        case failed(String)
    }

    @Published private(set) var state: State = .missing

    static let buildbotURL: URL = {
        #if arch(arm64)
        return URL(string: "https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/pcsx_rearmed_libretro.dylib.zip")!
        #else
        return URL(string: "https://buildbot.libretro.com/nightly/apple/osx/x86_64/latest/pcsx_rearmed_libretro.dylib.zip")!
        #endif
    }()

    init() {
        Paths.createDirectories()
        adoptBundledCoreIfPresent()
        refresh()
    }

    var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    func refresh() {
        if FileManager.default.fileExists(atPath: Paths.corePath.path) {
            state = .installed(name: Paths.corePath.lastPathComponent)
        } else if case .failed = state {
            // keep the error visible
        } else {
            state = .missing
        }
    }

    /// If a core was shipped inside the .app bundle, copy it into place on first run.
    private func adoptBundledCoreIfPresent() {
        guard !FileManager.default.fileExists(atPath: Paths.corePath.path),
              let bundled = Bundle.main.url(forResource: "pcsx_rearmed_libretro", withExtension: "dylib")
                ?? Bundle.main.url(forResource: "pcsx_rearmed_libretro",
                                   withExtension: "dylib", subdirectory: "Cores")
        else { return }
        try? FileManager.default.copyItem(at: bundled, to: Paths.corePath)
    }

    /// Installs a core the user picked from disk.
    func install(from url: URL) {
        do {
            try FileManager.default.createDirectory(at: Paths.cores, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: Paths.corePath)
            try FileManager.default.copyItem(at: url, to: Paths.corePath)
            prepareForLoading(Paths.corePath)
            refresh()
        } catch {
            state = .failed("Could not install that core: \(error.localizedDescription)")
        }
    }

    /// Downloads pcsx_rearmed from the libretro buildbot. User-initiated only.
    func downloadFromBuildbot() {
        state = .working("Downloading pcsx_rearmed…")
        Task {
            do {
                let (temporary, response) = try await URLSession.shared.download(from: Self.buildbotURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw NSError(domain: "PS1Sim", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "The buildbot returned HTTP \(http.statusCode)."
                    ])
                }
                let zip = Paths.cores.appendingPathComponent("core-download.zip")
                try? FileManager.default.removeItem(at: zip)
                try FileManager.default.moveItem(at: temporary, to: zip)

                state = .working("Unpacking…")
                try unzip(zip, into: Paths.cores)
                try? FileManager.default.removeItem(at: zip)

                guard FileManager.default.fileExists(atPath: Paths.corePath.path) else {
                    throw NSError(domain: "PS1Sim", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "The download did not contain pcsx_rearmed_libretro.dylib."
                    ])
                }
                prepareForLoading(Paths.corePath)
                refresh()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// A freshly downloaded dylib is quarantined and unsigned; both stop dlopen.
    private func prepareForLoading(_ url: URL) {
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
        run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
    }

    private func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", archive.path, "-d", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PS1Sim", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Could not unpack the downloaded core."
            ])
        }
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Tracks whether a usable PS1 BIOS is present in the system directory.
enum BIOS {
    /// Filenames pcsx_rearmed looks for, in rough preference order.
    static let knownNames = [
        "scph5501.bin", "scph5500.bin", "scph5502.bin", "scph5503.bin",
        "scph7001.bin", "scph7003.bin", "scph1001.bin", "scph1000.bin",
        "scph101.bin", "scph103.bin", "SCPH1001.BIN", "PSXONPSP660.bin",
    ]

    static var installed: [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: Paths.system.path)) ?? []
        return contents.filter { name in
            let lower = name.lowercased()
            return lower.hasSuffix(".bin") && (lower.hasPrefix("scph") || lower.hasPrefix("psx"))
        }.sorted()
    }

    static var isPresent: Bool { !installed.isEmpty }

    /// Copies a user-selected BIOS image into the system directory.
    static func install(from url: URL) throws {
        try FileManager.default.createDirectory(at: Paths.system, withIntermediateDirectories: true)
        let destination = Paths.system.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
    }
}
