//
//  BarFlagsView.swift
//  Woodshed
//
//  The manual "revisit flags" sheet: your own notes pinned to bars. Add a flag for a
//  bar, edit or delete it, or tap one to jump the practice section to that bar.
//  Presented from the practice screen's More menu.
//

import SwiftUI

struct BarFlagsView: View {
    @ObservedObject var session: PracticeSession
    @Environment(\.dismiss) private var dismiss

    @State private var newBar = 1
    @State private var editorBar: Int?      // non-nil ⇒ editor open for this bar
    @State private var editorNote = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Add a flag") {
                    Stepper("Bar \(newBar)", value: $newBar, in: 1...session.measureCount)
                    Button {
                        editorBar = newBar
                        editorNote = session.flagNote(forBar: newBar) ?? ""
                    } label: {
                        Label(session.flagNote(forBar: newBar) == nil ? "Add note for bar \(newBar)…"
                                                                       : "Edit note for bar \(newBar)…",
                              systemImage: "flag")
                    }
                }

                Section(session.flags.isEmpty ? "" : "Flagged bars") {
                    if session.flags.isEmpty {
                        Text("No flags yet. Add a note above (or tap a flag on the score) to mark a spot to revisit.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(session.flags) { f in
                        HStack(spacing: 10) {
                            Button {
                                session.focusBar(f.bar); dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Text("Bar \(f.bar)").bold().monospacedDigit()
                                        .frame(minWidth: 56, alignment: .leading)
                                    Text(f.note).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Menu {
                                flagActions(f)
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                            }
                            .menuIndicator(.hidden).fixedSize()
                        }
                        .contextMenu { flagActions(f) }
                        .swipeActions { Button("Delete", role: .destructive) { session.removeFlag(bar: f.bar) } }
                    }
                }
            }
            .navigationTitle("Flags")
            .toolbar { Button("Done") { dismiss() } }
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
        .frame(minWidth: 460, minHeight: 480)
        .onAppear { newBar = min(max(1, session.currentBar), session.measureCount) }
    }

    @ViewBuilder
    private func flagActions(_ f: BarFlag) -> some View {
        Button { session.focusBar(f.bar); dismiss() } label: { Label("Practise bar \(f.bar)", systemImage: "target") }
        Button { editorBar = f.bar; editorNote = f.note } label: { Label("Edit note…", systemImage: "pencil") }
        Button(role: .destructive) { session.removeFlag(bar: f.bar) } label: { Label("Delete", systemImage: "trash") }
    }
}
