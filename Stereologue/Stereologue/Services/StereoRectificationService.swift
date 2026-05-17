import Vision
import CoreImage
import CoreGraphics
import OSLog
import simd

enum RectificationError: LocalizedError {
    case homographyFailed
    case correctionFailed

    var errorDescription: String? {
        switch self {
        case .homographyFailed:
            return "Failed to compute stereo image alignment"
        case .correctionFailed:
            return "Failed to apply stereo rectification"
        }
    }
}

actor StereoRectificationService {

    private let logger = Logger(
        subsystem: "net.atompowered.Stereologue",
        category: "StereoRectification"
    )

    private let ciContext = CIContext()

    // MARK: - Public API

    func rectify(
        left: CGImage,
        right: CGImage
    ) async throws -> (left: CGImage, right: CGImage) {
        let (leftForAnalysis, rightForAnalysis) = cropToCommonSize(
            left: left, right: right
        )

        let H: matrix_float3x3
        do {
            H = try computeHomography(
                reference: leftForAnalysis, floating: rightForAnalysis
            )
        } catch {
            logger.info("Homography failed, trying translational alignment")
            return try rectifyTranslational(left: left, right: right)
        }

        guard isReasonableHomography(H) else {
            logger.warning("Homography too extreme, skipping rectification")
            return (left, right)
        }

        let correctedRight = try applyHomography(
            H, to: right, matchingExtentOf: left
        )

        logger.info("Stereo rectification applied")
        return (left, correctedRight)
    }

    // MARK: - Vision Homography

    private nonisolated func computeHomography(
        reference: CGImage,
        floating: CGImage
    ) throws -> matrix_float3x3 {
        let request = VNHomographicImageRegistrationRequest(
            targetedCGImage: floating
        )
        let handler = VNImageRequestHandler(cgImage: reference)
        try handler.perform([request])

        guard let result = request.results?.first else {
            throw RectificationError.homographyFailed
        }

        return result.warpTransform
    }

    // MARK: - Homography Validation

    private func isReasonableHomography(_ H: matrix_float3x3) -> Bool {
        let corners: [SIMD3<Float>] = [
            SIMD3(0, 0, 1), SIMD3(1, 0, 1),
            SIMD3(1, 1, 1), SIMD3(0, 1, 1)
        ]
        let identity: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)
        ]

        let mapped = corners.map { p -> SIMD2<Float> in
            let r = H * p
            guard abs(r.z) > 1e-6 else {
                return SIMD2(.infinity, .infinity)
            }
            return SIMD2(r.x / r.z, r.y / r.z)
        }

        for p in mapped {
            if p.x < -0.3 || p.x > 1.3 || p.y < -0.3 || p.y > 1.3 {
                return false
            }
        }

        let maxDisplacement = zip(mapped, identity)
            .map { distance($0.0, $0.1) }
            .max() ?? 0

        return maxDisplacement < 0.15
    }

    // MARK: - Perspective Warp

    private func applyHomography(
        _ H: matrix_float3x3,
        to image: CGImage,
        matchingExtentOf reference: CGImage
    ) throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let refW = CGFloat(reference.width)
        let refH = CGFloat(reference.height)

        let normalizedCorners: [SIMD3<Float>] = [
            SIMD3(0, 0, 1),
            SIMD3(1, 0, 1),
            SIMD3(1, 1, 1),
            SIMD3(0, 1, 1)
        ]

        let mappedCorners = normalizedCorners.map { p -> CGPoint in
            let r = H * p
            return CGPoint(
                x: CGFloat(r.x / r.z) * refW,
                y: CGFloat(r.y / r.z) * refH
            )
        }

        guard let filter = CIFilter(name: "CIPerspectiveTransform") else {
            throw RectificationError.correctionFailed
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: mappedCorners[0]), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: mappedCorners[1]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: mappedCorners[2]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: mappedCorners[3]), forKey: "inputTopLeft")

        guard let output = filter.outputImage else {
            throw RectificationError.correctionFailed
        }

        let cropRect = CGRect(x: 0, y: 0, width: refW, height: refH)
        guard let result = ciContext.createCGImage(output, from: cropRect) else {
            throw RectificationError.correctionFailed
        }

        return result
    }

    // MARK: - Translational Fallback

    private func rectifyTranslational(
        left: CGImage,
        right: CGImage
    ) throws -> (left: CGImage, right: CGImage) {
        let transform = try computeTranslation(reference: left, floating: right)

        if abs(transform.ty) < 1.5 && abs(transform.tx) < 1.5 {
            return (left, right)
        }

        let ciImage = CIImage(cgImage: right)
        let transformed = ciImage.transformed(by: transform)
        let cropRect = CGRect(
            x: 0, y: 0,
            width: CGFloat(left.width), height: CGFloat(left.height)
        )

        guard let corrected = ciContext.createCGImage(transformed, from: cropRect) else {
            return (left, right)
        }

        logger.info("Stereo rectification applied (translational fallback)")
        return (left, corrected)
    }

    private nonisolated func computeTranslation(
        reference: CGImage,
        floating: CGImage
    ) throws -> CGAffineTransform {
        let request = VNTranslationalImageRegistrationRequest(
            targetedCGImage: floating
        )
        let handler = VNImageRequestHandler(cgImage: reference)
        try handler.perform([request])

        guard let result = request.results?.first else {
            return .identity
        }

        return result.alignmentTransform
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
