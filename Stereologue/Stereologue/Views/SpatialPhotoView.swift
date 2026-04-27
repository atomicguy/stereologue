//
//  SpatialPhotoView.swift
//  Stereologue
//
//  Photos-style spatial photo viewer for visionOS.
//  Displays stereo HEICs via RealityKit's ImagePresentationComponent
//  in a dedicated window with a thumbnail strip ornament and
//  swipe-to-navigate transitions.
//

#if os(visionOS)

import SwiftUI
import RealityKit
import NukeUI
import OSLog

private let logger = Logger(
    subsystem: "net.atompowered.Stereologue",
    category: "SpatialPhotoView"
)

struct SpatialPhotoView: View {
    @Environment(SpatialPhotoViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    let spatialPhotoService: SpatialPhotoService

    @State private var spatialPhotoURL: URL?
    @State private var isLoading = false
    @State private var displayedCardUUID: String?

    var body: some View {
        GeometryReader3D { geometry in
            ZStack {
                // Spatial photo with push transition
                if let spatialPhotoURL {
                    spatialPhotoContent(url: spatialPhotoURL, geometry: geometry)
                        .id(displayedCardUUID)
                        .transition(pushTransition)
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ornament(
            attachmentAnchor: .scene(.top),
            contentAlignment: .init(horizontal: .center, vertical: .bottom, depth: .front)
        ) {
            titleOrnament
                .padding(.bottom, 40)
        }
        .ornament(
            attachmentAnchor: .scene(.bottom),
            contentAlignment: .init(horizontal: .center, vertical: .top, depth: .front)
        ) {
            thumbnailStripOrnament
                .padding(.top, 40)
        }
        .gesture(
            DragGesture(minimumDistance: 50)
                .onEnded { value in
                    let horizontal = value.translation.width
                    if horizontal < -50 && viewModel.hasNext {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            viewModel.goToNext()
                        }
                    } else if horizontal > 50 && viewModel.hasPrevious {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            viewModel.goToPrevious()
                        }
                    }
                }
        )
        .task(id: viewModel.currentCardUUID) {
            await loadSpatialPhoto()
        }
        .onChange(of: viewModel.isPresented) { _, presented in
            if !presented {
                dismiss()
            }
        }
    }

    // MARK: - Spatial Photo Content

    @ViewBuilder
    private func spatialPhotoContent(url: URL, geometry: GeometryProxy3D) -> some View {
        RealityView { content in
            let entity = Entity()
            do {
                var component = try await ImagePresentationComponent(
                    contentsOf: url
                )
                component.desiredViewingMode = .spatialStereo
                entity.components.set(component)
                content.add(entity)
            } catch {
                logger.error(
                    "ImagePresentationComponent failed: \(error.localizedDescription)"
                )
            }
        } update: { content in
            guard let entity = content.entities.first,
                  let component = entity.components[ImagePresentationComponent.self] else {
                return
            }
            let presentationSize = component.presentationScreenSize
            guard presentationSize != .zero else { return }
            let bounds = content.convert(
                geometry.frame(in: .local), from: .local, to: .scene
            )
            let scale = min(
                bounds.extents.x / presentationSize.x,
                bounds.extents.y / presentationSize.y
            )
            entity.scale = SIMD3<Float>(scale, scale, 1.0)
            entity.position.z = 0
        }
    }

    // MARK: - Push Transition

    private var pushTransition: AnyTransition {
        switch viewModel.navigationDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    // MARK: - Title Ornament

    private var titleOrnament: some View {
        Group {
            if let card = viewModel.currentCard {
                Text(card.title)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 800)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassBackgroundEffect()
            }
        }
    }

    // MARK: - Thumbnail Strip Ornament

    private var thumbnailStripOrnament: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.35)) {
                    viewModel.goToPrevious()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }
            .disabled(!viewModel.hasPrevious || isLoading)
            .padding(.trailing, 8)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(viewModel.cards, id: \.uuid) { card in
                            thumbnailItem(card: card)
                                .id(card.uuid)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: 600)
                .onChange(of: viewModel.currentCardUUID) { _, newUUID in
                    withAnimation {
                        proxy.scrollTo(newUUID, anchor: .center)
                    }
                }
                .onAppear {
                    proxy.scrollTo(viewModel.currentCardUUID, anchor: .center)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.35)) {
                    viewModel.goToNext()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3)
            }
            .disabled(!viewModel.hasNext || isLoading)
            .padding(.leading, 8)

            Divider()
                .frame(height: 40)
                .padding(.horizontal, 12)

            Button {
                viewModel.dismiss()
            } label: {
                Text("Done")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    // MARK: - Thumbnail Item

    private func thumbnailItem(card: StereoCard) -> some View {
        Button {
            guard card.uuid != viewModel.currentCardUUID else { return }
            if let currentIdx = viewModel.currentIndex,
               let targetIdx = viewModel.cards.firstIndex(where: { $0.uuid == card.uuid }) {
                viewModel.navigationDirection = targetIdx > currentIdx
                    ? .forward : .backward
            }
            withAnimation(.easeInOut(duration: 0.35)) {
                viewModel.currentCardUUID = card.uuid
            }
        } label: {
            CardThumbnailView(card: card)
                .overlay {
                    if card.uuid == viewModel.currentCardUUID {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white, lineWidth: 2)
                    }
                }
                .opacity(card.uuid == viewModel.currentCardUUID ? 1.0 : 0.6)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // MARK: - Loading

    private func loadSpatialPhoto() async {
        guard let card = viewModel.currentCard,
              card.hasStereoDetections else { return }

        isLoading = true
        spatialPhotoURL = nil

        do {
            let url = try await spatialPhotoService.spatialPhotoURL(for: card)
            withAnimation(.easeInOut(duration: 0.35)) {
                spatialPhotoURL = url
                displayedCardUUID = card.uuid
            }
            prefetchAdjacent()
        } catch {
            logger.error("Failed to create spatial photo: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func prefetchAdjacent() {
        guard let idx = viewModel.currentIndex else { return }
        var adjacent: [StereoCard] = []
        if idx > 0 { adjacent.append(viewModel.cards[idx - 1]) }
        if idx < viewModel.cards.count - 1 { adjacent.append(viewModel.cards[idx + 1]) }
        Task {
            await spatialPhotoService.prefetch(cards: adjacent)
        }
    }
}

#endif
