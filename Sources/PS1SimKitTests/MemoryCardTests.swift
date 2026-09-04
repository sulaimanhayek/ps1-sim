import Foundation
import PS1SimKit

/// Builds card images in memory so the format handling can be checked without
/// anyone's real save data.
struct CardBuilder {
    var data = Data(repeating: 0, count: MemoryCardImage.size)

    init() {
        data[0] = 0x4D; data[1] = 0x43          // "MC"
        for slot in 1...15 { data[slot * 128] = 0xA0 }   // every block free
    }

    /// Writes a save occupying `blocks` blocks starting at `slot`, chaining the
    /// directory entries the way the console does: 0x51, then 0x52…, then 0x53.
    mutating func addSave(slot: Int, filename: String, title: String, blocks: Int) {
        let byteSize = blocks * MemoryCardImage.blockSize
        for offset in 0..<blocks {
            let entry = (slot + offset) * 128
            data[entry] = blocks == 1 ? 0x51
                        : (offset == 0 ? 0x51 : (offset == blocks - 1 ? 0x53 : 0x52))
            if offset == 0 {
                data[entry + 4] = UInt8(byteSize & 0xFF)
                data[entry + 5] = UInt8((byteSize >> 8) & 0xFF)
                data[entry + 6] = UInt8((byteSize >> 16) & 0xFF)
                data[entry + 7] = UInt8((byteSize >> 24) & 0xFF)
                for (i, byte) in Array(filename.utf8).enumerated() where i < 20 {
                    data[entry + 0x0A + i] = byte
                }
            }
        }
        let titleAt = slot * MemoryCardImage.blockSize + 4
        for (i, byte) in Array(title.utf8).enumerated() where i < 64 {
            data[titleAt + i] = byte
        }
    }

    mutating func setState(slot: Int, _ byte: UInt8) { data[slot * 128] = byte }
}

func runMemoryCardTests() {
    Check.suite("MemoryCardImage — rejects what is not a card") {
        Check.isNil(MemoryCardImage(data: Data()), "empty data")
        Check.isNil(MemoryCardImage(data: Data(repeating: 0, count: 1024)), "too short")
        Check.isNil(MemoryCardImage(data: Data(repeating: 0, count: MemoryCardImage.size)),
                    "right size but no MC signature")
    }

    Check.suite("MemoryCardImage — an empty formatted card") {
        let card = MemoryCardImage(data: CardBuilder().data)
        Check.equal(card?.usedBlocks, 0, "nothing used")
        Check.equal(card?.freeBlocks, 15, "all 15 free")
        Check.equal(card?.saves.count, 0, "no saves")
    }

    Check.suite("MemoryCardImage — reads saves and block counts") {
        var builder = CardBuilder()
        builder.addSave(slot: 1, filename: "BASLUS-00662PARASITE", title: "PARASITE EVE  ACT1", blocks: 1)
        builder.addSave(slot: 2, filename: "BASLUS-00594FF8-S01", title: "FINAL FANTASY VIII", blocks: 2)
        let card = MemoryCardImage(data: builder.data)

        Check.equal(card?.usedBlocks, 3, "one single plus one double block")
        Check.equal(card?.freeBlocks, 12, "the rest are free")
        Check.equal(card?.saves.count, 2, "two saves, not three — links are not saves")
        Check.equal(card?.saves.first?.title, "PARASITE EVE  ACT1", "title read from the block")
        Check.equal(card?.saves.first?.filename, "BASLUS-00662PARASITE", "filename read from the directory")
        Check.equal(card?.saves.last?.blocks, 2, "a two-block save reports two")
    }

    // The bug that shipped: any byte other than 0xA0 counted as in use, so a
    // zeroed or half-written card reported almost full.
    Check.suite("MemoryCardImage — only real states count as used") {
        var builder = CardBuilder()
        builder.addSave(slot: 1, filename: "TESTSAVE", title: "TEST", blocks: 1)
        for slot in 5...15 { builder.setState(slot: slot, 0x00) }   // never written
        let card = MemoryCardImage(data: builder.data)
        Check.equal(card?.usedBlocks, 1, "zeroed blocks are free, not used")
        Check.equal(card?.freeBlocks, 14, "and are reported as free")
    }

    Check.suite("MemoryCardImage — a save with no filename is skipped") {
        var builder = CardBuilder()
        builder.setState(slot: 1, 0x51)   // marked used, but nothing written
        let card = MemoryCardImage(data: builder.data)
        Check.equal(card?.usedBlocks, 1, "the block is still counted as used")
        Check.equal(card?.saves.count, 0, "but it is not listed as a save")
    }

    Check.suite("MemoryCardImage — a longer card still reads") {
        var builder = CardBuilder()
        builder.addSave(slot: 1, filename: "TESTSAVE", title: "TEST", blocks: 1)
        // Some dumps carry a trailing header or padding.
        let card = MemoryCardImage(data: builder.data + Data(repeating: 0, count: 64))
        Check.equal(card?.saves.count, 1, "trailing bytes are ignored")
    }
}
