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

struct WiggleStereoView: View {
    let card: StereoCard
    let cropOverride: UserCropOverride?

    @Environment(\.spatialPhotoService) private var spatialPhotoService
    @Environment(\.dismiss) private var dismiss

    @State private var leftImage: Image?
    @State private var rightImage: Image?
    @State private var showingLeft = true
    @State private var isLoading = true
    @State private var error: String?
    @State private var isPlaying = true
    @State private var interval: Double = 0.15

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView("Loading stereo pair…")
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
                leftImage
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(showingLeft ? 1 : 0)

                rightImage
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(showingLeft ? 0 : 1)
            }
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
        .overlay(alignment: .bottom) {
            controls
                .padding(.bottom, 40)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }

                // Speed control
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Loading

    private func loadImages() async {
        guard let service = spatialPhotoService else {
            error = "Spatial photo service unavailable"
            isLoading = false
            return
        }

        do {
            let pair = try await service.croppedStereoPair(
                for: card,
                cropOverride: cropOverride
            )
            leftImage = Image(platformImage: pair.left)
            rightImage = Image(platformImage: pair.right)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
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
