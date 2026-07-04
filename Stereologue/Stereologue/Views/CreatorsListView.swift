//
//  CreatorsListView.swift
//  Stereologue
//
//  Browse creators in a grid with mosaic thumbnails.
//

import SwiftUI
import SwiftData

struct CreatorsListView: View {
    @Query(sort: \Creator.name) private var creators: [Creator]

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(creators, id: \.name) { creator in
                    let name = creator.name
                    NavigationLink(value: creator) {
                        BrowseMosaicItem(
                            title: name,
                            cardPredicate: #Predicate { $0.creator?.name == name }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Creators")
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        CreatorsListView()
    }
    .previewEnvironment()
}
#endif
