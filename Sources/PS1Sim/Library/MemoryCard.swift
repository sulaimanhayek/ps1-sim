import Foundation
import PS1SimKit

/// A memory card file on disk: where it is, what it holds, and backing it up.
/// The format itself is parsed by `MemoryCardImage` in PS1SimKit.
struct MemoryCard {

    typealias Save = MemoryCardImage.Save

    let url: URL
    private let image: MemoryCardImage

    var saves: [Save] { image.saves }
    var usedBlocks: Int { image.usedBlocks }
    var freeBlocks: Int { image.freeBlocks }

    /// nil when the file is missing or is not a card image.
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let image = MemoryCardImage(data: data) else { return nil }
        self.url = url
        self.image = image
    }

    // MARK: - Discovery

    static let extensions = ["mcd", "mcr", "mc", "srm", "ps1"]

    /// Every card in the save directory.
    static func allCards() -> [MemoryCard] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.saves, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .compactMap { MemoryCard(url: $0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    /// Copies the card into the backup folder with a timestamp, and returns the copy.
    @discardableResult
    func backUp() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "\(url.deletingPathExtension().lastPathComponent) \(stamp).\(url.pathExtension)"
        let destination = Paths.cardBackups.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: Paths.cardBackups,
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
