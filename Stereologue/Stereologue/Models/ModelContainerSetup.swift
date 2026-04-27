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
        get throws {
            let dir = URL.applicationSupportDirectory
                .appendingPathComponent("Stereologue", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
                return dir
            } catch {
                logger.error("Failed to create store directory: \(error)")
                throw ContainerSetupError.directoryCreationFailed(error)
            }
        }
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
            Collection.self,
        ])

        let destinationURL = try storeDirectory.appendingPathComponent("CatalogStore.store")

        // Version of the bundled catalog - increment when schema changes
        let currentCatalogVersion = 2  // v1 = string collections, v2 = Collection model
        let installedVersion = UserDefaults.standard.integer(forKey: "CatalogStoreVersion")

        // Copy bundled store on first launch OR when version changes
        if !FileManager.default.fileExists(atPath: destinationURL.path) || installedVersion < currentCatalogVersion {
            guard let bundledURL = Bundle.main.url(forResource: "CatalogStore", withExtension: "store") else {
                logger.error("CatalogStore.store not found in app bundle")
                throw ContainerSetupError.catalogStoreMissing
            }
            do {
                // Remove old store if it exists
                try? FileManager.default.removeItem(at: destinationURL)
                
                // Copy new store
                try FileManager.default.copyItem(at: bundledURL, to: destinationURL)
                
                // Update version
                UserDefaults.standard.set(currentCatalogVersion, forKey: "CatalogStoreVersion")
                
                logger.info("Copied bundled CatalogStore.store v\(currentCatalogVersion) to Application Support")
            } catch {
                logger.error("Failed to copy bundled catalog store: \(error)")
                throw ContainerSetupError.catalogStoreCopyFailed(error)
            }
        }

        let config = ModelConfiguration(
            "CatalogStore",
            schema: schema,
            url: destinationURL,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(
                for: schema,
                configurations: config
            )
        } catch {
            logger.error("Failed to create catalog container: \(error)")
            throw ContainerSetupError.containerCreationFailed(error)
        }
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
            UserCropOverride.self,
            UserFavorite.self,
            UserNote.self,
        ])

        let url = try storeDirectory.appendingPathComponent("UserStore.store")

        let config = ModelConfiguration(
            "UserStore",
            schema: schema,
            url: url,
            cloudKitDatabase: .none  // Change to .private(...) after adding iCloud entitlement
        )

        do {
            return try ModelContainer(
                for: schema,
                configurations: config
            )
        } catch {
            logger.error("Failed to create user container: \(error)")
            throw ContainerSetupError.containerCreationFailed(error)
        }
    }
}
