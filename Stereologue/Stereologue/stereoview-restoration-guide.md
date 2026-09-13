# Stereoview Restoration Pipeline — Agent Implementation Guide

## Context & Assumptions

- The caller has already detected and cropped the left/right stereo halves into two `CGImage` or `CIImage` values. The pipeline receives these as inputs.
- Both halves must be processed **identically and independently** through Stages 1–2, then passed together into Stages 3 and 5.
- Target: Swift/SwiftUI, macOS 14+, Apple Silicon primary (Intel fallback).
- All ML inference runs on-device; no network calls.

---

## Shared Setup (create once, inject everywhere)

```swift
// One context, one Metal device. Never create these per-image.
let metalDevice = MTLCreateSystemDefaultDevice()!
let ciContext = CIContext(
    mtlDevice: metalDevice,
    options: [
        .workingFormat: CIFormat.RGBAh,          // Float16 throughout
        .outputColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!
    ]
)
```

**Decision:** `.RGBAh` (Float16) keeps precision through the full chain without the memory cost of Float32. Linear sRGB as the working space prevents gamma-compounded errors when doing math on pixel values.

---

## Stage 1 — Ingest & Normalize

**Goal:** Bring each stereo half into the shared `CIContext` working space, ready for processing.

```swift
func ingest(_ cgImage: CGImage) -> CIImage {
    // Tag the source correctly — scanned prints are typically sRGB or Display P3.
    // If you know the scanner profile, use it; otherwise sRGB is the safe default.
    let sourceColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    var image = CIImage(cgImage: cgImage, options: [.colorSpace: sourceColorSpace])

    // Flip to linear light (removes gamma) so all subsequent math is linear.
    image = image.matchedToWorkingSpace(from: sourceColorSpace) ?? image
    return image
}
```

**Decision:** Do color space conversion here, once, not scattered through the chain. All downstream stages assume linear Float16 pixels.

---

## Stage 2 — Tone & Sepia Correction

Run these sub-steps in order. Each produces a `CIImage` input for the next.

### 2a. Sepia / Color Cast Neutralization

```swift
func neutralizeSepia(_ image: CIImage) -> CIImage {
    // Convert to LAB, attenuate a/b (chroma) channels, return to RGB.
    // CIFilter does not expose LAB directly; use a color matrix that
    // approximates sepia removal in RGB space by lifting shadows and
    // pulling warm bias toward neutral.
    let filter = CIFilter.colorPolynomial()
    // Coefficients below compress the red channel slightly and boost blue
    // to counteract the typical warm-brown paper-print cast.
    // Tune these with real scans; these are conservative starting values.
    filter.inputImage = image
    filter.redCoefficients   = CIVector(x: 0.0, y: 0.92, z: 0.0, w: 0.0)
    filter.greenCoefficients = CIVector(x: 0.0, y: 1.00, z: 0.0, w: 0.0)
    filter.blueCoefficients  = CIVector(x: 0.02, y: 1.06, z: 0.0, w: 0.0)
    return filter.outputImage!
}
```

**Alternative (more accurate):** Write a Metal kernel that converts to CIE LAB, zeros the a/b channels toward neutral, and converts back. Use this if the CIFilter approximation is too crude for your scans.

### 2b. Black & White Point Stretch (vImage)

```swift
func stretchContrast(_ image: CIImage, context: CIContext) -> CIImage {
    // Render to a vImage buffer, then apply ends-in contrast stretch.
    var format = vImage_CGImageFormat(
        bitsPerComponent: 16, bitsPerPixel: 64,
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue |
                                            CGBitmapInfo.floatComponents.rawValue)
    )!
    guard var buffer = try? vImage_Buffer(cgImage: context.createCGImage(image, from: image.extent)!,
                                          format: format) else { return image }
    defer { buffer.free() }

    var result = try! vImage_Buffer(size: buffer.size, bitsPerPixel: format.bitsPerPixel)
    defer { result.free() }

    // Stretch each channel so the darkest pixel → 0 and brightest → 1.
    vImageEndsInContrastStretch_ARGB16U(&buffer, &result, 0, 0, 0) // 0 = no percentile clip

    guard let cgOut = try? result.createCGImage(format: format) else { return image }
    return CIImage(cgImage: cgOut)
}
```

