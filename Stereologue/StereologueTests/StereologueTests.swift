//
//  StereologueTests.swift
//  StereologueTests
//
//  Created by Adam Schuster on 7/7/25.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
        let original = SpatialPhotoService.variantKey(for: base, quality: "v", style: nil, tier: .preview)
        let styled = SpatialPhotoService.variantKey(for: base, quality: "v", style: .enhance, tier: .preview)
        let otherStyle = SpatialPhotoService.variantKey(for: base, quality: "v", style: .preserveTone, tier: .preview)
        let fullTier = SpatialPhotoService.variantKey(for: base, quality: "v", style: nil, tier: .full)
        let lowRes = SpatialPhotoService.variantKey(for: base, quality: "w", style: nil, tier: .preview)

        // A user crop edit must never hit the old crop's cache entry.
        let recropped = SpatialPhotoCardData(
            uuid: base.uuid, frontImageID: base.frontImageID,
            leftDetection: ImageDetection(x: 110, y: 200, width: 300, height: 400),
            rightDetection: base.rightDetection,
            imageWidth: base.imageWidth, imageHeight: base.imageHeight
        )
        let recroppedKey = SpatialPhotoService.variantKey(for: recropped, quality: "v", style: nil, tier: .preview)

        #expect(Set([original, styled, otherStyle, fullTier, lowRes, recroppedKey]).count == 6)
        #expect(original == SpatialPhotoService.variantKey(for: base, quality: "v", style: nil, tier: .preview))
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

    // MARK: - Restoration evaluation set

    /// The fixture must load from the app bundle, cover every category, and
    /// name only cards that exist in the bundled catalog with both stereo
    /// detections — otherwise the eval tool and golden tests judge nothing.
    @Test func restorationEvalSetIsConsistentWithCatalog() async throws {
        let evalSet = try RestorationEvalSet.load()
        #expect(evalSet.cards.count >= 36)
        let categories = Set(evalSet.cards.map(\.category))
        #expect(categories == Set(RestorationEvalSet.categories))
        #expect(Set(evalSet.cards.map(\.uuid)).count == evalSet.cards.count, "duplicate uuids")

        let container = try Self.makeBundledCatalogContainer()
        let service = CatalogQueryService(modelContainer: container)
        let rows = await service.cardRows(uuids: evalSet.cards.map(\.uuid))
        #expect(rows.count == evalSet.cards.count, "every eval card must exist in the catalog")
        #expect(rows.allSatisfy { $0.hasStereoDetections })
    }

    // MARK: - Golden renders

    /// `StereologueTests/Fixtures/`: `eval-<category>-<uuid>-L.jpg` inputs
    /// (512 px left-eye crops of evaluation-set cards) and their
    /// `golden-…-<style>.jpg` renders. JPEG (quality 92) keeps the fixtures
    /// near a megabyte; its error is far below the 2 % tolerance.
    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// Every tone style, on every committed eye crop, must stay within 2 %
    /// mean absolute pixel difference of its committed golden render.
    ///
    /// To re-record after an intentional change, run the suite with
    /// `TEST_RUNNER_STEREOLOGUE_RECORD_GOLDENS=1`. The sandboxed test host
    /// can't write into the source tree, so the new goldens land in
    /// `RecordedGoldens/` under the host's temporary directory (the path is
    /// printed); copy them into `Fixtures/` and review them in the
    /// Restoration Eval tool before committing.
    @Test(arguments: RestorationStyle.allCases)
    func toneStylesMatchGoldenRenders(style: RestorationStyle) throws {
        let dir = Self.fixturesDirectory
        let sources = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("eval-") && $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(sources.count >= 4, "no eval-*.jpg fixtures in \(dir.path)")

        let record = ProcessInfo.processInfo.environment["STEREOLOGUE_RECORD_GOLDENS"] == "1"
        let recordDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordedGoldens", isDirectory: true)
        if record {
            try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
            print("STEREOLOGUE_RECORD_GOLDENS: writing to \(recordDir.path)")
        }
        let pipeline = RestorationPipeline()

        for source in sources {
            let input = try #require(Self.loadImage(source))
            let output = pipeline.restore(input, style: style)
            #expect(output.width == input.width && output.height == input.height)

            let goldenName = source.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "eval-", with: "golden-") + "-\(style.rawValue).jpg"
            let goldenURL = dir.appendingPathComponent(goldenName)
            if record {
                try Self.writeJPEG(output, to: recordDir.appendingPathComponent(goldenName))
                continue
            }
            let golden = try #require(
                Self.loadImage(goldenURL),
                "missing \(goldenName); record with STEREOLOGUE_RECORD_GOLDENS=1"
            )
            let difference = try #require(Self.meanAbsoluteDifference(output, golden))
            #expect(difference < 0.02, "\(goldenName) drifted by \(difference * 100)% mean pixel difference")
        }
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// Mean |a − b| over RGB, normalized to 0…1. `nil` on a size mismatch.
    private static func meanAbsoluteDifference(_ a: CGImage, _ b: CGImage) -> Double? {
        guard a.width == b.width, a.height == b.height,
              let pa = rgba(a), let pb = rgba(b) else { return nil }
        var total = 0
        var i = 0
        while i < pa.count {
            total += abs(Int(pa[i]) - Int(pb[i]))
                + abs(Int(pa[i + 1]) - Int(pb[i + 1]))
                + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
            i += 4
        }
        return Double(total) / Double(pa.count / 4 * 3) / 255
    }

    // MARK: - Paged rows

    /// Several cells appearing in one frame each call `loadNextPage`. That
    /// must fetch and append the next page exactly once, never duplicate a
    /// row (duplicate `ForEach` ids stop the grid loading), and still reach
    /// the end.
    @Test @MainActor func pagedRowsLoadEachPageOnceUnderBurstRequests() async {
        let total = 10
        let loader = PagedCardRows(pageSize: 4) { offset, limit in
            try? await Task.sleep(for: .milliseconds(20))
            return (offset..<min(offset + limit, total)).map {
                CardRow(uuid: "card-\($0)", title: "Card \($0)", frontImageID: nil, hasStereoDetections: true)
            }
        }
        await loader.reload()
        #expect(loader.rows.count == 4)

        for _ in 0..<5 { loader.loadNextPage() }
        await Self.settle(loader)
        #expect(loader.rows.count == 8, "burst of requests must add one page")
        #expect(Set(loader.rows.map(\.uuid)).count == loader.rows.count, "no duplicate rows")
        #expect(!loader.reachedEnd)

        loader.loadNextPage()
        await Self.settle(loader)
        #expect(loader.rows.count == total)
        #expect(loader.reachedEnd)
        #expect(loader.rows.map(\.uuid) == (0..<total).map { "card-\($0)" })

        loader.loadNextPage()
        await Self.settle(loader)
        #expect(loader.rows.count == total, "no fetch past the end")
    }

    @MainActor
    private static func settle(_ loader: PagedCardRows) async {
        for _ in 0..<200 where loader.isLoadingPage {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Pure geometry and formatting

    @Test func cropRectCentersScalesAndClampsDetections() throws {
        // Detections are centre + size in a 760-wide space; the source is 2560 wide.
        let scale = 2560.0 / 760.0
        let detection = ImageDetection(x: 218, y: 180, width: 314, height: 320)
        let rect = try #require(StereoPairRenderer.cropRect(
            for: detection, scaleX: scale, scaleY: scale, in: CGSize(width: 2560, height: 1335)
        ))
        #expect(abs(rect.minX - (218 - 157) * scale) < 1e-9)
        #expect(abs(rect.width - 314 * scale) < 1e-9)
        #expect(abs(rect.height - 320 * scale) < 1e-9)

        // A box hanging off the left edge is clamped to the image.
        let edge = StereoPairRenderer.cropRect(
            for: ImageDetection(x: 10, y: 100, width: 100, height: 100),
            scaleX: 1, scaleY: 1, in: CGSize(width: 760, height: 400)
        )
        #expect(edge == CGRect(x: 0, y: 50, width: 60, height: 100))

        // Entirely outside → nil, so the caller can report a crop failure.
        #expect(StereoPairRenderer.cropRect(
            for: ImageDetection(x: 900, y: 100, width: 50, height: 50),
            scaleX: 1, scaleY: 1, in: CGSize(width: 760, height: 400)
        ) == nil)
    }

    @Test func matchDimensionsCropsToTheSmallerEye() throws {
        let left = try #require(Self.makeTestImage(width: 300, height: 200))
        let right = try #require(Self.makeTestImage(width: 280, height: 210))

        let (l, r) = StereoPairRenderer.matchDimensions(left: left, right: right)
        #expect(l.width == 280 && l.height == 200)
        #expect(r.width == 280 && r.height == 200)

        let (sameL, sameR) = StereoPairRenderer.matchDimensions(left: left, right: left)
        #expect(sameL === left && sameR === left, "equal sizes pass through untouched")
    }

    @Test @MainActor func safeShareFilenameStripsPunctuationAndBounds() {
        #expect(CardPagerView.safeShareFilename(from: "Brooklyn Bridge, N.Y. \"East River\"") == "Brooklyn Bridge N Y East River")
        #expect(CardPagerView.safeShareFilename(from: "   ") == "Spatial Photo")
        #expect(CardPagerView.safeShareFilename(from: String(repeating: "a", count: 200)).count == 80)
        #expect(!CardPagerView.safeShareFilename(from: "Trailing period.").hasSuffix("."))
    }

    // MARK: - Catalog queries

    @Test func yearCountsCoverEveryDatedCardInAscendingOrder() async throws {
        let container = try Self.makeBundledCatalogContainer()
        let service = CatalogQueryService(modelContainer: container)

        let groups = await service.yearCounts()

        #expect(groups.count > 50)
        #expect(groups.map(\.year) == groups.map(\.year).sorted())
        #expect(groups.allSatisfy { $0.count > 0 })
        let dated = await service.cardRows(
            matching: #Predicate { $0.yearStart != nil },
            sortBy: [SortDescriptor(\.uuid)], offset: 0, limit: 100_000
        )
        #expect(groups.map(\.count).reduce(0, +) == dated.count)
    }

    @Test @MainActor func mainContextCardsMatchingPreservesOrder() async throws {
        let container = try Self.makeBundledCatalogContainer()
        let service = CatalogQueryService(modelContainer: container)
        let page = await service.cardRows(matching: nil, sortBy: PagedCardGridView.defaultSort, offset: 0, limit: 5)
        let requested = Array(page.map(\.uuid).reversed())

        let cards = container.mainContext.cards(matching: requested + ["missing"])

        #expect(cards.map(\.uuid) == requested)
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
