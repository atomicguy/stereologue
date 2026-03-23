//
//  Place.swift
//  Stereologue
//
//  Normalized geographic subject model (~1,350 unique).
//  Many-to-many: a card has multiple places, a place has many cards.
//

import Foundation
import SwiftData

@Model
final class Place {

    #Unique<Place>([\.name])

    #Index<Place>([\.name])

    var name: String

    @Relationship(inverse: \StereoCard.places)
    var cards: [StereoCard] = []

    var cardCount: Int {
        cards.count
    }

    init(name: String = "") {
        self.name = name
    }
}
