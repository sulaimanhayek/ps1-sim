import Foundation

/// Turning disc filenames into titles, and spotting when several files are
/// discs of one game.
///
/// This is pure string work with no filesystem access, which is why it lives
/// here rather than on `GameLibrary`: it is the part worth testing directly.
public enum DiscTitle {

    /// Filenames carry scene and redump decorations that no one wants to read in
    /// a library: "Final Fantasy VII (USA) (Disc 1) [SLUS-00867].cue".
    public static func pretty(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ",
                                         options: .regularExpression)
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: ".", with: " ")
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? url.lastPathComponent : name
    }

    /// Matches "(Disc 1)", "[Disk 2]", "CD2", "- disc 3".
    ///
    /// The digit count is capped at two deliberately. Without a cap, "Disc 1997"
    /// in a title would read as a disc number, and more importantly a bare year
    /// could make two unrelated files look like discs of one game.
    static let marker = #"[-_ ]*(?:dis[ck]|cd)\s*[-_]?\s*\d{1,2}"#

    /// The title two discs of the same game share.
    ///
    /// `pretty` only strips bracketed decorations, so "Chrono Cross CD1" keeps
    /// its marker and would never group with CD2. This drops the marker wherever
    /// it appears, bracketed or not.
    public static func grouping(_ url: URL) -> String {
        var name = pretty(url)
        name = name.replacingOccurrences(of: marker, with: " ",
                                         options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        // A file named only "Disc 1" would otherwise group under the empty
        // string, dragging in every other such file.
        return trimmed.isEmpty ? pretty(url) : trimmed
    }

    /// The disc number in a filename, or nil if it names no disc.
    public static func discNumber(_ url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let match = name.range(of: marker, options: [.regularExpression, .caseInsensitive]),
              let digits = name[match].range(of: #"\d{1,2}"#, options: .regularExpression) else {
            return nil
        }
        return Int(name[digits])
    }
}