**Decision:** `vImageEndsInContrastStretch` is the correct primitive here — not histogram equalization, which is too aggressive for portraits. Use `vImageEqualization` only on specific regions if needed.

### 2c. Tiled Local Contrast (CLAHE approximation)

vImage has no built-in CLAHE. Implement it as tiled equalization with bilinear blending:

```swift
func applyCLAHE(_ image: CIImage, tileSize: Int = 128, context: CIContext) -> CIImage {
    let extent = image.extent
    let cols = Int(ceil(extent.width  / CGFloat(tileSize)))
    let rows = Int(ceil(extent.height / CGFloat(tileSize)))

    // 1. Equalize each tile independently into an output buffer.
    // 2. Bilinear-blend at tile borders (each output pixel is a weighted
    //    average of the 1–4 nearest tile equalization results).
    // 3. Recombine into a single CIImage.
    //
    // Operate on the luminance (Y) channel only to avoid color shifts:
    // extract Y, apply CLAHE to Y, recombine with original Cb/Cr.
    // Use CIFilter.colorControls / a Y-isolation kernel for the split.
    //
    // Implementation: use vImageHistogramCalculation_PlanarF per tile,
    // then vImageEqualization_PlanarF, then blend with vImageAlphaBlend.
    // This is ~40–60 lines; keep it in its own file (CLAHEProcessor.swift).
}
```

**Decision:** CLAHE rather than global equalization preserves local detail without blowing highlights on lighter areas of the print. Tile size 128 px is a good default for ~1500 px wide scans; expose it as a parameter.

### 2d. Global Tone Curve

```swift
func applyToneCurve(_ image: CIImage) -> CIImage {
    let filter = CIFilter.toneCurve()
    filter.inputImage = image
    // Slight S-curve: lift shadows gently, protect highlights.
    // These are conservative defaults for faded paper prints.
    filter.point0 = CGPoint(x: 0.0,  y: 0.0)
    filter.point1 = CGPoint(x: 0.25, y: 0.20)  // shadow lift
    filter.point2 = CGPoint(x: 0.50, y: 0.50)  // midpoint neutral
    filter.point3 = CGPoint(x: 0.75, y: 0.80)  // highlight protect
    filter.point4 = CGPoint(x: 1.0,  y: 1.0)
    return filter.outputImage!
}
```

**Decision:** Hardcode conservative defaults; expose the five control points as user-adjustable parameters in the UI if needed. This is not model-inferred — it is a best-practice curve for albumen/silver-gelatin prints.

---

## Stage 3 — Dust & Scratch Repair (stereo-aware)

Single-image ML denoisers were tried here (SCUNet, tiled at 512×512 through
Core ML) and removed: on visionOS the tiled inference was too slow to be
interactive, and the results on scanned albumen/silver-gelatin prints were
not reliably better than the input.

The current approach exploits the stereo pair instead. A blemish on one
print almost never lands on the same scene point of the other print, so
`StereoPairProcessor` detects defects (morphological top-hat/bottom-hat),
computes dense optical flow between the eyes (`VNGenerateOpticalFlowRequest`),
and fills each defect from the disparity-corresponding pixels of the sibling
eye, falling back to neighborhood inpainting where the flow disagrees. Blown
highlights are recovered the same way. This runs only on the deliberate
"deep" path.

A learned scratch *detector* (e.g. the U-Net from *Bringing Old Photos Back
to Life*) would slot in as a drop-in replacement for the morphological
detector; the fill stage is unchanged.

---

## Stage 5 — Stereo Alignment (Zero Vertical Parallax)

**Goal:** Align the restored left and right images so vertical disparity is ≤1 px before VR presentation.

### Decision: Use `VNHomographicImageRegistrationRequest`

