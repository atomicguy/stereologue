//
//  CropEditorView.swift
//  Stereologue
//
//  Interactive editor for adjusting left/right stereo crop bounding boxes.
//  iPadOS/macOS: drag handles on the image.
//  visionOS: slider-based controls with a live preview.
//

import SwiftUI
import NukeUI

struct CropEditorView: View {
    let card: StereoCard
    @Environment(UserDataService.self) private var userDataService
    @Environment(\.dismiss) private var dismiss

    // Working copies of the detections being edited (in image-pixel coordinates)
    @State private var leftDetection: ImageDetection
    @State private var rightDetection: ImageDetection
    @State private var hasOverride: Bool

    init(card: StereoCard, existingOverride: UserCropOverride?) {
        self.card = card
        let left = existingOverride?.leftDetection ?? card.leftDetection
        let right = existingOverride?.rightDetection ?? card.rightDetection
        _leftDetection = State(initialValue: left)
        _rightDetection = State(initialValue: right)
        _hasOverride = State(initialValue: existingOverride != nil)
    }

    var body: some View {
        NavigationStack {
            editorBody
                .navigationTitle("Edit Crops")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                    }
                    if hasOverride {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Reset to ML", role: .destructive) { resetToML() }
                        }
                    }
                }
        }
    }

    // MARK: - Platform-specific editor body

    @ViewBuilder
    private var editorBody: some View {
        #if os(visionOS)
        sliderEditorBody
        #else
        dragEditorBody
        #endif
    }

    // MARK: - Drag-based editor (iPadOS / macOS)

    #if !os(visionOS)
    @ViewBuilder
    private var dragEditorBody: some View {
        GeometryReader { geo in
            if let url = card.frontImageURL(quality: "q") {
                dragEditorContent(url: url, containerSize: geo.size)
            } else {
                ContentUnavailableView(
                    "No Image",
                    systemImage: "photo",
                    description: Text("This card has no front image.")
                )
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
    }

    @ViewBuilder
    private func dragEditorContent(url: URL, containerSize: CGSize) -> some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                dragImageLayer(image: image, containerSize: containerSize)
            } else if state.error != nil {
                ContentUnavailableView(
                    "Failed to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Could not load the card image.")
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func dragImageLayer(image: Image, containerSize: CGSize) -> some View {
        let imgW = card.imageWidth ?? 1
        let imgH = card.imageHeight ?? 1
        let aspectRatio = imgW / imgH
        let fitSize = fitSize(aspect: aspectRatio, within: containerSize)
        let scaleX = fitSize.width / imgW
        let scaleY = fitSize.height / imgH

        ZStack {
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: fitSize.width, height: fitSize.height)

            DraggableBox(
                detection: $leftDetection,
                color: .blue,
                label: "L",
                scaleX: scaleX,
                scaleY: scaleY,
                imageSize: fitSize
            )

            DraggableBox(
                detection: $rightDetection,
                color: .green,
                label: "R",
                scaleX: scaleX,
                scaleY: scaleY,
                imageSize: fitSize
            )
        }
        .frame(width: fitSize.width, height: fitSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    // MARK: - Slider-based editor (visionOS)

    #if os(visionOS)
    /// Which box is being edited
    @State private var selectedSide: CropSide = .left

    enum CropSide: String, CaseIterable, Identifiable {
        case left = "Left"
        case right = "Right"
        var id: String { rawValue }
    }

    private var selectedDetection: Binding<ImageDetection> {
        selectedSide == .left ? $leftDetection : $rightDetection
    }

    private var selectedColor: Color {
        selectedSide == .left ? .blue : .green
    }

    @ViewBuilder
    private var sliderEditorBody: some View {
        VStack(spacing: 0) {
            // Image preview with overlay boxes
            sliderImagePreview
                .frame(maxHeight: .infinity)

            Divider()

            // Slider controls
            sliderControls
                .padding()
                .frame(height: 220)
        }
    }

    @ViewBuilder
    private var sliderImagePreview: some View {
        GeometryReader { geo in
            if let url = card.frontImageURL(quality: "q") {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        sliderPreviewLayer(image: image, containerSize: geo.size)
                    } else if state.error != nil {
                        ContentUnavailableView(
                            "Failed to Load",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Could not load the card image.")
                        )
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func sliderPreviewLayer(image: Image, containerSize: CGSize) -> some View {
        let imgW = card.imageWidth ?? 1
        let imgH = card.imageHeight ?? 1
        let aspectRatio = imgW / imgH
        let fitSize = fitSize(aspect: aspectRatio, within: containerSize)
        let scaleX = fitSize.width / imgW
        let scaleY = fitSize.height / imgH

        ZStack {
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: fitSize.width, height: fitSize.height)

            // Read-only box overlays
            detectionBoxOverlay(leftDetection, scaleX: scaleX, scaleY: scaleY,
                                color: .blue, label: "L",
                                isSelected: selectedSide == .left)
            detectionBoxOverlay(rightDetection, scaleX: scaleX, scaleY: scaleY,
                                color: .green, label: "R",
                                isSelected: selectedSide == .right)
        }
        .frame(width: fitSize.width, height: fitSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func detectionBoxOverlay(
        _ detection: ImageDetection,
        scaleX: Double, scaleY: Double,
        color: Color, label: String,
        isSelected: Bool
    ) -> some View {
        let w = detection.width * scaleX
        let h = detection.height * scaleY
        let cx = detection.x * scaleX
        let cy = detection.y * scaleY

        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(color, lineWidth: isSelected ? 3 : 1.5)
            .background(color.opacity(isSelected ? 0.12 : 0.04))
            .overlay(alignment: .top) {
                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.8), in: Capsule())
                    .offset(y: -14)
            }
            .frame(width: w, height: h)
            .position(x: cx, y: cy)
    }

    @ViewBuilder
    private var sliderControls: some View {
        let imgW = card.imageWidth ?? 1
        let imgH = card.imageHeight ?? 1
        let det = selectedDetection

        VStack(spacing: 12) {
            // Side picker
            Picker("Side", selection: $selectedSide) {
                ForEach(CropSide.allCases) { side in
                    Text(side.rawValue).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            // Edge sliders in a 2x2 grid
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    edgeSlider(label: "Left Edge",
                               value: Binding(
                                get: { det.wrappedValue.x - det.wrappedValue.width / 2 },
                                set: { newLeft in
                                    let right = det.wrappedValue.x + det.wrappedValue.width / 2
                                    let clamped = min(newLeft, right - 20)
                                    det.wrappedValue.width = right - clamped
                                    det.wrappedValue.x = (clamped + right) / 2
                                }
                               ),
                               range: 0...imgW)

                    edgeSlider(label: "Right Edge",
                               value: Binding(
                                get: { det.wrappedValue.x + det.wrappedValue.width / 2 },
                                set: { newRight in
                                    let left = det.wrappedValue.x - det.wrappedValue.width / 2
                                    let clamped = max(newRight, left + 20)
                                    det.wrappedValue.width = clamped - left
                                    det.wrappedValue.x = (left + clamped) / 2
                                }
                               ),
                               range: 0...imgW)
                }

                VStack(alignment: .leading, spacing: 8) {
                    edgeSlider(label: "Top Edge",
                               value: Binding(
                                get: { det.wrappedValue.y - det.wrappedValue.height / 2 },
                                set: { newTop in
                                    let bottom = det.wrappedValue.y + det.wrappedValue.height / 2
                                    let clamped = min(newTop, bottom - 20)
                                    det.wrappedValue.height = bottom - clamped
                                    det.wrappedValue.y = (clamped + bottom) / 2
                                }
                               ),
                               range: 0...imgH)

                    edgeSlider(label: "Bottom Edge",
                               value: Binding(
                                get: { det.wrappedValue.y + det.wrappedValue.height / 2 },
                                set: { newBottom in
                                    let top = det.wrappedValue.y - det.wrappedValue.height / 2
                                    let clamped = max(newBottom, top + 20)
                                    det.wrappedValue.height = clamped - top
                                    det.wrappedValue.y = (top + clamped) / 2
                                }
                               ),
                               range: 0...imgH)
                }
            }
        }
    }

    private func edgeSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .tint(Color.accentColor)
        }
    }
    #endif

    // MARK: - Shared Helpers

    private func fitSize(aspect: Double, within container: CGSize) -> CGSize {
        let containerAspect = container.width / container.height
        if aspect > containerAspect {
            let w = container.width
            return CGSize(width: w, height: w / aspect)
        } else {
            let h = container.height
            return CGSize(width: h * aspect, height: h)
        }
    }

    // MARK: - Actions

    private func save() {
        userDataService.saveCropOverride(
            cardUUID: card.uuid,
            leftDetection: leftDetection,
            rightDetection: rightDetection
        )
        dismiss()
    }

    private func resetToML() {
        userDataService.deleteCropOverride(for: card.uuid)
        leftDetection = card.leftDetection
        rightDetection = card.rightDetection
        hasOverride = false
    }
}

// MARK: - Draggable Bounding Box

/// An interactive bounding box overlay that can be moved and resized.
/// The detection coordinates are in image-pixel space (center x/y, width, height).
/// The view maps them to screen space using scale factors.
private struct DraggableBox: View {
    @Binding var detection: ImageDetection
    let color: Color
    let label: String
    let scaleX: Double
    let scaleY: Double
    let imageSize: CGSize

    /// Snapshot of the detection at drag start, so cumulative translation works correctly.
    @State private var dragStart: ImageDetection?

    private let minBoxSize: CGFloat = 30
    private let handleVisualSize: CGFloat = 12
    private let handleHitSize: CGFloat = 44

    enum Handle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case body
    }

    // Screen-space rect derived from detection
    private var screenRect: CGRect {
        let w = detection.width * scaleX
        let h = detection.height * scaleY
        let cx = detection.x * scaleX
        let cy = detection.y * scaleY
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    var body: some View {
        // Layer 1: Box outline with low-priority body drag
        Rectangle()
            .strokeBorder(color, lineWidth: 2)
            .background(color.opacity(0.08))
            .frame(width: screenRect.width, height: screenRect.height)
            .position(x: screenRect.midX, y: screenRect.midY)
            .gesture(dragGesture(for: .body))

        // Layer 2: Label (no gesture)
        Text(label)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.8), in: Capsule())
            .position(x: screenRect.midX, y: screenRect.minY - 14)
            .allowsHitTesting(false)

        // Layer 3: Handles on top — each is a large invisible hit area with a small visible dot
        handleView(at: CGPoint(x: screenRect.minX, y: screenRect.minY), handle: .topLeft)
        handleView(at: CGPoint(x: screenRect.maxX, y: screenRect.minY), handle: .topRight)
        handleView(at: CGPoint(x: screenRect.minX, y: screenRect.maxY), handle: .bottomLeft)
        handleView(at: CGPoint(x: screenRect.maxX, y: screenRect.maxY), handle: .bottomRight)
        handleView(at: CGPoint(x: screenRect.midX, y: screenRect.minY), handle: .top)
        handleView(at: CGPoint(x: screenRect.midX, y: screenRect.maxY), handle: .bottom)
        handleView(at: CGPoint(x: screenRect.minX, y: screenRect.midY), handle: .left)
        handleView(at: CGPoint(x: screenRect.maxX, y: screenRect.midY), handle: .right)
    }

    @ViewBuilder
    private func handleView(at point: CGPoint, handle: Handle) -> some View {
        let isCorner: Bool = {
            switch handle {
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            default: return false
            }
        }()
        let dotSize = isCorner ? handleVisualSize : handleVisualSize * 0.7

        // Large invisible hit target with small visible circle inside
        Color.clear
            .frame(width: handleHitSize, height: handleHitSize)
            .contentShape(Rectangle())
            .overlay {
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .frame(width: dotSize, height: dotSize)
            }
            .position(x: point.x, y: point.y)
            .gesture(dragGesture(for: handle))
    }

    private func dragGesture(for handle: Handle) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    dragStart = detection
                }
                guard let start = dragStart else { return }
                applyDrag(handle: handle, translation: value.translation, start: start)
            }
            .onEnded { _ in
                dragStart = nil
                clampDetection()
            }
    }

    /// Applies cumulative drag translation to the snapshot taken at drag start.
    private func applyDrag(handle: Handle, translation: CGSize, start: ImageDetection) {
        let dx = translation.width / scaleX
        let dy = translation.height / scaleY
        let imgW = imageSize.width / scaleX
        let imgH = imageSize.height / scaleY
        let minW = minBoxSize / scaleX
        let minH = minBoxSize / scaleY

        switch handle {
        case .body:
            detection.x = clamp(start.x + dx, min: start.width / 2, max: imgW - start.width / 2)
            detection.y = clamp(start.y + dy, min: start.height / 2, max: imgH - start.height / 2)
            detection.width = start.width
            detection.height = start.height

        default:
            let origLeft = start.x - start.width / 2
            let origRight = start.x + start.width / 2
            let origTop = start.y - start.height / 2
            let origBottom = start.y + start.height / 2

            var newLeft = origLeft
            var newRight = origRight
            var newTop = origTop
            var newBottom = origBottom

            switch handle {
            case .topLeft:      newLeft += dx; newTop += dy
            case .topRight:     newRight += dx; newTop += dy
            case .bottomLeft:   newLeft += dx; newBottom += dy
            case .bottomRight:  newRight += dx; newBottom += dy
            case .top:          newTop += dy
            case .bottom:       newBottom += dy
            case .left:         newLeft += dx
            case .right:        newRight += dx
            case .body:         break
            }

            if newRight - newLeft < minW {
                switch handle {
                case .topLeft, .bottomLeft, .left:
                    newLeft = newRight - minW
                default:
                    newRight = newLeft + minW
                }
            }
            if newBottom - newTop < minH {
                switch handle {
                case .topLeft, .topRight, .top:
                    newTop = newBottom - minH
                default:
                    newBottom = newTop + minH
                }
            }

            detection.width = newRight - newLeft
            detection.height = newBottom - newTop
            detection.x = (newLeft + newRight) / 2
            detection.y = (newTop + newBottom) / 2
        }
    }

    private func clampDetection() {
        let maxW = imageSize.width / scaleX
        let maxH = imageSize.height / scaleY
        detection.width = clamp(detection.width, min: minBoxSize / scaleX, max: maxW)
        detection.height = clamp(detection.height, min: minBoxSize / scaleY, max: maxH)
        detection.x = clamp(detection.x, min: detection.width / 2, max: maxW - detection.width / 2)
        detection.y = clamp(detection.y, min: detection.height / 2, max: maxH - detection.height / 2)
    }

    private func clamp(_ value: Double, min minVal: Double, max maxVal: Double) -> Double {
        Swift.min(Swift.max(value, minVal), maxVal)
    }
}
