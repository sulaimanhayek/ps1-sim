import Foundation
import AppKit
import PS1SimKit

/// The persistent list of imported games. Games are referenced in place — importing
/// records a path, it does not copy multi-gigabyte disc images.
@MainActor
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var importError: String?

    static let discExtensions = ["cue", "chd", "pbp", "m3u", "bin", "img", "iso", "exe", "ccd", "toc"]
    /// Recognised only so the import error can say what is actually wrong.
    static let archiveExtensions = ["7z", "zip", "rar", "gz", "tar", "bz2", "xz"]

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
        var resolved: [URL] = []
        for url in urls {
            switch resolveDisc(at: url) {
            case .success(let disc): resolved.append(disc)
            case .failure(let message): importError = message
            }
        }

        var added = 0
        for entry in collapseMultiDisc(resolved) {
            guard !games.contains(where: { $0.path == entry.url.path }) else { continue }
            games.append(Game(title: entry.title, path: entry.url.path))
            added += 1
        }
        if added > 0 {
            games.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            save()
        }
    }

    // MARK: - Multi-disc games

    private struct Entry {
        let url: URL
        let title: String
    }

    /// Turns "Game (Disc 1).cue" and "Game (Disc 2).cue" into a single library
    /// entry backed by a generated .m3u, which is what lets the core swap discs
    /// mid-game. Discs imported one at a time stay separate entries; import them
    /// together to get the playlist.
    private func collapseMultiDisc(_ urls: [URL]) -> [Entry] {
        var order: [String] = []
        var groups: [String: [(disc: Int, url: URL)]] = [:]

        for url in urls {
            let key = DiscTitle.grouping(url)
            if order.firstIndex(of: key) == nil { order.append(key) }
            groups[key, default: []].append((DiscTitle.discNumber(url) ?? 1, url))
        }

        return order.compactMap { title in
            guard let discs = groups[title] else { return nil }
            guard discs.count > 1, Set(discs.map(\.disc)).count == discs.count else {
                // Left alone, a lone disc keeps the name it had on disk.
                return Entry(url: discs[0].url, title: DiscTitle.pretty(discs[0].url))
            }
            let sorted = discs.sorted { $0.disc < $1.disc }.map(\.url)
            guard let playlist = writePlaylist(named: title, discs: sorted) else {
                return Entry(url: sorted[0], title: title)
            }
            return Entry(url: playlist, title: title)
        }
    }




    private func writePlaylist(named title: String, discs: [URL]) -> URL? {
        let safe = title.replacingOccurrences(of: "/", with: "-")
        let url = Paths.playlists.appendingPathComponent("\(safe).m3u")
        // Absolute paths: the discs stay wherever the user keeps them, and the
        // playlist lives in our own directory, so relative paths would not resolve.
        let contents = discs.map(\.path).joined(separator: "\n") + "\n"
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
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
        guard let image = NSImage(contentsOf: imageURL) else {
            importError = "\(imageURL.lastPathComponent) could not be read as an image."
            return
        }
        setArtwork(image, for: game)
    }

    /// Covers are normalised to PNG at a sane size. Box scans run to several
    /// thousand pixels a side, which is wasted on a 220pt tile and slows the grid.
    func setArtwork(_ image: NSImage, for game: Game) {
        guard let index = games.firstIndex(where: { $0.id == game.id }),
              let data = Self.pngData(from: image, maxEdge: 1024) else {
            importError = "That image could not be converted."
            return
        }
        // A fresh filename each time, so SwiftUI cannot show a cached older cover.
        let name = "\(game.id.uuidString)-\(Int(Date().timeIntervalSince1970)).png"
        do {
            try data.write(to: Paths.artwork.appendingPathComponent(name), options: .atomic)
            if let old = games[index].artworkFile {
                try? FileManager.default.removeItem(at: Paths.artwork.appendingPathComponent(old))
            }
            games[index].artworkFile = name
            save()
        } catch {
            importError = "Could not save that cover: \(error.localizedDescription)"
        }
    }

    /// Points an existing entry at a different file — used after converting to CHD,
    /// so play time, cover and save states survive the change.
    func repoint(_ game: Game, to url: URL) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index].path = url.path
        save()
    }

    func removeArtwork(for game: Game) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        if let old = games[index].artworkFile {
            try? FileManager.default.removeItem(at: Paths.artwork.appendingPathComponent(old))
        }
        games[index].artworkFile = nil
        save()
    }

    func setCoverShowsWhole(_ whole: Bool, for game: Game) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index].coverShowsWhole = whole
        save()
    }

    /// Pulls a cover off the clipboard — the usual way people get box art.
    func pasteArtwork(for game: Game) {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?
                .first as? NSImage else {
            importError = "There is no image on the clipboard."
            return
        }
        setArtwork(image, for: game)
    }

    private static func pngData(from image: NSImage, maxEdge: CGFloat) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(source.width), height = CGFloat(source.height)
        let scale = min(1, maxEdge / max(width, height))
        let target = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())

        guard let context = CGContext(data: nil,
                                      width: Int(target.width), height: Int(target.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(origin: .zero, size: target))
        guard let resized = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: resized).representation(using: .png, properties: [:])
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
            if Self.archiveExtensions.contains(ext) {
                return .failure("""
                \(url.lastPathComponent) is a \(ext.uppercased()) archive. \
                Extract it first, then import the .cue or .bin inside it.
                """)
            }
            return .failure("""
            \(url.lastPathComponent) is not a disc image PS1Sim can open. \
            Supported: \(Self.discExtensions.joined(separator: ", ")).
            """)
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

}
