//
//  CardDetailView.swift
//  Stereologue
//
//  Full detail view for a stereoview card showing front/back images,
//  metadata, favorite toggle, and user notes.
//

import SwiftUI
import NukeUI

struct CardDetailView: View {
    let card: StereoCard
    @Environment(UserDataService.self) private var userDataService

    @State private var noteText = ""
    @State private var notes: [UserNote] = []
    @State private var isFavorite = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Hero front image — no horizontal padding so it extends under sidebar
                frontImageSection

                // Back image
                if card.backImageID != nil {
                    backImageSection
                }

                // Metadata
                metadataSection

                // Notes
                notesSection

                Spacer(minLength: 40)
            }
        }
        .navigationTitle(card.title)
        .fontDesign(.serif)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    userDataService.toggleFavorite(cardUUID: card.uuid)
                    isFavorite.toggle()
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                }
            }
        }
        .onAppear {
            isFavorite = userDataService.isFavorite(cardUUID: card.uuid)
            notes = userDataService.notes(for: card.uuid)
        }
    }

    // MARK: - Front Image

    @ViewBuilder
    private var frontImageSection: some View {
        if let url = card.frontImageURL(quality: "q") {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if state.error != nil {
                    imagePlaceholder
                } else {
                    imagePlaceholder
                        .overlay { ProgressView() }
                }
            }
            .backgroundExtensionEffect()
        }
    }

    // MARK: - Back Image

    @ViewBuilder
    private var backImageSection: some View {
        if let url = card.backImageURL(quality: "q") {
            Text("Back of Card")
                .font(.headline)
                .padding(.horizontal)

            LazyImage(url: url) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if state.error != nil {
                    imagePlaceholder
                } else {
                    imagePlaceholder
                        .overlay { ProgressView() }
                }
            }
            .backgroundExtensionEffect()
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let date = card.displayDate {
                Label(date, systemImage: "calendar")
            }

            if let creator = card.creator {
                NavigationLink(value: creator) {
                    Label(creator.name, systemImage: "person")
                }
            }

            if !card.subjects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Subjects", systemImage: "tag")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(card.subjects, id: \.name) { subject in
                            NavigationLink(value: subject) {
                                Text(subject.name)
                                    .font(.subheadline)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                        }
                    }
                }
            }

            if !card.places.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Places", systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(card.places, id: \.name) { place in
                            NavigationLink(value: place) {
                                Text(place.name)
                                    .font(.subheadline)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                        }
                    }
                }
            }

            if let collection = card.collection {
                Label(collection, systemImage: "building.columns")
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes")
                .font(.headline)

            HStack {
                TextField("Add a note…", text: $noteText)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    guard !noteText.isEmpty else { return }
                    userDataService.addNote(text: noteText, to: card.uuid)
                    noteText = ""
                    notes = userDataService.notes(for: card.uuid)
                }
                .buttonStyle(.bordered)
            }

            ForEach(notes, id: \.id) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.text)
                    Text(note.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Placeholder

    private var imagePlaceholder: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1.6, contentMode: .fit)
            .overlay {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 700, height: 800)) {
    NavigationStack {
        CardDetailView(card: PreviewSampleData.sampleCard)
    }
    .previewEnvironment()
}
#endif
