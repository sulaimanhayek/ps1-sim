import Foundation

/// Disc labels for the Discs menu, read from an .m3u when there is one.
public enum Playlist {
    /// - Parameter count: how many discs the core actually mounted. The core is
    ///   the authority, not the file: a playlist listing five discs the core
    ///   refused still shows only what is really there, and a short or missing
    ///   playlist is padded rather than dropping discs off the menu.
    public static func labels(for url: URL, count: Int) -> [String] {
        var names: [String] = []
        if url.pathExtension.lowercased() == "m3u",
           let text = try? String(contentsOf: url, encoding: .utf8) {
            names = parse(text)
        }
        return (0..<count).map { index in
            names.indices.contains(index) ? names[index] : "Disc \(index + 1)"
        }
    }

    /// Split out from `labels` so it can be tested without writing a file.
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }
}
