import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let onLaunch: (Game) -> Void

    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var installer: CoreInstaller
    @State private var search = ""
    @State private var showingSettings = false
    @State private var renaming: Game?
    @State private var renameText = ""
    @StateObject private var converter = ChdConverter()

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 22)]

    private var filtered: [Game] {
        guard !search.isEmpty else { return library.games }
        return library.games.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            if !installer.isInstalled || !BIOS.isPresent {
                setupBanner
            }
            content
        }
        .background(Theme.background)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(item: $renaming) { game in renameSheet(game) }
        .alert("Disc conversion", isPresented: Binding(
            get: { converter.message != nil },
            set: { if !$0 { converter.clear() } })) {
            Button("OK", role: .cancel) { converter.clear() }
        } message: {
            Text(converter.message ?? "")
        }
        .overlay(alignment: .bottom) { conversionProgress }
        .alert("Import failed",
               isPresented: Binding(get: { library.importError != nil },
                                    set: { if !$0 { library.importError = nil } })) {
            Button("OK", role: .cancel) { library.importError = nil }
        } message: {
            Text(library.importError ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PS1Sim").font(.system(size: 19, weight: .semibold))
                Text(library.games.isEmpty ? "No games yet"
                                           : "\(library.games.count) game\(library.games.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            searchField
            Button(action: importGames) {
                Label("Import Game", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .keyboardShortcut("i", modifiers: .command)

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
    }

    private var setupBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(bannerTitle).font(.system(size: 12, weight: .medium))
                Text("Open Settings to finish setup — games will not boot until this is done.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button("Open Settings") { showingSettings = true }.buttonStyle(.bordered)
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
        .background(Color.orange.opacity(0.10))
    }

    private var bannerTitle: String {
        if !installer.isInstalled && !BIOS.isPresent { return "Emulator core and BIOS are missing" }
        if !installer.isInstalled { return "Emulator core is not installed" }
        return "No PlayStation BIOS installed"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if library.games.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(filtered) { game in
                        GameTile(game: game)
                            .onTapGesture(count: 2) { onLaunch(game) }
                            .contextMenu { menu(for: game) }
                            // Dropping an image on a tile sets its cover; the
                            // window-wide handler below imports discs.
                            .onDrop(of: [.image], isTargeted: nil) { providers in
                                loadDroppedCover(providers, for: game)
                                return true
                            }
                    }
                }
                .padding(24)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "opticaldisc")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(Theme.secondaryText)
            Text("Your library is empty").font(.system(size: 17, weight: .medium))
            Text("Import a disc image — .cue, .chd, .pbp or .m3u — or drag one into this window.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button(action: importGames) { Label("Import Game", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for game: Game) -> some View {
        Button("Play") { onLaunch(game) }
        Button("Rename…") { renameText = game.title; renaming = game }
        Menu("Cover") {
            Button("Choose Image…") { chooseArtwork(for: game) }
            Button("Paste from Clipboard") { library.pasteArtwork(for: game) }
            if game.artworkFile != nil {
                Divider()
                Button(game.fitsWholeCover ? "Crop to Fill Tile" : "Show Whole Cover") {
                    library.setCoverShowsWhole(!game.fitsWholeCover, for: game)
                }
                Button("Remove Cover", role: .destructive) { library.removeArtwork(for: game) }
            }
        }
        Divider()
        if ChdConverter.canConvert(game.url) {
            Button("Convert to CHD…") {
                converter.convert(game.url) { chd in library.repoint(game, to: chd) }
            }
            .disabled(converter.isBusy)
        }
        Button("Show Disc in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([game.url])
        }
        Button("Reveal Save States") {
            let directory = Paths.statesDirectory(for: game.id)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        }
        Divider()
        Button("Remove from Library", role: .destructive) { library.remove(game) }
    }

    private func renameSheet(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Game").font(.system(size: 14, weight: .semibold))
            TextField("Title", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 300)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                Button("Save") {
                    library.rename(game, to: renameText)
                    renaming = nil
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var conversionProgress: some View {
        if case .working(let text) = converter.state {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 11.5))
                Text("This takes a few minutes for a full disc.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
            .padding(.bottom, 18)
        }
    }

    // MARK: - Panels

    private func importGames() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose PlayStation disc images you own"
        panel.allowedContentTypes = GameLibrary.discExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { library.addGames(from: panel.urls) }
    }

    private func chooseArtwork(for game: Game) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose cover art — square images fit the tile best"
        if panel.runModal() == .OK, let url = panel.url { library.setArtwork(url, for: game) }
    }

    private func loadDroppedCover(_ providers: [NSItemProvider], for game: Game) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
            guard let image = image as? NSImage else { return }
            Task { @MainActor in library.setArtwork(image, for: game) }
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in library.addGames(from: [url]) }
            }
        }
    }
}

/// One cover in the grid.
struct GameTile: View {
    let game: Game
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                cover
                if hovering {
                    Color.black.opacity(0.42)
                    Image(systemName: "play.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                }
                if !game.fileExists {
                    VStack {
                        Spacer()
                        Text("Disc file missing")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.vertical, 4).frame(maxWidth: .infinity)
                            .background(Color.red.opacity(0.85))
                    }
                }
            }
            // Square, because a PlayStation jewel case insert is square. A fixed
            // height would have drifted out of proportion as the grid resizes.
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
            .shadow(color: .black.opacity(hovering ? 0.45 : 0.22),
                    radius: hovering ? 13 : 7, y: hovering ? 6 : 3)
            .scaleEffect(hovering ? 1.03 : 1.0)

            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(game.playtimeDescription)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
            }
        }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .help("Double-click to play")
    }

    /// The artwork. Covers that are not square are handled two ways: filled and
    /// cropped by default, which is what looks right for real box scans, or shown
    /// whole over a blurred, enlarged copy of themselves so the tile stays full
    /// instead of showing bars.
    @ViewBuilder
    private var cover: some View {
        if let url = game.artworkURL, let image = NSImage(contentsOf: url) {
            if game.fitsWholeCover {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 18)
                        .opacity(0.55)
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                }
            } else {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        } else {
            LinearGradient(colors: [game.accent, game.accent.opacity(0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(game.initials)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
