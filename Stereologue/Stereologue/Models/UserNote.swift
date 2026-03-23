//
//  UserNote.swift
//  Stereologue
//
//  A user-authored note/comment attached to a catalog card.
//  Syncs via CloudKit. References card by UUID string.
//

import Foundation
import SwiftData

@Model
final class UserNote {

    var id: UUID = UUID()
    var cardUUID: String = ""
    var text: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        cardUUID: String = "",
        text: String = ""
    ) {
        self.id = UUID()
        self.cardUUID = cardUUID
        self.text = text
        self.createdAt = .now
        self.updatedAt = .now
    }
}
