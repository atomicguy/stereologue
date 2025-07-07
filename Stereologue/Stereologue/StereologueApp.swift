//
//  StereologueApp.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import SwiftUI
import SwiftData

@main
struct StereologueApp: App {
    let container: ModelContainer
    
    init() {
        do {
            // Initialize SwiftData container with all schemas
            container = try ModelContainer(for:
                CardSchemaV1.StereoCard.self,
                TitleSchemaV1.Title.self,
                AuthorSchemaV1.Author.self,
                SubjectSchemaV1.Subject.self,
                DateSchemaV1.Date.self,
                CollectionSchemaV1.Collection.self,
                CropSchemaV1.Crop.self
            )
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
                .cardRepository(CardRepository(modelContext: container.mainContext))
        }
        
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
        
        #if os(visionOS)
        ImmersiveSpace(id: "SpatialCardView") {
            SpatialCardEnvironment()
        }
        #endif
    }
}