Apple's Vision framework homography registration is the right tool here — it handles the moderate perspective and scale differences typical in re-photographed stereocard scans, and it's ANE-accelerated. SIFT/ORB + RANSAC is only needed if you find Vision's alignment failing on highly damaged or blank-sky regions.

```swift
// StereoAlignment.swift
import Vision

func alignStereoHalves(
    reference: CIImage,   // left half (fixed)
    floating: CIImage,    // right half (to be warped)
    context: CIContext
) async throws -> CIImage {

    let refCG = context.createCGImage(reference, from: reference.extent)!
    let fltCG = context.createCGImage(floating,  from: floating.extent)!

    let request = VNHomographicImageRegistrationRequest(targetedCGImage: refCG)
    let handler = VNImageRequestHandler(cgImage: fltCG)
    try handler.perform([request])

    guard let obs = request.results?.first as? VNImageHomographicAlignmentObservation else {
        return floating // No alignment found; return as-is
    }

    // Apply the warpTransform to the floating image
    let warp = obs.warpTransform  // simd_float3x3
    return applyHomography(warp, to: floating, reference: reference, context: context)
}

func applyHomography(
    _ H: simd_float3x3,
    to image: CIImage,
    reference: CIImage,
    context: CIContext
) -> CIImage {
    // Convert simd_float3x3 → CATransform3D → CIPerspectiveTransform
    // Map the four corners of `image` through H, clamp to reference extent.
    let ext = reference.extent
    let corners = [
        CGPoint(x: ext.minX, y: ext.minY),
        CGPoint(x: ext.maxX, y: ext.minY),
        CGPoint(x: ext.maxX, y: ext.maxY),
        CGPoint(x: ext.minX, y: ext.maxY)
    ].map { transformPoint($0, by: H) }

    let filter = CIFilter.perspectiveTransform()
    filter.inputImage     = image
    filter.bottomLeft     = corners[0]
    filter.bottomRight    = corners[1]
    filter.topRight       = corners[2]
    filter.topLeft        = corners[3]
    return filter.outputImage!.cropped(to: ext)
}
```

**Vertical parallax check (optional validation):**

```swift
func verticalParallaxRMS(left: CIImage, right: CIImage, context: CIContext) -> Double {
    // Run VNFeaturePrintObservation on a grid of patches,
    // match nearest neighbors, measure mean |Δy|.
    // If > 1.5 px, flag for re-alignment or user correction.
}
```

**Fallback:** If `VNHomographicImageRegistrationRequest` returns nil (insufficient features — common with blank skies or very uniform prints), fall back to a translational-only alignment using `VNTranslationalImageRegistrationRequest`, which is more robust on low-texture images.

---

## Pipeline Orchestration

```swift
// RestorationPipeline.swift
actor RestorationPipeline {
    let context: CIContext

    init(context: CIContext) { self.context = context }

    func restore(left: CIImage, right: CIImage) async throws -> (CIImage, CIImage) {
        // Stages 1–2 are identical and independent per half — run concurrently.
        async let restoredLeft  = restoreHalf(left)
        async let restoredRight = restoreHalf(right)
        let (l, r) = try await (restoredLeft, restoredRight)

        // Stage 5: align right to left
        let aligned = try await alignStereoHalves(reference: l, floating: r, context: context)
        return (l, aligned)
    }

    private func restoreHalf(_ image: CIImage) async -> CIImage {
        var img = ingest(image)                              // Stage 1
        img = neutralizeSepia(img)                           // Stage 2a
        img = stretchContrast(img, context: context)         // Stage 2b
        img = applyCLAHE(img, context: context)              // Stage 2c
        img = applyToneCurve(img)                            // Stage 2d
        return img
    }
}
```

**Note:** `actor` isolation ensures the shared `CIContext` is accessed safely from async contexts. The `async let` concurrency in `restore()` parallelizes the two halves, halving wall-clock time on M-series chips that have sufficient ANE bandwidth.

---

## Key Numbers to Keep Handy

| Parameter | Value | Rationale |
|---|---|---|
| CLAHE tile | 128 px | Good default for ~1500 px wide scan |
