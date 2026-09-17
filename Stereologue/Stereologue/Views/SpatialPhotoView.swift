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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let spatialPhotoService: SpatialPhotoService

    @State private var spatialPhotoData: Data?
    @State private var isLoading = false
    @State private var isRestoring = false
    @State private var currentStyle: RestorationStyle?
    /// Render at source resolution instead of the preview cap. Explicit
    /// user request only; prefetch always warms the preview tier.
    @State private var fullResolution = false
    private var tier: RenderTier { fullResolution ? .full : .preview }
    @State private var displayedCardUUID: String?
    @State private var useFadeTransition = false
    @State private var isFavorite = false
    @State private var loadError: String?
    /// The in-progress restoration render, so the spinner can cancel it.
    @State private var restoreTask: Task<Void, Never>?

    var body: some View {
        GeometryReader3D { geometry in
            ZStack {
                // Spatial photo with push transition
                if let spatialPhotoData {
                    spatialPhotoContent(data: spatialPhotoData, geometry: geometry)
                        .id("\(displayedCardUUID ?? "")_\(currentStyle?.rawValue ?? "none")_\(tier.rawValue)")
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
        .alert("Couldn't Load Photo", isPresented: .init(
            get: { loadError != nil },
            set: { if !$0 { loadError = nil } }
        )) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }

    /// Snapshot of the card plus any user crop override, built on MainActor.
    /// Resolves the model by indexed UUID; only the cards actually rendered
    /// (current and its neighbors) are ever materialized.
    private func cardData(forUUID uuid: String) -> SpatialPhotoCardData? {
        guard let card = modelContext.cards(matching: [uuid]).first else { return nil }
        return card.spatialPhotoData(
            cropOverride: userDataService.cropOverride(for: uuid)
        )
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
                component.desiredViewingMode = .spatialStereo
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
            if let row = viewModel.currentRow {
                Text(row.title)
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
                        ForEach(viewModel.rows, id: \.uuid) { row in
                            thumbnailItem(row: row)
                                .id(row.uuid)
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

            if isRestoring {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Button {
                        restoreTask?.cancel()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel restoration")
                }
            } else {
                Menu {
                    Picker("Restoration", selection: Binding(
                        get: { currentStyle },
                        set: { newStyle in
                            applyRender(style: newStyle, fullResolution: fullResolution)
                        }
                    )) {
                        Text("Original").tag(RestorationStyle?.none)
                        ForEach(RestorationStyle.allCases) { style in
                            Text(style.displayName).tag(RestorationStyle?.some(style))
                        }
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { fullResolution },
                        set: { applyRender(style: currentStyle, fullResolution: $0) }
                    )) {
                        Label("Full Resolution", systemImage: "arrow.up.left.and.arrow.down.right")
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

    private func thumbnailItem(row: CardRow) -> some View {
        Button {
            guard row.uuid != viewModel.currentCardUUID else { return }
            if let currentIdx = viewModel.currentIndex,
               let targetIdx = viewModel.index(of: row.uuid) {
                viewModel.navigationDirection = targetIdx > currentIdx
                    ? .forward : .backward
            }
            withAnimation(.easeInOut(duration: 0.35)) {
                viewModel.currentCardUUID = row.uuid
            }
        } label: {
            CardThumbnailView(row: row)
                .overlay {
                    if row.uuid == viewModel.currentCardUUID {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white, lineWidth: 2)
                    }
                }
                .opacity(row.uuid == viewModel.currentCardUUID ? 1.0 : 0.6)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    // MARK: - Loading

    private func loadSpatialPhoto() async {
        guard let row = viewModel.currentRow,
              row.hasStereoDetections,
              let cardData = cardData(forUUID: row.uuid) else { return }
        let cardUUID = row.uuid

        // Navigating away cancels any restoration still rendering for the
        // previous card.
        restoreTask?.cancel()
        isRestoring = false
        isLoading = true
        useFadeTransition = false

        do {
            let data = try await spatialPhotoService.spatialHEICData(
                for: cardData, style: currentStyle, tier: tier
            )
            withAnimation(.easeInOut(duration: 0.35)) {
                spatialPhotoData = data
                displayedCardUUID = cardUUID
            }
            prefetchAdjacent()
        } catch is CancellationError {
            // Superseded by a newer card; the newer task owns the state now.
            return
        } catch {
            logger.error("Failed to create spatial photo: \(error.localizedDescription)")
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Renders the current card with the requested style and tier. The
    /// previous in-progress render (if any) is cancelled first, so rapid menu
    /// changes don't pile up.
    private func applyRender(style: RestorationStyle?, fullResolution: Bool) {
        guard let row = viewModel.currentRow,
              row.hasStereoDetections,
              let cardData = cardData(forUUID: row.uuid) else { return }
        let cardUUID = row.uuid

        restoreTask?.cancel()
        isRestoring = true
        restoreTask = Task {
            defer { isRestoring = false }
            do {
                let data = try await spatialPhotoService.spatialHEICData(
                    for: cardData, style: style, tier: fullResolution ? .full : .preview
                )
                useFadeTransition = true
                withAnimation(.easeInOut(duration: 0.35)) {
                    spatialPhotoData = data
                    displayedCardUUID = cardUUID
                    currentStyle = style
                    self.fullResolution = fullResolution
                }
            } catch is CancellationError {
                // User cancelled or changed their mind; keep what's showing.
            } catch {
                logger.error("Failed to create spatial photo: \(error.localizedDescription)")
                loadError = error.localizedDescription
            }
        }
    }

    /// Warms the neighbors at the current style.
    private func prefetchAdjacent() {
        guard let idx = viewModel.currentIndex else { return }
        let rows = viewModel.rows
        let adjacent = [idx - 1, idx + 1]
            .filter { rows.indices.contains($0) }
            .compactMap { cardData(forUUID: rows[$0].uuid) }
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
    let rows = PreviewSampleData.sampleRows
    if let first = rows.first {
        vm.present(rows: rows, initialCardUUID: first.uuid)
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
