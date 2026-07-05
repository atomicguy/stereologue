//
//  Collection.swift
//  Stereologue
//
//  Created on 4/11/26.
//

import Foundation
import SwiftData

// `nonisolated` so the model is readable from `CatalogQueryService`'s
// background `@ModelActor` context (the project defaults to MainActor).
@Model
nonisolated final class Collection {
    
    #Unique<Collection>([\.name])
    #Index<Collection>([\.name])
    
    var name: String
    
    // Inverse relationship - SwiftData manages this automatically
    @Relationship(inverse: \StereoCard.collection)
    var cards: [StereoCard] = []

    /// Denormalized count of related cards. Populated at import/migration and
    /// backfilled on first launch (see `CatalogQueryService`), so browse tiles
    /// can show the badge without an unbounded per-tile count query.
    var cardCount: Int = 0

    init(name: String) {
        self.name = name
    }
}
