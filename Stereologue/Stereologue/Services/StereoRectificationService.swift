import Vision
import CoreImage
import CoreGraphics
import OSLog

enum RectificationError: LocalizedError {
    case correctionFailed

    var errorDescription: String? {
        switch self {
        case .correctionFailed:
            return "Failed to apply stereo rectification"
        }
    }
}

/// Removes vertical misalignment between the two frames of a stereoview card
/// while preserving horizontal parallax.
///
/// A stereo pair differs by two things: horizontal *parallax* — the depth cue
/// that makes the spatial photo work — and unwanted *vertical* misalignment
/// introduced when the two prints were mounted and the card was scanned.
///
/// The correct operation is therefore to null out the vertical offset and
/// leave the horizontal offset alone. We deliberately do **not** use a full
/// homography (`VNHomographicImageRegistrationRequest`): morphing one frame to
/// globally match the other cancels the very parallax it's supposed to keep,
/// flattening the scene. Instead we estimate the global translation between
/// the frames and apply only its vertical component.
actor StereoRectificationService {

    private let logger = Logger(
        subsystem: "net.atompowered.Stereologue",
        category: "StereoRectification"
    )

    private let ciContext = CIContext()

    /// Vertical corrections below this many pixels aren't worth applying.
    private let minShiftPixels: CGFloat = 0.5

    /// A "vertical" shift larger than this fraction of frame height isn't a
    /// real misalignment — registration latched onto the wrong content. Two
    /// frames of the same card are never off by a quarter of their height.
    private let maxShiftFraction: CGFloat = 0.25

    // MARK: - Public API

    func rectify(
        left: CGImage,
        right: CGImage
    ) async throws -> (left: CGImage, right: CGImage) {
        let (leftForAnalysis, rightForAnalysis) = cropToCommonSize(
            left: left, right: right
        )

        // Estimate the global shift that best aligns the right frame onto the
        // left. tx captures the (depth-dependent) horizontal parallax and is
        // discarded; ty is the vertical misalignment we want to remove.
        let verticalShift = computeVerticalShift(
            reference: leftForAnalysis, floating: rightForAnalysis
        )

        guard abs(verticalShift) >= minShiftPixels else {
            logger.info("Stereo pair already vertically aligned; nothing to correct")
            return (left, right)
        }

        let maxShift = CGFloat(rightForAnalysis.height) * maxShiftFraction
        guard abs(verticalShift) <= maxShift else {
            logger.warning(
                "Vertical shift \(verticalShift, privacy: .public)px exceeds \(self.maxShiftFraction * 100, privacy: .public)% of height; skipping rectification"
            )
            return (left, right)
        }

        let corrected = try applyVerticalShift(verticalShift, to: right)
        logger.info(
            "Stereo rectification applied (Δy=\(verticalShift, privacy: .public)px)"
        )
        return (left, corrected)
    }

    // MARK: - Vertical Shift Estimation

    /// Returns the vertical offset (in pixels of the analysis images) that best
    /// aligns `floating` onto `reference`, or `0` if registration fails.
    ///
    /// The horizontal component of the alignment is intentionally ignored: it
    /// is the stereo parallax, which must be preserved.
    private nonisolated func computeVerticalShift(
        reference: CGImage,
        floating: CGImage
    ) -> CGFloat {
        let request = VNTranslationalImageRegistrationRequest(
            targetedCGImage: floating
        )
        let handler = VNImageRequestHandler(cgImage: reference)
        do {
            try handler.perform([request])
        } catch {
            return 0
        }
        guard let result = request.results?.first else { return 0 }
        return result.alignmentTransform.ty
    }

    // MARK: - Vertical Shift Application

    private func applyVerticalShift(
        _ dy: CGFloat,
        to image: CGImage
    ) throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        // Vertical translation only — no horizontal component, so parallax is
        // untouched. Same Core Image transform path the previous fallback used,
        // so the sign/orientation convention is unchanged.
        let shifted = ciImage.transformed(
            by: CGAffineTransform(translationX: 0, y: dy)
        )
        let cropRect = CGRect(
            x: 0, y: 0,
            width: CGFloat(image.width), height: CGFloat(image.height)
        )
        guard let result = ciContext.createCGImage(shifted, from: cropRect) else {
            throw RectificationError.correctionFailed
        }
        return result
    }

    // MARK: - Dimension Matching

    private func cropToCommonSize(
        left: CGImage, right: CGImage
    ) -> (CGImage, CGImage) {
        if left.width == right.width && left.height == right.height {
            return (left, right)
        }

        let w = min(left.width, right.width)
        let h = min(left.height, right.height)

        let leftRect = CGRect(
            x: (left.width - w) / 2, y: (left.height - h) / 2,
            width: w, height: h
        )
        let rightRect = CGRect(
            x: (right.width - w) / 2, y: (right.height - h) / 2,
            width: w, height: h
        )

        return (
            left.cropping(to: leftRect) ?? left,
            right.cropping(to: rightRect) ?? right
        )
    }
}
