import Foundation
import PS1SimKit

func runPlaylistTests() {
    Check.suite("Playlist.parse — reads .m3u lines") {
        let text = """
        # Chrono Cross
        /games/Chrono Cross CD1.cue
        /games/Chrono Cross CD2.cue

        """
        Check.equal(Playlist.parse(text), ["Chrono Cross CD1", "Chrono Cross CD2"],
                    "comments and blank lines are dropped, extensions stripped")
        Check.equal(Playlist.parse(""), [], "an empty playlist yields nothing")
        Check.equal(Playlist.parse("#only a comment"), [], "comments alone yield nothing")
        Check.equal(Playlist.parse("  /games/A.cue  "), ["A"], "surrounding whitespace is trimmed")
    }

    Check.suite("Playlist.labels — the core decides how many") {
        let missing = URL(fileURLWithPath: "/nope/none.m3u")
        Check.equal(Playlist.labels(for: missing, count: 2), ["Disc 1", "Disc 2"],
                    "an unreadable playlist still labels every disc")
        Check.equal(Playlist.labels(for: URL(fileURLWithPath: "/games/A.cue"), count: 1),
                    ["Disc 1"], "a plain .cue is not parsed as a playlist")
        Check.equal(Playlist.labels(for: missing, count: 0), [], "no discs, no labels")
    }
}
