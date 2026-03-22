//
//  MetadataEntity.swift
//  Retroview
//
//  Updated for OS 26 - Class Inheritance Support
//

import Foundation
import SwiftData

// MARK: - Base Schema for Metadata Entities (OS 26)

enum MetadataSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(2, 0, 0)
    
    static var models: [any PersistentModel.Type] {
        [
            MetadataEntity.self,
            AuthorMetadata.self,
            SubjectMetadata.self,
            DateMetadata.self,
            TitleMetadata.self,
            CardSchemaV1.StereoCard.self
        ]
    }
    
    // MARK: - Base Metadata Entity
    
    @Model
    class MetadataEntity {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        @Attribute(.externalStorage) var thumbnailData: Data?
        
        @Relationship(deleteRule: .nullify)
        var cards: [CardSchemaV1.StereoCard] = []
        
        init(name: String) {
            self.id = UUID()
            self.name = name
            self.createdAt = Date()
        }
    }
    
    // MARK: - Specialized Subclasses
    
    @Model
    class AuthorMetadata: MetadataEntity {
        var biography: String?
        var nationality: String?
        var activeYears: String?
        
        init(name: String, biography: String? = nil, nationality: String? = nil, activeYears: String? = nil) {
            self.biography = biography
            self.nationality = nationality
            self.activeYears = activeYears
            super.init(name: name)
        }
    }
    
    @Model
    class SubjectMetadata: MetadataEntity {
        var category: String?
        var subcategory: String?
        
        init(name: String, category: String? = nil, subcategory: String? = nil) {
            self.category = category
            self.subcategory = subcategory
            super.init(name: name)
        }
    }
    
    @Model
    class DateMetadata: MetadataEntity {
        var exactDate: Date?
        var dateRangeStart: Date?
        var dateRangeEnd: Date?
        var precision: DatePrecision?
        
        enum DatePrecision: String, Codable {
            case exact
            case year
            case decade
            case century
            case approximate
        }
        
        init(name: String, exactDate: Date? = nil, precision: DatePrecision? = nil) {
            self.exactDate = exactDate
            self.precision = precision
            super.init(name: name)
        }
    }
    
    @Model
    class TitleMetadata: MetadataEntity {
        var language: String?
        var isOriginalTitle: Bool
        
        @Relationship(deleteRule: .nullify)
        var picks: [CardSchemaV1.StereoCard] = []
        
        init(name: String, language: String? = nil, isOriginalTitle: Bool = true) {
            self.language = language
            self.isOriginalTitle = isOriginalTitle
            super.init(name: name)
        }
    }
}

// MARK: - Query Extensions for Type-Based Filtering

extension MetadataSchemaV2 {
    // Helper predicates for filtering by type
    static func authorPredicate() -> Predicate<MetadataEntity> {
        #Predicate { $0 is AuthorMetadata }
    }
    
    static func subjectPredicate() -> Predicate<MetadataEntity> {
        #Predicate { $0 is SubjectMetadata }
    }
    
    static func datePredicate() -> Predicate<MetadataEntity> {
        #Predicate { $0 is DateMetadata }
    }
    
    static func titlePredicate() -> Predicate<MetadataEntity> {
        #Predicate { $0 is TitleMetadata }
    }
}
