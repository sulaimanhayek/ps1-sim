import Foundation

/// Converts a .cue/.bin disc image to .chd, which is typically about half the size
/// and lossless — the core reads either.
///
/// The work is done by `chdman`, MAME's tool. PS1Sim does not ship it, because it
/// is a separate GPL project; if it is not installed the UI says how to get it.
@MainActor
final class ChdConverter: ObservableObject {

    enum State: Equatable {
        case idle
        case working(String)
        case finished(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    var isBusy: Bool { if case .working = state { return true }; return false }

    /// The text an alert should show, or nil while there is nothing to report.
    var message: String? {
        switch state {
        case .finished(let text), .failed(let text): return text
        case .idle, .working: return nil
        }
    }

    func clear() { state = .idle }

    /// Homebrew on both architectures, plus anything already on PATH.
    private static let searchPaths = [
        "/opt/homebrew/bin/chdman",
        "/usr/local/bin/chdman",
        "/opt/local/bin/chdman",
    ]

    static var toolURL: URL? {
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "chdman"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        guard (try? which.run()) != nil else { return nil }
        which.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : URL(fileURLWithPath: output)
    }

    static var isAvailable: Bool { toolURL != nil }

    static let installHint = "chdman comes with MAME. Install it with: brew install rom-tools"

    /// Only these are worth converting — a .chd or .pbp is already compressed.
    static func canConvert(_ url: URL) -> Bool {
        ["cue", "bin", "iso", "img", "toc", "ccd"].contains(url.pathExtension.lowercased())
    }

    /// Runs chdman and calls back with the .chd on success. The original is left
    /// alone; deleting several gigabytes is the user's decision, not ours.
    func convert(_ source: URL, completion: @escaping (URL) -> Void) {
        guard let tool = Self.toolURL else {
            state = .failed(Self.installHint)
            return
        }
        let destination = source.deletingPathExtension().appendingPathExtension("chd")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            state = .failed("\(destination.lastPathComponent) already exists.")
            return
        }

        state = .working("Converting \(source.lastPathComponent)…")
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = tool
            process.arguments = ["createcd", "-i", source.path, "-o", destination.path]
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors

            do {
                try process.run()
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
                return
            }
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                                as: UTF8.self)
            process.waitUntilExit()

            let succeeded = process.terminationStatus == 0
                && FileManager.default.fileExists(atPath: destination.path)
            await MainActor.run {
                if succeeded {
                    self.state = .finished("Converted to \(destination.lastPathComponent)")
                    completion(destination)
                } else {
                    // chdman explains itself on stderr; the last line is the reason.
                    let reason = detail.split(whereSeparator: \.isNewline).last.map(String.init)
                        ?? "chdman exited with status \(process.terminationStatus)"
                    try? FileManager.default.removeItem(at: destination)
                    self.state = .failed(reason)
                }
            }
        }
    }
}
