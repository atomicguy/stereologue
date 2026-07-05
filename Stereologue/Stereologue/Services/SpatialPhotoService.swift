//
//  SpatialPhotoService.swift
//  Stereologue
//
//  Converts stereoview card images into spatial HEIC files for visionOS.
//
//  Downloads the full card image, crops the left and right stereo pairs
//  using detection bounding boxes, then packages them as a spatial HEIC
//  with appropriate metadata using Image I/O.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers
import Nuke
import OSLog
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Sendable snapshot of the catalog/user data needed to render a spatial photo.
///
/// `SpatialPhotoService` is an actor and `StereoCard` / `UserCropOverride` are
/// `@Model` classes bound to MainActor — those models can't safely cross
/// actor boundaries. Callers build this snapshot on MainActor (resolving any
/// crop override in the process), then hand it to the service.
nonisolated struct SpatialPhotoCardData: Sendable {
    let uuid: String
    let frontImageID: String?
    let leftDetection: ImageDetection
    let rightDetection: ImageDetection
    let imageWidth: Double?
    let imageHeight: Double?

    var hasStereoDetections: Bool {
        leftDetection.width > 0 && rightDetection.width > 0
    }

    func frontImageURL(quality: String) -> URL? {
        guard let id = frontImageID else { return nil }
        return URL(string: "https://iiif-prod.nypl.org/index.php?id=\(id)&t=\(quality)")
    }
}

extension StereoCard {
    /// Builds a Sendable snapshot suitable for passing to `SpatialPhotoService`.
    /// Resolves an optional user crop override into the effective detections.
    func spatialPhotoData(cropOverride: UserCropOverride? = nil) -> SpatialPhotoCardData {
        SpatialPhotoCardData(
            uuid: uuid,
            frontImageID: frontImageID,
            leftDetection: cropOverride?.leftDetection ?? leftDetection,
            rightDetection: cropOverride?.rightDetection ?? rightDetection,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
    }
}

/// Metadata to embed in spatial HEIC files for sharing.
struct SpatialPhotoMetadata {
    var title: String?
    var creator: String?
    var date: String?
    var subjects: [String]
    var places: [String]
    var source: String?
    var copyright: String?

    nonisolated init(
        title: String?,
        creator: String?,
        date: String?,
        subjects: [String],
        places: [String]
    ) {
        self.title = title
        self.creator = creator
        self.date = date
        self.subjects = subjects
        self.places = places
        self.source = "The New York Public Library"
        self.copyright = "No known U.S. copyright restrictions"
    }
}

/// Errors that can occur during spatial photo conversion.
enum SpatialPhotoError: LocalizedError {
    case noFrontImage
    case missingDetections
    case downloadFailed(Error)
    case cgImageCreationFailed
    case cropFailed(String)
    case heicWriteFailed
    case imageDestinationCreationFailed

