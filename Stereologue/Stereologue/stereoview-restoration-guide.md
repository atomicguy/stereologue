# Stereoview Restoration Pipeline — Agent Implementation Guide

## Context & Assumptions

- The caller has already detected and cropped the left/right stereo halves into two `CGImage` or `CIImage` values. The pipeline receives these as inputs.
- Both halves must be processed **identically and independently** through Stages 1–3, then passed together into Stage 5.
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

## Stage 3 — SCUNet: Dust, Scratch & Grain Removal

### 3a. Model Setup

```swift
// RestorationModel.swift
import CoreML

final class SCUNetModel {
    static let shared = SCUNetModel()
    let model: MLModel

    private init() {
        let config = MLModelConfiguration()
        // Apple Silicon: ANE + CPU. Intel: GPU + CPU.
        config.computeUnits = ProcessInfo.processInfo.processorCount > 8
            ? .cpuAndNeuralEngine   // M-series
            : .cpuAndGPU            // Intel fallback
        let url = Bundle.main.url(forResource: "SCUNet_color_real", withExtension: "mlpackage")!
        model = try! MLModel(contentsOf: url, configuration: config)
    }
}
```

**Decision:** `.cpuAndNeuralEngine` — **not** `.all`. Using `.all` on Apple Silicon silently routes eligible ops to GPU instead of ANE, costing ~24% throughput. Detect M-series by core count (>8 efficiency + performance cores) or `ProcessInfo.processInfo.machineHardwareName`.

### 3b. Tiled Inference with Hann Window Blending

**Decision:** Tile at 512×512 with 64 px overlap. This is SCUNet's effective receptive field boundary; smaller tiles introduce visible seams, larger tiles waste memory.

```swift
// TiledInference.swift
func runSCUNet(on image: CIImage, context: CIContext) -> CIImage {
    let tileSize  = 512
    let overlap   = 64
    let stride    = tileSize - overlap
    let extent    = image.extent
    let model     = SCUNetModel.shared.model

    // Accumulator buffers (Float32, linear RGB)
    var accumRGB    = [Float](repeating: 0, count: Int(extent.width * extent.height) * 3)
    var accumWeight = [Float](repeating: 0, count: Int(extent.width * extent.height))

    // Pre-compute Hann window for this tile size
    let hannWindow = makeHannWindow(size: tileSize) // see below

    for row in stride(from: 0, through: Int(extent.height) - 1, by: stride) {
        for col in stride(from: 0, through: Int(extent.width) - 1, by: stride) {
            let tileRect = CGRect(
                x: CGFloat(col), y: CGFloat(row),
                width: CGFloat(tileSize), height: CGFloat(tileSize)
            ).intersection(extent)

            // Crop tile, pad to 512×512 if near edge
            let tileCI = image.cropped(to: tileRect)
                              .paddedToSize(tileSize, context: context)  // helper

            // Run model
            let input  = try! MLDictionaryFeatureProvider(dictionary: ["image": tileCIToMLBuffer(tileCI)])
            let output = try! model.prediction(from: input)
            let outBuf = output.featureValue(for: "output")!.multiArrayValue!

            // Accumulate into full-image buffer, weighted by Hann window
            blendTileIntoAccumulator(
                tile: outBuf, hann: hannWindow,
                into: &accumRGB, weights: &accumWeight,
                at: (col, row), imageWidth: Int(extent.width)
            )
        }
    }

    // Normalize and convert accumulator back to CIImage
    return accumulatorToCIImage(accumRGB, accumWeight, extent: extent)
}

func makeHannWindow(size: Int) -> [Float] {
    // 2D separable Hann: w[i,j] = hann1D[i] * hann1D[j]
    let hann1D = (0..<size).map { i in
        0.5 * (1 - cos(2 * .pi * Float(i) / Float(size - 1)))
    }
    return (0..<size).flatMap { row in
        (0..<size).map { col in hann1D[row] * hann1D[col] }
    }
}
```

**File organization (DRY):**
- `SCUNetModel.swift` — singleton model wrapper, compute unit selection
- `TiledInference.swift` — tiling loop, Hann accumulation, normalization
- `MLBufferHelpers.swift` — `tileCIToMLBuffer(_:)`, `accumulatorToCIImage(_:_:extent:)`
- `CIImageExtensions.swift` — `paddedToSize(_:context:)`, `matchedToWorkingSpace(from:)`

### 3c. Model Conversion Reference (Python, run offline)

```python
import torch, coremltools as ct

# Load pretrained SCUNet (color_real variant)
model = SCUNet(in_nc=3, config=[4,4,4,4,4,4,4], dim=64)
model.load_state_dict(torch.load("scunet_color_real_psnr.pth"))
model.eval()

# Pre-compute relative-position-bias tensors as buffers (avoids trace issues)
# See: github.com/john-rocky/CoreML-Models/blob/master/docs/coreml_conversion_notes.md
patch_rpb_as_buffers(model)  # your helper

ts = torch.jit.trace(model, torch.rand(1, 3, 512, 512))

mlmodel = ct.convert(
    ts,
    inputs=[ct.ImageType(name="image", shape=(1,3,512,512), scale=1/255.0)],
    outputs=[ct.ImageType(name="output")],
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS14,
)

# Optional: 6-bit palettization (~37% size reduction, negligible quality loss)
from coremltools.optimize.coreml import palettize_weights, OptimizationConfig, OpPalettizerConfig
config = OptimizationConfig(global_config=OpPalettizerConfig(nbits=6, mode="kmeans"))
mlmodel = palettize_weights(mlmodel, config)

mlmodel.save("SCUNet_color_real.mlpackage")
```

**Conversion gotchas:**
- `torch.roll` (Swin shifted windows) must be replaced with `slice + cat` before tracing
- `expand(-1, ...)` crashes coremltools <9.0; use coremltools ≥9.0
- Bicubic resize with `antialias=True` does not trace; use bilinear or nearest
- Tile inputs must be **static 512×512** — `RangeDim` falls off ANE entirely

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
        // Stages 1–3 are identical and independent per half — run concurrently.
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
        img = runSCUNet(on: img, context: context)           // Stage 3
        return img
    }
}
```

**Note:** `actor` isolation ensures the shared `CIContext` is accessed safely from async contexts. The `async let` concurrency in `restore()` parallelizes the two halves, halving wall-clock time on M-series chips that have sufficient ANE bandwidth.

---

## Key Numbers to Keep Handy

| Parameter | Value | Rationale |
|---|---|---|
| Tile size | 512 × 512 | SCUNet receptive field boundary |
| Tile overlap | 64 px | Eliminates seam artifacts |
| CLAHE tile | 128 px | Good default for ~1500 px wide scan |
| Compute units (M-series) | `.cpuAndNeuralEngine` | ~24% faster than `.all` |
| Compute units (Intel) | `.cpuAndGPU` | No ANE available |
| Model precision | FP16 | Half memory, ANE-native |
| Palettization | 6-bit per-group | ~37% size reduction, negligible loss |
| SCUNet disk size (FP16) | ~35 MB | Unpalettized |
| SCUNet disk size (6-bit) | ~13 MB | Palettized |
