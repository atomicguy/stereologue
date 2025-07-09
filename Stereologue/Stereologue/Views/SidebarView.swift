//
//  SidebarView.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import SwiftUI
import SwiftData

struct SidebarView: View {
    let collections: [CollectionSchemaV1.Collection]
    @Binding var searchText: String
    
    @Query private var allCards: [CardSchemaV1.StereoCard]
    @Environment(\.cardRepository) private var repository
    
    var body: some View {
        List {
            Section("Library") {
                NavigationLink {
                    AllCardsView()
                } label: {
                    Label("All Cards", systemImage: "rectangle.stack")
                    Spacer()
                    Text("\(allCards.count)")
                        .foregroundStyle(.secondary)
                }
            }
            
            if !collections.isEmpty {
                Section("Collections") {
                    ForEach(collections) { collection in
                        NavigationLink {
                            CollectionDetailView(collection: collection)
                        } label: {
                            Label(collection.name, systemImage: "folder")
                            Spacer()
                            Text("\(collection.cards.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Stereologue")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Sample", systemImage: "plus") {
                    addSampleCard()
                }
            }
        }
    }
    
    private func addSampleCard() {
        guard let repository = repository else { return }
        
        do {
            _ = try repository.createSampleCard()
        } catch {
            print("Failed to create sample card: \(error)")
        }
    }
}
