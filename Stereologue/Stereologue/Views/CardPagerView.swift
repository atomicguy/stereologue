//
//  CardPagerView.swift
//  Stereologue
//
//  Horizontally-paging wrapper around CardDetailView that lets the user
//  swipe left/right to browse adjacent cards from the originating grid.
//
//  The pager works in `CardRow`s (a Sendable value per card). Only the page
//  actually on screen — and its toolbar — resolves the full `StereoCard`
//  model, by an indexed UUID fetch, so entering the pager from a 41K-row
//  grid costs the same as from a 10-row one.
//

import SwiftUI
import SwiftData
import Nuke

struct CardPagerView: View {
    let initialRow: CardRow
    @Environment(\.modelContext) private var modelContext
    @Environment(CardListContext.self) private var cardListContext
    @Environment(UserDataService.self) private var userDataService
    @Environment(\.spatialPhotoService) private var spatialPhotoService

    // Warm the adjacent cards' full-res images into the memory cache so a swipe
    // reveals them without a fresh download/decode. `.memoryCache` (the default)
    // performs the expensive decode ahead of display, unlike `.diskCache`.
    @State private var prefetcher = ImagePrefetcher(
        pipeline: .shared,
        destination: .memoryCache
    )

    /// Snapshot of the originating grid's rows, taken once on first appearance
    /// so the pager isn't disturbed by the grid loading further pages.
    @State private var rows: [CardRow]?
    @State private var indexByUUID: [String: Int] = [:]
    @State private var currentCardUUID: String?
    /// The full model for the page on screen; drives the toolbar and sharing.
    @State private var currentCard: StereoCard?
    @State private var isFavorite = false
    @State private var showWiggleStereo = false
    @State private var shareItem: URL?
    @State private var isGeneratingShare = false
    @State private var shareError: String?
    @State private var showNewAlbum = false
    @State private var newAlbumName = ""
    #if os(visionOS)
    @Environment(SpatialPhotoViewModel.self) private var spatialPhotoViewModel
    @Environment(\.pushWindow) private var pushWindow
    #endif

    init(initialRow: CardRow) {
        self.initialRow = initialRow
        _currentCardUUID = State(initialValue: initialRow.uuid)
    }

    private var displayRows: [CardRow] {
        rows ?? [initialRow]
    }

    private var currentIndex: Int? {
        currentCardUUID.flatMap { indexByUUID[$0] }
    }

