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

    var body: some View {
        BrowseMosaicGrid(
            entities: collections,
            id: \.name,
            title: { $0.name },
            count: \.cardCount,
            predicate: { collection in
                let name = collection.name
                return #Predicate { $0.collection?.name == name }
            }
        )
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
