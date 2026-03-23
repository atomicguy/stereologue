//
//  UserDataService.swift
//  Stereologue
//
//  Convenience methods for querying user data in the
//  CloudKit-synced container.
//

import Foundation
import SwiftData
import OSLog

@Observable
@MainActor
final class UserDataService {

    private let userContext: ModelContext
    private let logger = Logger(subsystem: "net.atompowered.Stereologue", category: "UserData")

    init(userContext: ModelContext) {
        self.userContext = userContext
    }

    // MARK: - Favorites

    func isFavorite(cardUUID: String) -> Bool {
        let descriptor = FetchDescriptor<UserFavorite>(
            predicate: #Predicate { $0.cardUUID == cardUUID }
        )
        return (try? userContext.fetchCount(descriptor)) ?? 0 > 0
    }

    func toggleFavorite(cardUUID: String) {
        let descriptor = FetchDescriptor<UserFavorite>(
            predicate: #Predicate { $0.cardUUID == cardUUID }
        )

        if let existing = try? userContext.fetch(descriptor).first {
            userContext.delete(existing)
        } else {
            let favorite = UserFavorite(cardUUID: cardUUID)
            userContext.insert(favorite)
        }
    }

    func allFavoriteUUIDs() -> [String] {
        let descriptor = FetchDescriptor<UserFavorite>(
            sortBy: [SortDescriptor(\.favoritedAt, order: .reverse)]
        )
        return (try? userContext.fetch(descriptor).map(\.cardUUID)) ?? []
    }

    // MARK: - Notes

    func notes(for cardUUID: String) -> [UserNote] {
        let descriptor = FetchDescriptor<UserNote>(
            predicate: #Predicate { $0.cardUUID == cardUUID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? userContext.fetch(descriptor)) ?? []
    }

    func addNote(text: String, to cardUUID: String) {
        let note = UserNote(cardUUID: cardUUID, text: text)
        userContext.insert(note)
    }

    func deleteNote(_ note: UserNote) {
        userContext.delete(note)
    }

    // MARK: - Albums

    func allAlbums() -> [UserAlbum] {
        let descriptor = FetchDescriptor<UserAlbum>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? userContext.fetch(descriptor)) ?? []
    }

    func createAlbum(name: String) -> UserAlbum {
        let album = UserAlbum(name: name)
        userContext.insert(album)
        return album
    }

    func deleteAlbum(_ album: UserAlbum) {
        userContext.delete(album)
    }
}
