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

/// Errors that can occur during user data operations.
enum UserDataError: LocalizedError {
    case fetchFailed(String, Error)
    case saveFailed(Error)
    case deleteFailed(Error)
    case contextUnavailable
    
    var errorDescription: String? {
        switch self {
        case .fetchFailed(let operation, let error):
            return "Failed to fetch \(operation): \(error.localizedDescription)"
        case .saveFailed(let error):
            return "Failed to save changes: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "Failed to delete item: \(error.localizedDescription)"
        case .contextUnavailable:
            return "Database context is not available"
        }
    }
}

@Observable
@MainActor
final class UserDataService {

    private let userContext: ModelContext
    private let logger = Logger(subsystem: "net.atompowered.Stereologue", category: "UserData")

    /// The most recent error that occurred, if any.
    /// Views can observe this to show error alerts.
    private(set) var lastError: UserDataError?

    /// Albums, sorted most-recently-updated first. Kept in sync with the user
    /// container via SwiftData's `didSave` notification, so SwiftUI views that
    /// read this property re-render whenever albums change — including from
    /// CloudKit sync.
    ///
    /// `@Query` would be the natural fit here, but `@Query` reads from
    /// `\.modelContext`, which this app reserves for the *catalog* container.
    /// The user container lives behind `\.userModelContext`, so this service
    /// publishes the reactive list itself.
    private(set) var albums: [UserAlbum] = []

    /// Favorited card UUIDs, most-recently-favorited first. Kept in sync with
    /// the user container via the same `didSave` observer as `albums`, so views
    /// reading it re-render whenever favorites change — including CloudKit sync.
    /// This is what makes the Favorites grid update after favoriting elsewhere.
    private(set) var favoriteUUIDs: [String] = []

    /// Held only so it's discoverable; the observer is never torn down because
    /// `UserDataService` lives for the entire app lifetime.
    private var didSaveObservation: NSObjectProtocol?

    /// Clears the last error. Call this after displaying an error to the user.
    func clearLastError() {
        lastError = nil
    }

