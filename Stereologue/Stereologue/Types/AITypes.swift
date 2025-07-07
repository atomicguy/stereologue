// AITypes.swift
// Types and structures for AI analysis

import Foundation

// MARK: - AI Analysis Results
struct AIAnalysis {
    let subjects: [String]
    let extractedText: [String]
    let confidence: Float
    let suggestedTags: [String]
    let analysisDate: Date
    
    init(subjects: [String], extractedText: [String], confidence: Float, suggestedTags: [String]) {
        self.subjects = subjects
        self.extractedText = extractedText
        self.confidence = confidence
        self.suggestedTags = suggestedTags
        self.analysisDate = Date()
    }
}

// MARK: - Scene Detection
struct SceneAnalysis {
    let primaryScene: String
    let confidence: Float
    let alternativeScenes: [String]
}

struct ObjectDetection {
    let objects: [DetectedObject]
    let confidence: Float
}

struct DetectedObject {
    let name: String
    let confidence: Float
    let boundingBox: CGRect?
}

// MARK: - Text Recognition
struct TextAnalysis {
    let recognizedText: [String]
    let confidence: Float
    let language: String?
    let regions: [TextRegion]
}

struct TextRegion {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

// MARK: - Smart Categorization
struct CategorySuggestion {
    let category: String
    let confidence: Float
    let reasoning: String
}

struct ThemeAnalysis {
    let primaryTheme: String
    let subThemes: [String]
    let confidence: Float
    let keywords: [String]
}

// MARK: - Quality Assessment
struct ImageQualityAssessment {
    let overallScore: Float
    let sharpness: Float
    let contrast: Float
    let brightness: Float
    let colorBalance: Float
    let suggestions: [QualityImprovement]
}

struct QualityImprovement {
    let type: ImprovementType
    let severity: Float
    let description: String
}

enum ImprovementType {
    case sharpen
    case adjustBrightness
    case adjustContrast
    case colorCorrection
    case noiseReduction
}

// MARK: - Similarity Matching
struct SimilarityScore {
    let cardId: UUID
    let score: Float
    let matchingFactors: [SimilarityFactor]
}

enum SimilarityFactor {
    case visualSimilarity(Float)
    case subjectMatch(Float)
    case authorMatch(Float)
    case temporalProximity(Float)
    case styleMatch(Float)
}

// MARK: - Processing Status
enum AIProcessingStatus {
    case pending
    case analyzing
    case completed(AIAnalysis)
    case failed(Error)
}

// MARK: - Apple Intelligence Models
enum AIModel {
    case sceneClassification
    case textRecognition
    case objectDetection
    case qualityAssessment
    case similarityMatching
    
    var modelName: String {
        switch self {
        case .sceneClassification:
            return "VNImageClassificationRequest"
        case .textRecognition:
            return "VNRecognizeTextRequest"
        case .objectDetection:
            return "VNDetectObjectRequest"
        case .qualityAssessment:
            return "ImageQualityClassifier"
        case .similarityMatching:
            return "VisualSimilarityModel"
        }
    }
}

// MARK: - Batch Processing
struct BatchAnalysisRequest {
    let cardIds: [UUID]
    let models: [AIModel]
    let priority: TaskPriority
}

struct BatchAnalysisResult {
    let completedAnalyses: [UUID: AIAnalysis]
    let failedAnalyses: [UUID: Error]
    let processingTime: TimeInterval
}