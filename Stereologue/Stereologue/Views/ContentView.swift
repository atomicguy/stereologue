//
//  ContentView.swift
//  Stereologue
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var cards: [StereoCard]

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if cards.isEmpty {
                    ContentUnavailableView(
                        "No Cards",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("The catalog could not be loaded.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(cards, id: \.uuid) { card in
                                CardGridItemView(card: card)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Stereologue")
        }
    }
}
