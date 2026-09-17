//
//  ReloadableImage.swift
//  Stereologue
//
//  A `LazyImage` whose failure is visible and recoverable: the failed state
//  is drawn distinctly and tapping it restarts the request.
//

import SwiftUI
import Nuke
import NukeUI

/// What a `ReloadableImage` shows while it has no image.
enum ImageLoadPhase {
    /// The request is in flight.
    case loading
    /// The request failed. Calling `reload` starts a fresh one.
    case failed(reload: () -> Void)
}

/// Wraps `LazyImage` with a distinct, tappable failed state.
///
/// `LazyImage` only starts a request when it appears or when its request
/// changes, so a cell whose download fails while it stays on screen (a
/// stalled NYPL connection, or the headset coming off mid-download on
/// visionOS) stays failed until it is scrolled away and back. This view hands
/// the placeholder a `reload` closure that gives the `LazyImage` a fresh
/// identity, which re-issues the request. Nuke never caches failures, so the
/// retry is a real download.
struct ReloadableImage<Content: View, Placeholder: View>: View {
    private let request: ImageRequest?
    private let priority: ImageRequest.Priority
    private let onCompletion: ((Result<ImageResponse, Error>) -> Void)?
    private let content: (Image) -> Content
    private let placeholder: (ImageLoadPhase) -> Placeholder

    /// Incremented by `reload`; used as the `LazyImage`'s identity.
    @State private var attempt = 0

    /// - Parameters:
    ///   - request: The image request, or `nil` to show the loading
    ///     placeholder permanently (a card with no image ID).
    ///   - priority: Request priority.
    ///   - onCompletion: Called once per attempt with the result.
    ///   - content: Renders the loaded image.
    ///   - placeholder: Renders the loading or failed state. For the failed
    ///     state, overlay an `ImageReloadButton` (or any control) that calls
    ///     the phase's `reload`.
    init(
        request: ImageRequest?,
        priority: ImageRequest.Priority = .normal,
        onCompletion: ((Result<ImageResponse, Error>) -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping (ImageLoadPhase) -> Placeholder
    ) {
        self.request = request
        self.priority = priority
        self.onCompletion = onCompletion
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        if let request {
            LazyImage(request: request) { state in
                if let image = state.image {
                    content(image)
                } else if state.error != nil {
                    placeholder(.failed(reload: { attempt += 1 }))
                } else {
                    placeholder(.loading)
                }
            }
            .priority(priority)
            .onCompletion { onCompletion?($0) }
            .transition(.opacity)
            .id(attempt)
        } else {
            placeholder(.loading)
        }
    }
}

/// The standard "tap to reload" control shown over a failed image.
///
/// A nested button wins the tap over an enclosing `NavigationLink`, so it is
/// safe to overlay on grid cells: tapping the badge reloads, tapping anywhere
/// else on the cell still navigates.
struct ImageReloadButton: View {
    /// `false` for small thumbnails, where only the icon fits.
    var showsLabel = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(showsLabel ? .body : .caption2)
                if showsLabel {
                    Text("Tap to reload")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, showsLabel ? 10 : 4)
            .padding(.vertical, showsLabel ? 6 : 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reload image")
        #if os(iOS) || os(visionOS)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 8))
        .hoverEffect(.highlight)
        #endif
    }
}

/// A placeholder fill that is visible on every platform, including over
/// visionOS glass, where `.quaternary` all but disappears.
extension ShapeStyle where Self == Color {
    static var placeholderFill: Color { Color(.systemFill) }
}
