import Foundation

/// Reads a PlayStation memory card image well enough to show what is on it.
///
/// The layout is the documented one: 128 KB split into 16 blocks of 8 KB. Block 0
/// is the directory — 64 frames of 128 bytes, of which frames 1...15 describe
/// blocks 1...15. A save longer than one block chains through the others, so the
/// directory is walked rather than counted.
struct MemoryCard {

    struct Save: Identifiable {
        let id: String
        /// The name the game shows, read from the save itself.
        let title: String
        /// The on-card filename, e.g. "BASLUS-00662PARASITE-EVE".
        let filename: String
        let blocks: Int
    }

    static let blockSize = 8192
    static let blockCount = 16
    static let size = blockSize * blockCount

    let url: URL
    let saves: [Save]
    /// Data blocks in use, out of the 15 a card has for saves.
    let usedBlocks: Int
    var freeBlocks: Int { 15 - usedBlocks }

    /// nil when the file is missing or is not a card image.
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url), data.count >= Self.size else { return nil }
        // A formatted card starts with "MC".
        guard data[0] == 0x4D, data[1] == 0x43 else { return nil }

        self.url = url
        var saves: [Save] = []
        var used = 0

        for slot in 1...15 {
            let entry = slot * 128
            // 0x51 first block of a save, 0x52 a middle link, 0x53 the last. A
            // free block is 0xA0 — but anything else is not "in use" either, and
            // treating it as used is how a half-written card reads as full.
            let state = data[entry]
            guard state == 0x51 || state == 0x52 || state == 0x53 else { continue }
            used += 1
            guard state == 0x51 else { continue }   // only the first block names a save

            let filename = Self.string(data, at: entry + 0x0A, length: 20)
            guard !filename.isEmpty else { continue }
            let byteSize = Int(data[entry + 4]) | Int(data[entry + 5]) << 8
                         | Int(data[entry + 6]) << 16 | Int(data[entry + 7]) << 24
            let blocks = max(1, (byteSize + Self.blockSize - 1) / Self.blockSize)
            saves.append(Save(id: "\(slot)-\(filename)",
                              title: Self.title(data, block: slot) ?? filename,
                              filename: filename,
                              blocks: blocks))
        }

        self.saves = saves
        self.usedBlocks = used
    }

    /// The save's own display name: 64 bytes of Shift-JIS at the start of its block.
    /// Games write their title here, which is what the console's card browser shows.
    private static func title(_ data: Data, block: Int) -> String? {
        let start = block * blockSize + 4
        guard start + 64 <= data.count else { return nil }
        let bytes = data.subdata(in: start..<(start + 64))
        let trimmed = bytes.prefix { $0 != 0 }
        guard !trimmed.isEmpty,
              let text = String(data: Data(trimmed), encoding: .shiftJIS) else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func string(_ data: Data, at offset: Int, length: Int) -> String {
        let bytes = data.subdata(in: offset..<min(offset + length, data.count)).prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Discovery

    static let extensions = ["mcd", "mcr", "mc", "srm", "ps1"]

    /// Every card in the save directory, newest first.
    static func allCards() -> [MemoryCard] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.saves, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .compactMap { MemoryCard(url: $0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    /// Copies the card next to itself with a timestamp, and returns the copy.
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
