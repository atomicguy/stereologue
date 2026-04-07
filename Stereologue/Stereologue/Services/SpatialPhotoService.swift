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

    /// In-flight conversion tasks, keyed by card UUID, to avoid duplicate work.
    private var inFlightTasks: [String: Task<URL, Error>] = [:]

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

    /// Returns the URL to a spatial HEIC for the given card, creating it if needed.
    ///
    /// If the spatial HEIC is already cached on disk, returns immediately.
    /// Otherwise downloads the source image, crops the stereo pair, and
    /// writes the spatial HEIC. Concurrent requests for the same card
    /// are coalesced into a single download/conversion.
    ///
    /// - Parameters:
    ///   - card: The stereo card to convert.
    ///   - quality: IIIF quality code for the source image (default "v" = 2560px).
    /// - Returns: File URL of the generated spatial HEIC.
    func spatialPhotoURL(
        for card: StereoCard,
        quality: String = "v"
    ) async throws -> URL {
        let outputURL = cacheDirectory.appendingPathComponent(
            "\(card.uuid).heic"
        )

        // Return cached file if it exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            logger.debug("Cache hit for spatial photo: \(card.uuid)")
            return outputURL
        }

        // Coalesce concurrent requests for the same card
        if let existingTask = inFlightTasks[card.uuid] {
            return try await existingTask.value
        }

        let task = Task<URL, Error> {
            defer { inFlightTasks[card.uuid] = nil }
            return try await createSpatialPhoto(
                for: card, quality: quality, outputURL: outputURL
            )
        }

        inFlightTasks[card.uuid] = task
        return try await task.value
    }

    /// Prefetches spatial photos for the given cards.
    ///
    /// Starts downloading and converting in the background. Failures are
    /// logged but not thrown, since this is a best-effort optimization.
    func prefetch(cards: [StereoCard], quality: String = "v") {
        for card in cards {
            guard card.hasStereoDetections else { continue }
            Task {
                do {
                    _ = try await spatialPhotoURL(for: card, quality: quality)
                } catch {
                    logger.warning(
                        "Prefetch failed for \(card.uuid): \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Removes the cached spatial photo for a card.
    func evict(cardUUID: String) {
        let url = cacheDirectory.appendingPathComponent("\(cardUUID).heic")
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes all cached spatial photos.
    func evictAll() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Spatial HEIC Creation

    private func createSpatialPhoto(
        for card: StereoCard,
        quality: String,
        outputURL: URL
    ) async throws -> URL {
        guard let sourceURL = card.frontImageURL(quality: quality) else {
            throw SpatialPhotoError.noFrontImage
        }

        guard card.hasStereoDetections else {
            throw SpatialPhotoError.missingDetections
        }

        logger.info("Creating spatial photo for \(card.uuid)")

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

        print("[SpatialDebug] Source image: \(sourceImage.width)x\(sourceImage.height)")
        print("[SpatialDebug] Card imageWidth/Height: \(card.imageWidth ?? -1) x \(card.imageHeight ?? -1)")
        print("[SpatialDebug] Scale factors: \(scaleX) x \(scaleY)")
        print("[SpatialDebug] Left detection: x=\(card.leftDetection.x) y=\(card.leftDetection.y) w=\(card.leftDetection.width) h=\(card.leftDetection.height)")
        print("[SpatialDebug] Right detection: x=\(card.rightDetection.x) y=\(card.rightDetection.y) w=\(card.rightDetection.width) h=\(card.rightDetection.height)")

        let leftCGImage = try cropImage(
            sourceImage, detection: card.leftDetection, label: "left",
            scaleX: scaleX, scaleY: scaleY
        )
        let rightCGImage = try cropImage(
            sourceImage, detection: card.rightDetection, label: "right",
            scaleX: scaleX, scaleY: scaleY
        )

        // 3. Resize to matching dimensions (required for spatial photos)
        let (leftFinal, rightFinal) = matchDimensions(
            left: leftCGImage, right: rightCGImage
        )

        // 4. Write spatial HEIC
        try writeSpatialHEIC(
            leftImage: leftFinal,
            rightImage: rightFinal,
            to: outputURL
        )

        logger.info("Spatial photo created: \(outputURL.lastPathComponent)")
        return outputURL
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

        print("[SpatialDebug] \(label) cropRect: \(cropRect)")

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

    /// Writes a spatial HEIC file containing the left and right stereo images
    /// with spatial metadata for visionOS presentation.
    private func writeSpatialHEIC(
        leftImage: CGImage,
        rightImage: CGImage,
        to outputURL: URL
    ) throws {
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

        // Create image properties dictionaries
        let leftProperties = imageProperties(
            isLeft: true,
            encodedDisparityAdjustment: encodedDisparityAdjustment,
            position: leftPosition,
            intrinsics: intrinsics
        )
        let rightProperties = imageProperties(
            isLeft: false,
            encodedDisparityAdjustment: encodedDisparityAdjustment,
            position: rightPosition,
            intrinsics: intrinsics
        )

        // Create the HEIC image destination with 2 images
        let destinationProperties: [CFString: Any] = [
            kCGImagePropertyPrimaryImage: 0
        ]

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
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
    }

    /// Extracts a CGImage from Nuke's platform image type.
    private func platformCGImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #elseif canImport(AppKit)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
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
