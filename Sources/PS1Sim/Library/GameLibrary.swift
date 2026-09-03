import Foundation
import AppKit

/// The persistent list of imported games. Games are referenced in place — importing
/// records a path, it does not copy multi-gigabyte disc images.
@MainActor
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var importError: String?

    static let discExtensions = ["cue", "chd", "pbp", "m3u", "bin", "img", "iso", "exe", "ccd", "toc"]

    init() {
        Paths.createDirectories()
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.libraryFile),
              let decoded = try? JSONDecoder().decode([Game].self, from: data) else { return }
        games = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(games) else { return }
        try? data.write(to: Paths.libraryFile, options: .atomic)
    }

    // MARK: - Mutation

    func addGames(from urls: [URL]) {
        var added = 0
        for url in urls {
            switch resolveDisc(at: url) {
            case .success(let resolved):
                guard !games.contains(where: { $0.path == resolved.path }) else { continue }
                games.append(Game(title: prettyTitle(for: resolved), path: resolved.path))
                added += 1
            case .failure(let message):
                importError = message
            }
        }
        if added > 0 {
            games.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            save()
        }
    }

    func remove(_ game: Game) {
        games.removeAll { $0.id == game.id }
        try? FileManager.default.removeItem(at: Paths.statesDirectory(for: game.id))
        save()
    }

    func rename(_ game: Game, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index].title = trimmed
        games.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        save()
    }

    func setArtwork(_ imageURL: URL, for game: Game) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        let ext = imageURL.pathExtension.isEmpty ? "png" : imageURL.pathExtension
        let name = "\(game.id.uuidString).\(ext)"
        let destination = Paths.artwork.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: imageURL, to: destination)
            games[index].artworkFile = name
            save()
        } catch {
            importError = "Could not copy that image: \(error.localizedDescription)"
        }
    }

    func recordSession(gameID: UUID, seconds: Double) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].playSeconds += seconds
        games[index].lastPlayedAt = Date()
        save()
    }

    // MARK: - Disc resolution

    private enum Resolution {
        case success(URL)
        case failure(String)
    }

    /// Picks the file the core should actually open. A bare .bin gets a generated
    /// .cue so multi-track audio and correct sector sizes still work.
    private func resolveDisc(at url: URL) -> Resolution {
        let ext = url.pathExtension.lowercased()
        guard Self.discExtensions.contains(ext) else {
            return .failure("\(url.lastPathComponent) is not a PlayStation disc image.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure("\(url.lastPathComponent) could not be found.")
        }
        if ext == "bin" || ext == "img" {
            let sibling = url.deletingPathExtension().appendingPathExtension("cue")
            if FileManager.default.fileExists(atPath: sibling.path) { return .success(sibling) }
            if let generated = generateCue(for: url) { return .success(generated) }
        }
        return .success(url)
    }

    private func generateCue(for binURL: URL) -> URL? {
        let cueURL = Paths.generatedCues.appendingPathComponent(
            binURL.deletingPathExtension().lastPathComponent + ".cue")
        let contents = """
        FILE "\(binURL.path)" BINARY
          TRACK 01 MODE2/2352
            INDEX 01 00:00:00

        """
        do {
            try contents.write(to: cueURL, atomically: true, encoding: .utf8)
            return cueURL
        } catch {
            return nil
        }
    }

    private func prettyTitle(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        // Strip the usual scene/redump decorations: "(USA)", "[SLUS-01005]", "Disc 1".
        name = name.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ",
                                         options: .regularExpression)
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: ".", with: " ")
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? url.lastPathComponent : name
    }
}
