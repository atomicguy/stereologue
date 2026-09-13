//
//  StereoPairRenderer.swift
//  Stereologue
//
//  Pure stereo-pair rendering: download → crop → restore → rectify →
//  dimension-match → spatial HEIC encode.
//
//  Holds no caches and does no coalescing — that is `SpatialPhotoService`'s
//  job. Every async entry point is `@concurrent`, so the work always runs on
//  the global executor rather than on whichever actor called it, and each
//  stage boundary checks for cancellation so a viewer that has moved on stops
//  paying for the render it abandoned.
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
/// `StereoCard` / `UserCropOverride` are `@Model` classes bound to MainActor
/// and can't cross actor boundaries. Callers build this snapshot on MainActor
/// (resolving any crop override in the process), then hand it to the service.
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

    /// Stable fingerprint of the effective crop geometry. Part of every cache
    /// key, so a user crop edit can never be served a render of the old crop.
    var cropKey: String {
        func f(_ d: ImageDetection) -> String {
            String(format: "%.1f,%.1f,%.1f,%.1f", d.x, d.y, d.width, d.height)
        }
        return "L\(f(leftDetection))R\(f(rightDetection))"
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

    /// Whether this card has usable detection bounding boxes for both sides.
    var hasStereoDetections: Bool {
        leftDetection.width > 0 && rightDetection.width > 0
    }
}

/// How much of the source resolution a render keeps.
///
/// Everything a viewer shows by default — and everything prefetch warms — is
/// `preview`. `full` is for an explicit user request (and sharing), and is
/// where any future defect-repair pass will run.
nonisolated enum RenderTier: String, Sendable, CaseIterable {
    /// Each eye downscaled so its width is at most `previewMaxWidth` pixels.
    case preview
    /// Source resolution.
    case full

    static let previewMaxWidth = 1024

    var displayName: String {
        switch self {
        case .preview: "Preview"
        case .full: "Full Resolution"
        }
    }
}

