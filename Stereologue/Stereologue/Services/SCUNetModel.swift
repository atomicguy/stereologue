import CoreML
import OSLog

/// Lazily loads the on-device SCUNet dust/scratch/grain-removal model.
///
/// `nil` when `SCUNet_color_real.mlpackage` isn't bundled (it isn't checked
/// in — see `stereoview-restoration-guide.md` for how to convert and add
/// it) or fails to load. Callers treat `nil` as "denoising stage
/// unavailable" and skip it; the rest of the restoration pipeline is
/// unaffected either way.
nonisolated enum SCUNetModel {
    // Apple documents `MLModel` as safe to *call* from concurrent threads,
    // but that isn't the same as safe to *execute* concurrently: genuinely
    // concurrent `prediction(from:)` calls against this model (from
    // different tiles, or from the two stereo eyes restoring in parallel)
    // were observed to hang outright rather than merely serialize or slow
    // down. Every prediction — regardless of caller — goes through this one
    // serial queue so the underlying model only ever runs one request at a
    // time.
    static let predictionQueue = DispatchQueue(
        label: "net.atompowered.Stereologue.SCUNetPrediction"
    )

    nonisolated(unsafe) static let shared: MLModel? = {
        let logger = Logger(subsystem: "net.atompowered.Stereologue", category: "SCUNetModel")
        // Xcode compiles the checked-in .mlpackage to .mlmodelc at build
        // time and ships only the compiled form in the app bundle.
        guard let url = Bundle.main.url(forResource: "SCUNet_color_real", withExtension: "mlmodelc") else {
            logger.notice("SCUNet_color_real.mlmodelc not bundled; denoising stage disabled")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            // iOS/visionOS only — every target device is Apple Silicon, so
            // there's no Intel fallback to branch on. `.all` would let CoreML
            // silently route eligible ops to GPU instead of ANE.
            config.computeUnits = .cpuAndNeuralEngine
            return try MLModel(contentsOf: url, configuration: config)
        } catch {
            logger.error("Failed to load SCUNet model: \(error.localizedDescription)")
            return nil
        }
    }()
}
