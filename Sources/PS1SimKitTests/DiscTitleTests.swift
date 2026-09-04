import Foundation
import PS1SimKit

/// Filename parsing. Both bugs this guards against were real: multi-disc games
/// silently failing to group, and unrelated games grouping when they should not.
func runDiscTitleTests() {
    func url(_ name: String) -> URL { URL(fileURLWithPath: "/games/\(name)") }

    Check.suite("DiscTitle.pretty — strips scene decorations") {
        Check.equal(DiscTitle.pretty(url("Final Fantasy VII (USA) (Disc 1) [SLUS-00867].cue")),
                    "Final Fantasy VII", "brackets and parens go")
        Check.equal(DiscTitle.pretty(url("Metal_Gear_Solid.cue")),
                    "Metal Gear Solid", "underscores become spaces")
        Check.equal(DiscTitle.pretty(url("Tekken 3.chd")), "Tekken 3", "a clean name is left alone")
        // Stripping everything would leave an empty label in the library.
        Check.equal(DiscTitle.pretty(url("(USA).cue")), "(USA).cue", "falls back when nothing remains")
    }

    Check.suite("DiscTitle.discNumber — finds the disc") {
        Check.equal(DiscTitle.discNumber(url("Game (Disc 2).cue")), 2, "(Disc 2)")
        Check.equal(DiscTitle.discNumber(url("Game [Disk 3].cue")), 3, "[Disk 3] — k spelling")
        Check.equal(DiscTitle.discNumber(url("Chrono Cross CD1.cue")), 1, "bare CD1")
        Check.equal(DiscTitle.discNumber(url("Game - disc 4.bin")), 4, "dash separated")
        Check.equal(DiscTitle.discNumber(url("GAME (DISC 2).cue")), 2, "case insensitive")
        Check.isNil(DiscTitle.discNumber(url("Tekken 3.chd")), "a trailing numeral is not a disc")
        Check.isNil(DiscTitle.discNumber(url("Gran Turismo 2.cue")), "nor is a sequel number")
    }

    Check.suite("DiscTitle.grouping — same game, different discs") {
        // The bug that shipped: these two produced different keys and never grouped.
        Check.equal(DiscTitle.grouping(url("Chrono Cross CD1.cue")),
                    DiscTitle.grouping(url("Chrono Cross CD2.cue")), "CD1 and CD2 agree")
        Check.equal(DiscTitle.grouping(url("Final Fantasy VII (USA) (Disc 1).cue")),
                    DiscTitle.grouping(url("Final Fantasy VII (USA) (Disc 3).cue")),
                    "bracketed discs agree")
        Check.equal(DiscTitle.grouping(url("Chrono Cross CD1.cue")), "Chrono Cross", "key is readable")

        // The opposite failure matters just as much: unrelated games merging into
        // one entry would make a game unlaunchable.
        Check.check(DiscTitle.grouping(url("Tekken 3.chd")) != DiscTitle.grouping(url("Tekken 2.chd")),
                    "sequels stay separate")
        Check.check(DiscTitle.grouping(url("Gran Turismo 2.cue")) != DiscTitle.grouping(url("Gran Turismo.cue")),
                    "a numbered sequel is not disc 2")
        Check.equal(DiscTitle.grouping(url("Disc 1.cue")), "Disc 1",
                    "a file named only for its disc keeps a key of its own")
    }
}