/// Metadata to embed in spatial HEIC files for sharing.
nonisolated struct SpatialPhotoMetadata: Sendable {
    var title: String?
    var creator: String?
    var date: String?
    var subjects: [String]
    var places: [String]
    var source: String?
    var copyright: String?

    init(
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
nonisolated enum SpatialPhotoError: LocalizedError {
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

nonisolated struct StereoPairRenderer: Sendable {

    private let logger = Logger(
        subsystem: "net.atompowered.Stereologue",
        category: "StereoPairRenderer"
    )

    /// The Nuke pipeline used for downloading source images.
    private let pipeline: ImagePipeline

    /// Corrects vertical misalignment and tilt between stereo pairs.
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

    init(pipeline: ImagePipeline) {
        self.pipeline = pipeline
    }

    // MARK: - Public API

    /// Renders the spatial HEIC bytes for a card. Runs entirely off the
    /// caller's actor and honors task cancellation between stages.
    @concurrent
    func spatialHEICData(
        for card: SpatialPhotoCardData,
        quality: String,
        style: RestorationStyle?,
        tier: RenderTier,
        metadata: SpatialPhotoMetadata? = nil
    ) async throws -> Data {
        let (left, right) = try await preparedStereoPair(
            for: card, quality: quality, style: style, tier: tier
        )
        try Task.checkCancellation()
        return try makeSpatialHEICData(
            leftImage: left, rightImage: right, metadata: metadata
        )
    }

    /// Downloads, crops, restores, rectifies, and dimension-matches the stereo
    /// pair for a card, returning the two eye images ready for spatial encoding
    /// or flat-screen display.
    @concurrent
    func preparedStereoPair(
        for card: SpatialPhotoCardData,
        quality: String,
        style: RestorationStyle? = nil,
        tier: RenderTier = .preview
    ) async throws -> (left: CGImage, right: CGImage) {
        guard let sourceURL = card.frontImageURL(quality: quality) else {
            throw SpatialPhotoError.noFrontImage
        }

        guard card.hasStereoDetections else {
            throw SpatialPhotoError.missingDetections
        }

        let leftDetection = card.leftDetection
        let rightDetection = card.rightDetection

        logger.info("Preparing stereo pair for \(card.uuid) (\(style?.rawValue ?? "original"), \(tier.rawValue))")

        // 1. Download source image via Nuke (benefits from its disk cache).
        //    Nuke's async API cancels the download with the task.
        let sourceImage: CGImage
        do {
            let platformImage = try await pipeline.image(for: sourceURL)
            guard let cgImage = platformCGImage(from: platformImage) else {
                throw SpatialPhotoError.cgImageCreationFailed
            }
            sourceImage = cgImage
        } catch let error as SpatialPhotoError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpatialPhotoError.downloadFailed(error)
        }
        try Task.checkCancellation()

        // 2. Crop left and right images using detection bounding boxes.
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

        // 2b. Preview tier: downscale both eyes by one shared factor (so
        // parallax geometry stays identical between them) before any pixel
        // work, which is what bounds the cost of every later stage.
        if tier == .preview {
            let widest = Double(max(leftCGImage.width, rightCGImage.width))
            let factor = min(1.0, Double(RenderTier.previewMaxWidth) / widest)
            if factor < 1 {
                leftCGImage = downscaled(leftCGImage, by: factor) ?? leftCGImage
                rightCGImage = downscaled(rightCGImage, by: factor) ?? rightCGImage
            }
        }
        try Task.checkCancellation()

        // 3. Optionally restore tone and contrast. The two eyes are
        // independent, so restore them concurrently.
        if let style {
            let pipeline = restorationPipeline
            async let leftRestored = pipeline.restore(leftCGImage, style: style)
            async let rightRestored = pipeline.restore(rightCGImage, style: style)
            leftCGImage = await leftRestored
            rightCGImage = await rightRestored
            try Task.checkCancellation()

            // 3a. Even out overall brightness between the two eyes. A global
            // per-image remap; preserves parallax (and therefore depth).
            let matched = pipeline.matchPair(left: leftCGImage, right: rightCGImage)
            leftCGImage = matched.left
            rightCGImage = matched.right
            try Task.checkCancellation()
        }

        // 4. Rectify vertical misalignment between the stereo pair.
        do {
            let rectified = try rectificationService.rectify(
                left: leftCGImage, right: rightCGImage
            )
            leftCGImage = rectified.left
            rightCGImage = rectified.right
        } catch {
            logger.warning(
                "Stereo rectification failed, continuing without: \(error.localizedDescription)"
            )
        }
        try Task.checkCancellation()

        // 5. Resize to matching dimensions (required for spatial photos).
        return Self.matchDimensions(left: leftCGImage, right: rightCGImage)
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
        guard let rect = Self.cropRect(
            for: detection, scaleX: scaleX, scaleY: scaleY,
            in: CGSize(width: source.width, height: source.height)
        ), let cropped = source.cropping(to: rect) else {
            throw SpatialPhotoError.cropFailed(label)
        }
        logger.debug("Cropped \(label) image: \(cropped.width)x\(cropped.height)")
        return cropped
    }

    /// The pixel rectangle a detection selects in an image of `size`, or
    /// `nil` if it falls entirely outside. Pure geometry, exposed for tests.
    static func cropRect(
        for detection: ImageDetection,
        scaleX: Double, scaleY: Double,
        in size: CGSize
    ) -> CGRect? {
        let w = detection.width * scaleX
        let h = detection.height * scaleY
        let rect = CGRect(
            x: detection.x * scaleX - w / 2,
            y: detection.y * scaleY - h / 2,
            width: w, height: h
        )
        let clamped = rect.intersection(CGRect(origin: .zero, size: size))
        return clamped.isEmpty ? nil : clamped
    }

    /// Resamples an image by `factor` (< 1) with high-quality interpolation.
    private func downscaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Ensures left and right images have identical pixel dimensions
    /// by cropping to the smaller dimension on each axis.
    static func matchDimensions(
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
