//
//  ModelContext+Cards.swift
//  Stereologue
//
//  Bridges the user container (which references cards by UUID string) and the
//  catalog container (which stores the cards themselves).
//

import Foundation
import SwiftData

extension ModelContext {
    /// Fetches the catalog cards for the given `uuids`, preserving their order.
    ///
    /// The UUID match is pushed into the store (uuid is indexed) rather than
    /// loading the whole 41K-card catalog and filtering in memory. Results are
    /// returned in the same order as `uuids`, so caller-defined orderings
    /// (favorited-at, album sort) are respected.
    func cards(matching uuids: [String]) -> [StereoCard] {
        guard !uuids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<StereoCard>(
            predicate: #Predicate { uuids.contains($0.uuid) }
        )
        let matched = (try? fetch(descriptor)) ?? []
        let orderMap = Dictionary(uniqueKeysWithValues: uuids.enumerated().map { ($1, $0) })
        return matched.sorted { (orderMap[$0.uuid] ?? 0) < (orderMap[$1.uuid] ?? 0) }
    }
}
