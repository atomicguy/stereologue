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

/// Removes vertical misalignment and in-plane tilt between the two frames of a
/// stereoview card while preserving horizontal parallax.
///
/// A stereo pair differs by two things: horizontal *parallax* — the depth cue
/// that makes the spatial photo work — and unwanted *rigid* misalignment
/// (vertical offset plus a small rotation) introduced when the two prints were
/// mounted and the card was scanned.
///
/// The correct operation is to null out the vertical offset and tilt and leave
/// the horizontal offset alone. We deliberately do **not** use a full
/// homography (`VNHomographicImageRegistrationRequest`): morphing one frame to
/// globally match the other cancels the very parallax it's supposed to keep,
/// flattening the scene. Instead we estimate the rigid misalignment from
/// translational registration and apply only its vertical + rotational parts.
/// Holds only a thread-safe `CIContext` and a `Logger`, so it's a Sendable
/// class rather than an actor: rectifying one pair never queues behind
/// another, and the render task can be cancelled between stages.
nonisolated final class StereoRectificationService: @unchecked Sendable {

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

    /// In-plane rotations below this (radians, ~0.086°) aren't worth the
    /// resample they'd cost.
    private let minRotationRadians: CGFloat = 0.0015

    /// A tilt beyond this (radians, ~4°) isn't a real scan misalignment — a
    /// half-frame registration went bad. Correct vertical only in that case.
    private let maxRotationRadians: CGFloat = 0.0698

    /// Registration runs on copies no wider than this. Vision's translational
    /// registration cost scales with pixel count, and sub-pixel precision at
    /// 640 px is ample once scaled back up to the full frame.
    private let analysisMaxWidth = 640

    // MARK: - Public API

    func rectify(
        left: CGImage,
        right: CGImage
    ) throws -> (left: CGImage, right: CGImage) {
        let (leftCommon, rightCommon) = cropToCommonSize(
            left: left, right: right
        )

        // Register on downscaled copies; the measured shift scales back up by
        // the same factor, and rotation is scale-invariant.
        let analysisScale = min(1.0, CGFloat(analysisMaxWidth) / CGFloat(leftCommon.width))
        let leftForAnalysis = analysisScale < 1
            ? (downscaled(leftCommon, by: analysisScale) ?? leftCommon) : leftCommon
        let rightForAnalysis = analysisScale < 1
            ? (downscaled(rightCommon, by: analysisScale) ?? rightCommon) : rightCommon
        let appliedScale = CGFloat(leftForAnalysis.width) / CGFloat(leftCommon.width)

        let alignment = computeAlignment(
            reference: leftForAnalysis, floating: rightForAnalysis
        )

        // Vertical shift (in full-frame pixels): apply if meaningful and plausible.
        var verticalShift = alignment.verticalShift / appliedScale
        if abs(verticalShift) < minShiftPixels {
            verticalShift = 0
        } else {
            let maxShift = CGFloat(rightCommon.height) * maxShiftFraction
            if abs(verticalShift) > maxShift {
                logger.warning(
                    "Vertical shift \(verticalShift, privacy: .public)px exceeds \(self.maxShiftFraction * 100, privacy: .public)% of height; ignoring it"
                )
                verticalShift = 0
            }
        }

        // Rotation: apply if meaningful and plausible.
        var rotation = alignment.rotation
        if abs(rotation) > maxRotationRadians {
            logger.warning(
                "In-plane rotation \(rotation, privacy: .public)rad implausible; ignoring it"
            )
            rotation = 0
        } else if abs(rotation) < minRotationRadians {
            rotation = 0
        }

        guard verticalShift != 0 || rotation != 0 else {
            logger.info("Stereo pair already aligned; nothing to correct")
            return (left, right)
        }

        let corrected = try applyCorrection(
            verticalShift: verticalShift, rotation: rotation, to: right
        )
        logger.info(
            "Stereo rectification applied (Δy=\(verticalShift, privacy: .public)px, θ=\(rotation, privacy: .public)rad)"
        )
        return (left, corrected)
    }

    // MARK: - Alignment Estimation

    /// The rigid misalignment of the right frame relative to the left, minus
    /// the horizontal (parallax) component.
    private struct Alignment {
        /// Vertical offset in pixels of the analysis images.
        var verticalShift: CGFloat
        /// In-plane rotation in radians (counter-clockwise positive).
        var rotation: CGFloat
    }

    private func computeAlignment(
        reference: CGImage,
        floating: CGImage
    ) -> Alignment {
        // Whole-image vertical offset — the most robust measurement, and what
        // drives the primary correction.
        let verticalShift = verticalOffset(
            reference: reference, floating: floating
        ) ?? 0

        // Estimate tilt from how that vertical offset varies across the frame:
        // split into left and right halves and register each independently. A
        // rotation shows up as a different vertical offset on the two sides, and
        // its gradient over the halves' horizontal separation is the angle.
        //
        // Deriving rotation from the same translational measurement (rather than
        // decomposing a homography) keeps its sign convention identical to the
        // vertical correction, so both move the image the same, correct way.
        let rotation = estimateRotation(reference: reference, floating: floating)

        return Alignment(verticalShift: verticalShift, rotation: rotation)
    }

    /// Vertical component of the translational alignment of `floating` onto
    /// `reference`, or `nil` if registration fails. The horizontal component is
    /// intentionally dropped: it is the stereo parallax, which must survive.
    private func verticalOffset(
        reference: CGImage,
        floating: CGImage
    ) -> CGFloat? {
        let request = VNTranslationalImageRegistrationRequest(
            targetedCGImage: floating
        )
        let handler = VNImageRequestHandler(cgImage: reference)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let result = request.results?.first else { return nil }
        return result.alignmentTransform.ty
    }

    /// Rotation (radians) from the difference in vertical offset between the
    /// left and right halves of the frame. Returns `0` if either half fails to
    /// register or the frame is too narrow to split.
    private func estimateRotation(
        reference: CGImage,
        floating: CGImage
    ) -> CGFloat {
        let w = reference.width
        let h = reference.height
        let leftW = w / 2
        let rightW = w - leftW
        guard leftW > 0, rightW > 0 else { return 0 }

        let leftRect = CGRect(x: 0, y: 0, width: leftW, height: h)
        let rightRect = CGRect(x: leftW, y: 0, width: rightW, height: h)

        guard let refLeft = reference.cropping(to: leftRect),
              let floLeft = floating.cropping(to: leftRect),
              let refRight = reference.cropping(to: rightRect),
              let floRight = floating.cropping(to: rightRect),
              let tyLeft = verticalOffset(reference: refLeft, floating: floLeft),
              let tyRight = verticalOffset(reference: refRight, floating: floRight)
        else { return 0 }

        // The two halves' centroids sit half the frame width apart (w/4 and
        // 3w/4), so the vertical-offset gradient per pixel — i.e. the small
        // angle in radians — is the difference divided by w/2.
        let separation = CGFloat(w) / 2
        return (tyRight - tyLeft) / separation
    }

    // MARK: - Correction Application

    private func applyCorrection(
        verticalShift dy: CGFloat,
        rotation: CGFloat,
        to image: CGImage
    ) throws -> CGImage {
        // Clamp first so the strip a shift or rotation uncovers is filled
        // with replicated edge pixels rather than left transparent — which
        // would otherwise render as a black band in the spatial photo.
        let ciImage = CIImage(cgImage: image).clampedToExtent()

        var transform = CGAffineTransform.identity
        if rotation != 0 {
            // Rotate about the image center so the tilt is corrected in place.
            let cx = CGFloat(image.width) / 2
            let cy = CGFloat(image.height) / 2
            transform = CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(rotationAngle: rotation))
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
        }
        // Vertical translation only — no horizontal component, so parallax is
        // untouched. Same Core Image transform path the vertical-only version
        // used, so the sign/orientation convention is unchanged.
        transform = transform.concatenating(
            CGAffineTransform(translationX: 0, y: dy)
        )

        let shifted = ciImage.transformed(by: transform)
        let cropRect = CGRect(
            x: 0, y: 0,
            width: CGFloat(image.width), height: CGFloat(image.height)
        )
        guard let result = ciContext.createCGImage(shifted, from: cropRect) else {
            throw RectificationError.correctionFailed
        }
        return result
    }

    // MARK: - Analysis Downscale

    private func downscaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
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
