//
//  RestorationEvalView.swift
//  Stereologue
//
//  Debug-only tool: renders the evaluation set at any style and tier for
//  side-by-side review, and exports PNGs for offline comparison.
//

#if DEBUG

import SwiftUI
import SwiftData
import ImageIO
import UniformTypeIdentifiers
import OSLog

struct RestorationEvalView: View {
    @Environment(\.spatialPhotoService) private var spatialPhotoService
    @Environment(\.modelContext) private var modelContext
    @Environment(UserDataService.self) private var userDataService
    @Environment(\.dismiss) private var dismiss

    @State private var evalSet: RestorationEvalSet?
    @State private var loadError: String?
    @State private var selected: RestorationEvalCard?
    @State private var style: RestorationStyle? = .enhance
    @State private var tier: RenderTier = .preview
    @State private var showRightEye = false

    @State private var original: (left: CGImage, right: CGImage)?
    @State private var rendered: (left: CGImage, right: CGImage)?
    @State private var isRendering = false
    @State private var renderTask: Task<Void, Never>?

    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress: (done: Int, total: Int)?
    @State private var exportFolder: URL?

    // Scratch-detector spike (Phase 3.3): overlay the Core ML mask on the
    // rendered pair. The model is loaded from Documents, not bundled.
    @State private var detector: ScratchDetector?
    @State private var detectorStatus = "Scratch detector: not loaded"
    @State private var showScratchMask = false
    @State private var maskThreshold: Float = 0.4
    @State private var maskedPair: (left: CGImage, right: CGImage)?
    @State private var maskStats: String?

    private static let logger = Logger(subsystem: "net.atompowered.Stereologue", category: "RestorationEval")

