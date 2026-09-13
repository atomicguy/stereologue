//
//  StereologueTests.swift
//  StereologueTests
//
//  Created by Adam Schuster on 7/7/25.
//

import Testing
import Foundation
import CoreGraphics
import SwiftData
@testable import Stereologue

struct StereologueTests {

    @Test func restorePreservesDimensionsForEveryStyle() throws {
        let input = try #require(Self.makeTestImage(width: 96, height: 64))
        let pipeline = RestorationPipeline()

        for style in RestorationStyle.allCases {
            let output = pipeline.restore(input, style: style)
            #expect(output.width == input.width, "\(style) changed width")
            #expect(output.height == input.height, "\(style) changed height")
            #expect(!Self.isUniform(output), "\(style) collapsed to a flat color")
        }
    }

    /// Mirrors the real call site (SpatialPhotoService's preparedStereoPair):
    /// the two eyes restored concurrently through `async let` on the shared,
    /// Sendable pipeline.
    @Test func restoreRunsConcurrentlyForBothEyes() async throws {
        let left = try #require(Self.makeTestImage(width: 300, height: 200))
        let right = try #require(Self.makeTestImage(width: 300, height: 200))
        let pipeline = RestorationPipeline()

        async let leftOut = pipeline.restore(left, style: .enhance)
        async let rightOut = pipeline.restore(right, style: .enhance)
        let (l, r) = await (leftOut, rightOut)

        #expect(l.width == left.width)
        #expect(r.width == right.width)
    }

    @Test func matchPairLeavesBalancedPairUntouched() throws {
        let image = try #require(Self.makeTestImage(width: 64, height: 64))
        let pipeline = RestorationPipeline()

        let matched = pipeline.matchPair(left: image, right: image)

        // Identical eyes are already balanced; the pipeline should short-circuit
        // and hand back the very same images rather than re-rendering them.
        #expect(matched.left === image)
        #expect(matched.right === image)
    }

    @Test func variantKeyDistinguishesEveryRenderInput() {
        let base = SpatialPhotoCardData(
            uuid: "abc", frontImageID: "G1",
            leftDetection: ImageDetection(x: 100, y: 200, width: 300, height: 400),
            rightDetection: ImageDetection(x: 500, y: 200, width: 300, height: 400),
            imageWidth: 1000, imageHeight: 500
        )
        let original = SpatialPhotoService.variantKey(for: base, quality: "v", style: nil)
        let styled = SpatialPhotoService.variantKey(for: base, quality: "v", style: .enhance)
        let otherStyle = SpatialPhotoService.variantKey(for: base, quality: "v", style: .preserveTone)
        let lowRes = SpatialPhotoService.variantKey(for: base, quality: "w", style: nil)

        // A user crop edit must never hit the old crop's cache entry.
        let recropped = SpatialPhotoCardData(
            uuid: base.uuid, frontImageID: base.frontImageID,
            leftDetection: ImageDetection(x: 110, y: 200, width: 300, height: 400),
            rightDetection: base.rightDetection,
            imageWidth: base.imageWidth, imageHeight: base.imageHeight
        )
        let recroppedKey = SpatialPhotoService.variantKey(for: recropped, quality: "v", style: nil)

        #expect(Set([original, styled, otherStyle, lowRes, recroppedKey]).count == 5)
        #expect(original == SpatialPhotoService.variantKey(for: base, quality: "v", style: nil))
        #expect(original.hasPrefix("abc_"), "evict(cardUUID:) relies on the uuid prefix")
    }

    // MARK: - Catalog paging (against the real bundled store)

    /// Opens a private copy of the bundled catalog. Also exercises SwiftData's
    /// lightweight migration of the shipped store to the current schema (e.g.
    /// the `title` index), which is exactly what happens on a user's device.
    private static func makeBundledCatalogContainer() throws -> ModelContainer {
        let bundled = try #require(Bundle.main.url(forResource: "CatalogStore", withExtension: "store"))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StereologueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("CatalogStore.store")
        try FileManager.default.copyItem(at: bundled, to: url)
        let schema = Schema([StereoCard.self, Creator.self, Subject.self, Place.self, Collection.self])
        let config = ModelConfiguration("CatalogStoreTest", schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: config)
    }

    @Test func catalogPagesRowsInStableOrderOffMainActor() async throws {
        let container = try Self.makeBundledCatalogContainer()
        let service = CatalogQueryService(modelContainer: container)
        let sort = PagedCardGridView.defaultSort

        let clock = ContinuousClock()
        let start = clock.now
        let page0 = await service.cardRows(matching: nil, sortBy: sort, offset: 0, limit: 80)
        let page1 = await service.cardRows(matching: nil, sortBy: sort, offset: 80, limit: 80)
        let deep = await service.cardRows(matching: nil, sortBy: sort, offset: 30_000, limit: 80)
        let elapsed = clock.now - start

        #expect(page0.count == 80)
        #expect(page1.count == 80)
        #expect(deep.count == 80)
        #expect(Set(page0.map(\.uuid)).isDisjoint(with: page1.map(\.uuid)))
        #expect(Set(page1.map(\.uuid)).isDisjoint(with: deep.map(\.uuid)))
        let first = try #require(page0.first?.title)
        let far = try #require(deep.first?.title)
        #expect(first.localizedStandardCompare(far) != .orderedDescending)
        // Three title-sorted pages, including one deep into the catalog. With
        // the title index this is milliseconds; without it each page re-sorts
        // 41K rows.
        #expect(elapsed < .seconds(2), "paging took \(elapsed)")
    }

    @Test func catalogRowsByUUIDPreserveRequestedOrder() async throws {
        let container = try Self.makeBundledCatalogContainer()
        let service = CatalogQueryService(modelContainer: container)

        let page = await service.cardRows(matching: nil, sortBy: PagedCardGridView.defaultSort, offset: 0, limit: 6)
        let requested = Array(page.map(\.uuid).reversed())
        let rows = await service.cardRows(uuids: requested + ["not-a-card"])

        #expect(rows.map(\.uuid) == requested)
    }

    @Test func catalogSearchPredicatePagesTooOffMainActor() async throws {
        let container = try Self.makeBundledCatalogContainer()
        let service = CatalogQueryService(modelContainer: container)
        let text = "bridge"
        let predicate = #Predicate<StereoCard> { $0.title.localizedStandardContains(text) }

        let rows = await service.cardRows(matching: predicate, sortBy: PagedCardGridView.defaultSort, offset: 0, limit: 40)

        #expect(rows.count == 40)
        #expect(rows.allSatisfy { $0.title.localizedStandardContains(text) })
    }

    @Test func parseYearReadsLeadingFourDigits() {
        #expect(StereoCard.parseYear(from: "1871-08") == 1871)
        #expect(StereoCard.parseYear(from: "1850") == 1850)
        #expect(StereoCard.parseYear(from: "ca. 1900") == nil)
        #expect(StereoCard.parseYear(from: "18") == nil)
        #expect(StereoCard.parseYear(from: nil) == nil)
    }

    /// A synthetic noisy gradient — enough structure that a restoration
    /// producing a degenerate (blank/uniform) output is visibly wrong.
    private static func makeTestImage(width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8((x * 255) / max(1, width - 1))
                pixels[i + 1] = UInt8((y * 255) / max(1, height - 1))
                pixels[i + 2] = UInt8(((x ^ y) * 37) % 256)
                pixels[i + 3] = 255
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private static func isUniform(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let first = pixels[0]
        return pixels.allSatisfy { $0 == first }
    }
}
