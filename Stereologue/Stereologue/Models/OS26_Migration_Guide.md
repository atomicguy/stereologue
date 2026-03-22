//
//  OS26_Migration_Guide.md
//  Stereologue
//
//  Guide for updating SwiftData models to OS 26
//

# SwiftData Model Updates for OS 26

## Summary of Improvements

### 1. Class Inheritance Support ⭐ NEW
**File**: `MetadataEntity.swift`

Your current metadata models (Author, Subject, Date, Title) share common properties and could benefit from SwiftData's new class inheritance support. This would:

- Reduce code duplication
- Enable polymorphic queries across all metadata types
- Add extensibility for future metadata types
- Improve query performance with type-based filtering

**Benefits:**
- Query all metadata at once: `@Query var allMetadata: [MetadataEntity]`
- Filter by specific type: `@Query(filter: #Predicate { $0 is AuthorMetadata }) var authors`
- Share common functionality (thumbnails, card relationships)

**Migration Path:**
1. Create `MetadataSchemaV2` with base `MetadataEntity` class
2. Migrate existing Author, Subject, Date, Title to subclasses
3. Use `VersionedSchema` to handle migration from V1 to V2
4. Update queries to leverage inheritance

### 2. AppIntents Integration ⭐ NEW
**File**: `StereoCardAppIntents.swift`

OS 26 brings powerful new AppIntents capabilities:

#### Visual Intelligence Integration
- Users can circle stereo cards in photos/camera
- Your app provides matching cards from the collection
- Uses `IntentValueQuery` with `SemanticContentDescriptor`

#### Spotlight Indexing
- Make all stereo cards searchable system-wide
- Search by title, author, subject, date
- Direct deep linking to specific cards
- Uses `IndexedEntity` protocol

#### App Shortcuts
- "Search my Stereologue cards"
- "Find stereo cards in Stereologue"
- Customizable Siri phrases

**Benefits:**
- Increased discoverability via system search
- Better integration with Apple Intelligence
- Enhanced user workflows outside your app

### 3. Enhanced Computed Properties
**Updated**: `Collection.swift`, `StereoCard.swift`

Added helper computed properties for:
- Quick access to primary metadata (`primaryAuthor`, `primarySubject`)
- Status checking (`hasCompleteMetadata`, `hasFrontImage`)
- Display strings (`displayTitle`)
- Collection stats (`cardCount`, `isEmpty`)

**Future Enhancement:**
Once you have external data sources (like UserDefaults for favorites), you can use:
- `@ComputedProperty` - For properties that access external sources
- `@DeferredProperty` - For expensive async operations (e.g., AI analysis of images)

### 4. Improved Relationship Management

Enhanced the StereoCard model with:
- Better null-safety for optional relationships
- Helper methods for primary metadata access
- Status checking methods

## Implementation Checklist

### Immediate Actions (Low Risk)
- [x] Add computed properties to Collection and StereoCard
- [x] Create AppIntents structure for Spotlight integration
- [x] Add Spotlight indexing to app initialization
- [ ] Test Spotlight search functionality
- [ ] Add App Shortcuts to Info.plist

### Medium-Term Actions (Requires Testing)
- [ ] Implement Visual Intelligence query handler
- [ ] Add image recognition for visual search
- [ ] Create deep linking infrastructure
- [ ] Test AppIntents integration

### Long-Term Actions (Requires Migration)
- [ ] Design metadata class hierarchy (MetadataEntity base class)
- [ ] Create migration schema (V2)
- [ ] Test migration with existing data
- [ ] Update all queries to use new hierarchy
- [ ] Deploy migration to production

## Code Integration Steps

### 1. Enable AppIntents in Info.plist

Add to your Info.plist:
```xml
<key>NSUserActivityTypes</key>
<array>
    <string>com.stereologue.ViewCard</string>
    <string>com.stereologue.SearchCards</string>
</array>
```

### 2. Add Required Capabilities

In Xcode:
1. Target Settings → Signing & Capabilities
2. Add "App Intents" capability
3. Add "Siri" capability (for shortcuts)

### 3. Update CardRepository

Add Spotlight reindexing on card updates:
```swift
func updateCard(_ card: StereoCard, context: ModelContext) async {
    // ... existing update logic ...
    
    // Reindex in Spotlight
    let indexingService = SpotlightIndexingService(modelContext: context)
    await indexingService.reindexCard(card)
}

func deleteCard(_ card: StereoCard, context: ModelContext) async {
    let cardId = card.uuid.uuidString
    
    // ... existing delete logic ...
    
    // Remove from Spotlight
    let indexingService = SpotlightIndexingService(modelContext: context)
    await indexingService.removeCardFromIndex(cardId)
}
```

### 4. Handle Deep Links

In your main app:
```swift
.onOpenURL { url in
    // Parse URL like: stereologue://card/{uuid}
    if url.scheme == "stereologue" {
        handleDeepLink(url)
    }
}
```

## Performance Considerations

### External Storage
Your current use of `@Attribute(.externalStorage)` is excellent for:
- Image data (thumbnails, standard, spatial photos)
- Keeps database file size manageable
- Continue this pattern for new large data

### Relationship Delete Rules
Review your delete rules:
- `cascade` - Good for owned relationships (titles, crops)
- `nullify` - Good for shared relationships (authors, subjects)
- Consider `deny` for critical data integrity

### Query Optimization
With OS 26:
- Use inheritance predicates for type filtering
- Leverage indexed properties for search
- Consider batch operations for Spotlight indexing

## Testing Strategy

1. **Unit Tests**
   - Test metadata class hierarchy
   - Test AppIntent value queries
   - Test Spotlight entity creation

2. **Integration Tests**
   - Test schema migration
   - Test Spotlight indexing
   - Test deep linking

3. **User Acceptance Tests**
   - Search in Spotlight
   - Use Siri shortcuts
   - Test Visual Intelligence (if implemented)

## Questions to Consider

1. **Do you want to migrate to class inheritance?**
   - Pro: Better organization, shared functionality
   - Con: Requires data migration

2. **Do you have image recognition capabilities?**
   - Needed for Visual Intelligence integration
   - Could use Vision framework for feature extraction

3. **What deep linking scheme works for your app?**
   - Need to define URL structure
   - Need to handle navigation

4. **Do you want background indexing?**
   - Index cards as they're created
   - Batch reindex periodically
   - User-triggered reindex

## Resources

- [Apple: Adopting Class Inheritance in SwiftData](https://developer.apple.com/documentation/SwiftData/Adopting-inheritance-in-SwiftData)
- [Apple: AppIntents Framework](https://developer.apple.com/documentation/AppIntents)
- [Apple: Integrating with Visual Intelligence](https://developer.apple.com/documentation/VisualIntelligence)
- [Apple: Spotlight Search](https://developer.apple.com/documentation/CoreSpotlight)

## Next Steps

1. Review the proposed changes
2. Test Spotlight integration in a development build
3. Decide on class inheritance migration timeline
4. Implement Visual Intelligence if desired
5. Submit app with new capabilities
