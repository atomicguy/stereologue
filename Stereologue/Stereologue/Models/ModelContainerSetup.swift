//
//  ModelContainerSetup.swift
//  Stereologue
//
//  Two-container architecture:
//  - Catalog container: local-only, holds 41K StereoCard records
//  - User container: CloudKit-synced, holds favorites/albums/notes
//

import Foundation
import SwiftData
import OSLog

enum StereologueContainers {

    private static let logger = Logger(subsystem: "net.atompowered.Stereologue", category: "Containers")

    private static var storeDirectory: URL {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Stereologue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Catalog Container (Local Only)

    /// Contains the NYPL stereoview card catalog.
    /// On first launch, copies the pre-built store from the app bundle.
    /// Never syncs to CloudKit. Supports #Unique constraints.
    static func makeCatalogContainer() throws -> ModelContainer {
        let schema = Schema([
            StereoCard.self,
            Creator.self,
            Subject.self,
            Place.self,
        ])

        let destinationURL = storeDirectory.appendingPathComponent("CatalogStore.store")

        // Copy bundled store on first launch
        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            guard let bundledURL = Bundle.main.url(forResource: "CatalogStore", withExtension: "store") else {
                fatalError("CatalogStore.store not found in app bundle")
            }
            do {
                try FileManager.default.copyItem(at: bundledURL, to: destinationURL)
                logger.info("Copied bundled CatalogStore.store to Application Support")
            } catch {
                fatalError("Failed to copy bundled catalog store: \(error)")
            }
        }

        let config = ModelConfiguration(
            "CatalogStore",
            schema: schema,
            url: destinationURL,
            cloudKitDatabase: .none
        )

        return try ModelContainer(
            for: schema,
            configurations: config
        )
    }

    // MARK: - User Container (CloudKit Synced)

    /// Contains user-generated data: albums, favorites, notes.
    /// Syncs via CloudKit across devices.
    ///
    /// To enable CloudKit sync, add the iCloud capability with
    /// container "iCloud.net.atompowered.Stereologue" to the
    /// Xcode project, then change `.none` below to:
    ///   `.private("iCloud.net.atompowered.Stereologue")`
    static func makeUserContainer() throws -> ModelContainer {
        let schema = Schema([
            UserAlbum.self,
            UserAlbumEntry.self,
            UserFavorite.self,
            UserNote.self,
        ])

        let url = storeDirectory.appendingPathComponent("UserStore.store")

        let config = ModelConfiguration(
            "UserStore",
            schema: schema,
            url: url,
            cloudKitDatabase: .none  // Change to .private(...) after adding iCloud entitlement
        )

        return try ModelContainer(
            for: schema,
            configurations: config
        )
    }
}
