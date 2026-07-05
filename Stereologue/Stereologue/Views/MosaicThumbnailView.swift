//
//  MosaicThumbnailView.swift
//  Stereologue
//
//  A 2×2 mosaic of card thumbnails used in browse lists.
//

import SwiftUI
import SwiftData
import Nuke
import NukeUI

/// One cell of a thumbnail mosaic. Reports load completion (success *or*
/// failure) via `onResolved` so the enclosing mosaic can show a loading
/// indicator until every expected image has resolved.
private struct MosaicCell: View {
    let url: URL?
    let onResolved: () -> Void

    var body: some View {
        if let url {
            LazyImage(request: BrowseMosaicItem.thumbnailRequest(for: url)) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(.systemFill)
                }
            }
            .priority(.normal)
            .onCompletion { _ in onResolved() }
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            Color(.systemFill)
        }
    }
}

/// A 2×2 grid of up to four card thumbnails. Shows a progress indicator until
/// every non-empty cell has finished loading — so a four-image tile waits for
/// all four, while a one-image tile only waits for the one. `isLoadingPreview`
/// keeps the indicator up while the preview URLs themselves are still being
/// fetched (before any cell exists).
private struct MosaicGrid: View {
    let imageURLs: [URL]
    var isLoadingPreview: Bool = false

    @State private var resolvedCount = 0

    private var expectedCount: Int { min(imageURLs.count, 4) }
    private var isLoading: Bool { isLoadingPreview || resolvedCount < expectedCount }

    var body: some View {
        let urls = Array(imageURLs.prefix(4))

        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                cell(urls, 0)
                cell(urls, 1)
            }
            GridRow {
                cell(urls, 2)
                cell(urls, 3)
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        // Reset the counter whenever the underlying images change (e.g. the tile
        // is reused for a different entity), so the indicator tracks the new set.
        .onChange(of: imageURLs) { resolvedCount = 0 }
    }

    @ViewBuilder
    private func cell(_ urls: [URL], _ index: Int) -> some View {
        MosaicCell(url: urls.indices.contains(index) ? urls[index] : nil) {
            if resolvedCount < expectedCount { resolvedCount += 1 }
        }
    }
}

/// A standalone 2×2 mosaic for a fixed set of cards.
struct MosaicThumbnailView: View {
    let cards: [StereoCard]

    private let mosaicSize: CGFloat = 80

    var body: some View {
        MosaicGrid(imageURLs: cards.compactMap { $0.frontImageURL(quality: "t") })
            .frame(width: mosaicSize, height: mosaicSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Browse List Cell

/// A browse-list grid cell: a 2×2 thumbnail mosaic with a card-count badge and
/// a title, used by the Subjects/Creators/Places/Collections lists.
///
/// The count is passed in from the entity's denormalized `cardCount` (no query),
/// and the four preview images come from a bounded fetch run on the background
/// `CatalogQueryService` so scrolling never blocks on SwiftData.
struct BrowseMosaicItem: View {
    let title: String
    let count: Int
    let cardPredicate: Predicate<StereoCard>
    let queryService: CatalogQueryService?

    @State private var previewImageURLs: [URL] = []
    @State private var isLoadingPreview = true

    private let aspectRatio: CGFloat = 1.6

    /// The Nuke request used to load a mosaic cell.
    ///
    /// Shared by `BrowseMosaicGrid`'s prefetcher so the prefetched, decoded, and
    /// resized image lands in the memory cache under the *same* key the cell
    /// requests. Sources the 150px IIIF rendition (`t`, chosen upstream); the
    /// `.pixels` unit avoids the screen-scale multiplication that
    /// `.resize(width:)` applies by default.
    static func thumbnailRequest(for url: URL) -> ImageRequest {
        ImageRequest(url: url, processors: [.resize(width: 150, unit: .pixels)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    MosaicGrid(
                        imageURLs: previewImageURLs,
                        isLoadingPreview: isLoadingPreview
                    )
                }
                .overlay(alignment: .bottomTrailing) { countBadge }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                #if os(iOS) || os(visionOS)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
                .hoverEffect(.lift)
                #endif

            Text(title)
                .font(.caption)
                .lineLimit(2)
        }
        .task(id: title) { await load() }
    }

    private func load() async {
        guard let queryService else {
            isLoadingPreview = false
            return
        }
        isLoadingPreview = true
        previewImageURLs = await queryService.previewImageURLs(matching: cardPredicate)
        isLoadingPreview = false
    }

    private var countBadge: some View {
        Text("\(count)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)
    }
}

// MARK: - Browse Mosaic Grid

/// A browse grid of entities rendered as mosaic tiles, with image prefetching
/// for upcoming rows (mirrors `CardGridView`). Each list — Subjects, Creators,
/// Places, Collections — supplies its entities plus a title, a denormalized
/// count key path, and a card predicate.
struct BrowseMosaicGrid<Entity: Hashable>: View {
    let entities: [Entity]
    let id: KeyPath<Entity, String>
    let title: (Entity) -> String
    let count: KeyPath<Entity, Int>
    let predicate: (Entity) -> Predicate<StereoCard>

    @Environment(\.catalogQueryService) private var queryService
    // Prefetch into the memory cache (the default) so mosaics appear decoded:
    // .diskCache would only download bytes and skip the expensive decode/resize.
    @State private var prefetcher = ImagePrefetcher(
        pipeline: .shared,
        destination: .memoryCache
    )
    // Entities whose preview images have already been queued for prefetch, so
    // repeated `onAppear` callbacks don't re-run the bounded preview fetch.
    @State private var prefetchedKeys: Set<String> = []

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(entities, id: id) { entity in
                    NavigationLink(value: entity) {
                        BrowseMosaicItem(
                            title: title(entity),
                            count: entity[keyPath: count],
                            cardPredicate: predicate(entity),
                            queryService: queryService
                        )
                        .onAppear { prefetchAhead(from: entity) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .onDisappear { prefetcher.stopPrefetching() }
    }

    /// Warms the memory cache with preview images for the next several entities
    /// so their mosaics are decoded before they scroll into view. The bounded
    /// fetches run on the background `CatalogQueryService`.
    private func prefetchAhead(from entity: Entity) {
        guard let queryService else { return }
        guard let index = entities.firstIndex(of: entity) else { return }
        let range = (index + 1)..<min(index + 7, entities.count)
        guard !range.isEmpty else { return }

        let upcoming = entities[range].filter { !prefetchedKeys.contains($0[keyPath: id]) }
        guard !upcoming.isEmpty else { return }
        upcoming.forEach { prefetchedKeys.insert($0[keyPath: id]) }
        let predicates = upcoming.map { predicate($0) }

        Task { @MainActor in
            var requests: [ImageRequest] = []
            for predicate in predicates {
                let urls = await queryService.previewImageURLs(matching: predicate)
                requests += urls.map { BrowseMosaicItem.thumbnailRequest(for: $0) }
            }
            guard !requests.isEmpty else { return }
            prefetcher.startPrefetching(with: requests)
        }
    }
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    MosaicThumbnailView(cards: PreviewSampleData.sampleCards)
        .padding()
        .previewEnvironment()
}
#endif
