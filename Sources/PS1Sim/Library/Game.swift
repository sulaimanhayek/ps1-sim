import Foundation
import SwiftUI

struct Game: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    /// Path handed to the core: a .cue/.chd/.pbp/.m3u, never a bare .bin.
    var path: String
    var addedAt: Date
    var lastPlayedAt: Date?
    var playSeconds: Double
    /// Filename inside Paths.artwork, if the user picked cover art.
    var artworkFile: String?
    /// Show the whole cover inside the square tile instead of cropping it to fill.
    /// Optional so a library written before covers were adjustable still decodes.
    var coverShowsWhole: Bool?

    init(title: String, path: String) {
        self.id = UUID()
        self.title = title
        self.path = path
        self.addedAt = Date()
        self.playSeconds = 0
    }

    var url: URL { URL(fileURLWithPath: path) }
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }

    var artworkURL: URL? {
        artworkFile.map { Paths.artwork.appendingPathComponent($0) }
    }

    var fitsWholeCover: Bool { coverShowsWhole ?? false }

    /// Deterministic accent colour derived from the title, for the placeholder cover.
    var accent: Color {
        var hash: UInt64 = 5381
        for byte in title.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.55, brightness: 0.62)
    }

    var initials: String {
        let words = title.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }

    var playtimeDescription: String {
        if playSeconds < 60 { return "Never played" }
        let minutes = Int(playSeconds / 60)
        if minutes < 60 { return "\(minutes) min played" }
        return String(format: "%.1f hrs played", playSeconds / 3600)
    }
}
