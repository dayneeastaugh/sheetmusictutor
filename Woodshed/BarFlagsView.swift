//
//  BarFlagsView.swift
//  Woodshed
//
//  The manual "revisit flags" panel: your own notes pinned to bars. Add a flag for
//  a bar, edit or delete it, or tap one to jump the practice section to that bar.
//  Lives in the practice screen's INSPECTOR (Flags tab).
//

import SwiftUI

struct FlagsPanel: View {
    @ObservedObject var session: PracticeSession

    @State private var newBar = 1
    @State private var editorBar: Int?      // non-nil ⇒ editor open for this bar
    @State private var editorNote = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Add a flag
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add a flag").font(.subheadline).bold()
                    Stepper("Bar \(newBar)", value: $newBar, in: 1...session.measureCount)
                        .font(.caption)
                    Button {
                        editorBar = newBar
                        editorNote = session.flagNote(forBar: newBar) ?? ""
                    } label: {
                        Label(session.flagNote(forBar: newBar) == nil ? "Add note for bar \(newBar)…"
                                                                       : "Edit note for bar \(newBar)…",
                              systemImage: "flag")
                    }
                    .font(.caption)
                }

                Divider()

                if session.flags.isEmpty {
                    Text("No flags yet. Add a note above (or tap a ⚑ on the score) to mark a spot to revisit.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Flagged bars").font(.subheadline).bold()
                        ForEach(session.flags) { f in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Button {
                                    session.focusBar(f.bar)
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("Bar \(f.bar)").font(.caption).bold().monospacedDigit()
                                        Text(f.note).font(.caption)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Practise bar \(f.bar)")
                                Spacer()
                                Menu {
                                    Button { session.focusBar(f.bar) } label: { Label("Practise bar \(f.bar)", systemImage: "target") }
                                    Button { editorBar = f.bar; editorNote = f.note } label: { Label("Edit note…", systemImage: "pencil") }
                                    Button(role: .destructive) { session.removeFlag(bar: f.bar) } label: { Label("Delete", systemImage: "trash") }
                                } label: {
                                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                                }
                                .menuIndicator(.hidden).fixedSize()
                                .buttonStyle(.borderless)
                            }
                            Divider()
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { newBar = min(max(1, session.currentBar), session.measureCount) }
        .alert("Flag bar \(editorBar ?? 0)", isPresented: Binding(get: { editorBar != nil },
                                                                  set: { if !$0 { editorBar = nil } })) {
            TextField("Note (e.g. LH jump)", text: $editorNote)
            Button("Save") { if let b = editorBar { session.setFlag(bar: b, note: editorNote) }; editorBar = nil }
            if let b = editorBar, session.flagNote(forBar: b) != nil {
                Button("Delete", role: .destructive) { session.removeFlag(bar: b); editorBar = nil }
            }
            Button("Cancel", role: .cancel) { editorBar = nil }
        } message: {
            Text("A short reminder of what to work on at this bar.")
        }
    }
}
