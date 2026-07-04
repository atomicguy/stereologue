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
    @State private var showDetections = false
    @State private var showCropEditor = false
    @State private var cropOverride: UserCropOverride?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Title
                Text(card.title)
                    .font(.title2.bold())
                    .padding(.horizontal)

                // Hero front image — no horizontal padding so it extends under sidebar
                frontImageSection
                    .padding(.horizontal, cardImageHorizontalPadding)

                // Back image
                if card.backImageID != nil {
                    backImageSection
                        .padding(.horizontal, cardImageHorizontalPadding)
                }

                // Metadata
                metadataSection

                // Notes
                notesSection

                // NYPL attribution
                attributionSection

                Spacer(minLength: 40)
            }
            .padding(.top, 12)
        }
        .fontDesign(.serif)
        .onAppear {
            notes = userDataService.notes(for: card.uuid)
            cropOverride = userDataService.cropOverride(for: card.uuid)
        }
        .sheet(isPresented: $showCropEditor) {
            cropOverride = userDataService.cropOverride(for: card.uuid)
        } content: {
            CropEditorView(card: card, existingOverride: cropOverride)
        }
    }

    // MARK: - Front Image

    private var cardImageHorizontalPadding: CGFloat {
        #if os(visionOS)
        return 20
        #else
        return 0
        #endif
    }

    private var hasDetections: Bool {
        card.leftDetection.width > 0 || card.rightDetection.width > 0
    }

    private var effectiveLeft: ImageDetection {
        cropOverride?.leftDetection ?? card.leftDetection
    }

    private var effectiveRight: ImageDetection {
        cropOverride?.rightDetection ?? card.rightDetection
    }

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
            .overlay {
                if showDetections {
                    detectionOverlay
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasDetections {
                    HStack(spacing: 4) {
                        Button {
                            showCropEditor = true
                        } label: {
                            Image(systemName: "crop")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                                .padding(8)
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation { showDetections.toggle() }
                        } label: {
                            Image(systemName: showDetections ? "viewfinder.circle.fill" : "viewfinder.circle")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                                .padding(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .transition(.opacity)
            .backgroundExtensionEffect()
        }
    }

    // MARK: - Detection Overlay

    private var detectionOverlay: some View {
        GeometryReader { geo in
            let imgW = card.imageWidth ?? 1
            let imgH = card.imageHeight ?? 1
            let scaleX = geo.size.width / imgW
            let scaleY = geo.size.height / imgH

            ZStack {
                detectionBox(effectiveLeft, scaleX: scaleX, scaleY: scaleY, color: .blue)
                detectionBox(effectiveRight, scaleX: scaleX, scaleY: scaleY, color: .green)
            }
        }
    }

    private func detectionBox(
        _ detection: ImageDetection,
        scaleX: Double,
        scaleY: Double,
        color: Color
    ) -> some View {
        let w = detection.width * scaleX
        let h = detection.height * scaleY
        let centerX = detection.x * scaleX
        let centerY = detection.y * scaleY

        return RoundedRectangle(cornerRadius: 4)
            .strokeBorder(color, lineWidth: 2)
            .overlay(alignment: .topLeading) {
                Text(detection.classification)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.7), in: Capsule())
                    .offset(x: 4, y: 4)
            }
            .frame(width: w, height: h)
            .position(x: centerX, y: centerY)
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
                FlowLayout(spacing: 6) {
                    ForEach(card.subjects, id: \.name) { subject in
                        NavigationLink(value: subject) {
                            Label(subject.name, systemImage: "tag")
                        }
                    }
                }
            }

            if !card.places.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(card.places, id: \.name) { place in
                        NavigationLink(value: place) {
                            Label(place.name, systemImage: "mappin.and.ellipse")
                        }
                    }
                }
            }

            if let collection = card.collection {
                NavigationLink(value: collection) {
                    Label(collection.name, systemImage: "building.columns")
                }
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

    // MARK: - Attribution

    private var attributionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Link(destination: URL(string: "https://digitalcollections.nypl.org/items/\(card.uuid)")!) {
                Label("From The New York Public Library", systemImage: "building.columns")
            }

            Link(destination: URL(string: "https://rightsstatements.org/page/NoC-US/1.0/?language=en")!) {
                Label("No known U.S. copyright restrictions", systemImage: "checkmark.seal")
                    .font(.subheadline)
            }
        }
        .foregroundStyle(.secondary)
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
