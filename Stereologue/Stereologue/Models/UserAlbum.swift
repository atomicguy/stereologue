//
//  UserAlbum.swift
//  Stereologue
//
//  User-created grouping of stereoview cards.
//  Syncs via CloudKit. References cards by UUID string,
//  NOT by SwiftData relationship (cross-container).
//

import Foundation
import SwiftData

@Model
final class UserAlbum {

    var id: UUID = UUID()
    var name: String = ""
    var albumDescription: String = ""

    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \UserAlbumEntry.album)
    var entries: [UserAlbumEntry] = []

    var coverCardUUID: String?

    init(
        name: String = "",
        albumDescription: String = "",
        coverCardUUID: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.albumDescription = albumDescription
        self.coverCardUUID = coverCardUUID
        self.createdAt = .now
        self.updatedAt = .now
    }
}

extension UserAlbum {

    /// Ordered list of card UUIDs in this album.
    var cardUUIDs: [String] {
        entries
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.cardUUID)
    }

    var cardCount: Int {
        entries.count
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    func addCard(uuid: String) {
        guard !entries.contains(where: { $0.cardUUID == uuid }) else { return }
        let maxOrder = entries.map(\.sortOrder).max() ?? -1
        let entry = UserAlbumEntry(cardUUID: uuid, sortOrder: maxOrder + 1)
        entries.append(entry)
        updatedAt = .now
    }

    func removeCard(uuid: String) {
        entries.removeAll { $0.cardUUID == uuid }
        updatedAt = .now
    }

    func containsCard(uuid: String) -> Bool {
        entries.contains { $0.cardUUID == uuid }
    }
}
