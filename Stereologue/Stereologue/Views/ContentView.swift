//
//  ContentView.swift
//  Stereologue
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var cards: [StereoCard]

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
                    List(cards, id: \.uuid) { card in
                        HStack(spacing: 12) {
                            CardThumbnailView(card: card)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                if let creator = card.creator {
                                    Text(creator.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                if let date = card.displayDate {
                                    Text(date)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Stereologue")
        }
    }
}
