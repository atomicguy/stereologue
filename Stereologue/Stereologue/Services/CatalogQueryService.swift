//
//  CatalogQueryService.swift
//  Stereologue
//
//  Background catalog queries that keep SwiftData work off the main actor.
//
//  Browsing lists (Subjects/Creators/Places/Collections) render mosaic tiles
//  whose preview images come from bounded fetches. Running those on the main
//  `ModelContext` hitches scrolling, so this `@ModelActor` owns its own context
//  on a background executor and returns only Sendable values (image URLs).
//

import Foundation
import SwiftData

/// A browse entity that keeps a denormalized count of its related cards.
/// Class-bound and `nonisolated` so the count can be updated through the
/// background `@ModelActor` (the project defaults to MainActor isolation).
protocol CardCountable: AnyObject {
    nonisolated var cardCount: Int { get set }
    nonisolated var cards: [StereoCard] { get }
}

extension Subject: CardCountable {}
extension Creator: CardCountable {}
extension Place: CardCountable {}
extension Collection: CardCountable {}

@ModelActor
actor CatalogQueryService {

    /// Returns every distinct `yearStart` with its card count, sorted ascending.
    ///
    /// Scans the (indexed) `yearStart` column across the whole catalog — a large
    /// fetch that would hitch the main actor — and returns Sendable value types.
    func yearCounts() -> [YearGroup] {
        var descriptor = FetchDescriptor<StereoCard>(
            predicate: #Predicate { $0.yearStart != nil },
            sortBy: [SortDescriptor(\.yearStart)]
        )
        descriptor.propertiesToFetch = [\.yearStart]
        let years = (try? modelContext.fetch(descriptor))?.compactMap(\.yearStart) ?? []

        let byYear = Dictionary(grouping: years) { $0 }
        return byYear.keys.sorted().map { YearGroup(year: $0, count: byYear[$0]!.count) }
    }

    /// Returns up to `limit` front-image URLs for cards matching `predicate`,
    /// running the fetch on this actor's background context.
    func previewImageURLs(
        matching predicate: Predicate<StereoCard>,
        quality: String = "t",
        limit: Int = 4
    ) -> [URL] {
        var descriptor = FetchDescriptor<StereoCard>(predicate: predicate)
        descriptor.fetchLimit = limit
        let cards = (try? modelContext.fetch(descriptor)) ?? []
        return cards.compactMap { $0.frontImageURL(quality: quality) }
    }

    /// Populates the denormalized `cardCount` on every browse entity. Intended
    /// to run once per install (guarded by the caller); faults each entity's
    /// relationship a single time, so it is deliberately off the main actor.
    func backfillCardCounts() throws {
        try backfill(Subject.self)
        try backfill(Creator.self)
        try backfill(Place.self)
        try backfill(Collection.self)
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    private func backfill<T>(_ type: T.Type) throws
    where T: PersistentModel & CardCountable {
        let items = try modelContext.fetch(FetchDescriptor<T>())
        for item in items {
            let actual = item.cards.count
            if item.cardCount != actual {
                item.cardCount = actual
            }
        }
    }
}
