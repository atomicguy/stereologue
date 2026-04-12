//
//  SpatialPhotoView.swift
//  Stereologue
//
//  visionOS spatial photo viewer with card-to-card navigation.
//  Displays stereo HEICs via RealityKit's ImagePresentationComponent
//  and supports swiping or tapping through adjacent cards.
//

#if os(visionOS)

import SwiftUI
import RealityKit
import OSLog

private let logger = Logger(
    subsystem: "net.atompowered.Stereologue",
    category: "SpatialPhotoView"
)

struct SpatialPhotoView: View {
    let cards: [StereoCard]
    let spatialPhotoService: SpatialPhotoService
    var onDismiss: () -> Void

    @State private var currentCardUUID: String
    @State private var spatialPhotoURL: URL?
    @State private var isLoading = false

    init(
        cards: [StereoCard],
        initialCardUUID: String,
        spatialPhotoService: SpatialPhotoService,
        onDismiss: @escaping () -> Void
    ) {
        self.cards = cards
        self.spatialPhotoService = spatialPhotoService
        self.onDismiss = onDismiss
        _currentCardUUID = State(initialValue: initialCardUUID)
    }

    private var currentCard: StereoCard? {
        cards.first(where: { $0.uuid == currentCardUUID })
    }

    private var currentIndex: Int? {
        cards.firstIndex(where: { $0.uuid == currentCardUUID })
    }

    private var hasPrevious: Bool {
        guard let idx = currentIndex else { return false }
        return idx > 0
    }

    private var hasNext: Bool {
        guard let idx = currentIndex else { return false }
        return idx < cards.count - 1
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.95)
                .ignoresSafeArea()

            if let spatialPhotoURL {
                RealityView { content in
                    let entity = Entity()
                    do {
                        var component = try await ImagePresentationComponent(
                            contentsOf: spatialPhotoURL
                        )
                        component.desiredViewingMode = .spatialStereo
                        component.screenHeight = 0.4
                        entity.components.set(component)
                        content.add(entity)
                    } catch {
                        logger.error(
                            "ImagePresentationComponent failed: \(error.localizedDescription)"
                        )
                    }
                }
                .id(spatialPhotoURL)
            } else if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
            }

            // Edge tap zones for prev/next navigation
            HStack(spacing: 0) {
                Button {
                    goToPrevious()
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .leading) {
                            Image(systemName: "chevron.compact.left")
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.leading, 20)
                        }
                }
                .buttonStyle(.plain)
                .opacity(hasPrevious && !isLoading ? 1 : 0)
                .allowsHitTesting(hasPrevious && !isLoading)
                .hoverEffect(.highlight)

                Spacer()
                    .frame(maxWidth: .infinity)

                Button {
                    goToNext()
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .trailing) {
                            Image(systemName: "chevron.compact.right")
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.trailing, 20)
                        }
                }
                .buttonStyle(.plain)
                .opacity(hasNext && !isLoading ? 1 : 0)
                .allowsHitTesting(hasNext && !isLoading)
                .hoverEffect(.highlight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarHidden(true)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            navigationOrnament
        }
        .task(id: currentCardUUID) {
            await loadSpatialPhoto()
        }
    }

    // MARK: - Navigation Ornament

    private var navigationOrnament: some View {
        HStack(spacing: 16) {
            Button {
                goToPrevious()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!hasPrevious || isLoading)

            Text(currentCard?.title ?? "")
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button {
                goToNext()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!hasNext || isLoading)

            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(minWidth: 650, maxWidth: 900)
        .glassBackgroundEffect()
    }

    // MARK: - Navigation

    private func goToPrevious() {
        guard let idx = currentIndex, idx > 0 else { return }
        currentCardUUID = cards[idx - 1].uuid
    }

    private func goToNext() {
        guard let idx = currentIndex, idx < cards.count - 1 else { return }
        currentCardUUID = cards[idx + 1].uuid
    }

    // MARK: - Loading

    private func loadSpatialPhoto() async {
        guard let card = currentCard, card.hasStereoDetections else { return }

        isLoading = true
        spatialPhotoURL = nil

        do {
            let url = try await spatialPhotoService.spatialPhotoURL(for: card)
            spatialPhotoURL = url
            prefetchAdjacent()
        } catch {
            logger.error("Failed to create spatial photo: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func prefetchAdjacent() {
        guard let idx = currentIndex else { return }
        var adjacent: [StereoCard] = []
        if idx > 0 { adjacent.append(cards[idx - 1]) }
        if idx < cards.count - 1 { adjacent.append(cards[idx + 1]) }
        Task {
            await spatialPhotoService.prefetch(cards: adjacent)
        }
    }
}

#endif
