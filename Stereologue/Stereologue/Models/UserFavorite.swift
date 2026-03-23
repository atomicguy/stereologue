//
//  UserFavorite.swift
//  Stereologue
//
//  Marks a catalog card as a user favorite.
//  Syncs via CloudKit. References card by UUID string.
//

import Foundation
import SwiftData

@Model
final class UserFavorite {

    var cardUUID: String = ""
    var favoritedAt: Date = Date.now

    init(cardUUID: String = "") {
        self.cardUUID = cardUUID
        self.favoritedAt = .now
    }
}
