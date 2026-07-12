//
//  CardPagerView.swift
//  Stereologue
//
//  Horizontally-paging wrapper around CardDetailView that lets the user
//  swipe left/right to browse adjacent cards from the originating grid.
//

import SwiftUI
import Nuke

struct CardPagerView: View {
    let initialCard: StereoCard
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

    @State private var cards: [StereoCard]?
    @State private var currentCardUUID: String?
    @State private var isFavorite = false
    @State private var showWiggleStereo = false
    @State private var shareItem: URL?
    @State private var isGeneratingShare = false
    @State private var shareError: String?
    #if os(visionOS)
    @Environment(SpatialPhotoViewModel.self) private var spatialPhotoViewModel
    @Environment(\.pushWindow) private var pushWindow
    #endif

    init(initialCard: StereoCard) {
        self.initialCard = initialCard
        _currentCardUUID = State(initialValue: initialCard.uuid)
    }

    private var displayCards: [StereoCard] {
        cards ?? [initialCard]
    }

    private var currentCard: StereoCard {
        displayCards.first(where: { $0.uuid == currentCardUUID }) ?? initialCard
    }

    #if os(visionOS)
    private var stereoCards: [StereoCard] {
        displayCards.filter(\.hasStereoDetections)
    }
    #endif

    var body: some View {
        cardContent
        #if !os(visionOS)
            .sheet(isPresented: $showWiggleStereo) {
                NavigationStack {
                    WiggleStereoView(
                        card: currentCard,
                        cropOverride: nil
                    )
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
    }

    // MARK: - Card Pager Content

    @ViewBuilder
    private var cardContent: some View {
        if displayCards.count > 1 {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(displayCards, id: \.uuid) { card in
                        CardDetailView(card: card)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentCardUUID)
            .navigationTitle("")
            .toolbar { cardToolbar(for: currentCard) }
            .onChange(of: currentCardUUID) {
                isFavorite = userDataService.isFavorite(cardUUID: currentCard.uuid)
                prefetchNeighbors()
            }
            .onAppear {
                snapshotContextIfNeeded()
                isFavorite = userDataService.isFavorite(cardUUID: currentCard.uuid)
                prefetchNeighbors()
            }
            .onDisappear { prefetcher.stopPrefetching() }
            #if os(visionOS)
            .onChange(of: spatialPhotoViewModel.currentCardUUID) { _, newUUID in
                guard spatialPhotoViewModel.isPresented,
                      let newUUID,
                      displayCards.contains(where: { $0.uuid == newUUID }) else { return }
                currentCardUUID = newUUID
            }
            #endif
        } else {
            CardDetailView(card: initialCard)
                .navigationTitle("")
                .toolbar { cardToolbar(for: initialCard) }
                .onAppear {
                    snapshotContextIfNeeded()
                    isFavorite = userDataService.isFavorite(cardUUID: initialCard.uuid)
                }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func cardToolbar(for card: StereoCard) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                userDataService.toggleFavorite(cardUUID: card.uuid)
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
            }
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
                    cards: stereoCards,
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
    private static func safeShareFilename(from title: String) -> String {
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

    /// Prefetches the full-resolution front (and back) images of the cards
    /// immediately adjacent to the current one. Uses a bare URL request — the
    /// same one `CardDetailView` renders via `LazyImage(url:)` — so the decoded
    /// image lands under the matching memory-cache key and the swipe reuses it.
    private func prefetchNeighbors() {
        let cards = displayCards
        guard cards.count > 1,
              let index = cards.firstIndex(where: { $0.uuid == currentCardUUID }) else { return }
        let urls = [index - 1, index + 1]
            .filter { cards.indices.contains($0) }
            .flatMap { neighbor -> [URL] in
                let card = cards[neighbor]
                return [
                    card.frontImageURL(quality: "q"),
                    card.backImageURL(quality: "q")
                ].compactMap { $0 }
            }
        prefetcher.startPrefetching(with: urls)
    }

    private func snapshotContextIfNeeded() {
        guard cards == nil else { return }
        let contextCards = cardListContext.cards
        if contextCards.contains(where: { $0.uuid == initialCard.uuid }) {
            cards = contextCards
        } else {
            cards = [initialCard]
        }
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
        CardPagerView(initialCard: PreviewSampleData.sampleCard)
    }
    .previewEnvironment()
    .environment(CardListContext())
}
#endif
