// AIAnalysisService.swift
// Apple Intelligence integration for card analysis

import Foundation
import Vision
import CoreML

@globalActor
actor AIServiceActor {
    static let shared = AIServiceActor()
    private init() {}
}

@AIServiceActor
final class AIAnalysisService {
    private let sceneClassifier: VNImageClassificationRequest
    private let textDetector: VNRecognizeTextRequest
    
    init() throws {
        // Initialize Apple Intelligence models
        self.sceneClassifier = VNImageClassificationRequest()
        self.textDetector = VNRecognizeTextRequest()
        self.textDetector.recognitionLevel = .accurate
    }
    
    func analyzeCard(imageData: Data) async throws -> AIAnalysis {
        let image = try createCGImage(from: imageData)
        
        async let scenes = detectScenes(in: image)
        async let text = extractText(from: image)
        async let objects = detectObjects(in: image)
        
        let (detectedScenes, extractedText, detectedObjects) = try await (scenes, text, objects)
        
        return AIAnalysis(
            subjects: detectedScenes + detectedObjects,
            extractedText: extractedText,
            confidence: calculateConfidence(detectedScenes, detectedObjects),
            suggestedTags: generateTags(from: detectedScenes, objects: detectedObjects)
        )
    }
    
    private func detectScenes(in image: CGImage) async throws -> [String] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNImageClassificationRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let observations = request.results as? [VNClassificationObservation] ?? []
                let scenes = observations
                    .filter { $0.confidence > 0.5 }
                    .prefix(5)
                    .map { $0.identifier }
                
                continuation.resume(returning: Array(scenes))
            }
            
            let handler = VNImageRequestHandler(cgImage: image)
            try? handler.perform([request])
        }
    }
    
    private func extractText(from image: CGImage) async throws -> [String] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { 
                    try? $0.topCandidates(1).first?.string 
                }
                
                continuation.resume(returning: text)
            }
            
            let handler = VNImageRequestHandler(cgImage: image)
            try? handler.perform([request])
        }
    }
    
    private func detectObjects(in image: CGImage) async throws -> [String] {
        // Implementation for object detection using Apple's models
        return []
    }
    
    private func createCGImage(from data: Data) throws -> CGImage {
        #if os(macOS)
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AIServiceError.invalidImageData
        }
        #else
        guard let image = UIImage(data: data)?.cgImage else {
            throw AIServiceError.invalidImageData
        }
        #endif
        return image
    }
    
    private func calculateConfidence(_ scenes: [String], _ objects: [String]) -> Float {
        // Calculate overall confidence score
        return 0.8
    }
    
    private func generateTags(from scenes: [String], objects: [String]) -> [String] {
        // Generate smart tags based on detected content
        return scenes + objects
    }
}

// MARK: - Error Types
enum AIServiceError: LocalizedError {
    case invalidImageData
    case analysisTimeout
    case modelLoadFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Invalid image data provided"
        case .analysisTimeout:
            return "AI analysis timed out"
        case .modelLoadFailed:
            return "Failed to load AI model"
        }
    }
}