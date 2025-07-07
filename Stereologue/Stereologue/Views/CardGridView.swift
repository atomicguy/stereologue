//
//  CardGridView.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import SwiftUI
import SwiftData

struct CardGridView: View {
    let cards: [CardSchemaV1.StereoCard]
    @Binding var selectedCard: CardSchemaV1.StereoCard?
    
    @State private var visualDensity: VisualDensity = .comfortable
    @State private var sortOption: SortOption = .title
    
    private var adaptiveColumns: [GridItem] {
        Array(repeating: GridItem(.adaptive(minimum: visualDensity.itemSize.width)), 
              count: visualDensity.gridColumns)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: adaptiveColumns, spacing: visualDensity.itemSpacing) {
                    ForEach(sortedCards) { card in
                        CardThumbnailView(card: card)
                            .frame(
                                width: visualDensity.itemSize.width,
                                height: visualDensity.itemSize.height
                            )
                            .onTapGesture {
                                selectedCard = card
                            }
                            .contextMenu {
                                CardContextMenu(card: card)
                            }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(cards.isEmpty ? "No Cards" : "\(cards.count) Cards")
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Menu("Density", systemImage: "rectangle.grid.1x2") {
                    ForEach(VisualDensity.allCases, id: \.self) { density in
                        Button(density.name) {
                            withAnimation(.liquidGlass) {
                                visualDensity = density
                            }
                        }
                    }
                }
                
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button(option.name) {
                            sortOption = option
                        }
                    }
                }
            }
        }
    }
    
    private var sortedCards: [CardSchemaV1.StereoCard] {
        cards.sorted { card1, card2 in
            switch sortOption {
            case .title:
                return (card1.titlePick?.text ?? "") < (card2.titlePick?.text ?? "")
            case .date:
                return (card1.dates.first?.text ?? "") < (card2.dates.first?.text ?? "")
            case .author:
                return (card1.authors.first?.name ?? "") < (card2.authors.first?.name ?? "")
            case .recent:
                return true // Would need a createdAt field
            }
        }
    }
}

enum SortOption: CaseIterable {
    case title, date, author, recent
    
    var name: String {
        switch self {
        case .title: return "Title"
        case .date: return "Date"
        case .author: return "Author" 
        case .recent: return "Recently Added"
        }
    }
}

extension VisualDensity {
    var name: String {
        switch self {
        case .spacious: return "Spacious"
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        case .dense: return "Dense"
        }
    }
}

#Preview {
    CardGridView(
        cards: [],
        selectedCard: .constant(nil)
    )
    .modelContainer(for: CardSchemaV1.StereoCard.self, inMemory: true)
}