    var errorDescription: String? {
        switch self {
        case .noFrontImage:
            return "Card has no front image ID"
        case .missingDetections:
            return "Card is missing left or right detection bounding boxes"
        case .downloadFailed(let error):
            return "Failed to download source image: \(error.localizedDescription)"
        case .cgImageCreationFailed:
            return "Failed to create CGImage from downloaded data"
        case .cropFailed(let side):
            return "Failed to crop \(side) image from source"
        case .heicWriteFailed:
            return "Failed to finalize spatial HEIC file"
        case .imageDestinationCreationFailed:
            return "Failed to create image destination for HEIC output"
        }
    }
}

/// Service that creates and caches spatial HEIC files from stereoview cards.
///
/// Uses Nuke for image downloading/caching and Image I/O for spatial HEIC
/// creation. Generated files are cached on disk keyed by card UUID.
actor SpatialPhotoService {

    private let logger = Logger(
        subsystem: "net.atompowered.Stereologue",
        category: "SpatialPhoto"
    )

    /// The Nuke pipeline used for downloading source images.
    private let pipeline: ImagePipeline

    /// Directory where generated spatial HEIC files are cached.
    private let cacheDirectory: URL

    /// In-memory cache of generated spatial HEIC bytes, keyed by variant.
    ///
    /// The viewer builds a `CGImageSource` straight from these bytes, so the
    /// display path never writes to or reads back from disk. Bounded with a
    /// simple LRU; the bytes are also exactly what the share path needs.
    private var dataCache: [String: Data] = [:]
    private var dataCacheOrder: [String] = []
    private let dataCacheLimit = 16

    /// In-flight conversion tasks, keyed by variant, to coalesce duplicate work.
    private var inFlightTasks: [String: Task<Data, Error>] = [:]

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

    /// Corrects vertical misalignment between stereo pairs.
    private let rectificationService = StereoRectificationService()

    /// Tone and contrast restoration for scanned prints.
    private let restorationPipeline = RestorationPipeline()

    // MARK: - Stereoview Camera Defaults

    /// Baseline (interaxial distance) in meters.
    /// Standard stereoview cards used ~65mm lens separation.
    private static let baselineMeters: Double = 0.065

    /// Horizontal field of view in degrees for each individual stereo image.
    /// Typical stereoview lenses had ~30° horizontal FOV.
    private static let horizontalFOVDegrees: Double = 30.0

    /// Default disparity adjustment as a fraction of image width.
    /// Apple recommends 2% as a good starting point.
    private static let disparityAdjustmentFraction: Double = 0.02

    /// Identity rotation quaternion (no rotation).
    private static let identityRotation: [Double] = [0, 0, 0, 1]

    // MARK: - Initialization

    init(pipeline: ImagePipeline = .shared) {
        self.pipeline = pipeline

        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        self.cacheDirectory = caches.appendingPathComponent(
            "SpatialPhotos", isDirectory: true
        )

        // Ensure cache directory exists
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Public API

    /// Returns the spatial HEIC **bytes** for the given card, generating them if needed.
    ///
    /// The viewer builds a `CGImageSource` directly from this data via
    /// `ImagePresentationComponent(imageSource:)`, so the display path never
    /// touches the filesystem. Results are cached in memory and concurrent
    /// requests for the same variant are coalesced into a single conversion.
    ///
    /// - Parameters:
    ///   - card: Sendable card snapshot. Build with `card.spatialPhotoData(cropOverride:)` on MainActor.
    ///   - quality: IIIF quality code for the source image (default "v" = 2560px).
    /// - Returns: In-memory spatial HEIC data.
    func spatialHEICData(
        for card: SpatialPhotoCardData,
        quality: String = "v",
        style: RestorationStyle? = nil
    ) async throws -> Data {
        // Quality and style are part of the key: two callers requesting the same
        // card at different resolutions/styles must not coalesce onto one task
        // or alias the same cache entry.
        let suffix = style.map { "_restored_\($0.rawValue)" } ?? ""
        let variant = "\(card.uuid)_\(quality)\(suffix)"

        if let cached = dataCache[variant] {
            logger.debug("Cache hit for spatial photo: \(variant)")
            return cached
        }

        // Coalesce concurrent requests for the same variant
        if let existingTask = inFlightTasks[variant] {
            return try await existingTask.value
        }

        let task = Task<Data, Error> {
            defer { inFlightTasks[variant] = nil }
            let (left, right) = try await preparedStereoPair(
                for: card, quality: quality, style: style
            )
            let data = try makeSpatialHEICData(leftImage: left, rightImage: right)
            cacheData(data, for: variant)
            logger.info("Spatial photo generated in memory: \(variant)")
            return data
        }

        inFlightTasks[variant] = task
        return try await task.value
    }

    /// Prefetches spatial photos for the given cards.
    ///
    /// Starts downloading and converting in the background. Failures are
    /// logged but not thrown, since this is a best-effort optimization.
    func prefetch(
        cards: [SpatialPhotoCardData],
        quality: String = "v",
        style: RestorationStyle? = nil
    ) {
        for card in cards {
            guard card.hasStereoDetections else { continue }
            Task {
                do {
                    _ = try await spatialHEICData(
                        for: card, quality: quality, style: style
                    )
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
    /// Unlike `spatialPhotoURL(for:)`, this always writes metadata (IPTC/EXIF)
    /// into the file so recipients see the card's title, creator, date, etc.
    /// The metadata must be built on MainActor by the caller.
    func shareableSpatialPhotoURL(
        for card: SpatialPhotoCardData,
        metadata: SpatialPhotoMetadata,
        quality: String = "v"
    ) async throws -> URL {
        let outputURL = cacheDirectory.appendingPathComponent(
            "\(card.uuid)_\(quality)_share.heic"
        )

        // Always regenerate to ensure metadata is current
        try? FileManager.default.removeItem(at: outputURL)

        let (left, right) = try await preparedStereoPair(for: card, quality: quality)
        let data = try makeSpatialHEICData(
            leftImage: left, rightImage: right, metadata: metadata
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
        let (leftFinal, rightFinal) = try await preparedStereoPair(
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
    /// restoration styles, and the shareable copy).
    func evict(cardUUID: String) {
        let prefix = "\(cardUUID)_"
        for key in dataCacheOrder where key.hasPrefix(prefix) {
            dataCache[key] = nil
        }
        dataCacheOrder.removeAll { $0.hasPrefix(prefix) }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("\(cardUUID)_") {
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

    // MARK: - Stereo Pair Preparation

    /// Downloads, crops, restores, rectifies, and dimension-matches the stereo
    /// pair for a card, returning the two eye images ready for spatial encoding
    /// (`makeSpatialHEICData`) or flat-screen display (`croppedStereoPair`).
    private func preparedStereoPair(
        for card: SpatialPhotoCardData,
        quality: String,
        style: RestorationStyle? = nil
    ) async throws -> (left: CGImage, right: CGImage) {
        guard let sourceURL = card.frontImageURL(quality: quality) else {
            throw SpatialPhotoError.noFrontImage
        }

        guard card.hasStereoDetections else {
            throw SpatialPhotoError.missingDetections
        }

        let leftDetection = card.leftDetection
        let rightDetection = card.rightDetection

        logger.info("Preparing stereo pair for \(card.uuid)")

        // 1. Download source image via Nuke (benefits from its disk cache)
        let sourceImage: CGImage
        do {
            let platformImage = try await pipeline.image(for: sourceURL)
            guard let cgImage = platformCGImage(from: platformImage) else {
                throw SpatialPhotoError.cgImageCreationFailed
            }
            sourceImage = cgImage
        } catch let error as SpatialPhotoError {
            throw error
        } catch {
            throw SpatialPhotoError.downloadFailed(error)
        }

        // 2. Crop left and right images using detection bounding boxes
        // Detection coordinates may be in the original image's pixel space,
        // not the downloaded (scaled) image's space. Compute a scale factor.
        let sourceWidth = Double(sourceImage.width)
        let sourceHeight = Double(sourceImage.height)
        let scaleX = card.imageWidth.map { sourceWidth / $0 } ?? 1.0
        let scaleY = card.imageHeight.map { sourceHeight / $0 } ?? 1.0

        var leftCGImage = try cropImage(
            sourceImage, detection: leftDetection, label: "left",
            scaleX: scaleX, scaleY: scaleY
        )
        var rightCGImage = try cropImage(
            sourceImage, detection: rightDetection, label: "right",
            scaleX: scaleX, scaleY: scaleY
        )

        // 3. Optionally restore tone and contrast
        if let style {
            leftCGImage = await restorationPipeline.restore(leftCGImage, style: style)
            rightCGImage = await restorationPipeline.restore(rightCGImage, style: style)
        }

        // 4. Rectify vertical misalignment between the stereo pair
        do {
            let rectified = try await rectificationService.rectify(
                left: leftCGImage, right: rightCGImage
            )
            leftCGImage = rectified.left
            rightCGImage = rectified.right
        } catch {
            logger.warning(
                "Stereo rectification failed, continuing without: \(error.localizedDescription)"
            )
        }

        // 5. Resize to matching dimensions (required for spatial photos)
        return matchDimensions(left: leftCGImage, right: rightCGImage)
    }

    // MARK: - Image Cropping

    /// Crops a region from the source image using an `ImageDetection` bounding box.
    ///
    /// The detection's x/y are center coordinates and width/height are
    /// the box dimensions, possibly in a different pixel space than the
    /// downloaded image. Scale factors adjust from detection space to source space.
    private func cropImage(
        _ source: CGImage,
        detection: ImageDetection,
        label: String,
        scaleX: Double = 1.0,
        scaleY: Double = 1.0
    ) throws -> CGImage {
        let scaledX = detection.x * scaleX
        let scaledY = detection.y * scaleY
        let scaledW = detection.width * scaleX
        let scaledH = detection.height * scaleY

        let cropRect = CGRect(
            x: scaledX - scaledW / 2,
            y: scaledY - scaledH / 2,
            width: scaledW,
            height: scaledH
        )

        logger.debug("\(label) cropRect: \(cropRect.debugDescription)")

        // Clamp to image bounds
        let imageBounds = CGRect(
            x: 0, y: 0,
            width: source.width,
            height: source.height
        )
        let clampedRect = cropRect.intersection(imageBounds)

        guard !clampedRect.isEmpty,
              let cropped = source.cropping(to: clampedRect) else {
            throw SpatialPhotoError.cropFailed(label)
        }

        logger.debug(
            "Cropped \(label) image: \(cropped.width)x\(cropped.height)"
        )
        return cropped
    }

    /// Ensures left and right images have identical pixel dimensions
    /// by cropping to the smaller dimension on each axis.
    private func matchDimensions(
        left: CGImage, right: CGImage
    ) -> (CGImage, CGImage) {
        let targetWidth = min(left.width, right.width)
        let targetHeight = min(left.height, right.height)

        if left.width == targetWidth && left.height == targetHeight
            && right.width == targetWidth && right.height == targetHeight {
            return (left, right)
        }

        let targetRect = CGRect(
            x: 0, y: 0,
            width: targetWidth,
            height: targetHeight
        )

        let leftMatched = left.cropping(to: targetRect) ?? left
        let rightMatched = right.cropping(to: targetRect) ?? right
        return (leftMatched, rightMatched)
    }

    // MARK: - Spatial HEIC Writing

    /// Encodes a spatial HEIC (left + right stereo images with spatial metadata
    /// for visionOS presentation) entirely in memory and returns the bytes.
    private func makeSpatialHEICData(
        leftImage: CGImage,
        rightImage: CGImage,
        metadata: SpatialPhotoMetadata? = nil
    ) throws -> Data {
        // Compute spatial metadata from image dimensions
        let imageWidth = Double(leftImage.width)
        let imageHeight = Double(leftImage.height)

        let hFOVRadians = Self.horizontalFOVDegrees * .pi / 180.0
        let focalLengthPixels = imageWidth / (2.0 * tan(hFOVRadians / 2.0))

        // Intrinsics matrix (3x3, row-major) for simplified pinhole model
        let intrinsics: [Double] = [
            focalLengthPixels, 0, imageWidth / 2.0,
            0, focalLengthPixels, imageHeight / 2.0,
            0, 0, 1
        ]

        // Camera positions: left at -baseline/2, right at +baseline/2
        let halfBaseline = Self.baselineMeters / 2.0
        let leftPosition: [Double] = [-halfBaseline, 0, 0]
        let rightPosition: [Double] = [halfBaseline, 0, 0]

        // Encoded disparity adjustment: fraction * 10000
        let encodedDisparityAdjustment = Int(
            Self.disparityAdjustmentFraction * 10000
        )

        // Build optional metadata dictionaries
        let iptcDict = metadata.map { buildIPTCDictionary(from: $0) }
        let tiffDict = metadata.map { buildTIFFDictionary(from: $0) }

        // Create image properties dictionaries
        var leftProperties = imageProperties(
            isLeft: true,
            encodedDisparityAdjustment: encodedDisparityAdjustment,
            position: leftPosition,
            intrinsics: intrinsics
        )
        var rightProperties = imageProperties(
            isLeft: false,
            encodedDisparityAdjustment: encodedDisparityAdjustment,
            position: rightPosition,
            intrinsics: intrinsics
        )

        // Embed IPTC and TIFF metadata into both images
        if let iptc = iptcDict {
            leftProperties[kCGImagePropertyIPTCDictionary] = iptc
            rightProperties[kCGImagePropertyIPTCDictionary] = iptc
        }
        if let tiff = tiffDict {
            leftProperties[kCGImagePropertyTIFFDictionary] = tiff
            rightProperties[kCGImagePropertyTIFFDictionary] = tiff
        }

        // Create the HEIC image destination with 2 images, backed by CFData
        let destinationProperties: [CFString: Any] = [
            kCGImagePropertyPrimaryImage: 0
        ]

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.heic.identifier as CFString,
            2,
            destinationProperties as CFDictionary
        ) else {
            throw SpatialPhotoError.imageDestinationCreationFailed
        }

        // Add left image first (primary image at index 0)
        CGImageDestinationAddImage(
            destination, leftImage, leftProperties as CFDictionary
        )
        CGImageDestinationAddImage(
            destination, rightImage, rightProperties as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw SpatialPhotoError.heicWriteFailed
        }

        return data as Data
    }

    /// Extracts a CGImage from Nuke's platform image type.
    private func platformCGImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #elseif canImport(AppKit)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// Builds an IPTC metadata dictionary from card metadata.
    private func buildIPTCDictionary(
        from metadata: SpatialPhotoMetadata
    ) -> [CFString: Any] {
        var iptc: [CFString: Any] = [:]

        if let title = metadata.title {
            iptc[kCGImagePropertyIPTCObjectName] = title
            iptc[kCGImagePropertyIPTCCaptionAbstract] = title
        }
        if let creator = metadata.creator {
            iptc[kCGImagePropertyIPTCByline] = [creator]
        }
        if !metadata.subjects.isEmpty {
            iptc[kCGImagePropertyIPTCKeywords] = metadata.subjects
        }
        if let place = metadata.places.first {
            iptc[kCGImagePropertyIPTCContentLocationName] = place
        }
        if let source = metadata.source {
            iptc[kCGImagePropertyIPTCSource] = source
            iptc[kCGImagePropertyIPTCCredit] = source
        }
        if let copyright = metadata.copyright {
            iptc[kCGImagePropertyIPTCCopyrightNotice] = copyright
        }

        return iptc
    }

    /// Builds a TIFF metadata dictionary from card metadata.
    private func buildTIFFDictionary(
        from metadata: SpatialPhotoMetadata
    ) -> [CFString: Any] {
        var tiff: [CFString: Any] = [:]

        if let title = metadata.title {
            tiff[kCGImagePropertyTIFFImageDescription] = title
        }
        if let creator = metadata.creator {
            tiff[kCGImagePropertyTIFFArtist] = creator
        }
        if let copyright = metadata.copyright {
            tiff[kCGImagePropertyTIFFCopyright] = copyright
        }

        return tiff
    }

    /// Builds the properties dictionary for one image in the stereo pair.
    private func imageProperties(
        isLeft: Bool,
        encodedDisparityAdjustment: Int,
        position: [Double],
        intrinsics: [Double]
    ) -> [CFString: Any] {
        return [
            kCGImagePropertyGroups: [
                kCGImagePropertyGroupIndex: 0,
                kCGImagePropertyGroupType:
                    kCGImagePropertyGroupTypeStereoPair,
                (isLeft
                    ? kCGImagePropertyGroupImageIsLeftImage
                    : kCGImagePropertyGroupImageIsRightImage): true,
                kCGImagePropertyGroupImageDisparityAdjustment:
                    encodedDisparityAdjustment
            ],
            kCGImagePropertyHEIFDictionary: [
                kIIOMetadata_CameraExtrinsicsKey: [
                    kIIOCameraExtrinsics_Position: position,
                    kIIOCameraExtrinsics_Rotation: Self.identityRotation
                ],
                kIIOMetadata_CameraModelKey: [
                    kIIOCameraModel_Intrinsics: intrinsics,
                    kIIOCameraModel_ModelType:
                        kIIOCameraModelType_SimplifiedPinhole
                ]
            ],
            kCGImagePropertyHasAlpha: false
        ]
    }
}

// MARK: - StereoCard Convenience

extension StereoCard {
    /// Whether this card has usable detection bounding boxes for both sides.
    var hasStereoDetections: Bool {
        leftDetection.width > 0 && rightDetection.width > 0
    }
}
