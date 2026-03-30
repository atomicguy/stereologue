//
//  CreatorsListView.swift
//  Stereologue
//
//  Browse creators with mosaic thumbnails.
//

import SwiftUI
import SwiftData

struct CreatorsListView: View {
    @Query(sort: \Creator.name) private var creators: [Creator]

    var body: some View {
        List(creators, id: \.name) { creator in
            NavigationLink(value: creator) {
                HStack(spacing: 12) {
                    MosaicThumbnailView(cards: creator.cards)
                    VStack(alignment: .leading) {
                        Text(creator.name)
                            .font(.headline)
                        Text("^[\(creator.cardCount) card](inflect: true)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Creators")
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 400, height: 700)) {
    NavigationStack {
        CreatorsListView()
    }
    .previewEnvironment()
}
#endif
