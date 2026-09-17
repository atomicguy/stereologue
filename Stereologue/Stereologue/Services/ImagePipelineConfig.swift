//
//  ImagePipelineConfig.swift
//  Stereologue
//
//  Configures a shared Nuke ImagePipeline optimized for browsing
//  a large catalog of NYPL stereoview card images.
//

import Foundation
import Nuke
import OSLog
import Synchronization

extension ImagePipeline {
    /// Configured pipeline for the Stereologue catalog.
    ///
    /// - 100 MB memory cache (holds ~200 grid thumbnails in memory)
    /// - 500 MB disk cache (persistent across launches), and no `URLCache`
    ///   underneath it so bytes aren't written to disk twice
    /// - 20 s request timeout with retries for stalled connections (the NYPL
    ///   image server intermittently accepts a connection and never answers)
    /// - Only bytes that decode as an image are written to the disk cache, so
    ///   a bad response can never poison a URL until eviction
    /// - Deduplication enabled (avoids redundant downloads for the same URL)
    /// - Progressive decoding disabled (NYPL IIIF returns complete JPEGs)
    nonisolated static let stereologue: ImagePipeline = {
        var config = ImagePipeline.Configuration()

        // Memory cache: ~100 MB
        config.imageCache = ImageCache(costLimit: 100 * 1024 * 1024, countLimit: 500)

        // Disk cache: ~500 MB
        let dataCache = try? DataCache(name: "net.atompowered.Stereologue.ImageCache")
        dataCache?.sizeLimit = 500 * 1024 * 1024
        config.dataCache = dataCache

        // Nuke's default session keeps a 150 MB `URLCache`; with a `DataCache`
        // in front of it that only doubles the disk footprint.
        let session = URLSessionConfiguration.default
        session.urlCache = nil
        session.timeoutIntervalForRequest = 20
        config.dataLoader = RetryingDataLoader(base: DataLoader(configuration: session))

        config.isProgressiveDecodingEnabled = false

        return ImagePipeline(configuration: config, delegate: StereologuePipelineDelegate())
    }()

    /// Drops every cached image, in memory and on disk, including anything
    /// Nuke's default `URLCache` stored before this app stopped using it.
    nonisolated static func clearStereologueCaches() {
        stereologue.cache.removeAll()
        DataLoader.sharedUrlCache.removeAllCachedResponses()
    }
}

// MARK: - Cache Validation

/// Refuses to write bytes to the disk cache unless they carry an image
/// signature. Nuke stores downloaded data *before* decoding it, so without
/// this a 200 response with an HTML or text body would be served from disk
/// (and fail to decode) on every later request for that URL.
private nonisolated final class StereologuePipelineDelegate: ImagePipeline.Delegate, Sendable {

    private static let logger = Logger(
        subsystem: "net.atompowered.Stereologue", category: "ImageCache"
    )

    func willCache(
        data: Data,
        image: ImageContainer?,
        for request: ImageRequest,
        pipeline: ImagePipeline,
        completion: @escaping (Data?) -> Void
    ) {
        if ImageSignature.matches(data) {
            completion(data)
        } else {
            Self.logger.warning(
                "Not caching non-image response (\(data.count) bytes) for \(request.url?.absoluteString ?? "?", privacy: .public)"
            )
            completion(nil)
        }
    }
}

/// Magic-number check for the image formats the pipeline can decode.
nonisolated enum ImageSignature {
    static func matches(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        // JPEG
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }
        // PNG
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }
        // GIF87a / GIF89a
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return true }
        // HEIF family (HEIC/AVIF): ISO BMFF "ftyp" box at offset 4
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return true }
        // WebP: "RIFF" .... "WEBP"
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }
        return false
    }
}

// MARK: - Retrying Loader

/// Wraps Nuke's `DataLoader` and retries a request that failed before any
/// byte arrived — a timeout, a dropped connection, or a 5xx/429 — with a
/// short backoff. A request that already streamed data is never retried, so
/// the caller never sees bytes twice.
nonisolated final class RetryingDataLoader: DataLoading {

    private let base: DataLoader
    private let maxRetries: Int

    init(base: DataLoader, maxRetries: Int = 2) {
        self.base = base
        self.maxRetries = maxRetries
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Nuke.Cancellable {
        let handle = RetryHandle()
        start(request, attempt: 0, handle: handle, didReceiveData: didReceiveData, completion: completion)
        return handle
    }

    private func start(
        _ request: URLRequest,
        attempt: Int,
        handle: RetryHandle,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let receivedBytes = Mutex(false)
        let task = base.loadData(with: request) { data, response in
            receivedBytes.withLock { $0 = true }
            didReceiveData(data, response)
        } completion: { [self] error in
            guard let error,
                  attempt < maxRetries,
                  !receivedBytes.withLock({ $0 }),
                  !handle.isCancelled,
                  Self.isRetryable(error) else {
                completion(error)
                return
            }
            // 1 s, then 2 s.
            let delay = Duration.seconds(1 << attempt)
            Task {
                try? await Task.sleep(for: delay)
                guard !handle.isCancelled else {
                    completion(URLError(.cancelled))
                    return
                }
                self.start(request, attempt: attempt + 1, handle: handle,
                           didReceiveData: didReceiveData, completion: completion)
            }
        }
        handle.adopt(task)
    }

    /// Whether an error describes a request that never got an answer, or an
    /// answer that says to try again later.
    static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        if case .statusCodeUnacceptable(let code) = error as? DataLoader.Error {
            return code == 429 || (500...599).contains(code)
        }
        return false
    }

    /// The cancellable handed to Nuke. Forwards `cancel` to whichever attempt
    /// is in flight, and stops any further attempts.
    private final class RetryHandle: Nuke.Cancellable, Sendable {
        private struct State {
            var current: (any Nuke.Cancellable)?
            var isCancelled = false
        }
        private let state = Mutex(State())

        var isCancelled: Bool { state.withLock { $0.isCancelled } }

        /// Tracks a new attempt; cancels it immediately if `cancel` already ran.
        func adopt(_ task: any Nuke.Cancellable) {
            let cancelNow = state.withLock { s -> Bool in
                s.current = task
                return s.isCancelled
            }
            if cancelNow { task.cancel() }
        }

        func cancel() {
            let current = state.withLock { s -> (any Nuke.Cancellable)? in
                s.isCancelled = true
                return s.current
            }
            current?.cancel()
        }
    }
}