    var body: some View {
        Group {
            if let evalSet {
                content(evalSet)
            } else if let loadError {
                ContentUnavailableView("Evaluation Set Missing", systemImage: "flask", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Restoration Eval")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    renderTask?.cancel()
                    exportTask?.cancel()
                    dismiss()
                }
            }
        }
        .task {
            do { evalSet = try RestorationEvalSet.load() } catch { loadError = error.localizedDescription }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: - Layout

    private func content(_ evalSet: RestorationEvalSet) -> some View {
        HStack(spacing: 0) {
            cardList(evalSet)
                .frame(width: 300)
            Divider()
            VStack(spacing: 12) {
                controls
                comparison
                exportBar(evalSet)
            }
            .padding()
        }
    }

    private func cardList(_ evalSet: RestorationEvalSet) -> some View {
        List(selection: $selected) {
            ForEach(evalSet.byCategory, id: \.category) { group in
                Section(group.category.capitalized) {
                    ForEach(group.cards) { card in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title).lineLimit(2)
                            Text(card.note).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(card)
                    }
                }
            }
        }
        .onChange(of: selected) { render() }
        .onChange(of: style) { render() }
        .onChange(of: tier) { render() }
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            Picker("Style", selection: $style) {
                Text("Original").tag(RestorationStyle?.none)
                ForEach(RestorationStyle.allCases) { s in
                    Text(s.displayName).tag(RestorationStyle?.some(s))
                }
            }
            .pickerStyle(.segmented)
            Picker("Tier", selection: $tier) {
                ForEach(RenderTier.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Toggle("Right eye", isOn: $showRightEye)
                .toggleStyle(.switch)
        }
        HStack {
            Toggle("Scratch mask", isOn: $showScratchMask)
                .toggleStyle(.switch)
                .disabled(detector == nil)
                .onChange(of: showScratchMask) { updateMask() }
            if showScratchMask {
                Slider(value: $maskThreshold, in: 0.2...0.9, step: 0.05)
                    .frame(width: 160)
                    .onChange(of: maskThreshold) { updateMask() }
                Text("≥ \(maskThreshold, format: .number.precision(.fractionLength(2)))")
                    .monospacedDigit()
            }
            if detector == nil {
                Button("Load detector") { loadDetector() }
            }
            Text(maskStats ?? detectorStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    @ViewBuilder
    private var comparison: some View {
        if selected == nil {
            ContentUnavailableView("Select a card", systemImage: "photo.on.rectangle.angled")
        } else {
            HStack(spacing: 12) {
                eyePanel(title: "Original (preview)", pair: original)
                eyePanel(
                    title: "\(style?.displayName ?? "Original") · \(tier.displayName)"
                        + (showScratchMask && maskedPair != nil ? " · scratch mask" : ""),
                    pair: showScratchMask ? (maskedPair ?? rendered) : rendered
                )
            }
            .overlay {
                if isRendering { ProgressView().controlSize(.large) }
            }
        }
    }

    private func eyePanel(title: String, pair: (left: CGImage, right: CGImage)?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Group {
                if let pair {
                    let eye = showRightEye ? pair.right : pair.left
                    Image(decorative: eye, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay(alignment: .bottomTrailing) {
                            Text("\(eye.width)×\(eye.height)")
                                .font(.caption2.monospacedDigit())
                                .padding(4)
                                .background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func exportBar(_ evalSet: RestorationEvalSet) -> some View {
        HStack {
            if let exportProgress {
                ProgressView(value: Double(exportProgress.done), total: Double(max(1, exportProgress.total)))
                    .frame(width: 200)
                Text("\(exportProgress.done)/\(exportProgress.total)")
                    .monospacedDigit()
                Button("Cancel") { exportTask?.cancel() }
            } else {
                Button("Export All Styles as PNG (\(tier.displayName))") { exportAll(evalSet) }
                    .disabled(spatialPhotoService == nil)
            }
            Spacer()
            if let exportFolder {
                Text(exportFolder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                #if os(macOS)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([exportFolder]) }
                #endif
            }
        }
    }

    // MARK: - Rendering

    private func cardData(for card: RestorationEvalCard) -> SpatialPhotoCardData? {
        guard let model = modelContext.cards(matching: [card.uuid]).first else { return nil }
        return model.spatialPhotoData(cropOverride: userDataService.cropOverride(for: card.uuid))
    }

    private func render() {
        renderTask?.cancel()
        guard let selected, let service = spatialPhotoService, let data = cardData(for: selected) else {
            original = nil
            rendered = nil
            return
        }
        let style = style
        let tier = tier
        isRendering = true
        renderTask = Task {
            defer { isRendering = false }
            do {
                async let base = service.preparedStereoPair(for: data, style: nil, tier: .preview)
                async let look = service.preparedStereoPair(for: data, style: style, tier: tier)
                let (baseResult, lookResult) = try await (base, look)
                original = baseResult
                rendered = lookResult
                maskedPair = nil
                maskStats = nil
                updateMask()
            } catch is CancellationError {
            } catch {
                Self.logger.error("Eval render failed: \(error.localizedDescription)")
                loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Scratch detector

    private func loadDetector() {
        detectorStatus = "Scratch detector: loading…"
        Task.detached {
            do {
                let loaded = try ScratchDetector.load()
                await MainActor.run {
                    detector = loaded
                    detectorStatus = "Scratch detector: \(loaded.inputSize)px model loaded"
                    updateMask()
                }
            } catch {
                await MainActor.run { detectorStatus = "Scratch detector: \(error.localizedDescription)" }
            }
        }
    }

    /// Recomputes the red overlay and the mask density for the rendered pair.
    private func updateMask() {
        guard showScratchMask, let detector, let pair = rendered else { return }
        let threshold = maskThreshold
        Task.detached {
            let left = detector.overlay(on: pair.left, threshold: threshold)
            let right = detector.overlay(on: pair.right, threshold: threshold)
            let stats = detector.maskFractions(for: pair.left, threshold: threshold)
            await MainActor.run {
                if let left, let right { maskedPair = (left, right) }
                if let stats {
                    maskStats = String(format: "left eye: %.2f%% flagged, %.2f%% excluding a 6%% border",
                                       stats.whole * 100, stats.interior * 100)
                }
            }
        }
    }

    // MARK: - Export

    /// Writes `<uuid>_<eye>_<style>.png` for every card and style at the
    /// selected tier into a dated folder under the app's Documents directory.
    private func exportAll(_ evalSet: RestorationEvalSet) {
        guard let service = spatialPhotoService else { return }
        let styles: [RestorationStyle?] = [nil] + RestorationStyle.allCases
        let jobs = evalSet.cards.flatMap { card in styles.map { (card, $0) } }
        let tier = tier
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let folder = URL.documentsDirectory
            .appendingPathComponent("RestorationEval", isDirectory: true)
            .appendingPathComponent("\(stamp)_\(tier.rawValue)", isDirectory: true)
        let inputs = jobs.compactMap { card, style in cardData(for: card).map { ($0, card.category, style) } }

        exportProgress = (0, inputs.count)
        exportFolder = folder
        exportTask = Task {
            defer { exportProgress = nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, job) in inputs.enumerated() {
                    try Task.checkCancellation()
                    let (data, category, style) = job
                    let pair = try await service.preparedStereoPair(for: data, style: style, tier: tier)
                    let styleName = style?.rawValue ?? "original"
                    try Self.writePNG(pair.left, to: folder.appendingPathComponent("\(category)_\(data.uuid)_L_\(styleName).png"))
                    try Self.writePNG(pair.right, to: folder.appendingPathComponent("\(category)_\(data.uuid)_R_\(styleName).png"))
                    exportProgress = (index + 1, inputs.count)
                }
            } catch is CancellationError {
            } catch {
                Self.logger.error("Eval export failed: \(error.localizedDescription)")
                loadError = error.localizedDescription
            }
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

#Preview(traits: .fixedLayout(width: 1100, height: 700)) {
    NavigationStack {
        RestorationEvalView()
    }
    .previewEnvironment()
}

#endif
