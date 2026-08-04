import SwiftUI
import EncoreCore

/// Rename / re-describe / re-scope an owned playlist via InnerTube edit_playlist.
/// (YouTube Music auto-generates playlist art — custom art isn't supported.)
struct PlaylistEditSheet: View {
    let playlistId: String
    @State var title: String
    @State var description: String
    var onSaved: (String, String) -> Void
    /// Called after a successful delete so the page can navigate away.
    var onDeleted: (() -> Void)? = nil

    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var privacy = "KEEP"
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Playlist").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)

            field("Name") {
                TextField("Playlist name", text: $title).textFieldStyle(.roundedBorder)
            }
            field("Description") {
                TextEditor(text: $description)
                    .font(.system(size: 13)).frame(height: 76)
                    .scrollContentBackground(.hidden)
                    .padding(6).background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
            }
            field("Privacy") {
                Picker("", selection: $privacy) {
                    Text("Keep current").tag("KEEP")
                    Text("Private").tag("PRIVATE")
                    Text("Public").tag("PUBLIC")
                    Text("Unlisted").tag("UNLISTED")
                }.pickerStyle(.menu).labelsHidden().fixedSize()
            }

            Text("YouTube Music auto-generates playlist artwork — custom art isn't supported for regular playlists.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }

            HStack {
                Button("Delete Playlist…", role: .destructive) { confirmingDelete = true }
                    .disabled(saving)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.bgElevated)
        .alert("Delete “\(title)”?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deletePlaylist() }
        } message: {
            Text("This removes the playlist from your YouTube Music account for good — it can't be undone. The songs stay in your library.")
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func save() {
        saving = true; error = nil
        let name = title.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = (try? await YTM.shared.editPlaylist(
                playlistId: playlistId, title: name, description: description,
                privacy: privacy == "KEEP" ? nil : privacy)) ?? false
            saving = false
            if ok {
                onSaved(name, description)
                player.showToast("Playlist updated")
                LibraryStore.shared.invalidate()
                dismiss()
            } else {
                error = "Couldn't save — you can only edit your own playlists."
            }
        }
    }

    private func deletePlaylist() {
        saving = true; error = nil
        Task {
            let ok = (try? await YTM.shared.deletePlaylist(playlistId: playlistId)) ?? false
            saving = false
            if ok {
                player.showToast("Deleted “\(title)”")
                PageCache.shared.collections["playlist-\(playlistId)"] = nil
                LibraryStore.shared.invalidate()
                onDeleted?()
                dismiss()
            } else {
                error = "Couldn't delete — you can only delete your own playlists."
            }
        }
    }
}
