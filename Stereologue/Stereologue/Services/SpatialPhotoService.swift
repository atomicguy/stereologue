//
//  SpatialPhotoService.swift
//  Stereologue
//
//  Cache and request-coalescing front for `StereoPairRenderer`.
//
//  The actor owns only cheap state: the in-memory HEIC cache, the on-disk
//  share directory, and the map of in-flight renders. The rendering itself
//  runs off-actor (`StereoPairRenderer` is `@concurrent`), so a cache hit or
//  a new request for card B is never queued behind a slow render of
//  card A. Waiters are counted per variant; when the last one cancels, the
//  render is cancelled too.
//

import Foundation
import Nuke
import OSLog
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

actor SpatialPhotoService {

    private let logger = Logger(
        subsystem: "net.atompowered.Stereologue",
        category: "SpatialPhoto"
    )

    private let renderer: StereoPairRenderer

    /// Directory where shareable spatial HEIC files are written.
    private let cacheDirectory: URL

    /// In-memory cache of generated spatial HEIC bytes, keyed by variant.
    ///
    /// The viewer builds a `CGImageSource` straight from these bytes, so the
    /// display path never writes to or reads back from disk. Bounded with a
    /// simple LRU; the bytes are also exactly what the share path needs.
    private var dataCache: [String: Data] = [:]
    private var dataCacheOrder: [String] = []
    private let dataCacheLimit = 16

    /// An in-progress render. `waiters` counts callers currently awaiting it;
    /// when a cancellation drops that to zero the task is cancelled. `token`
    /// lets the task's own cleanup recognize whether the entry is still its own
    /// (a cancelled entry can be replaced by a fresh render for the same key).
    private struct InFlight {
        let task: Task<Data, Error>
        let token: UUID
        var waiters: Int
    }
    private var inFlight: [String: InFlight] = [:]

    // MARK: - Initialization

    init(pipeline: ImagePipeline = .shared) {
        renderer = StereoPairRenderer(pipeline: pipeline)

        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        cacheDirectory = caches.appendingPathComponent(
            "SpatialPhotos", isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Cache Keys

    /// Cache/coalescing key for one rendered variant. Every input that changes
    /// the pixels is part of it: source quality, effective crop, and
    /// restoration style.
    nonisolated static func variantKey(
        for card: SpatialPhotoCardData,
        quality: String,
        style: RestorationStyle?
    ) -> String {
        var key = "\(card.uuid)_\(quality)_\(card.cropKey)"
        if let style { key += "_\(style.rawValue)" }
        return key
    }

    // MARK: - Public API

    /// Returns the spatial HEIC **bytes** for the given card, rendering them if
    /// needed.
    ///
    /// Results are cached in memory and concurrent requests for the same
    /// variant coalesce onto one render. Cancelling the calling task releases
    /// this caller's interest; the render itself is cancelled once nobody is
    /// waiting on it.
    ///
    /// - Parameters:
    ///   - card: Sendable card snapshot. Build with
    ///     `card.spatialPhotoData(cropOverride:)` on MainActor.
    ///   - quality: IIIF quality code for the source image (default "v" = 2560px).
    ///   - style: Tone restoration to apply, or `nil` for the original.
    ///   - priority: Priority of a render started by this call. Coalesced
    ///     callers escalate an existing render automatically.
    func spatialHEICData(
        for card: SpatialPhotoCardData,
        quality: String = "v",
        style: RestorationStyle? = nil,
        priority: TaskPriority = .userInitiated
    ) async throws -> Data {
        let variant = Self.variantKey(for: card, quality: quality, style: style)

        if let cached = dataCache[variant] {
            logger.debug("Cache hit for spatial photo: \(variant)")
            return cached
        }

        let entry: InFlight
        if var existing = inFlight[variant] {
            existing.waiters += 1
            inFlight[variant] = existing
            entry = existing
        } else {
            let token = UUID()
            let renderer = renderer
            let task = Task(priority: priority) {
                defer {
                    if inFlight[variant]?.token == token {
                        inFlight[variant] = nil
                    }
                }
                let data = try await renderer.spatialHEICData(
                    for: card, quality: quality, style: style
                )
                cacheData(data, for: variant)
                logger.info("Spatial photo generated in memory: \(variant)")
                return data
            }
            entry = InFlight(task: task, token: token, waiters: 1)
            inFlight[variant] = entry
        }

        let data = try await withTaskCancellationHandler {
            try await entry.task.value
        } onCancel: {
            Task { await self.abandon(variant, token: entry.token) }
        }
        // A caller cancelled while another waiter kept the render alive still
        // gets here with a value; report the cancellation instead so the view
        // that moved on doesn't apply stale data.
        try Task.checkCancellation()
        return data
    }

    /// Prefetches spatial photos for the given cards at low priority.
    /// Failures are logged but not thrown.
    func prefetch(
        cards: [SpatialPhotoCardData],
        quality: String = "v",
        style: RestorationStyle? = nil
    ) {
        for card in cards {
            guard card.hasStereoDetections else { continue }
            Task(priority: .utility) {
                do {
                    _ = try await spatialHEICData(
                        for: card, quality: quality, style: style,
                        priority: .utility
                    )
                } catch is CancellationError {
                } catch {
                    logger.warning(
                        "Prefetch failed for \(card.uuid): \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Returns a spatial HEIC URL with card metadata embedded, suitable for sharing.
    ///
    /// Always regenerates so the embedded IPTC/EXIF metadata is current. The
    /// metadata must be built on MainActor by the caller.
    func shareableSpatialPhotoURL(
        for card: SpatialPhotoCardData,
        metadata: SpatialPhotoMetadata,
        quality: String = "v"
    ) async throws -> URL {
        let outputURL = cacheDirectory.appendingPathComponent(
            "\(card.uuid)_\(quality)_share.heic"
        )
        try? FileManager.default.removeItem(at: outputURL)

        let data = try await renderer.spatialHEICData(
            for: card, quality: quality, style: nil, metadata: metadata
        )
        try data.write(to: outputURL)
        return outputURL
    }

    /// Returns the cropped left and right stereo pair as platform images.
    ///
    /// Useful for flat-screen stereo previews (wiggle stereoscopy, anaglyph, etc.)
    /// where individual images are needed rather than a spatial HEIC file.
    func croppedStereoPair(
        for card: SpatialPhotoCardData,
        quality: String = "v",
        style: RestorationStyle? = nil
    ) async throws -> (left: PlatformImage, right: PlatformImage) {
        let (leftFinal, rightFinal) = try await renderer.preparedStereoPair(
            for: card, quality: quality, style: style
        )

        #if canImport(UIKit)
        let left = UIImage(cgImage: leftFinal)
        let right = UIImage(cgImage: rightFinal)
        #elseif canImport(AppKit)
        let left = NSImage(cgImage: leftFinal, size: NSSize(
            width: leftFinal.width, height: leftFinal.height
        ))
        let right = NSImage(cgImage: rightFinal, size: NSSize(
            width: rightFinal.width, height: rightFinal.height
        ))
        #endif

        return (left, right)
    }

    /// Removes every cached spatial photo variant for a card (all qualities,
    /// crops, restoration styles, and the shareable copy).
    func evict(cardUUID: String) {
        let prefix = "\(cardUUID)_"
        for key in dataCacheOrder where key.hasPrefix(prefix) {
            dataCache[key] = nil
        }
        dataCacheOrder.removeAll { $0.hasPrefix(prefix) }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes all cached spatial photos.
    func evictAll() {
        dataCache.removeAll()
        dataCacheOrder.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Private

    /// Called when a waiter's task is cancelled. Drops its interest in the
    /// render and cancels the render once nobody else is waiting.
    private func abandon(_ variant: String, token: UUID) {
        guard var entry = inFlight[variant], entry.token == token else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            inFlight[variant] = nil
            logger.debug("Cancelled abandoned render: \(variant)")
        } else {
            inFlight[variant] = entry
        }
    }

    /// Inserts data into the bounded in-memory cache, evicting the oldest
    /// variants once the limit is exceeded.
    private func cacheData(_ data: Data, for key: String) {
        if dataCache[key] == nil { dataCacheOrder.append(key) }
        dataCache[key] = data
        while dataCacheOrder.count > dataCacheLimit {
            let evicted = dataCacheOrder.removeFirst()
            dataCache[evicted] = nil
        }
    }
}
