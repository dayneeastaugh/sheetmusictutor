//
//  ContentView.swift
//  Woodshed
//
//  App root: a NavigationSplitView with the song library as the sidebar and the
//  practice screen as the detail. This is the Mac/iPad shell — on iPad the sidebar
//  collapses into a slide-over; on Mac it's a persistent left column. Selecting a
//  song in the sidebar loads it into the detail pane. See docs/DESIGN.md.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var library = SongLibrary()
    // Selection is by song *id* (stable across rename/favourite edits, which mint a
    // new Song value with the same id) so editing metadata never drops the detail.
    @State private var selection: Song.ID?

    var body: some View {
        NavigationSplitView {
            LibraryView(library: library, selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            if let id = selection, let song = library.songs.first(where: { $0.id == id }) {
                PracticeView(song: song, library: library)
                    .id(song.id)   // new song ⇒ fresh PracticeSession; a rename keeps it
            } else {
                ContentUnavailableView("Select a song",
                                       systemImage: "pianokeys",
                                       description: Text("Pick a song from the library to practise, or tap + to import one."))
            }
        }
    }
}

struct LibraryView: View {
    @ObservedObject var library: SongLibrary
    @Binding var selection: Song.ID?
    // Guided two-step import: pick the score (MusicXML/.mxl), then the MIDI. The old
    // single picker required multi-selecting both files at once — undiscoverable.
    // ONE .fileImporter drives both steps: SwiftUI gives a view a single file-importer
    // presentation slot, so attaching two modifiers means the first never presents.
    private enum ImportStep { case score, midi }
    @State private var importStep: ImportStep = .score
    @State private var showImporter = false
    @State private var pendingScoreURL: URL?
    @State private var importError: String?
    @State private var renameTarget: Song?
    @State private var renameText = ""

    /// Step 1 file types: MusicXML, uncompressed or .mxl (MuseScore's default export).
    private var scoreTypes: [UTType] {
        var t: [UTType] = [.xml]
        if let x = UTType(filenameExtension: "musicxml") { t.append(x) }
        if let z = UTType(filenameExtension: "mxl") { t.append(z) }
        return t
    }
    /// Step 2 file types: standard MIDI.
    private var midiTypes: [UTType] {
        var t: [UTType] = [.midi]
        if let m = UTType(filenameExtension: "mid") { t.append(m) }
        return t
    }

    var body: some View {
        List(selection: $selection) {
            if library.songs.isEmpty {
                Text("No songs yet. Tap + to import a MusicXML + MIDI pair.")
                    .foregroundStyle(.secondary)
            }
            ForEach(library.songs) { song in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).font(.headline)
                        Text(rowSubtitle(song))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if song.meta.favourite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    // Explicit per-row menu — works by click on Mac and tap on iPad
                    // (swipe-to-delete is iPad-only, so we don't rely on it).
                    Menu {
                        songActions(song)
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .buttonStyle(.borderless)
                }
                .tag(song.id)
                .contextMenu { songActions(song) }
                .swipeActions {
                    Button("Delete", role: .destructive) { library.delete(song) }
                }
            }
            if library.unreadableFolderCount > 0 {
                Label("\(library.unreadableFolderCount) song folder(s) couldn't be read",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .navigationTitle("Library")
        .toolbar {
            Button {
                importStep = .score
                showImporter = true
            } label: { Label("Add song", systemImage: "plus") }
        }
        // One importer, two steps: score first, then (re-presented) the MIDI.
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importStep == .score ? scoreTypes : midiTypes,
                      allowsMultipleSelection: false) { result in
            switch importStep {
            case .score:
                if case .success(let urls) = result, let url = urls.first {
                    pendingScoreURL = url
                    importStep = .midi
                    // Re-present after the panel has fully dismissed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { showImporter = true }
                }
            case .midi:
                let midiURL: URL? = { if case .success(let urls) = result { return urls.first }; return nil }()
                if let midiURL, let xmlURL = pendingScoreURL {
                    performImport(musicXML: xmlURL, midi: midiURL)
                }
                pendingScoreURL = nil
                importStep = .score
            }
        }
        .alert("Import", isPresented: Binding(get: { importError != nil },
                                              set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .alert("Rename song", isPresented: Binding(get: { renameTarget != nil },
                                                   set: { if !$0 { renameTarget = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { saveRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    /// Row actions, shared by the ⋯ menu and the right-click/long-press context menu.
    @ViewBuilder
    private func songActions(_ song: Song) -> some View {
        Button("Rename…") { renameTarget = song; renameText = song.title }
        Button(song.meta.favourite ? "Remove favourite" : "Favourite") { toggleFavourite(song) }
        Button("Delete", role: .destructive) { library.delete(song) }
    }

    /// Row subtitle: practice status once there's history, else the date added.
    private func rowSubtitle(_ song: Song) -> String {
        if let last = song.meta.lastPracticed {
            var s = "Practiced \(last.formatted(date: .abbreviated, time: .omitted))"
            if let best = song.meta.bestAccuracy { s += " · best \(Int(best * 100))%" }
            return s
        }
        return "Added \(song.meta.dateAdded.formatted(date: .abbreviated, time: .omitted))"
    }

    private func toggleFavourite(_ song: Song) {
        var meta = song.meta
        meta.favourite.toggle()
        library.update(meta, in: song.folder)
    }

    private func saveRename() {
        guard let song = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            var meta = song.meta
            meta.title = name
            library.update(meta, in: song.folder)
        }
        renameTarget = nil
    }

    /// Import the picked pair. Validated by actually fusing it: a pair that can't be
    /// parsed is rejected (and removed) with a clear error, and a pair that parses
    /// but doesn't reconcile cleanly is imported with an up-front warning — never
    /// silently, so practice is never graded against a wrong model unannounced.
    private func performImport(musicXML xml: URL, midi mid: URL) {
        do {
            let song = try library.importSong(musicXML: xml, midi: mid)
            // Validate the copied pair by fusing it (same path the practice screen uses).
            do {
                let fused = try Ingest.fuse(midiData: try Data(contentsOf: song.midiURL),
                                            musicXMLData: try Data(contentsOf: song.musicXMLURL))
                if let warning = PracticeSession.warningText(for: fused) {
                    importError = "Imported “\(song.title)” with a warning:\n\n\(warning)"
                }
            } catch {
                library.delete(song)   // unusable pair — don't leave it in the library
                importError = "Couldn't import: the files aren't a readable MusicXML + MIDI pair (\(error))."
            }
        } catch {
            importError = "Couldn't import: \(error)"
        }
    }
}
