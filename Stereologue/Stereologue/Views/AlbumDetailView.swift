//
//  AlbumDetailView.swift
//  Stereologue
//
//  Grid of cards belonging to a user album, with rename, delete, and
//  remove-card actions. Bridges the user container (album entries) and
//  catalog container (cards).
//

import SwiftUI
import SwiftData

struct AlbumDetailView: View {
    let album: UserAlbum
    @Environment(\.catalogQueryService) private var queryService
    @Environment(UserDataService.self) private var userDataService

    @State private var rows: [CardRow] = []
    @State private var hasLoaded = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        // The tab hosting this view can outlive the album by one render pass
        // after deletion; never touch a deleted model's properties.
        if album.isDeleted {
            Color.clear
        } else {
            content
        }
    }

    private var content: some View {
        Group {
            if hasLoaded {
                CardGridView(
                    rows: rows,
                    emptyTitle: "Empty Album",
                    emptySystemImage: "rectangle.stack",
                    emptyDescription: "Add cards from a card's \"Add to Album\" menu.",
                    removeAction: CardGridRemoveAction(
                        title: "Remove from Album",
                        systemImage: "rectangle.stack.badge.minus"
                    ) { row in
                        userDataService.removeCard(uuid: row.uuid, from: album)
                    }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(album.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename…", systemImage: "pencil") {
                        renameText = album.name
                        showRename = true
                    }
                    Button("Delete Album", systemImage: "trash", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                } label: {
                    Label("Album Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Album", isPresented: $showRename) {
            TextField("Album name", text: $renameText)
            Button("Rename") { userDataService.renameAlbum(album, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(album.name)”?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) {
                userDataService.deleteAlbum(album)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cards themselves stay in the catalog and in any other album.")
        }
        // Keyed on the album's card list, so the grid refetches when cards are
        // added or removed. The catalog lookup runs off the main actor.
        .task(id: album.cardUUIDs) {
            rows = await queryService?.cardRows(uuids: album.cardUUIDs) ?? []
            hasLoaded = true
        }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        AlbumDetailView(album: PreviewSampleData.sampleAlbum)
    }
    .previewEnvironment()
}
#endif
