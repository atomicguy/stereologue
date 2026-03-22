//
//  StereologueApp.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import SwiftUI
import SwiftData
import AppIntents

@main
struct StereologueApp: App {
    let container: ModelContainer
    
    init() {
        do {
            // OS 26: Consider using schema migration if you adopt the class hierarchy
            // For now, keeping existing schema structure
            container = try ModelContainer(for:
                CardSchemaV1.StereoCard.self,
                TitleSchemaV1.Title.self,
                AuthorSchemaV1.Author.self,
                SubjectSchemaV1.Subject.self,
                DateSchemaV1.Date.self,
                CollectionSchemaV1.Collection.self,
                CropSchemaV1.Crop.self
            )
            
            // OS 26: Initialize Spotlight indexing
            Task { @MainActor in
                let indexingService = SpotlightIndexingService(modelContext: container.mainContext)
                await indexingService.indexAllCards()
            }
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
                .environment(\.cardRepository, CardRepository(modelContext: container.mainContext))
        }
    }
}

// OS 26: Register App Shortcuts
extension StereologueApp {
    static var appShortcuts: AppShortcutsProvider.Type {
        StereologueShortcuts.self
    }
}