    init(userContext: ModelContext) {
        self.userContext = userContext
        refreshAlbums()
        refreshFavorites()
        didSaveObservation = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: userContext,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAlbums()
                self?.refreshFavorites()
            }
        }
    }

    private func refreshAlbums() {
        do {
            let descriptor = FetchDescriptor<UserAlbum>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            albums = try userContext.fetch(descriptor)
        } catch {
            logger.error("Failed to refresh albums: \(error)")
            lastError = .fetchFailed("albums", error)
        }
    }

    private func refreshFavorites() {
        do {
            let descriptor = FetchDescriptor<UserFavorite>(
                sortBy: [SortDescriptor(\.favoritedAt, order: .reverse)]
            )
            favoriteUUIDs = try userContext.fetch(descriptor).map(\.cardUUID)
        } catch {
            logger.error("Failed to refresh favorites: \(error)")
            lastError = .fetchFailed("favorites", error)
        }
    }

    // MARK: - Favorites

    func isFavorite(cardUUID: String) -> Bool {
        do {
            let descriptor = FetchDescriptor<UserFavorite>(
                predicate: #Predicate { $0.cardUUID == cardUUID }
            )
            return try userContext.fetchCount(descriptor) > 0
        } catch {
            logger.error("Failed to check favorite status for \(cardUUID): \(error)")
            lastError = .fetchFailed("favorite status", error)
            return false
        }
    }

    func toggleFavorite(cardUUID: String) {
        do {
            let descriptor = FetchDescriptor<UserFavorite>(
                predicate: #Predicate { $0.cardUUID == cardUUID }
            )

            if let existing = try userContext.fetch(descriptor).first {
                userContext.delete(existing)
                logger.debug("Removed favorite: \(cardUUID)")
            } else {
                let favorite = UserFavorite(cardUUID: cardUUID)
                userContext.insert(favorite)
                logger.debug("Added favorite: \(cardUUID)")
            }
            
            try saveContext()
        } catch let error as UserDataError {
            lastError = error
        } catch {
            logger.error("Failed to toggle favorite for \(cardUUID): \(error)")
            lastError = .fetchFailed("favorites", error)
        }
    }

    // MARK: - Notes

    func notes(for cardUUID: String) -> [UserNote] {
        do {
            let descriptor = FetchDescriptor<UserNote>(
                predicate: #Predicate { $0.cardUUID == cardUUID },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            return try userContext.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch notes for \(cardUUID): \(error)")
            lastError = .fetchFailed("notes", error)
            return []
        }
    }

    func addNote(text: String, to cardUUID: String) {
        do {
            let note = UserNote(cardUUID: cardUUID, text: text)
            userContext.insert(note)
            try saveContext()
            logger.debug("Added note to \(cardUUID)")
        } catch let error as UserDataError {
            lastError = error
        } catch {
            logger.error("Failed to add note to \(cardUUID): \(error)")
            lastError = .saveFailed(error)
        }
    }

    func deleteNote(_ note: UserNote) {
        do {
            userContext.delete(note)
            try saveContext()
            logger.debug("Deleted note")
        } catch let error as UserDataError {
            lastError = error
        } catch {
            logger.error("Failed to delete note: \(error)")
            lastError = .deleteFailed(error)
        }
    }

    // MARK: - Crop Overrides

    func cropOverride(for cardUUID: String) -> UserCropOverride? {
        do {
            let descriptor = FetchDescriptor<UserCropOverride>(
                predicate: #Predicate { $0.cardUUID == cardUUID },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            let matches = try userContext.fetch(descriptor)
            // With no DB-level unique constraint (unsupported under CloudKit),
            // a sync merge can produce duplicates. Keep the newest and drop the
            // rest; the deletes persist on the next save.
            if matches.count > 1 {
                for duplicate in matches.dropFirst() {
                    userContext.delete(duplicate)
                }
            }
            return matches.first
        } catch {
            logger.error("Failed to fetch crop override for \(cardUUID): \(error)")
            lastError = .fetchFailed("crop override", error)
            return nil
        }
    }

    func saveCropOverride(
        cardUUID: String,
        leftDetection: ImageDetection,
        rightDetection: ImageDetection
    ) {
        do {
            if let existing = cropOverride(for: cardUUID) {
                existing.leftDetection = leftDetection
                existing.rightDetection = rightDetection
                existing.updatedAt = .now
            } else {
                let override = UserCropOverride(
                    cardUUID: cardUUID,
                    leftDetection: leftDetection,
                    rightDetection: rightDetection
                )
                userContext.insert(override)
            }
            try saveContext()
            logger.debug("Saved crop override for \(cardUUID)")
        } catch let error as UserDataError {
            lastError = error
        } catch {
            logger.error("Failed to save crop override for \(cardUUID): \(error)")
            lastError = .saveFailed(error)
        }
    }

    func deleteCropOverride(for cardUUID: String) {
        do {
            if let existing = cropOverride(for: cardUUID) {
                userContext.delete(existing)
                try saveContext()
                logger.debug("Deleted crop override for \(cardUUID)")
            }
        } catch let error as UserDataError {
            lastError = error
        } catch {
            logger.error("Failed to delete crop override for \(cardUUID): \(error)")
            lastError = .deleteFailed(error)
        }
    }

    // MARK: - Albums

    func createAlbum(name: String) -> UserAlbum {
        let album = UserAlbum(name: name)
        userContext.insert(album)
        
        do {
            try saveContext()
            logger.debug("Created album: \(name)")
        } catch let error as UserDataError {
            lastError = error
        } catch {
            logger.error("Failed to create album: \(error)")
            lastError = .saveFailed(error)
        }
        
        return album
    }

    func deleteAlbum(_ album: UserAlbum) {
        do {
            userContext.delete(album)
            try saveContext()
            logger.debug("Deleted album")
        } catch let error as UserDataError {
            lastError = error
        } catch {
            logger.error("Failed to delete album: \(error)")
            lastError = .deleteFailed(error)
        }
    }
    
    // MARK: - Context Management
    
    /// Saves the user context and handles errors.
    private func saveContext() throws {
        do {
            if userContext.hasChanges {
                try userContext.save()
            }
        } catch {
            logger.error("Failed to save context: \(error)")
            throw UserDataError.saveFailed(error)
        }
    }
}
