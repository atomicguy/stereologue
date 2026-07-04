//
//  CollectionsListView.swift
//  Stereologue
//
//  Browse collections in a grid with mosaic thumbnails.
//

import SwiftUI
import SwiftData

struct CollectionsListView: View {
    @Query(sort: \Collection.name) private var collections: [Collection]

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(collections, id: \.name) { collection in
                    let name = collection.name
                    NavigationLink(value: collection) {
                        BrowseMosaicItem(
                            title: name,
                            cardPredicate: #Predicate { $0.collection?.name == name }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Collections")
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        CollectionsListView()
    }
    .previewEnvironment()
}
#endif
