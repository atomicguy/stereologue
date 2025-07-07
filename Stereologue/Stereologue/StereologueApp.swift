//
//  StereologueApp.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import SwiftUI
import SwiftData

@main
struct YourApp: App {
    let container: ModelContainer
    
    init() {
        // Initialize SwiftData container
        container = try! ModelContainer(for: CardSchemaV1.StereoCard.self, /* other schemas */)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
                .cardRepository(CardRepository(modelContext: container.mainContext))
        }
    }
}
