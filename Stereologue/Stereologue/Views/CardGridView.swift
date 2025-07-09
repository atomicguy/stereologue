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
    
    @State private var gridSize: GridSize = .medium
    
    private var columns: [GridItem] {
        Array(repeating: GridItem(.adaptive(minimum: gridSize.itemWidth)), count: 1)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: columns, spacing: gridSize.spacing) {
                    ForEach(cards, id: \.uuid) { card in
                        CardThumbnailView(card: card)
                            .frame(
                                width: gridSize.itemWidth,
                                height: gridSize.itemHeight
                            )
                            .onTapGesture {
                                selectedCard = card
                            }
                    }
                }
                .padding()
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu("Grid Size", systemImage: "rectangle.grid.1x2") {
                    ForEach(GridSize.allCases, id: \.self) { size in
                        Button(size.name) {
                            withAnimation(.easeInOut) {
                                gridSize = size
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var title: String {
        if cards.isEmpty {
            return "No Cards"
        } else {
            return "\(cards.count) Cards"
        }
    }
}

enum GridSize: CaseIterable {
    case small, medium, large
    
    var name: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
    
    var itemWidth: CGFloat {
        switch self {
        case .small: return 120
        case .medium: return 160
        case .large: return 200
        }
    }
    
    var itemHeight: CGFloat {
        itemWidth * 1.4 // 3:2 aspect ratio plus text
    }
    
    var spacing: CGFloat {
        switch self {
        case .small: return 8
        case .medium: return 12
        case .large: return 16
        }
    }
}
