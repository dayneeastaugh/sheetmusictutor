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
                PracticeView(song: song)
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
    @State private var showImporter = false
    @State private var importError: String?
    @State private var renameTarget: Song?
    @State private var renameText = ""

    /// File types the importer offers (MusicXML + MIDI).
    private var importTypes: [UTType] {
        var t: [UTType] = [.xml, .midi]
        if let x = UTType(filenameExtension: "musicxml") { t.append(x) }
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
                        Text("Added \(song.meta.dateAdded.formatted(date: .abbreviated, time: .omitted))")
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
        }
        .navigationTitle("Library")
        .toolbar {
            Button { showImporter = true } label: { Label("Add song", systemImage: "plus") }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importTypes,
                      allowsMultipleSelection: true) { result in
            handleImport(result)
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

    /// Pick out the MusicXML and MIDI from the chosen files and import them.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let xml = urls.first { ["musicxml", "xml"].contains($0.pathExtension.lowercased()) }
        let mid = urls.first { ["mid", "midi"].contains($0.pathExtension.lowercased()) }
        guard let xml, let mid else {
            importError = "Select one MusicXML (.musicxml/.xml) file and one MIDI (.mid) file together."
            return
        }
        do { try library.importSong(musicXML: xml, midi: mid) }
        catch { importError = "Couldn't import: \(error.localizedDescription)" }
    }
}
