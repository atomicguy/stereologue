//
//  UserAlbumEntry.swift
//  Stereologue
//
//  A single entry in a UserAlbum, referencing a catalog card by UUID.
//  Separate model (rather than [String] on UserAlbum) to support
//  sort order and per-entry metadata.
//

import Foundation
import SwiftData

@Model
final class UserAlbumEntry {

    var cardUUID: String = ""
    var sortOrder: Int = 0
    var addedAt: Date = Date.now
    var album: UserAlbum?

    init(
        cardUUID: String = "",
        sortOrder: Int = 0
    ) {
        self.cardUUID = cardUUID
        self.sortOrder = sortOrder
        self.addedAt = .now
    }
}
