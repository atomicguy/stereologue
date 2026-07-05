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

    var body: some View {
        BrowseMosaicGrid(
            entities: creators,
            id: \.name,
            title: { $0.name },
            count: \.cardCount,
            predicate: { creator in
                let name = creator.name
                return #Predicate { $0.creator?.name == name }
            }
        )
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
