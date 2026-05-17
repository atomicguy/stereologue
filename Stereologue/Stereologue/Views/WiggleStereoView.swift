//
//  WiggleStereoView.swift
//  Stereologue
//
//  Wiggle stereoscopy viewer for flat screens.
//  Alternates between the left and right cropped stereo images
//  to create an illusion of depth without special hardware.
//

#if !os(visionOS)

import SwiftUI
#if os(iOS)
import CoreMotion
#endif

// MARK: - View Mode

private enum StereoViewMode: String, CaseIterable {
    case wiggle = "Wiggle"
    case motion = "Motion"
}

#if os(iOS)
// MARK: - Device Motion Manager

/// Tracks device tilt using CoreMotion to drive parallax between stereo images.
@Observable
private final class DeviceMotionManager {
    /// Normalized tilt value from -1 (left) to 1 (right).
    var tilt: Double = 0

    private let motionManager = CMMotionManager()
    private let updateInterval: TimeInterval = 1.0 / 60.0
    /// Reference roll captured when motion tracking starts.
    private var referenceRoll: Double?
    /// Maximum roll angle (radians) that maps to full tilt (~15 degrees).
    private let maxRollAngle: Double = 0.26

    var isAvailable: Bool {
        motionManager.isDeviceMotionAvailable
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        referenceRoll = nil
        motionManager.deviceMotionUpdateInterval = updateInterval
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = motion.attitude.roll
            if self.referenceRoll == nil {
                self.referenceRoll = roll
            }
            let delta = roll - (self.referenceRoll ?? 0)
            self.tilt = max(-1, min(1, delta / self.maxRollAngle))
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        referenceRoll = nil
        tilt = 0
    }

    func recalibrate() {
        referenceRoll = nil
    }
}
#endif

struct WiggleStereoView: View {
    let card: StereoCard
    let cropOverride: UserCropOverride?

    @Environment(\.spatialPhotoService) private var spatialPhotoService
    @Environment(\.dismiss) private var dismiss

    @State private var baseLeftImage: Image?
    @State private var baseRightImage: Image?
    @State private var restoredImages: [RestorationStyle: (left: Image, right: Image)] = [:]

    @State private var showingLeft = true
    @State private var isLoading = true
    @State private var loadingMessage = "Loading stereo pair…"
    @State private var error: String?
    @State private var isPlaying = true
    @State private var interval: Double = 0.15
    @State private var currentStyle: RestorationStyle?
    @State private var isRestoring = false
    @State private var restorationError: String?
    #if os(iOS)
    @State private var viewMode: StereoViewMode = .motion
    @State private var motionManager = DeviceMotionManager()
    #endif

    private var leftImage: Image? {
        if let style = currentStyle, let cached = restoredImages[style] {
            return cached.left
        }
        return baseLeftImage
    }

