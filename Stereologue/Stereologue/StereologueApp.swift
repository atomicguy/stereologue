//
//  StereologueApp.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import SwiftUI
import SwiftData
import Nuke
import OSLog

@main
struct StereologueApp: App {

    let catalogContainer: ModelContainer
    let userContainer: ModelContainer
    let userDataService: UserDataService
    private let spatialPhotoService: SpatialPhotoService
    #if os(visionOS)
    @State private var spatialPhotoViewModel = SpatialPhotoViewModel()
    #endif
    
    @State private var initializationError: InitializationError?
    
    private static let logger = Logger(subsystem: "net.atompowered.Stereologue", category: "App")

    init() {
        // Set the shared Nuke pipeline for all LazyImage views
        ImagePipeline.shared = .stereologue

        spatialPhotoService = SpatialPhotoService(pipeline: .stereologue)

        var catalog: ModelContainer
        var user: ModelContainer
        var initError: InitializationError?

        do {
            catalog = try StereologueContainers.makeCatalogContainer()
            user = try StereologueContainers.makeUserContainer()
        } catch let error as ContainerSetupError {
            Self.logger.error("Container setup failed: \(error.localizedDescription)")
            (catalog, user) = Self.createFallbackContainers()
            initError = InitializationError(
                containerError: error,
                isUsingFallback: true
            )
        } catch {
            Self.logger.critical("Unexpected initialization error: \(error)")
            (catalog, user) = Self.createFallbackContainers()
            initError = InitializationError(
                containerError: .unknown(error),
                isUsingFallback: true
            )
        }

        catalogContainer = catalog
        userContainer = user
        userDataService = UserDataService(userContext: user.mainContext)
        initializationError = initError
    }
    
    /// Creates in-memory containers as a fallback when persistent storage fails.
    /// This allows the app to run but data won't persist between launches.
    private static func createFallbackContainers() -> (catalog: ModelContainer, user: ModelContainer) {
        logger.warning("Creating in-memory fallback containers")
        
        let catalogSchema = Schema([
            StereoCard.self,
            Creator.self,
            Subject.self,
            Place.self,
            Collection.self,
        ])
        
        let userSchema = Schema([
            UserAlbum.self,
            UserAlbumEntry.self,
            UserCropOverride.self,
            UserFavorite.self,
            UserNote.self,
        ])
        
        let catalogConfig = ModelConfiguration(
            "CatalogStore-InMemory",
            schema: catalogSchema,
            isStoredInMemoryOnly: true
        )
        
        let userConfig = ModelConfiguration(
            "UserStore-InMemory",
            schema: userSchema,
            isStoredInMemoryOnly: true
        )
        
        do {
            let catalog = try ModelContainer(for: catalogSchema, configurations: catalogConfig)
            let user = try ModelContainer(for: userSchema, configurations: userConfig)
            return (catalog, user)
        } catch {
            // If even in-memory containers fail, we have a serious problem
            fatalError("Failed to create in-memory fallback containers: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(catalogContainer)
                .environment(\.userModelContext, userContainer.mainContext)
                .environment(userDataService)
                .environment(\.spatialPhotoService, spatialPhotoService)
                #if os(visionOS)
                .environment(spatialPhotoViewModel)
                #endif
                .alert(
                    "Data Storage Error",
                    isPresented: .constant(initializationError != nil),
                    presenting: initializationError
                ) { error in
                    Button("Continue") {
                        // Dismiss - user can continue with in-memory storage
                    }
                    if error.recoverySuggestion != nil {
                        Button("Get Help") {
                            // Could open support URL or show more details
                            Self.logger.info("User requested help for: \(error.containerError)")
                        }
                    }
                } message: { error in
                    Text(error.userMessage)
                }
        }

        #if os(visionOS)
        WindowGroup(id: "spatial-photo") {
            SpatialPhotoView(spatialPhotoService: spatialPhotoService)
                .environment(spatialPhotoViewModel)
                .environment(userDataService)
        }
        .defaultSize(width: 1280, height: 720)
        .windowStyle(.plain)
        #endif
    }
}

// MARK: - Initialization Error Types

/// Errors that can occur during app container initialization.
enum ContainerSetupError: LocalizedError {
    case catalogStoreMissing
    case catalogStoreCopyFailed(Error)
    case directoryCreationFailed(Error)
    case containerCreationFailed(Error)
    case unknown(Error)
    
    var errorDescription: String? {
        switch self {
        case .catalogStoreMissing:
            return "The catalog database is missing from the app bundle"
        case .catalogStoreCopyFailed(let error):
            return "Failed to copy catalog database: \(error.localizedDescription)"
        case .directoryCreationFailed(let error):
            return "Failed to create storage directory: \(error.localizedDescription)"
        case .containerCreationFailed(let error):
            return "Failed to create database container: \(error.localizedDescription)"
        case .unknown(let error):
            return "An unexpected error occurred: \(error.localizedDescription)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .catalogStoreMissing:
            return "Try reinstalling the app from the App Store"
        case .catalogStoreCopyFailed, .directoryCreationFailed:
            return "Check that you have enough storage space and try restarting the app"
        case .containerCreationFailed:
            return "Try restarting your device or reinstalling the app"
        case .unknown:
            return "Please contact support if this problem persists"
        }
    }
}

/// Wrapper for initialization errors to present to the user.
struct InitializationError {
    let containerError: ContainerSetupError
    let isUsingFallback: Bool
    
    var userMessage: String {
        var message = containerError.localizedDescription
        if isUsingFallback {
            message += "\n\nThe app will continue with temporary storage. Your data may not be saved."
        }
        if let suggestion = containerError.recoverySuggestion {
            message += "\n\n\(suggestion)"
        }
        return message
    }
    
    var recoverySuggestion: String? {
        containerError.recoverySuggestion
    }
}

// MARK: - Environment Key for the User Container

private struct UserModelContextKey: EnvironmentKey {
    static let defaultValue: ModelContext? = nil
}

private struct SpatialPhotoServiceKey: EnvironmentKey {
    static let defaultValue: SpatialPhotoService? = nil
}

extension EnvironmentValues {
    var userModelContext: ModelContext? {
        get { self[UserModelContextKey.self] }
        set { self[UserModelContextKey.self] = newValue }
    }

    var spatialPhotoService: SpatialPhotoService? {
        get { self[SpatialPhotoServiceKey.self] }
        set { self[SpatialPhotoServiceKey.self] = newValue }
    }
}