    var body: some View {
        cardContent
            .navigationTitle("")
            .toolbar {
                if let currentCard {
                    cardToolbar(for: currentCard)
                }
            }
            .onAppear {
                snapshotContextIfNeeded()
                resolveCurrentCard()
                prefetchNeighbors()
            }
            .onChange(of: currentCardUUID) {
                resolveCurrentCard()
                prefetchNeighbors()
            }
            .onDisappear { prefetcher.stopPrefetching() }
            #if os(visionOS)
            .onChange(of: spatialPhotoViewModel.currentCardUUID) { _, newUUID in
                guard spatialPhotoViewModel.isPresented,
                      let newUUID,
                      indexByUUID[newUUID] != nil else { return }
                currentCardUUID = newUUID
            }
            #endif
            #if !os(visionOS)
            .sheet(isPresented: $showWiggleStereo) {
                if let currentCard {
                    NavigationStack {
                        WiggleStereoView(
                            card: currentCard,
                            cropOverride: userDataService.cropOverride(for: currentCard.uuid)
                        )
                    }
                }
            }
            #endif
            #if canImport(UIKit)
            .sheet(isPresented: .init(
                get: { shareItem != nil },
                set: { if !$0 { shareItem = nil } }
            )) {
                if let url = shareItem {
                    ShareSheet(items: [url])
                }
            }
            #endif
            .alert("Share Error", isPresented: .init(
                get: { shareError != nil },
                set: { if !$0 { shareError = nil } }
            )) {
                Button("OK") { shareError = nil }
            } message: {
                Text(shareError ?? "")
            }
            .alert("New Album", isPresented: $showNewAlbum) {
                TextField("Album name", text: $newAlbumName)
                Button("Create") {
                    guard let uuid = currentCardUUID else { return }
                    let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let album = userDataService.createAlbum(name: name.isEmpty ? "New Album" : name)
                    userDataService.addCard(uuid: uuid, to: album)
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    // MARK: - Card Pager Content

    @ViewBuilder
    private var cardContent: some View {
        if displayRows.count > 1 {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(displayRows, id: \.uuid) { row in
                        CardPage(uuid: row.uuid)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentCardUUID)
        } else {
            CardPage(uuid: initialRow.uuid)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func cardToolbar(for card: StereoCard) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isFavorite = userDataService.toggleFavorite(cardUUID: card.uuid)
            } label: {
                Label(isFavorite ? "Unfavorite" : "Favorite",
                      systemImage: isFavorite ? "heart.fill" : "heart")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            albumMenu(for: card)
        }
        if card.hasStereoDetections {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    generateAndShare(for: card)
                } label: {
                    if isGeneratingShare {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Share Spatial Photo", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isGeneratingShare || spatialPhotoService == nil)
            }
        }
        #if os(visionOS)
        ToolbarItem(placement: .primaryAction) {
            Button {
                spatialPhotoViewModel.present(
                    rows: displayRows.filter(\.hasStereoDetections),
                    initialCardUUID: card.uuid
                )
                pushWindow(id: "spatial-photo")
            } label: {
                Label("View in Stereo", systemImage: "cube.transparent")
            }
            .disabled(!card.hasStereoDetections)
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            Button {
                showWiggleStereo = true
            } label: {
                Label("View in Stereo", systemImage: "cube.transparent")
            }
            .disabled(!card.hasStereoDetections)
        }
        #endif
    }

    // MARK: - Albums

    /// Toggles the card's membership in each album, and offers to start a new
    /// album containing it.
    private func albumMenu(for card: StereoCard) -> some View {
        Menu {
            ForEach(userDataService.albums, id: \.id) { album in
                Toggle(album.name, isOn: Binding(
                    get: { album.containsCard(uuid: card.uuid) },
                    set: { include in
                        if include {
                            userDataService.addCard(uuid: card.uuid, to: album)
                        } else {
                            userDataService.removeCard(uuid: card.uuid, from: album)
                        }
                    }
                ))
            }
            if !userDataService.albums.isEmpty {
                Divider()
            }
            Button("New Album…", systemImage: "plus") {
                newAlbumName = ""
                showNewAlbum = true
            }
        } label: {
            Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
        }
    }

    // MARK: - Sharing

    private func generateAndShare(for card: StereoCard) {
        guard let service = spatialPhotoService else { return }
        // Snapshot all model data on MainActor before crossing the actor boundary.
        let cropOverride = userDataService.cropOverride(for: card.uuid)
        let cardData = card.spatialPhotoData(cropOverride: cropOverride)
        let metadata = SpatialPhotoMetadata(
            title: card.title,
            creator: card.creator?.name,
            date: card.displayDate,
            subjects: card.subjects.map(\.name),
            places: card.places.map(\.name)
        )
        let shareTitle = card.title
        isGeneratingShare = true
        Task {
            do {
                let cacheURL = try await service.shareableSpatialPhotoURL(
                    for: cardData,
                    metadata: metadata
                )
                // Copy to temp directory with a descriptive filename
                // so the share system can access it and Photos recognizes the type
                let safeName = Self.safeShareFilename(from: shareTitle)
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SharePhotos", isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: tempDir, withIntermediateDirectories: true
                )
                let shareURL = tempDir.appendingPathComponent("\(safeName).heic")
                try? FileManager.default.removeItem(at: shareURL)
                try FileManager.default.copyItem(at: cacheURL, to: shareURL)
                #if canImport(AppKit)
                Self.presentMacSharePicker(url: shareURL)
                #else
                shareItem = shareURL
                #endif
            } catch {
                shareError = error.localizedDescription
            }
            isGeneratingShare = false
        }
    }

    #if canImport(AppKit)
    /// Presents the system share menu anchored to the key window's content view.
    /// Bypasses SwiftUI's sheet so the macOS share menu pops out of the window
    /// directly instead of inside a dimmed modal that can only be dismissed with Escape.
    @MainActor
    private static func presentMacSharePicker(url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }
        let bounds = contentView.bounds
        let topY = contentView.isFlipped ? bounds.minY : bounds.maxY
        let anchor = NSRect(x: bounds.maxX - 80, y: topY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
    }
    #endif

    /// Produces a filesystem-safe name without quotes, punctuation, or trailing
    /// periods so LaunchServices and the share system can resolve the URL.
    static func safeShareFilename(from title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let stripped = title.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
        let collapsed = stripped
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let trimmed = String(collapsed.prefix(80))
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Spatial Photo" : trimmed
    }

    // MARK: - Helpers

    /// Resolves the on-screen page's model by indexed UUID fetch and refreshes
    /// the favorite state. Cheap: one row by unique index.
    private func resolveCurrentCard() {
        guard let uuid = currentCardUUID else { return }
        if currentCard?.uuid != uuid {
            currentCard = modelContext.cards(matching: [uuid]).first
        }
        isFavorite = userDataService.isFavorite(cardUUID: uuid)
    }

    /// Prefetches the full-resolution front (and back) images of the cards
    /// immediately adjacent to the current one. The front uses the same bare
    /// URL request `CardDetailView` renders, so the decoded image lands under
    /// the matching memory-cache key and the swipe reuses it.
    private func prefetchNeighbors() {
        let rows = displayRows
        guard rows.count > 1, let index = currentIndex else { return }
        let urls = [index - 1, index + 1]
            .filter { rows.indices.contains($0) }
            .compactMap { rows[$0].frontImageURL(quality: "q") }
        prefetcher.startPrefetching(with: urls)
    }

    private func snapshotContextIfNeeded() {
        guard rows == nil else { return }
        if cardListContext.index(of: initialRow.uuid) != nil {
            rows = cardListContext.rows
            indexByUUID = cardListContext.indexByUUID
        } else {
            rows = [initialRow]
            indexByUUID = [initialRow.uuid: 0]
        }
    }
}

// MARK: - Card Page

/// One page of the pager. Resolves its `StereoCard` by indexed UUID when it
/// comes on screen, so off-screen pages never fault a model.
private struct CardPage: View {
    let uuid: String
    @Environment(\.modelContext) private var modelContext
    @State private var card: StereoCard?

    var body: some View {
        Group {
            if let card {
                CardDetailView(card: card)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { resolve() }
        .onChange(of: uuid) { resolve() }
    }

    private func resolve() {
        guard card?.uuid != uuid else { return }
        card = modelContext.cards(matching: [uuid]).first
    }
}

// MARK: - Share Sheet

import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Build NSItemProviders with a registered HEIC file representation so
        // the share extension can actually load the file on visionOS. A bare
        // UIActivityItemSource that returns just a URL trips a LaunchServices
        // binding failure ("Only support loading options for CKShare and SWY
        // types") on visionOS and crashes libdispatch.
        let activityItems: [Any] = items.map { item -> Any in
            if let url = item as? URL, url.isFileURL {
                let provider = NSItemProvider()
                provider.suggestedName = url.deletingPathExtension().lastPathComponent
                // Register the broader image type first so Photos's share
                // extension activation rule (which filters on public.image)
                // recognizes the item, then HEIC for spatial-aware targets.
                for typeID in [UTType.image.identifier, UTType.heic.identifier] {
                    provider.registerFileRepresentation(
                        forTypeIdentifier: typeID,
                        fileOptions: [],
                        visibility: .all
                    ) { completion in
                        completion(url, false, nil)
                        return nil
                    }
                }
                return provider
            }
            return item
        }
        return UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#if canImport(AppKit)
import AppKit
#endif

#if DEBUG
#Preview(traits: .fixedLayout(width: 700, height: 800)) {
    NavigationStack {
        CardPagerView(initialRow: CardRow(PreviewSampleData.sampleCard))
    }
    .previewEnvironment()
}
#endif