    private var rightImage: Image? {
        if let style = currentStyle, let cached = restoredImages[style] {
            return cached.right
        }
        return baseRightImage
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView(loadingMessage)
                    .foregroundStyle(.white)
            } else if let error {
                ContentUnavailableView(
                    "Unable to Load",
                    systemImage: "eye.slash",
                    description: Text(error)
                )
            } else {
                stereoContent
            }
        }
        .task { await loadImages() }
        .alert("Restoration Failed", isPresented: .init(
            get: { restorationError != nil },
            set: { if !$0 { restorationError = nil } }
        )) {
            Button("OK") { restorationError = nil }
        } message: {
            Text(restorationError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .navigationTitle(card.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .preferredColorScheme(.dark)
    }

    // MARK: - Stereo Content

    @ViewBuilder
    private var stereoContent: some View {
        ZStack {
            if let leftImage, let rightImage {
                #if os(iOS)
                if viewMode == .motion {
                    motionStereoContent(left: leftImage, right: rightImage)
                } else {
                    wiggleStereoContent(left: leftImage, right: rightImage)
                }
                #else
                wiggleStereoContent(left: leftImage, right: rightImage)
                #endif
            }
        }
        .overlay(alignment: .bottom) {
            controls
                .padding(.bottom, 40)
        }
    }

    /// Timer-based wiggle mode: alternates left/right on a timer.
    @ViewBuilder
    private func wiggleStereoContent(left: Image, right: Image) -> some View {
        ZStack {
            left
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(showingLeft ? 1 : 0)

            right
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(showingLeft ? 0 : 1)
        }
        .animation(.easeInOut(duration: 0.08), value: showingLeft)
        .onTapGesture {
            isPlaying.toggle()
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while isPlaying && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                showingLeft.toggle()
            }
        }
    }

    #if os(iOS)
    /// Motion-based mode: cross-fades based on device tilt.
    @ViewBuilder
    private func motionStereoContent(left: Image, right: Image) -> some View {
        // Map tilt (-1...1) to left image opacity.
        // tilt < 0 (tilted left) → show left image
        // tilt > 0 (tilted right) → show right image
        let leftOpacity = 1.0 - ((motionManager.tilt + 1.0) / 2.0)

        ZStack {
            left
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(leftOpacity)

            right
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(1.0 - leftOpacity)
        }
        .onAppear { motionManager.start() }
        .onDisappear { motionManager.stop() }
    }
    #endif

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            #if os(iOS)
            if motionManager.isAvailable {
                Picker("Mode", selection: $viewMode) {
                    ForEach(StereoViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            #endif

            HStack(spacing: 20) {
                #if os(iOS)
                if viewMode == .wiggle {
                    wiggleControls
                }
                #else
                wiggleControls
                #endif

                restoreMenu
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        #if os(iOS)
        .onChange(of: viewMode) { _, newMode in
            if newMode == .motion {
                isPlaying = false
                motionManager.start()
            } else {
                motionManager.stop()
                isPlaying = true
            }
        }
        #endif
    }

    private var wiggleControls: some View {
        HStack(spacing: 20) {
            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }

            HStack(spacing: 8) {
                Image(systemName: "tortoise")
                    .font(.caption)
                Slider(value: $interval, in: 0.06...0.5)
                    .frame(width: 140)
                Image(systemName: "hare")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var restoreMenu: some View {
        if isRestoring {
            ProgressView()
                .controlSize(.small)
        } else {
            Menu {
                Picker("Restoration", selection: Binding(
                    get: { currentStyle },
                    set: { selectStyle($0) }
                )) {
                    Text("Original").tag(RestorationStyle?.none)
                    ForEach(RestorationStyle.allCases) { style in
                        Text(style.displayName).tag(RestorationStyle?.some(style))
                    }
                }
            } label: {
                Image(systemName: currentStyle != nil ? "wand.and.stars" : "wand.and.stars.inverse")
                    .font(.title2)
                    .foregroundStyle(currentStyle != nil ? .yellow : .white)
            }
        }
    }

    // MARK: - Loading

    private func loadImages() async {
        guard let service = spatialPhotoService else {
            error = "Spatial photo service unavailable"
            isLoading = false
            return
        }
        let cardData = card.spatialPhotoData(cropOverride: cropOverride)

        do {
            loadingMessage = "Loading stereo pair…"
            let pair = try await service.croppedStereoPair(for: cardData)
            baseLeftImage = Image(platformImage: pair.left)
            baseRightImage = Image(platformImage: pair.right)
        } catch {
            self.error = String(describing: error)
        }
        isLoading = false
    }

    private func selectStyle(_ style: RestorationStyle?) {
        currentStyle = style
        if let style, restoredImages[style] == nil {
            Task { await loadRestoration(style: style) }
        }
    }

    private func loadRestoration(style: RestorationStyle) async {
        guard let service = spatialPhotoService else { return }
        let cardData = card.spatialPhotoData(cropOverride: cropOverride)

        isRestoring = true
        do {
            let pair = try await service.croppedStereoPair(
                for: cardData,
                style: style
            )
            restoredImages[style] = (
                Image(platformImage: pair.left),
                Image(platformImage: pair.right)
            )
        } catch {
            restorationError = error.localizedDescription
            if currentStyle == style {
                currentStyle = nil
            }
        }
        isRestoring = false
    }
}

// MARK: - Platform Image Bridging

#if canImport(UIKit)
import UIKit
private extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif canImport(AppKit)
import AppKit
private extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#endif

#endif
