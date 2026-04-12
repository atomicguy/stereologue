//
//  Collection.swift
//  Stereologue
//
//  Created on 4/11/26.
//

import Foundation
import SwiftData

@Model
final class Collection {
    
    #Unique<Collection>([\.name])
    #Index<Collection>([\.name])
    
    var name: String
    
    // Inverse relationship - SwiftData manages this automatically
    @Relationship(inverse: \StereoCard.collection)
    var cards: [StereoCard] = []
    
    // Efficient count without loading all cards
    var cardCount: Int {
        cards.count
    }
    
    init(name: String) {
        self.name = name
    }
}
