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

    let catalogContainer: ModelContainer
    let userContainer: ModelContainer

    init() {
        do {
            catalogContainer = try StereologueContainers.makeCatalogContainer()
            userContainer = try StereologueContainers.makeUserContainer()
        } catch {
            fatalError("Failed to initialize model containers: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(catalogContainer)
                .environment(\.userModelContext, userContainer.mainContext)
        }
    }
}
// MARK: - Environment Key for the User Container

private struct UserModelContextKey: EnvironmentKey {
    static let defaultValue: ModelContext? = nil
}

extension EnvironmentValues {
    var userModelContext: ModelContext? {
        get { self[UserModelContextKey.self] }
        set { self[UserModelContextKey.self] = newValue }
    }
}

