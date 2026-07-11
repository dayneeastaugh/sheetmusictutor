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
    // Each file dialog is preceded by a short prompt saying what to pick (a bare
    // NSOpenPanel gives no context), and each dialog is opened by an explicit button
    // press — no timing-dependent auto-re-presenting. ONE .fileImporter drives both
    // steps: SwiftUI gives a view a single file-importer presentation slot.
    private enum ImportStep { case score, midi }
    @State private var importStep: ImportStep = .score
    @State private var importPrompt: ImportStep?   // non-nil → the step's guidance alert is up
    @State private var showImporter = false
    @State private var pendingScoreURL: URL?
    @State private var importError: String?
    @State private var renameTarget: Song?
    @State private var renameText = ""
    @State private var tagsTarget: Song?
    @State private var tagsText = ""
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .title
    @State private var showOverview = false

    private enum SortOrder: String, CaseIterable, Identifiable {
        case title = "Title", lastPracticed = "Last practised", best = "Best score"
        var id: String { rawValue }
    }

    /// The library filtered by the search field (title + tags) and sorted.
    private var visibleSongs: [Song] {
        var songs = library.songs
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            songs = songs.filter { s in
                s.title.lowercased().contains(q)
                    || (s.meta.tags ?? []).contains { $0.lowercased().contains(q) }
            }
        }
        switch sortOrder {
        case .title:
            return songs   // library storage order is already title-sorted
        case .lastPracticed:
            return songs.sorted { ($0.meta.lastPracticed ?? .distantPast) > ($1.meta.lastPracticed ?? .distantPast) }
        case .best:
            return songs.sorted { ($0.meta.bestAccuracy ?? -1) > ($1.meta.bestAccuracy ?? -1) }
        }
    }

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
            ForEach(visibleSongs) { song in
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
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search titles and tags")
        .toolbar {
            Button { showOverview = true } label: { Label("Practice overview", systemImage: "chart.bar.doc.horizontal") }
                .help("Totals and what's most due across all songs")
            Menu {
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            Button { importPrompt = .score } label: { Label("Add song", systemImage: "plus") }
        }
        .sheet(isPresented: $showOverview) { PracticeOverviewView(library: library) }
        // The per-step guidance: says what to pick before the (context-free) file dialog.
        .alert(importPrompt == .score ? "Import a song — step 1 of 2" : "Step 2 of 2 — the MIDI",
               isPresented: Binding(get: { importPrompt != nil },
                                    set: { if !$0 { importPrompt = nil } })) {
            if importPrompt == .score {
                Button("Choose score…") { importStep = .score; importPrompt = nil; showImporter = true }
                Button("Cancel", role: .cancel) { importPrompt = nil }
            } else {
                Button("Choose MIDI…") { importStep = .midi; importPrompt = nil; showImporter = true }
                Button("Cancel", role: .cancel) { pendingScoreURL = nil; importPrompt = nil }
            }
        } message: {
            Text(importPrompt == .score
                 ? "Choose the score exported from MuseScore (.musicxml, .xml or .mxl). You'll choose the matching MIDI (.mid) next."
                 : "Now choose the MIDI (.mid) exported from the same piece"
                   + (pendingScoreURL.map { " as “\($0.lastPathComponent)”." } ?? "."))
        }
        // One importer, two steps; each opened from the guidance alert above.
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importStep == .score ? scoreTypes : midiTypes,
                      allowsMultipleSelection: false) { result in
            switch importStep {
            case .score:
                if case .success(let urls) = result, let url = urls.first {
                    pendingScoreURL = url
                    importPrompt = .midi       // guide into step 2
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
        .alert("Tags", isPresented: Binding(get: { tagsTarget != nil },
                                            set: { if !$0 { tagsTarget = nil } })) {
            TextField("jazz, recital, hard", text: $tagsText)
            Button("Save") { saveTags() }
            Button("Cancel", role: .cancel) { tagsTarget = nil }
        } message: { Text("Comma-separated labels — searchable from the library search field.") }
    }

    /// Row actions, shared by the ⋯ menu and the right-click/long-press context menu.
    @ViewBuilder
    private func songActions(_ song: Song) -> some View {
        Button("Rename…") { renameTarget = song; renameText = song.title }
        Button("Edit tags…") { tagsTarget = song; tagsText = (song.meta.tags ?? []).joined(separator: ", ") }
        Button(song.meta.favourite ? "Remove favourite" : "Favourite") { toggleFavourite(song) }
        Button("Delete", role: .destructive) { library.delete(song) }
    }

    private func saveTags() {
        guard let song = tagsTarget else { return }
        var meta = song.meta
        let tags = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        meta.tags = tags.isEmpty ? nil : tags
        library.update(meta, in: song.folder)
        tagsTarget = nil
    }

    /// Row subtitle: practice status once there's history, else the date added; + tags.
    private func rowSubtitle(_ song: Song) -> String {
        var s: String
        if let last = song.meta.lastPracticed {
            s = "Practiced \(last.formatted(date: .abbreviated, time: .omitted))"
            if let best = song.meta.bestAccuracy { s += " · best \(Int(best * 100))%" }
        } else {
            s = "Added \(song.meta.dateAdded.formatted(date: .abbreviated, time: .omitted))"
        }
        if let tags = song.meta.tags, !tags.isEmpty {
            s += " · " + tags.map { "#\($0)" }.joined(separator: " ")
        }
        return s
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
