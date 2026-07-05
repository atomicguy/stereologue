//
//  SpatialPhotoView.swift
//  Stereologue
//
//  Photos-style spatial photo viewer for visionOS.
//  Displays stereo pairs via RealityKit's ImagePresentationComponent,
//  built from in-memory spatial HEIC bytes (no disk round-trip), in a
//  dedicated window with a thumbnail strip ornament and swipe-to-navigate
//  transitions.
//

#if os(visionOS)

import SwiftUI
import SwiftData
import RealityKit
import NukeUI
import ImageIO
import OSLog

private let logger = Logger(
    subsystem: "net.atompowered.Stereologue",
    category: "SpatialPhotoView"
)

struct SpatialPhotoView: View {
    @Environment(SpatialPhotoViewModel.self) private var viewModel
    @Environment(UserDataService.self) private var userDataService
    @Environment(\.dismiss) private var dismiss

    let spatialPhotoService: SpatialPhotoService

    @State private var spatialPhotoData: Data?
    @State private var isLoading = false
    @State private var isRestoring = false
    @State private var currentStyle: RestorationStyle?
    @State private var displayedCardUUID: String?
    @State private var useFadeTransition = false
    @State private var isFavorite = false
    @State private var isImmersive = false

    var body: some View {
        GeometryReader3D { geometry in
            ZStack {
                // Spatial photo with push transition
                if let spatialPhotoData {
                    spatialPhotoContent(data: spatialPhotoData, geometry: geometry)
                        .id("\(displayedCardUUID ?? "")_\(currentStyle?.rawValue ?? "none")")
                        .transition(photoTransition)
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                } else if isRunningInPreview {
                    stereoPhotoPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ornament(
            attachmentAnchor: .scene(.top),
            contentAlignment: .init(horizontal: .center, vertical: .bottom, depth: .front)
        ) {
            titleOrnament
                .padding(.bottom, 80)
                .offset(z: 80)
        }
        .ornament(
            attachmentAnchor: .scene(.bottom),
            contentAlignment: .init(horizontal: .center, vertical: .top, depth: .front)
        ) {
            thumbnailStripOrnament
                .padding(.top, 100)
                .offset(z: 200)
        }
        .task(id: viewModel.currentCardUUID) {
            await loadSpatialPhoto()
            refreshFavoriteState()
        }
        .onChange(of: viewModel.isPresented) { _, presented in
            if !presented {
                dismiss()
            }
        }
    }

    private func refreshFavoriteState() {
        guard let uuid = viewModel.currentCardUUID else {
            isFavorite = false
            return
        }
        isFavorite = userDataService.isFavorite(cardUUID: uuid)
    }

    // MARK: - Spatial Photo Content

    @ViewBuilder
    private func spatialPhotoContent(data: Data, geometry: GeometryProxy3D) -> some View {
        RealityView { content in
            let entity = Entity()
            do {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    logger.error("Failed to create CGImageSource from spatial photo data")
                    return
                }
                var component = try await ImagePresentationComponent(imageSource: source)
                component.desiredViewingMode = preferredViewingMode(for: component)
                entity.components.set(component)

                entity.components.set(InputTargetComponent(allowedInputTypes: .indirect))
                entity.components.set(CollisionComponent(shapes: [.generateBox(size: SIMD3(2, 2, 0.01))]))

                content.add(entity)
            } catch {
                logger.error(
                    "ImagePresentationComponent failed: \(error.localizedDescription)"
                )
            }
        } update: { content in
            guard let entity = content.entities.first,
                  var component = entity.components[ImagePresentationComponent.self] else {
                return
            }
            // Keep the presentation mode in sync with the immersive toggle.
            component.desiredViewingMode = preferredViewingMode(for: component)
            entity.components.set(component)

            // Immersive mode fills the field of view; skip windowed scaling.
            guard !isImmersive else { return }
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
            entity.position.z = -0.1
        }
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
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
    }

    /// Chooses the stereo viewing mode based on the immersive toggle, falling
    /// back to windowed `.spatialStereo` when immersive isn't available.
    private func preferredViewingMode(
        for component: ImagePresentationComponent
    ) -> ImagePresentationComponent.ViewingMode {
        if isImmersive,
           component.availableViewingModes.contains(.spatialStereoImmersive) {
            return .spatialStereoImmersive
        }
        return .spatialStereo
    }

    // MARK: - Stereo Photo Placeholder (Preview Only)

    private var isRunningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private var stereoPhotoPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(
                LinearGradient(
                    colors: [.gray.opacity(0.5), .gray.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(40)
    }

    // MARK: - Photo Transition

    private var photoTransition: AnyTransition {
        if useFadeTransition {
            return .opacity
        }
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
                    .background(Color("CardTint"))
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
                guard let uuid = viewModel.currentCardUUID else { return }
                userDataService.toggleFavorite(cardUUID: uuid)
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(isFavorite ? .red : .primary)
            }
            .disabled(viewModel.currentCardUUID == nil)

            Divider()
                .frame(height: 40)
                .padding(.horizontal, 12)

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isImmersive.toggle()
                }
            } label: {
                Image(systemName: isImmersive
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
                    .foregroundStyle(isImmersive ? .yellow : .primary)
            }
            .disabled(isLoading || spatialPhotoData == nil)

            Divider()
                .frame(height: 40)
                .padding(.horizontal, 12)

            if isRestoring {
                ProgressView()
                    .controlSize(.small)
            } else {
                Menu {
                    Picker("Restoration", selection: Binding(
                        get: { currentStyle },
                        set: { newStyle in
                            Task { await applyStyle(newStyle) }
                        }
                    )) {
                        Text("Original").tag(RestorationStyle?.none)
                        ForEach(RestorationStyle.allCases) { style in
                            Text(style.displayName).tag(RestorationStyle?.some(style))
                        }
                    }
                } label: {
                    Image(systemName: currentStyle != nil ? "wand.and.stars" : "wand.and.stars.inverse")
                        .font(.title3)
                        .foregroundStyle(currentStyle != nil ? .yellow : .primary)
                }
                .disabled(isLoading)
            }

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
        .background(Color("CardTint"))
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
        let cardData = card.spatialPhotoData()
        let cardUUID = card.uuid

        isLoading = true
        useFadeTransition = false

        do {
            let data = try await spatialPhotoService.spatialHEICData(
                for: cardData, style: currentStyle
            )
            withAnimation(.easeInOut(duration: 0.35)) {
                spatialPhotoData = data
                displayedCardUUID = cardUUID
            }
            prefetchAdjacent()
        } catch {
            logger.error("Failed to create spatial photo: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func applyStyle(_ style: RestorationStyle?) async {
        guard let card = viewModel.currentCard,
              card.hasStereoDetections else { return }
        let cardData = card.spatialPhotoData()
        let cardUUID = card.uuid

        isRestoring = true

        do {
            let data = try await spatialPhotoService.spatialHEICData(
                for: cardData,
                style: style
            )
            useFadeTransition = true
            withAnimation(.easeInOut(duration: 0.35)) {
                spatialPhotoData = data
                displayedCardUUID = cardUUID
                currentStyle = style
            }
        } catch {
            logger.error("Failed to create spatial photo: \(error.localizedDescription)")
        }
        isRestoring = false
    }

    private func prefetchAdjacent() {
        guard let idx = viewModel.currentIndex else { return }
        var adjacent: [SpatialPhotoCardData] = []
        if idx > 0 { adjacent.append(viewModel.cards[idx - 1].spatialPhotoData()) }
        if idx < viewModel.cards.count - 1 {
            adjacent.append(viewModel.cards[idx + 1].spatialPhotoData())
        }
        let style = currentStyle
        Task {
            await spatialPhotoService.prefetch(cards: adjacent, style: style)
        }
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func makePreviewViewModel() -> SpatialPhotoViewModel {
    let vm = SpatialPhotoViewModel()
    let cards = PreviewSampleData.sampleCards
    if let first = cards.first {
        vm.present(cards: cards, initialCardUUID: first.uuid)
    }
    return vm
}

#Preview(windowStyle: .plain) {
    SpatialPhotoView(spatialPhotoService: SpatialPhotoService())
        .environment(makePreviewViewModel())
        .previewEnvironment()
        .frame(width: 1280, height: 1024)
}
#endif

#endif
