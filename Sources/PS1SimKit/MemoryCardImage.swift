import Foundation

/// Reads a PlayStation memory card image well enough to show what is on it.
///
/// The layout is the documented one: 128 KB split into 16 blocks of 8 KB. Block 0
/// is the directory — 64 frames of 128 bytes, of which frames 1...15 describe
/// blocks 1...15. A save longer than one block chains through the others, so the
/// directory is walked rather than counted.
///
/// This parses bytes and nothing else. Finding cards on disk and backing them up
/// live in the app, so that the format handling can be tested against images
/// built in memory.
public struct MemoryCardImage {

    public struct Save: Identifiable, Equatable {
        public let id: String
        /// The name the game shows, read from the save itself.
        public let title: String
        /// The on-card filename, e.g. "BASLUS-00662PARASITE-EVE".
        public let filename: String
        public let blocks: Int
    }

    public static let blockSize = 8192
    public static let blockCount = 16
    public static let size = blockSize * blockCount
    /// One block is the directory, so 15 are left for saves.
    public static let dataBlocks = blockCount - 1

    public let saves: [Save]
    /// Data blocks in use, out of the 15 a card has for saves.
    public let usedBlocks: Int
    public var freeBlocks: Int { Self.dataBlocks - usedBlocks }

    /// nil when the data is too short or is not a formatted card.
    public init?(data: Data) {
        guard data.count >= Self.size else { return nil }
        // A formatted card starts with "MC".
        guard data[data.startIndex] == 0x4D,
              data[data.startIndex + 1] == 0x43 else { return nil }

        var saves: [Save] = []
        var used = 0

        for slot in 1...Self.dataBlocks {
            let entry = slot * 128
            // 0x51 first block of a save, 0x52 a middle link, 0x53 the last. A
            // free block is 0xA0 — but anything else is not "in use" either, and
            // treating it as used is how a half-written card reads as full.
            let state = data[data.startIndex + entry]
            guard state == 0x51 || state == 0x52 || state == 0x53 else { continue }
            used += 1
            guard state == 0x51 else { continue }   // only the first block names a save

            let filename = Self.string(data, at: entry + 0x0A, length: 20)
            guard !filename.isEmpty else { continue }
            let byteSize = Self.uint32(data, at: entry + 4)
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
    static func title(_ data: Data, block: Int) -> String? {
        let start = block * blockSize + 4
        guard start + 64 <= data.count else { return nil }
        let bytes = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + 64))
        let trimmed = bytes.prefix { $0 != 0 }
        guard !trimmed.isEmpty,
              let text = String(data: Data(trimmed), encoding: .shiftJIS) else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Little-endian, as the console wrote it.
    static func uint32(_ data: Data, at offset: Int) -> Int {
        let base = data.startIndex + offset
        return Int(data[base]) | Int(data[base + 1]) << 8
             | Int(data[base + 2]) << 16 | Int(data[base + 3]) << 24
    }

    static func string(_ data: Data, at offset: Int, length: Int) -> String {
        let start = data.startIndex + offset
        let end = min(start + length, data.endIndex)
        guard start < end else { return "" }
        let bytes = data.subdata(in: start..<end).prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
