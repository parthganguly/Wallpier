import Foundation
import AppKit
import CoreGraphics
import ImageIO
import XCTest
@testable import Wallpier

final class WallpierTests: XCTestCase {
    func testStateCodableRoundTrip() throws {
        let previous = DisplayAssignment(
            displayID: "1",
            displayName: "Built-in Display",
            imagePath: "/Pictures/one.jpg",
            scaling: .fit
        )
        let replacement = DisplayAssignment(
            displayID: "1",
            displayName: "Built-in Display",
            imagePath: "/Pictures/two.heic",
            scaling: .fill
        )
        var state = WallpaperState()
        state.folderPath = "/Pictures"
        state.selectedImagePath = replacement.imagePath
        state.selectedDisplayID = replacement.displayID
        state.scalingMode = .center
        state.rotationInterval = .oneHour
        state.shuffleEnabled = true
        state.currentSource = .favorites
        let remote = remoteReference(id: "94x38z")
        state.toggleFavorite(remote)
        state.collections = [WallpaperCollection(name: "Nature", wallpapers: [remote])]
        state.setAssignment(replacement)
        state.appendHistory(
            HistoryEntry(previous: previous, replacement: replacement, timestamp: Date(timeIntervalSince1970: 100))
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(WallpaperState.self, from: encoder.encode(state))
        XCTAssertEqual(decoded, state)
    }

    func testHistoryIsBoundedToTwentyEntries() {
        var state = WallpaperState()
        for index in 0..<25 {
            let previous = assignment(path: "\(index).jpg")
            let replacement = assignment(path: "\(index + 1).jpg")
            state.appendHistory(
                HistoryEntry(
                    previous: previous,
                    replacement: replacement,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }

        XCTAssertEqual(state.history.count, WallpaperState.historyLimit)
        XCTAssertEqual(state.history.first?.previous.imagePath, "5.jpg")
        XCTAssertEqual(state.history.last?.replacement.imagePath, "25.jpg")
    }

    func testNavigationWrapsInBothDirections() {
        XCTAssertEqual(WallpaperNavigation.index(after: 2, direction: 1, count: 3), 0)
        XCTAssertEqual(WallpaperNavigation.index(after: 0, direction: -1, count: 3), 2)
        XCTAssertEqual(WallpaperNavigation.index(after: nil, direction: 1, count: 3), 0)
        XCTAssertEqual(WallpaperNavigation.index(after: nil, direction: -1, count: 3), 2)
        XCTAssertNil(WallpaperNavigation.index(after: nil, direction: 1, count: 0))
    }

    func testRotationIntervals() {
        XCTAssertNil(RotationInterval.off.seconds)
        XCTAssertEqual(RotationInterval.fifteenMinutes.seconds, 900)
        XCTAssertEqual(RotationInterval.oneHour.seconds, 3_600)
        XCTAssertEqual(RotationInterval.oneDay.seconds, 86_400)
    }

    func testSupportedImageFilteringAndFilenameOrdering() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        for name in ["wallpaper10.JPG", "wallpaper2.png", "wallpaper1.heic", "ignored.gif"] {
            try Data([0]).write(to: folderURL.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(
            at: folderURL.appendingPathComponent("not-a-file.jpeg"),
            withIntermediateDirectories: false
        )

        let images = try SupportedWallpaperFiles.images(in: folderURL)
        XCTAssertEqual(images.map(\.lastPathComponent), [
            "wallpaper1.heic",
            "wallpaper2.png",
            "wallpaper10.JPG"
        ])
        XCTAssertTrue(SupportedWallpaperFiles.isSupported(URL(fileURLWithPath: "photo.heif")))
        XCTAssertFalse(SupportedWallpaperFiles.isSupported(URL(fileURLWithPath: "photo.gif")))
    }

    func testCorruptStateFallsBackToDefaults() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpierStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let stateURL = folderURL.appendingPathComponent("state.json")
        try Data("not json".utf8).write(to: stateURL)

        let state = WallpaperStateStore(stateURL: stateURL).load()
        XCTAssertEqual(state, WallpaperState())
    }

    func testVersionOneStateMigratesWithoutLosingLocalSelection() throws {
        let data = Data("""
        {
          "version": 1,
          "folderPath": "/Pictures/Wallpapers",
          "selectedImagePath": "/Pictures/Wallpapers/one.jpg",
          "scalingMode": "fit",
          "rotationInterval": "off",
          "shuffleEnabled": false,
          "displayAssignments": [],
          "history": []
        }
        """.utf8)

        let migrated = try JSONDecoder().decode(WallpaperState.self, from: data)
        XCTAssertEqual(migrated.version, WallpaperState.currentVersion)
        XCTAssertEqual(migrated.currentSource, .local)
        XCTAssertEqual(migrated.folderPath, "/Pictures/Wallpapers")
        XCTAssertTrue(migrated.favorites.isEmpty)
        XCTAssertTrue(migrated.collections.isEmpty)
    }

    func testWallpaperReferenceCodableRoundTrip() throws {
        var reference = remoteReference(id: "94x38z")
        reference.uploader = "test-user"
        reference.tags = ["nature", "mountains"]
        reference.cachedLocalPath = "/Caches/wallhaven-94x38z.jpg"

        let decoded = try JSONDecoder().decode(
            WallpaperReference.self,
            from: JSONEncoder().encode(reference)
        )
        XCTAssertEqual(decoded, reference)
    }

    func testCollectionAddRemoveAndRename() {
        let first = remoteReference(id: "first")
        let second = remoteReference(id: "second")
        var collection = WallpaperCollection(name: "  Nature  ")

        collection.add(first)
        collection.add(first)
        collection.add(second)
        XCTAssertEqual(collection.name, "Nature")
        XCTAssertEqual(collection.wallpapers.count, 2)

        collection.rename(to: "  Landscapes ")
        collection.remove(identityKey: first.identityKey)
        XCTAssertEqual(collection.name, "Landscapes")
        XCTAssertEqual(collection.wallpapers, [second])
    }

    func testFavoritePersistsWithoutDownloadingOriginal() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpierFavoriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let reference = remoteReference(id: "favorite")
        var state = WallpaperState()
        state.toggleFavorite(reference)
        let store = WallpaperStateStore(stateURL: folderURL.appendingPathComponent("state.json"))
        store.save(state)

        let restored = store.load()
        XCTAssertEqual(restored.favorites, [reference])
        XCTAssertNil(restored.favorites.first?.cachedLocalPath)
    }

    func testWallhavenURLConstructionUsesProviderNativeFiltersAndSFW() throws {
        let options = WallhavenSearchOptions(
            query: "misty mountains",
            category: .general,
            minimumWidth: 2560,
            minimumHeight: 1600,
            aspectRatio: .standard,
            sorting: .toplist
        )
        let url = WallhavenEndpoint.searchURL(options: options, page: 3)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(values["q"], "misty mountains")
        XCTAssertEqual(values["categories"], "100")
        XCTAssertEqual(values["purity"], "100")
        XCTAssertEqual(values["atleast"], "2560x1600")
        XCTAssertEqual(values["ratios"], "16x10")
        XCTAssertEqual(values["sorting"], "toplist")
        XCTAssertEqual(values["topRange"], "1M")
        XCTAssertEqual(values["page"], "3")
        XCTAssertNil(values["apikey"])
    }

    func testEmptyQueryRelevanceAsksWallhavenForTopWallpapers() throws {
        // Live Wallhaven answers relevance-without-query with an empty page, which made first launch look broken.
        func values(_ options: WallhavenSearchOptions) throws -> [String: String] {
            let components = try XCTUnwrap(URLComponents(url: WallhavenEndpoint.searchURL(options: options, page: 1), resolvingAgainstBaseURL: false))
            return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        let empty = try values(WallhavenSearchOptions(query: "  ", sorting: .relevance))
        XCTAssertEqual(empty["sorting"], "toplist")
        XCTAssertEqual(empty["topRange"], "1M")
        XCTAssertNil(empty["q"])
        let queried = try values(WallhavenSearchOptions(query: "forest", sorting: .relevance))
        XCTAssertEqual(queried["sorting"], "relevance")
        XCTAssertNil(queried["topRange"])
        XCTAssertEqual(try values(WallhavenSearchOptions(query: "", sorting: .dateAdded))["sorting"], "date_added")
    }

    func testWallhavenSearchAndDetailFixturesDecode() async throws {
        let searchClient = StubNetworkClient(data: try fixtureData(named: "wallhaven-search"))
        let provider = WallhavenProvider(client: searchClient)
        let page = try await provider.search(options: WallhavenSearchOptions(query: "nature"), page: 1)

        XCTAssertEqual(page.wallpapers.count, 2)
        XCTAssertEqual(page.currentPage, 1)
        XCTAssertEqual(page.lastPage, 3)
        XCTAssertEqual(page.total, 50)
        XCTAssertEqual(page.wallpapers.first?.wallpaperID, "94x38z")
        XCTAssertEqual(page.wallpapers.first?.resolution, "6742×3534")

        let detailClient = StubNetworkClient(data: try fixtureData(named: "wallhaven-detail"))
        let detailProvider = WallhavenProvider(client: detailClient)
        let detailed = try await detailProvider.fetchDetails(for: try XCTUnwrap(page.wallpapers.first))
        XCTAssertEqual(detailed.uploader, "test-user")
        XCTAssertEqual(detailed.tags, ["nature", "mountains"])
    }

    func testWallhavenRateLimitUsesRetryAfter() async throws {
        let client = StubNetworkClient(data: Data(), statusCode: 429, headers: ["Retry-After": "7"])
        let provider = WallhavenProvider(client: client)

        do {
            _ = try await provider.search(options: WallhavenSearchOptions(), page: 1)
            XCTFail("Expected a rate-limit error")
        } catch let error as RemoteProviderError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 7))
        }
    }

    func testWallhavenRetriesOneTransientGatewayFailure() async throws {
        let fixtureURL = Bundle(for: Self.self).url(forResource: "wallhaven-search", withExtension: "json")!
        let data = try Data(contentsOf: fixtureURL)
        let url = URL(string: "https://wallhaven.cc/api/v1/search")!
        let failure = HTTPURLResponse(url: url, statusCode: 502, httpVersion: nil, headerFields: nil)!
        let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let client = SequencedNetworkClient(responses: [(Data(), failure), (data, success)])
        let provider = WallhavenProvider(client: client, cacheLifetime: 0)

        let page = try await provider.search(options: WallhavenSearchOptions(), page: 1)

        XCTAssertEqual(page.wallpapers.count, 2)
        XCTAssertEqual(client.requestCount, 2)
    }

    func testCacheFilenameIsStableAndCollisionSafe() {
        let first = remoteReference(id: "same")
        var second = remoteReference(id: "same")
        second = WallpaperReference(
            providerIdentifier: second.providerIdentifier,
            wallpaperID: second.wallpaperID,
            sourcePageURL: second.sourcePageURL,
            originalURL: URL(string: "https://w.wallhaven.cc/full/ab/another-file.png")!,
            previewURL: second.previewURL,
            thumbnailURL: second.thumbnailURL,
            width: second.width,
            height: second.height,
            uploader: nil,
            tags: [],
            cachedLocalPath: nil
        )

        XCTAssertEqual(
            RemoteWallpaperCache.filename(for: first),
            RemoteWallpaperCache.filename(for: first)
        )
        XCTAssertNotEqual(
            RemoteWallpaperCache.filename(for: first),
            RemoteWallpaperCache.filename(for: second)
        )
        XCTAssertTrue(RemoteWallpaperCache.filename(for: second).hasSuffix(".png"))
    }

    func testRateLimitBlocksSubsequentNetworkCalls() async throws {
        let url = URL(string: "https://wallhaven.cc/api/v1/search")!
        let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!
        let client = SequencedNetworkClient(responses: [(Data(), response)])
        let provider = WallhavenProvider(client: client)
        for page in 1...2 {
            do {
                _ = try await provider.search(options: WallhavenSearchOptions(), page: page)
                XCTFail("Expected backoff")
            } catch let error as RemoteProviderError {
                guard case .rateLimited = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertEqual(client.requestCount, 1)
    }

    func testDetailCacheRetainsLatestLocalPath() async throws {
        let provider = WallhavenProvider(client: StubNetworkClient(data: try fixtureData(named: "wallhaven-detail")))
        var reference = remoteReference(id: "94x38z")
        _ = try await provider.fetchDetails(for: reference)
        reference.cachedLocalPath = "/tmp/newly-downloaded.jpg"
        let detail = try await provider.fetchDetails(for: reference)
        XCTAssertEqual(detail.cachedLocalPath, reference.cachedLocalPath)
    }

    func testCorruptCacheRecoversAtNewPathAndReusesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpierRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var reference = remoteReference(id: "broken")
        let damaged = root.appendingPathComponent(RemoteWallpaperCache.filename(for: reference))
        let badBytes = Data("invalid image".utf8)
        try badBytes.write(to: damaged)
        reference.cachedLocalPath = damaged.path
        let cache = RemoteWallpaperCache(rootURL: root)
        let missing = try await cache.cachedURL(for: reference)
        XCTAssertNil(missing)
        let incoming = root.appendingPathComponent("incoming.png")
        try writeTestImage(to: incoming)
        let recovered = try await cache.installDownloadedFile(incoming, for: reference, protectedPaths: [damaged.path])
        XCTAssertNotEqual(recovered, damaged)
        XCTAssertEqual(try Data(contentsOf: damaged), badBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        reference.cachedLocalPath = recovered.path
        let reused = try await cache.cachedURL(for: reference)
        XCTAssertEqual(reused, recovered)
    }

    func testCacheRejectsAdditionWhenProtectedAssetsFillBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpierCapacity-\(UUID())")
        let incoming = FileManager.default.temporaryDirectory.appendingPathComponent("WallpierIncoming-\(UUID()).png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: incoming) }
        let protected = root.appendingPathComponent("protected.png")
        try writeTestImage(to: protected)
        try writeTestImage(to: incoming)
        let cache = RemoteWallpaperCache(rootURL: root, maximumSizeBytes: 1)
        do {
            _ = try await cache.installDownloadedFile(incoming, for: remoteReference(id: "new"), protectedPaths: [protected.path])
            XCTFail("Expected capacity error")
        } catch RemoteWallpaperCacheError.capacityReached { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["protected.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
    }

    private func writeTestImage(to url: URL, red: CGFloat = 0.2, width: Int = 8) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testCacheEvictionKeepsProtectedFiles() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpierCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let old = rootURL.appendingPathComponent("old.jpg")
        let middle = rootURL.appendingPathComponent("middle.jpg")
        let protected = rootURL.appendingPathComponent("protected.jpg")
        try Data([1]).write(to: old)
        try Data([2]).write(to: middle)
        try Data([3]).write(to: protected)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: middle.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3)], ofItemAtPath: protected.path)

        let cache = RemoteWallpaperCache(rootURL: rootURL, maximumSizeBytes: 1)
        let removed = try await cache.evictIfNeeded(protectedPaths: [protected.path])
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), ["old.jpg", "middle.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
    }

    func testExternalWallpaperUndoSurvivesOriginalDeletionAndRelaunch() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("external.png")
        try writeTestImage(to: source)
        let bytes = try Data(contentsOf: source)
        let store = WallpaperHistoryStore(root: folder.appendingPathComponent("Rollback"))
        let entry = await store.prepare(previous: assignment(path: source.path), replacement: assignment(path: "next.png"))
        XCTAssertNil(entry.undoUnavailableReason)
        let rollback = try XCTUnwrap(entry.rollbackPath)
        XCTAssertNotEqual(rollback, source.path)
        var state = WallpaperState(); state.appendHistory(entry)
        let stateStore = WallpaperStateStore(stateURL: folder.appendingPathComponent("state.json"))
        XCTAssertTrue(stateStore.save(state))
        try FileManager.default.removeItem(at: source)
        let restoredEntry = try XCTUnwrap(stateStore.load().history.last)
        let restored = await store.undoAssignment(for: restoredEntry)
        XCTAssertEqual(restored?.imagePath, rollback)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: rollback)), bytes)
    }

    // Caches is purgeable, so a previous wallpaper still in the remote cache (state saved before RC1)
    // gets an owned rollback copy like any external file.
    func testCachedRemoteOriginalGetsOwnedRollbackCopy() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let originals = folder.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let source = originals.appendingPathComponent("remote.png")
        try writeTestImage(to: source)
        let bytes = try Data(contentsOf: source)
        let store = WallpaperHistoryStore(root: folder.appendingPathComponent("Rollback"))
        let entry = await store.prepare(previous: assignment(path: source.path), replacement: assignment(path: "next.png"))
        XCTAssertNil(entry.undoUnavailableReason)
        let rollback = try XCTUnwrap(entry.rollbackPath)
        try FileManager.default.removeItem(at: originals)
        let restored = await store.undoAssignment(for: entry)
        XCTAssertEqual(restored?.imagePath, rollback)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: rollback)), bytes)
    }

    func testRetainedOriginalIsReusedBoundedAndCleanedUp() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cached = folder.appendingPathComponent("wallhaven-a.png")
        try writeTestImage(to: cached)
        let root = folder.appendingPathComponent("Rollback")
        let store = WallpaperHistoryStore(root: root)
        let owned = try await store.retain(cached)
        XCTAssertEqual(owned, root.appendingPathComponent("wallhaven-a.png"))
        let reused = try await store.retain(cached)
        XCTAssertEqual(reused, owned)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["wallhaven-a.png"])
        // Over the limit, retention fails closed: never the cached path, and no partial file is left.
        let fullRoot = folder.appendingPathComponent("Full")
        let full = WallpaperHistoryStore(root: fullRoot, maximumSizeBytes: 1)
        do { _ = try await full.retain(cached); XCTFail("Budget exhaustion must throw") }
        catch { XCTAssertTrue(error is RetentionError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fullRoot.path), [])
        await store.cleanup(protectedPaths: [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testRollbackDeduplicatesBytesAndNeverOverwritesChangedSource() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("external.png")
        try writeTestImage(to: source)
        let root = folder.appendingPathComponent("Rollback")
        let store = WallpaperHistoryStore(root: root)
        let old = assignment(path: source.path); let next = assignment(path: "next.png")
        let first = await store.prepare(previous: old, replacement: next)
        let again = await store.prepare(previous: old, replacement: next)
        XCTAssertEqual(first.rollbackPath, again.rollbackPath)
        let firstURL = URL(fileURLWithPath: try XCTUnwrap(first.rollbackPath))
        let bytes = try Data(contentsOf: firstURL)
        try writeTestImage(to: source, red: 0.9)
        let changed = await store.prepare(previous: old, replacement: next)
        XCTAssertNotEqual(changed.rollbackPath, first.rollbackPath)
        XCTAssertEqual(try Data(contentsOf: firstURL), bytes)
        let owned = await store.prepare(previous: assignment(path: firstURL.path), replacement: next)
        XCTAssertNil(owned.rollbackPath)
        XCTAssertNil(owned.undoUnavailableReason)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testRollbackCleanupFollowsBoundedHistoryAndOtherReferences() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Rollback")
        let store = WallpaperHistoryStore(root: root)
        var state = WallpaperState()
        var paths: [String] = []
        for index in 0..<26 {
            let source = folder.appendingPathComponent("external-\(index).png")
            try writeTestImage(to: source, width: index + 8)
            let entry = await store.prepare(previous: assignment(path: source.path), replacement: assignment(path: "next.png"))
            paths.append(try XCTUnwrap(entry.rollbackPath))
            state.appendHistory(entry)
        }
        XCTAssertEqual(Set(paths).count, 26, "Each generated wallpaper must have distinct bytes")
        state.setAssignment(assignment(path: paths[0]))
        var favorite = remoteReference(id: "favorite"); favorite.cachedLocalPath = paths[1]
        var collectionItem = remoteReference(id: "collection"); collectionItem.cachedLocalPath = paths[2]
        state.favorites = [favorite]; state.collections = [WallpaperCollection(name: "Saved", wallpapers: [collectionItem])]
        await store.cleanup(protectedPaths: state.protectedCachePaths)
        XCTAssertEqual(state.history.count, 20)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 23)
        for path in paths.prefix(3) { XCTAssertTrue(FileManager.default.fileExists(atPath: path)) }
        for path in paths[3..<6] { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
        for path in paths.suffix(20) { XCTAssertTrue(FileManager.default.fileExists(atPath: path)) }
        state.history.removeAll(); state.displayAssignments.removeAll(); state.favorites.removeAll(); state.collections.removeAll()
        await store.cleanup(protectedPaths: state.protectedCachePaths)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testMissingPreviousWallpaperRecordsUnavailableUndoBarrier() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WallpaperHistoryStore(root: folder.appendingPathComponent("Rollback"))
        let entry = await store.prepare(previous: assignment(path: folder.appendingPathComponent("missing.png").path), replacement: assignment(path: "next.png"))
        XCTAssertEqual(entry.undoUnavailableReason, .previousFileUnavailable)
        var state = WallpaperState(); state.appendHistory(entry)
        let decoded = try JSONDecoder().decode(WallpaperState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.history.last?.undoUnavailableReason, .previousFileUnavailable)
        let restored = await store.undoAssignment(for: entry)
        XCTAssertNil(restored)
    }

    func testCorruptAndMissingRollbackAreNotOfferedForUndo() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("external.png")
        try writeTestImage(to: source)
        let store = WallpaperHistoryStore(root: folder.appendingPathComponent("Rollback"))
        let entry = await store.prepare(previous: assignment(path: source.path), replacement: assignment(path: "next.png"))
        let rollback = URL(fileURLWithPath: try XCTUnwrap(entry.rollbackPath))
        try Data("corrupt".utf8).write(to: rollback)
        let corrupt = await store.undoAssignment(for: entry)
        XCTAssertNil(corrupt)
        let recovered = await store.prepare(previous: assignment(path: source.path), replacement: assignment(path: "next.png"))
        XCTAssertNotEqual(recovered.rollbackPath, entry.rollbackPath)
        XCTAssertEqual(try Data(contentsOf: rollback), Data("corrupt".utf8))
        try FileManager.default.removeItem(at: rollback)
        let missing = await store.undoAssignment(for: entry)
        XCTAssertNil(missing)
    }

    func testRollbackCapacityFailureDoesNotPreventRecordingTheChange() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("external.png")
        try writeTestImage(to: source)
        let root = folder.appendingPathComponent("Rollback")
        let store = WallpaperHistoryStore(root: root, maximumSizeBytes: 1)
        let replacement = assignment(path: "new.png")
        let entry = await store.prepare(previous: assignment(path: source.path), replacement: replacement)
        XCTAssertEqual(entry.undoUnavailableReason, .preservationFailed)
        XCTAssertNil(entry.rollbackPath)
        // The policy returns a degraded entry, not a thrown error blocking a requested Set.
        var state = WallpaperState(); state.appendHistory(entry); state.setAssignment(replacement)
        XCTAssertEqual(state.assignment(for: "1"), replacement)
        let restored = await store.undoAssignment(for: entry)
        XCTAssertNil(restored)
    }

    func testLegacyHistoryFieldsDecodeWithoutRollbackMetadata() throws {
        let json = Data("""
        {"version":1,"history":[{"previous":{"displayID":"1","displayName":"Display","imagePath":"/old.jpg","scaling":"fit"},
        "replacement":{"displayID":"1","displayName":"Display","imagePath":"/new.jpg","scaling":"fill"},"timestamp":0}]}
        """.utf8)
        let state = try JSONDecoder().decode(WallpaperState.self, from: json)
        let entry = try XCTUnwrap(state.history.last)
        XCTAssertEqual(entry.previous.imagePath, "/old.jpg")
        XCTAssertNil(entry.rollbackPath); XCTAssertNil(entry.undoUnavailableReason)
        XCTAssertEqual(try JSONDecoder().decode(WallpaperState.self, from: JSONEncoder().encode(state)), state)
    }

    func testStateSaveReportsFailureForSafeCleanupGating() throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let blockedParent = folder.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blockedParent)
        let store = WallpaperStateStore(stateURL: blockedParent.appendingPathComponent("state.json"))
        XCTAssertFalse(store.save(WallpaperState()))
    }

    func testExternalSymlinkIsCopiedAsBytesNotAsALink() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("external.png")
        try writeTestImage(to: original)
        let originals = folder.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let link = originals.appendingPathComponent("external-link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let store = WallpaperHistoryStore(root: folder.appendingPathComponent("Rollback"))
        let entry = await store.prepare(previous: assignment(path: link.path), replacement: assignment(path: "next.png"))
        let rollback = URL(fileURLWithPath: try XCTUnwrap(entry.rollbackPath))
        XCTAssertFalse(try rollback.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        try FileManager.default.removeItem(at: original)
        let restored = await store.undoAssignment(for: entry)
        XCTAssertNotNil(restored)
    }

    func testDecodedHistoryAlsoEnforcesTwentyEntryBound() throws {
        var state = WallpaperState()
        state.history = (0..<25).map { index in
            HistoryEntry(previous: assignment(path: "\(index).png"), replacement: assignment(path: "next.png"), timestamp: Date())
        }
        let decoded = try JSONDecoder().decode(WallpaperState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.history.count, 20)
        XCTAssertEqual(decoded.history.first?.previous.imagePath, "5.png")
    }

    private func historyTestFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WallpierHistoryTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func assignment(path: String) -> DisplayAssignment {
        DisplayAssignment(
            displayID: "1",
            displayName: "Display",
            imagePath: path,
            scaling: .fill
        )
    }

    private func remoteReference(id: String) -> WallpaperReference {
        WallpaperReference(
            providerIdentifier: "wallhaven",
            wallpaperID: id,
            sourcePageURL: URL(string: "https://wallhaven.cc/w/\(id)")!,
            originalURL: URL(string: "https://w.wallhaven.cc/full/ab/wallhaven-\(id).jpg")!,
            previewURL: URL(string: "https://th.wallhaven.cc/lg/ab/\(id).jpg")!,
            thumbnailURL: URL(string: "https://th.wallhaven.cc/small/ab/\(id).jpg")!,
            width: 3840,
            height: 2160,
            uploader: nil,
            tags: [],
            cachedLocalPath: nil
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}

private final class StubNetworkClient: NetworkClient {
    let dataValue: Data
    let statusCode: Int
    let headers: [String: String]

    init(data: Data, statusCode: Int = 200, headers: [String: String] = [:]) {
        dataValue = data
        self.statusCode = statusCode
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/2",
            headerFields: headers
        )!
        return (dataValue, response)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        throw RemoteProviderError.originalUnavailable
    }
}

private final class SequencedNetworkClient: NetworkClient {
    private(set) var requestCount = 0
    private var responses: [(Data, HTTPURLResponse)]

    init(responses: [(Data, HTTPURLResponse)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = min(requestCount, responses.count - 1)
        requestCount += 1
        return responses[index]
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        throw RemoteProviderError.originalUnavailable
    }
}

// These tests instantiate the production controller without a window or restoreState().
// AppDelegate's XCTest guard runs before live startup; every external dependency is isolated.
@MainActor
private final class SetAuditScreen: NSScreen {
    let number: Int
    init(_ number: Int) { self.number = number; super.init() }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var localizedName: String { "Display \(number)" }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: number)]
    }
}

private final class SetAuditWallpaperService: WallpaperService {
    struct Call: Equatable {
        let image: URL
        let display: String
        let scaling: ScalingMode
    }
    var calls: [Call] = []
    var current: URL?
    var failure: Error?
    var afterApply: (() -> Void)?
    override func currentWallpaper(on screen: NSScreen) -> (imageURL: URL, scaling: ScalingMode)? {
        current.map { ($0, .center) }
    }
    override func setWallpaper(imageURL: URL, on screen: NSScreen, scaling: ScalingMode) throws -> WallpaperSetResult {
        calls.append(Call(image: imageURL, display: String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).intValue), scaling: scaling))
        if let failure { throw failure }
        current = imageURL
        afterApply?()
        return WallpaperSetResult(elapsedTime: 0.012)
    }
}

private final class SetAuditThumbnails: RemoteThumbnailProvider {
    var callbacks: [(NSImage?) -> Void] = []
    override func requestThumbnail(for url: URL, maximumPixelSize: Int = 420, completion: @escaping (NSImage?) -> Void) {
        callbacks.append(completion)
    }
}

// Continuations control order. The deadline only fails a stuck test; it never creates a race.
@MainActor
private final class SetAuditGate<Value> {
    let started = XCTestExpectation(description: "dependency reached")
    private var pending: CheckedContinuation<Value, Error>?
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started.fulfill()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.release(.failure(URLError(.timedOut)))
            }
        }
    }
    func release(_ result: Result<Value, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

@MainActor
private final class SetAuditNetwork: NetworkClient {
    var downloadGate = SetAuditGate<URL>()
    var dataGates: [SetAuditGate<Data>] = []
    var pendingDataGates: [SetAuditGate<Data>] = []
    var downloads: [URL] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !dataGates.isEmpty else { throw RemoteProviderError.originalUnavailable }
        let gate = dataGates.removeFirst()
        pendingDataGates.append(gate)
        return (try await gate.value(), response(request))
    }
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        downloads.append(request.url!)
        return (try await downloadGate.value(), response(request))
    }
    private func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

@MainActor
private final class SetAuditHarness {
    let controller: MainWindowController
    let network = SetAuditNetwork()
    let desktop = SetAuditWallpaperService()
    let thumbnails = SetAuditThumbnails()
    let store: WallpaperStateStore
    let root: URL
    let incoming: URL
    let prior: URL
    let x = SetAuditScreen(101)
    let y = SetAuditScreen(202)

    init(root: URL, references: [WallpaperReference], historyLimit: Int64 = WallpaperHistoryStore.maximumSizeBytes) {
        self.root = root
        incoming = root.appendingPathComponent("incoming.png")
        prior = root.appendingPathComponent("prior.png")
        store = WallpaperStateStore(stateURL: root.appendingPathComponent("state.json"))
        var state = WallpaperState()
        state.currentSource = .favorites
        state.favorites = references
        state.selectedRemoteIdentity = references.first?.identityKey
        state.selectedDisplayID = "101"
        state.collections = [WallpaperCollection(name: "Rotation", wallpapers: references)]
        state.selectedCollectionID = state.collections[0].id
        state.activeRotationCollectionID = state.collections[0].id
        state.rotationInterval = .oneHour
        store.save(state)
        let originals = root.appendingPathComponent("Originals")
        // Capture a separate box so all dependencies exist before constructing the controller.
        let displayList = DisplayList()
        displayList.screens = [x, y]
        controller = MainWindowController(window: nil, wallpaperService: desktop, stateStore: store,
            provider: WallhavenProvider(client: network), openverseProvider: OpenverseProvider(client: network), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: root.appendingPathComponent("Rollback"), maximumSizeBytes: historyLimit),
            remoteThumbnailProvider: thumbnails, availableScreens: { displayList.screens })
        self.displayList = displayList
        desktop.current = prior
        controller.scalingPopUp.addItems(withTitles: ScalingMode.allCases.map(\.displayName))
        controller.scalingPopUp.selectItem(at: 0)
        controller.refreshDisplays()
        controller.showFavorites(nil)
    }
    private let displayList: DisplayList
    private final class DisplayList { var screens: [NSScreen] = [] }
    func removeX() { displayList.screens = [y]; controller.refreshDisplays() }
    func cached(_ reference: WallpaperReference) -> URL { root.appendingPathComponent("Originals").appendingPathComponent(RemoteWallpaperCache.filename(for: reference)) }
    /// Where a set remote original lives once Wallpier owns it outside purgeable Caches.
    func owned(_ reference: WallpaperReference) -> URL { root.appendingPathComponent("Rollback").appendingPathComponent(RemoteWallpaperCache.filename(for: reference)) }
}

extension WallpierTests {
    // MARK: Gallery, desktop preview, apply bar and sidebar (redesign)
    //
    // These replace the inspector-era layout tests (actions pinned below a scrolling inspector,
    // inspector collapse). The inspector no longer exists; the same guarantees now apply to the
    // apply bar, which must keep Display, Scaling and Set visible in both gallery and preview.

    @MainActor
    func testThumbnailCellFillsWithAnyAspectAndRingsSelection() {
        let item = WallpaperCollectionViewItem()
        let cellSize = GalleryLayout.itemSize(availableWidth: 240, targetWidth: 240, spacing: 8)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: cellSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView!.addSubview(item.view)
        item.view.frame = NSRect(origin: .zero, size: cellSize)
        item.configure(identifier: "a", title: "A title", toolTip: "a", subtitle: "A maker · 1830")
        XCTAssertFalse(item.hasThumbnail)
        XCTAssertEqual(item.titleText, "A title")
        XCTAssertEqual(item.subtitleText, "A maker · 1830")
        let sources = [NSSize(width: 1080, height: 1920), NSSize(width: 3440, height: 1440)]
        let frames = sources.map { size -> (well: NSRect, picture: NSRect) in
            item.setThumbnail(NSImage(size: size))
            item.view.layoutSubtreeIfNeeded()
            XCTAssertTrue(item.hasThumbnail)
            return (item.wellFrame, item.thumbnailFrame)
        }
        // The well is identical whatever the artwork; the artwork keeps its own proportions inside it, uncropped,
        // centered on the well's bottom edge (a shared baseline).
        XCTAssertEqual(frames[0].well, frames[1].well)
        XCTAssertEqual(frames[0].well.insetBy(dx: -WallpaperCollectionViewItem.ringInset, dy: -WallpaperCollectionViewItem.ringInset).width, cellSize.width)
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(frame.well.insetBy(dx: -0.5, dy: -0.5).contains(frame.picture), "picture \(index) stays inside the well")
            XCTAssertEqual(frame.picture.maxY, frame.well.maxY, accuracy: 0.5, "shared baseline")
            XCTAssertEqual(frame.picture.width / frame.picture.height, sources[index].width / sources[index].height, accuracy: 0.02, "uncropped")
        }
        XCTAssertLessThanOrEqual(item.wellFrame.maxY + GalleryLayout.captionHeight, cellSize.height + 0.5)
        item.isSelected = true
        XCTAssertTrue(item.showsSelectionRing)
        item.isSelected = false
        XCTAssertFalse(item.showsSelectionRing)
        item.configure(identifier: "b", title: "b", toolTip: "b")
        XCTAssertFalse(item.hasThumbnail, "Reused cells must not show the previous wallpaper")
    }

    func testGalleryItemsDivideTheAvailableWidthExactly() {
        for target in GalleryLayout.thumbnailWidths {
            for width in stride(from: CGFloat(300), through: 2_400, by: 37) {
                let size = GalleryLayout.itemSize(availableWidth: width, targetWidth: target, spacing: 4)
                let columns = ((width + 4) / (size.width + 4)).rounded(.down)
                XCTAssertGreaterThanOrEqual(columns, 1)
                let used = columns * size.width + (columns - 1) * 4
                XCTAssertLessThanOrEqual(used, width)
                XCTAssertGreaterThan(used, width - columns, "No ragged gap at width \(width)")
                XCTAssertEqual(size.height, GalleryLayout.cellHeight(forWidth: size.width))
            }
        }
    }

    func testDesktopPreviewGeometryFollowsDisplayShapeAndScalingMode() {
        let display = CGSize(width: 2880, height: 1800)
        let stage = DesktopPreviewView.stageRect(in: CGRect(x: 0, y: 0, width: 1000, height: 400), display: display)
        XCTAssertEqual(stage.size, CGSize(width: 640, height: 400))
        XCTAssertEqual(stage.midX, 500)
        let wide = CGSize(width: 3840, height: 2160)
        let fill = DesktopPreviewView.imageRect(in: stage, image: wide, display: display, scaling: .fill)
        XCTAssertTrue(fill.insetBy(dx: -0.5, dy: -0.5).contains(stage), "Fill covers the whole display")
        XCTAssertEqual(fill.height, stage.height, accuracy: 0.5)
        let fit = DesktopPreviewView.imageRect(in: stage, image: wide, display: display, scaling: .fit)
        XCTAssertTrue(stage.insetBy(dx: -0.5, dy: -0.5).contains(fit), "Fit shows the whole image")
        XCTAssertEqual(fit.width, stage.width, accuracy: 0.5)
        let center = DesktopPreviewView.imageRect(in: stage, image: CGSize(width: 1440, height: 900), display: display, scaling: .center)
        XCTAssertEqual(center.width, stage.width / 2, accuracy: 0.5, "Center keeps the image's pixel size relative to the display")
        XCTAssertEqual(center.midX, stage.midX, accuracy: 0.5)
        // Wallhaven previews are 3:2 crops; drawing centre-crops them to the original's shape.
        let crop = DesktopPreviewView.cropRect(of: CGSize(width: 600, height: 400), toAspectOf: CGSize(width: 16, height: 9))
        XCTAssertEqual(crop.width, 600)
        XCTAssertEqual(crop.height, 337.5, accuracy: 0.01)
    }

    @MainActor
    func testApplyBarKeepsSetDisplayAndScalingVisibleEverywhere() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua) { _ in }
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let actions: [NSView] = [controller.displayPopUp, controller.scalingPopUp, controller.setWallpaperButton]
        for size in [NSSize(width: 1120, height: 720), window.minSize] {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            for source in [LibrarySource.discover, .collections] {
                if source == .discover { controller.showDiscover(nil) } else { controller.showCollections(nil) }
                for preview in [false, true] {
                    if preview != controller.isViewerVisible { controller.toggleViewer(nil) }
                    content.layoutSubtreeIfNeeded()
                    XCTAssertEqual(window.frame.size, size)
                    XCTAssertEqual(controller.isViewerVisible, preview)
                    XCTAssertTrue(controller.setWallpaperButton.isEnabled)
                    for action in actions {
                        let frame = action.convert(action.bounds, to: content)
                        XCTAssertFalse(action.isHiddenOrHasHiddenAncestor)
                        XCTAssertTrue(content.bounds.contains(frame), "\(action) clipped at \(size)")
                        XCTAssertGreaterThanOrEqual(action.frame.width, min(action.fittingSize.width, 120) - 1, "\(action) squeezed at \(size)")
                    }
                    let text = controller.selectionLabel.convert(controller.selectionLabel.bounds, to: content)
                    XCTAssertFalse(text.intersects(controller.displayPopUp.convert(controller.displayPopUp.bounds, to: content)))
                    XCTAssertFalse(controller.selectionLabel.stringValue.isEmpty)
                    if !preview {
                        // Cells always divide the visible width exactly, also after a resize.
                        let layout = controller.galleryLayoutForTesting
                        let scroll = controller.galleryScrollForTesting
                        let available = scroll.contentView.bounds.width - layout.sectionInset.left - layout.sectionInset.right
                        let expected = GalleryLayout.itemSize(availableWidth: available, targetWidth: layout.targetWidth,
                                                              spacing: layout.minimumInteritemSpacing)
                        XCTAssertEqual(layout.fittedItemSize, expected, "at \(size)")
                        XCTAssertEqual(controller.collectionView.item(at: IndexPath(item: 0, section: 0))?.view.frame.size, expected, "at \(size)")
                    }
                }
                controller.toggleViewer(nil)
            }
        }
        XCTAssertEqual(controller.setWallpaperButton.keyEquivalent, "\r")
        XCTAssertNil(controller.searchTask)
        XCTAssertNil(controller.detailTask)
    }

    @MainActor
    func testDesktopPreviewOpensBrowsesAndReturnsWithoutLosingSelection() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua) { _ in }
        defer { window.close() }
        controller.showFavorites(nil)
        let favorites = controller.state.favorites
        XCTAssertEqual(controller.state.selectedRemoteIdentity, favorites[1].identityKey)
        func key(_ characters: String, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        let menuItem = NSMenuItem(title: "", action: #selector(MainWindowController.toggleViewer(_:)), keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(menuItem))
        XCTAssertEqual(menuItem.title, "Preview on Desktop")

        controller.collectionView.keyDown(with: key(" ", code: 49))
        XCTAssertTrue(controller.isViewerVisible)
        XCTAssertFalse(controller.viewerView.isHidden)
        XCTAssertTrue(controller.galleryScrollForTesting.isHidden)
        XCTAssertEqual(controller.viewModeControl.selectedSegment, 1)
        XCTAssertTrue(controller.validateMenuItem(menuItem))
        XCTAssertEqual(menuItem.title, "Back to Gallery")
        XCTAssertEqual(controller.previewTitleLabel.stringValue, favorites[1].wallpaperID)
        XCTAssertNotNil(controller.stageView.image)
        XCTAssertEqual(controller.stageView.imagePixelSize, CGSize(width: favorites[1].width, height: favorites[1].height))
        XCTAssertEqual(controller.stageView.displayPixelSize, CGSize(width: 2880, height: 1800))

        controller.viewerView.keyDown(with: key(String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), code: 124))
        XCTAssertEqual(controller.state.selectedRemoteIdentity, favorites[2].identityKey)
        XCTAssertEqual(controller.previewTitleLabel.stringValue, favorites[2].wallpaperID)
        controller.scalingPopUp.selectItem(at: 1)
        controller.scalingSelectionChanged()
        XCTAssertEqual(controller.stageView.scaling, .fit)

        controller.viewerView.keyDown(with: key("\u{1b}", code: 53))
        XCTAssertFalse(controller.isViewerVisible)
        XCTAssertTrue(controller.viewerView.isHidden)
        XCTAssertFalse(controller.galleryScrollForTesting.isHidden)
        XCTAssertEqual(controller.collectionView.selectionIndexPaths, [IndexPath(item: 2, section: 0)])

        controller.toggleViewer(nil)
        XCTAssertTrue(controller.isViewerVisible)
        controller.showDiscover(nil)
        XCTAssertFalse(controller.isViewerVisible, "Changing source returns to the gallery")
        XCTAssertTrue(controller.viewerView.isHidden)
    }

    /// Deterministic dispatch: each key goes to the window's sendEvent (first responder → responder chain →
    /// default button), not a direct keyDown call, so responder and default-button interception are exercised.
    /// window.sendEvent skips the menu bar; Return through the activated app and production menu bar is
    /// covered separately by testActivatedReturnSpaceArrowsAndEscapeKeepTheirMeanings.
    @MainActor
    func testReturnSetsFromGalleryAndPreviewButSearchesFromSearchField() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let network = HangingNetwork()
        let (controller, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                         network: network, windowClass: KeyTestWindow.self) { _ in }
        defer { window.close() }
        controller.showFavorites(nil)
        window.orderFront(nil)
        func press(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            // The key window's sendEvent dispatches a plain key to the first responder, up the responder
            // chain, and finally to the default button. KeyTestWindow reports itself key, so this doesn't
            // depend on the test app being active.
            window.sendEvent(event)
            // A button's key equivalent highlights the button first and sends its action afterwards.
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        func settle(_ task: Task<Void, Never>?) {
            let done = expectation(description: "set finished")
            task?.cancel()
            Task { await task?.value; done.fulfill() }
            wait(for: [done], timeout: 5)
        }

        // The dispatch path reaches the grid: Space opens the preview.
        XCTAssertTrue(window.makeFirstResponder(controller.collectionView))
        press(" ", code: 49)
        XCTAssertTrue(controller.isViewerVisible, "key dispatch did not reach the grid (key window: \(window.isKeyWindow))")
        controller.toggleViewer(nil)

        for (preview, responder) in [(false, controller.collectionView as NSView), (true, controller.viewerView)] {
            if preview != controller.isViewerVisible { controller.toggleViewer(nil) }
            XCTAssertTrue(window.makeFirstResponder(responder))
            XCTAssertNil(controller.downloadTask)
            press("\r", code: 36)
            XCTAssertNotNil(controller.downloadTask, "Return with \(responder) focused must invoke Set Wallpaper")
            settle(controller.downloadTask)
            press("\u{3}", code: 76)   // keypad Enter
            XCTAssertNotNil(controller.downloadTask, "Enter with \(responder) focused must invoke Set Wallpaper")
            settle(controller.downloadTask)
            press("\r", code: 36, modifiers: .option)
            XCTAssertNil(controller.downloadTask, "Only an unmodified Return sets the wallpaper")
        }
        controller.toggleViewer(nil)

        // While a Set is running the guarded action refuses a second one.
        controller.setWallpaper(nil)
        let running = controller.downloadTask
        let before = network.downloads
        let deadline = Date().addingTimeInterval(5)
        while network.downloads == before && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let downloads = network.downloads
        XCTAssertEqual(downloads, before + 1, "The running Set reached its download")
        XCTAssertFalse(controller.setWallpaperButton.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(controller.collectionView))
        press("\r", code: 36)
        XCTAssertEqual(network.downloads, downloads, "Return must not start a second Set while one is running")
        settle(running)

        // Return in the search field searches; it never sets a wallpaper.
        XCTAssertTrue(window.makeFirstResponder(controller.searchField))
        controller.searchField.currentEditor()?.string = "forest"
        controller.searchTask?.cancel()
        press("\r", code: 36)
        XCTAssertNil(controller.downloadTask, "Return in the search field must not set a wallpaper")
        XCTAssertEqual(controller.state.wallhavenSearch.query, "forest")
        XCTAssertNotNil(controller.searchTask, "Return in the search field runs the search")
        XCTAssertEqual(controller.state.currentSource, .discover)
    }

    /// An uncached remote preview is drawn from a Wallhaven thumbnail and labelled as such;
    /// a downloaded original or a local file is drawn from its own pixels and is not.
    @MainActor
    func testOnlyCroppedRemotePreviewsAreMarkedApproximateAndNothingIsDownloaded() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Local")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func writePNG(_ index: Int, to url: URL) throws {
            let image = CaptureFixtures.image(index: index)
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        }
        try writePNG(0, to: folder.appendingPathComponent("a.png"))
        // A downloaded original lives in the cache, where Set also finds and validates it.
        let original = root.appendingPathComponent("Originals").appendingPathComponent(RemoteWallpaperCache.filename(for: CaptureFixtures.references()[3]))
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePNG(1, to: original)
        let network = DownloadCountingNetwork()
        let (controller, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                         network: network) { state in
            state.favorites[1].cachedLocalPath = original.path
            state.selectedRemoteIdentity = state.favorites[0].identityKey
            state.folderPath = folder.path
        }
        defer { window.close() }
        func waitFor(_ condition: @autoclosure () -> Bool, _ message: String) {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            XCTAssertTrue(condition(), message)
        }
        let notice = controller.approximatePreviewNotice
        controller.showFavorites(nil)
        controller.toggleViewer(nil)

        // Uncached remote: a Wallhaven thumbnail, clearly marked.
        XCTAssertNil(controller.state.favorites[0].cachedLocalPath)
        XCTAssertNotNil(controller.stageView.image)
        XCTAssertFalse(notice.isHiddenOrHasHiddenAncestor, "An uncached Wallhaven preview must be marked approximate")
        XCTAssertEqual(controller.viewerView.convert(notice.frame, from: notice.superview).intersection(controller.viewerView.bounds),
                       controller.viewerView.convert(notice.frame, from: notice.superview), "The notice must be fully visible")

        // Cached original: exact, unmarked.
        controller.nextWallpaper(nil)
        XCTAssertEqual(controller.state.selectedRemoteIdentity, controller.state.favorites[1].identityKey)
        XCTAssertTrue(notice.isHidden, "No notice before the original's preview has loaded")
        waitFor(controller.stageView.image != nil, "The downloaded original's preview loads")
        XCTAssertTrue(notice.isHidden, "A preview drawn from the downloaded original needs no source notice")

        // Back to the uncached one, then a local file.
        controller.previousWallpaper(nil)
        XCTAssertFalse(notice.isHidden)
        controller.showLocal(nil)
        waitFor(controller.state.selectedImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } == "a.png",
                "The local folder loads (\(controller.state.selectedImagePath ?? "nothing selected"))")
        controller.toggleViewer(nil)
        waitFor(controller.stageView.image != nil, "The local file's preview loads")
        XCTAssertTrue(notice.isHidden, "A local file's preview needs no source notice")

        // Previewing never downloads an original.
        XCTAssertEqual(network.downloads, 0)
    }

    @MainActor
    func testSidebarNavigatesSourcesCollectsDropsAndMarksRotation() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (controller, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua) { _ in }
        defer { window.close() }
        let sidebar = controller.sidebarForTesting
        func row(_ title: String) -> SidebarNode? { sidebar.rows.first { $0.title == title } }
        XCTAssertEqual(sidebar.rows.map(\.title), [
            "Library", "Favorites", "Folder", "Collections", "Evening Light", "Quiet Mornings",
            "Museums & Archives", "Cleveland Museum of Art", "The Met", "Wellcome Collection",
            "Photography & Space", "Openverse", "iNaturalist", "NASA Images",
            "Wallpapers & Digital", "Wallhaven", "KDE Plasma", "Pepper&Carrot"
        ])
        XCTAssertEqual(row("Favorites")?.count, 6)
        XCTAssertEqual(row("Evening Light")?.count, 5)
        XCTAssertEqual(sidebar.selectedItem, .favorites)
        let museums = try XCTUnwrap(row("Museums & Archives"))
        XCTAssertTrue(sidebar.outlineView.isItemExpanded(museums))
        sidebar.outlineView.collapseItem(museums)
        XCTAssertEqual(sidebar.outlineView.row(forItem: row("Cleveland Museum of Art")), -1)

        let quiet = controller.state.collections[1]
        sidebar.outlineView.selectRowIndexes([sidebar.outlineView.row(forItem: row("Quiet Mornings"))], byExtendingSelection: false)
        XCTAssertEqual(controller.state.currentSource, .collections)
        XCTAssertEqual(controller.state.selectedCollectionID, quiet.id)
        XCTAssertEqual(window.title, "Quiet Mornings")
        XCTAssertEqual(window.subtitle, "2 wallpapers")
        let reloadedMuseums = try XCTUnwrap(row("Museums & Archives"))
        XCTAssertFalse(sidebar.outlineView.isItemExpanded(reloadedMuseums))
        sidebar.outlineView.expandItem(reloadedMuseums)
        XCTAssertGreaterThanOrEqual(sidebar.outlineView.row(forItem: row("Cleveland Museum of Art")), 0)

        // Dropping a Discover result on a collection adds it once.
        let dropped = controller.remoteResults[11]
        XCTAssertEqual(sidebar.onDrop?(.collection(quiet.id), [dropped.identityKey, dropped.identityKey]), true)
        XCTAssertEqual(controller.state.collections[1].wallpapers.map(\.identityKey), quiet.wallpapers.map(\.identityKey) + [dropped.identityKey])
        XCTAssertEqual(row("Quiet Mornings")?.count, 3)
        XCTAssertEqual(window.subtitle, "3 wallpapers")
        XCTAssertEqual(sidebar.onDrop?(.discover, [dropped.identityKey]), false, "Only Favorites and collections accept drops")

        // Delete removes from the collection being viewed and keeps the selection's position.
        controller.collectionView.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        controller.collectionView(controller.collectionView, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        controller.removeSelected(nil)
        XCTAssertEqual(controller.state.collections[1].wallpapers.map(\.identityKey), [quiet.wallpapers[0].identityKey, dropped.identityKey])
        XCTAssertEqual(controller.state.selectedRemoteIdentity, dropped.identityKey)

        // Rotation: interval and source from the menus; the sidebar badges exactly that source.
        let interval = NSMenuItem(title: "", action: #selector(MainWindowController.setRotationInterval(_:)), keyEquivalent: "")
        interval.tag = RotationInterval.allCases.firstIndex(of: .oneHour)!
        controller.setRotationInterval(interval)
        let source = NSMenuItem(title: "", action: #selector(MainWindowController.useForRotation(_:)), keyEquivalent: "")
        source.representedObject = quiet.id
        controller.useForRotation(source)
        XCTAssertEqual(controller.state.rotationInterval, .oneHour)
        XCTAssertEqual(controller.state.activeRotationCollectionID, quiet.id)
        XCTAssertEqual(sidebar.rows.filter(\.isRotating).map(\.title), ["Quiet Mornings"])
        XCTAssertTrue(controller.validateMenuItem(interval))
        XCTAssertEqual(interval.state, .on)
        // The fixture never chooses a scaling mode, so it has the default: Fit (formerly Fill).
        XCTAssertTrue(controller.rotationSummaryLabel.stringValue.contains("“Quiet Mornings” on Studio Display using Fit to Screen"))
        interval.tag = 0
        controller.setRotationInterval(interval)
        XCTAssertEqual(controller.state.rotationInterval, .off)
        XCTAssertTrue(sidebar.rows.filter(\.isRotating).isEmpty)
    }

    @MainActor
    private func setAuditHarness(historyLimit: Int64 = WallpaperHistoryStore.maximumSizeBytes) throws -> SetAuditHarness {
        let root = try historyTestFolder()
        let harness = SetAuditHarness(root: root, references: [remoteReference(id: "aaaaaa"), remoteReference(id: "bbbbbb")],
                                      historyLimit: historyLimit)
        try writeTestImage(to: harness.incoming)
        try writeTestImage(to: harness.prior, width: 3)
        addTeardownBlock {
            let tasks = await MainActor.run {
                let tasks = [harness.controller.downloadTask, harness.controller.rotationTask,
                             harness.controller.searchTask, harness.controller.detailTask,
                             harness.controller.undoValidationTask].compactMap { $0 }
                tasks.forEach { $0.cancel() }
                harness.network.downloadGate.release(.failure(CancellationError()))
                harness.network.pendingDataGates.forEach { $0.release(.failure(CancellationError())) }
                return tasks
            }
            for task in tasks { await task.value }
            try FileManager.default.removeItem(at: root)
        }
        return harness
    }

    @MainActor
    private func finishAuditTask(_ task: Task<Void, Never>?) async throws {
        let task = try XCTUnwrap(task)
        let done = expectation(description: "production task finished")
        Task { await task.value; done.fulfill() }
        await fulfillment(of: [done], timeout: 6)
    }

    @MainActor
    func testInFlightSetCapturesImageDisplayAndScaling() async throws {
        let h = try setAuditHarness()
        let a = h.controller.state.favorites[0]
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        h.controller.nextWallpaper(nil)
        h.controller.displayPopUp.selectItem(at: 1)
        h.controller.displaySelectionChanged()
        h.controller.scalingPopUp.selectItem(at: 1)
        h.controller.scalingSelectionChanged()
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(h.desktop.calls, [.init(image: h.owned(a), display: "101", scaling: .fill)])
        XCTAssertEqual(h.controller.state.selectedRemoteIdentity, h.controller.state.favorites[1].identityKey)
        let entry = try XCTUnwrap(h.store.load().history.last)
        XCTAssertEqual(entry.replacement.imagePath, h.owned(a).path)
        XCTAssertEqual(entry.replacement.displayID, "101")
        XCTAssertEqual(entry.replacement.scaling, .fill)
        XCTAssertEqual(entry.previous.imagePath, h.prior.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(entry.rollbackPath))), try Data(contentsOf: h.prior))
        XCTAssertTrue(h.controller.statusLabel.stringValue.contains("on Display 101 in 12.0 ms."))
        XCTAssertTrue(h.controller.statusLabel.stringValue.contains(h.cached(a).lastPathComponent))
    }

    @MainActor
    func testInFlightSetRejectsUnavailableCapturedDisplay() async throws {
        let h = try setAuditHarness()
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        h.removeX()
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertTrue(h.desktop.calls.isEmpty, "An unavailable captured display must never reach the wallpaper boundary")
        XCTAssertTrue(h.store.load().history.isEmpty)
        XCTAssertTrue(h.controller.statusLabel.stringValue.contains("not currently available"))
    }
}

extension WallpierTests {
    @MainActor
    func testInFlightSetRejectsCompetingMutationsThenAcceptsNextSet() async throws {
        let h = try setAuditHarness()
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        try await finishAuditTask(h.controller.undoValidationTask)
        XCTAssertTrue(h.controller.undoButton.isEnabled)
        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        h.controller.nextWallpaper(nil)
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        h.controller.previousWallpaper(nil)
        h.controller.setWallpaper(nil)
        let rejectedStatus = "Wait for the current download to finish."
        XCTAssertEqual(h.controller.statusLabel.stringValue, rejectedStatus)
        h.controller.undoWallpaperChange(nil)
        h.controller.rotateWallpaper()
        XCTAssertEqual(h.controller.statusLabel.stringValue, rejectedStatus)
        XCTAssertFalse(h.controller.setWallpaperButton.isEnabled)
        XCTAssertFalse(h.controller.undoButton.isEnabled)
        XCTAssertNil(h.controller.rotationTask)
        XCTAssertEqual(h.network.downloads.count, 2)
        XCTAssertEqual(h.desktop.calls.count, 1)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(h.desktop.calls.map(\.image), h.controller.state.favorites.map(h.owned))
        XCTAssertEqual(h.store.load().history.count, 2)
        XCTAssertEqual(h.store.load().history.last?.previous.imagePath, h.desktop.calls[0].image.path)
        // The previously rejected A request is accepted now, using its cached original.
        h.controller.setWallpaper(nil)
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.owned(h.controller.state.favorites[0]), h.owned(h.controller.state.favorites[1]), h.owned(h.controller.state.favorites[0])])
        XCTAssertEqual(h.network.downloads.count, 2)
        XCTAssertEqual(h.store.load().history.count, 3)
    }

    @MainActor
    func testInFlightPreparationFailureAndCancellationAllowRecovery() async throws {
        for cancel in [false, true] {
            let h = try setAuditHarness()
            h.controller.setWallpaper(nil)
            await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
            if cancel {
                h.controller.downloadTask?.cancel()
                // Dependency deliberately completes despite cancellation.
                h.network.downloadGate.release(.success(h.incoming))
            } else {
                h.network.downloadGate.release(.failure(URLError(.notConnectedToInternet)))
            }
            try await finishAuditTask(h.controller.downloadTask)
            XCTAssertTrue(h.desktop.calls.isEmpty)
            XCTAssertTrue(h.store.load().history.isEmpty)
            XCTAssertNil(h.store.load().assignment(for: "101"))
            XCTAssertFalse(h.controller.statusLabel.stringValue.hasPrefix("Set "))
            XCTAssertTrue(h.controller.setWallpaperButton.isEnabled)
            h.network.downloadGate = SetAuditGate<URL>()
            try writeTestImage(to: h.incoming)
            h.controller.setWallpaper(nil)
            await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
            h.network.downloadGate.release(.success(h.incoming))
            try await finishAuditTask(h.controller.downloadTask)
            XCTAssertEqual(h.desktop.calls.count, 1)
            XCTAssertEqual(h.store.load().history.count, 1)
        }
    }

    @MainActor
    func testInFlightSetCapturesPriorAtApplicationAndUndoRestoresIt() async throws {
        let h = try setAuditHarness()
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        let changedPrior = h.root.appendingPathComponent("external-change.png")
        try writeTestImage(to: changedPrior, width: 6)
        h.desktop.current = changedPrior
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        let entry = try XCTUnwrap(h.store.load().history.last)
        XCTAssertEqual(entry.previous.imagePath, changedPrior.path)
        try FileManager.default.removeItem(at: changedPrior)
        try await finishAuditTask(h.controller.undoValidationTask)
        XCTAssertTrue(h.controller.undoButton.isEnabled)
        h.controller.undoWallpaperChange(nil)
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(h.desktop.calls.last?.image.path, entry.rollbackPath)
        XCTAssertEqual(h.desktop.calls.last?.display, "101")
        XCTAssertEqual(h.desktop.calls.last?.scaling, .center)
        XCTAssertTrue(h.store.load().history.isEmpty)
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, entry.rollbackPath)
        XCTAssertTrue(h.controller.statusLabel.stringValue.hasPrefix("Restored "))
    }

    @MainActor
    func testInFlightSetReportsUndoUnavailable() async throws {
        let h = try setAuditHarness()
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        try FileManager.default.removeItem(at: h.prior)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(h.desktop.calls.count, 1)
        XCTAssertEqual(h.store.load().history.last?.undoUnavailableReason, .previousFileUnavailable)
        XCTAssertEqual(h.store.load().history.last?.replacement.imagePath, h.desktop.calls[0].image.path)
        XCTAssertTrue(h.controller.statusLabel.stringValue.hasSuffix("Undo unavailable for this change."))
        XCTAssertFalse(h.controller.undoButton.isEnabled)
    }

    @MainActor
    func testInFlightWallpaperFailureDoesNotCommitAndCleansPreparedRollback() async throws {
        let h = try setAuditHarness()
        h.desktop.failure = CocoaError(.fileReadUnknown)
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(h.desktop.calls.count, 1)
        XCTAssertEqual(h.desktop.current, h.prior)
        XCTAssertTrue(h.store.load().history.isEmpty)
        XCTAssertNil(h.store.load().assignment(for: "101"))
        XCTAssertTrue(h.controller.statusLabel.stringValue.hasPrefix("Could Not Set Wallpaper:"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.root.appendingPathComponent("Rollback").path), [])
    }

    @MainActor
    func testInFlightCancellationAfterMutationStillCommitsSuccess() async throws {
        let h = try setAuditHarness()
        h.desktop.afterApply = { [weak controller = h.controller] in controller?.downloadTask?.cancel() }
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(h.desktop.calls.count, 1)
        XCTAssertEqual(h.store.load().history.count, 1)
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, h.desktop.current?.path)
        XCTAssertTrue(h.controller.statusLabel.stringValue.hasPrefix("Set "))
    }

    @MainActor
    func testInFlightNavigationDiscardsObsoleteSearchDetailAndPreview() async throws {
        let h = try setAuditHarness()
        let detail = SetAuditGate<Data>()
        h.network.dataGates = [detail]
        // Details and the stage image load only for the visible desktop preview.
        h.controller.toggleViewer(nil)
        await fulfillment(of: [detail.started], timeout: 2)
        let oldDetailTask = h.controller.detailTask
        let oldPreview = try XCTUnwrap(h.thumbnails.callbacks.first)
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        let search = SetAuditGate<Data>()
        h.network.dataGates = [search]
        h.controller.search(nil)
        await fulfillment(of: [search.started], timeout: 2)
        let oldSearchTask = h.controller.searchTask
        h.controller.searchField.stringValue = "new query"
        h.controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: h.controller.searchField))
        h.controller.showCollections(nil)
        h.controller.nextWallpaper(nil)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        let success = h.controller.statusLabel.stringValue
        let metadata = h.controller.previewMetadataLabel.stringValue
        detail.release(.success(try fixtureData(named: "wallhaven-detail")))
        search.release(.success(try fixtureData(named: "wallhaven-search")))
        let obsoleteImage = NSImage(size: NSSize(width: 1, height: 1))
        oldPreview(obsoleteImage)
        try await finishAuditTask(oldDetailTask)
        try await finishAuditTask(oldSearchTask)
        XCTAssertEqual(h.controller.state.currentSource, .collections)
        XCTAssertEqual(h.controller.state.wallhavenSearch.query, "new query")
        XCTAssertEqual(h.controller.previewTitleLabel.stringValue, "bbbbbb")
        XCTAssertEqual(h.controller.previewMetadataLabel.stringValue, metadata)
        XCTAssertFalse(h.controller.stageView.image === obsoleteImage)
        XCTAssertTrue(h.controller.remoteResults.isEmpty)
        XCTAssertEqual(h.controller.statusLabel.stringValue, success)
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.owned(h.controller.state.favorites[0])])
        XCTAssertEqual(h.store.load().history.count, 1)
    }
}

extension WallpierTests {
    @MainActor
    func testInFlightUndoRechecksCapturedDisplayBeforeMutation() async throws {
        let h = try setAuditHarness()
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        try await finishAuditTask(h.controller.undoValidationTask)
        XCTAssertTrue(h.controller.undoButton.isEnabled)
        h.controller.undoWallpaperChange(nil)
        // Undo has captured X, but its async restore-file validation has not completed.
        h.removeX()
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(h.desktop.calls.count, 1)
        XCTAssertEqual(h.store.load().history.count, 1)
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, h.desktop.current?.path)
        XCTAssertTrue(h.controller.statusLabel.stringValue.contains("not currently available"))
    }
}

// MARK: - Deterministic visual capture
//
// Offline, fixture-backed captures of the real AppKit window. Nothing here reaches Wallhaven,
// the user's state file, or the desktop: every dependency is injected and the desktop service
// is the recording stub. Images are drawn procedurally so before/after runs use identical content.
// Captures are written only when WALLPIER_CAPTURE_DIR is set.

enum CaptureFixtures {
    static let palettes: [(sky: (CGFloat, CGFloat, CGFloat), ground: (CGFloat, CGFloat, CGFloat), sun: (CGFloat, CGFloat, CGFloat))] = [
        ((0.98, 0.62, 0.42), (0.20, 0.13, 0.28), (1.00, 0.88, 0.60)),
        ((0.38, 0.62, 0.86), (0.10, 0.22, 0.30), (0.98, 0.98, 0.90)),
        ((0.10, 0.10, 0.22), (0.02, 0.04, 0.10), (0.85, 0.88, 1.00)),
        ((0.95, 0.80, 0.55), (0.45, 0.30, 0.20), (1.00, 0.95, 0.80)),
        ((0.55, 0.80, 0.75), (0.08, 0.30, 0.28), (1.00, 1.00, 0.92)),
        ((0.78, 0.48, 0.70), (0.18, 0.10, 0.25), (1.00, 0.80, 0.85)),
        ((0.22, 0.30, 0.45), (0.06, 0.08, 0.14), (0.95, 0.75, 0.45)),
        ((0.92, 0.92, 0.95), (0.55, 0.60, 0.70), (1.00, 1.00, 1.00)),
        ((0.30, 0.18, 0.40), (0.05, 0.03, 0.10), (0.98, 0.55, 0.45)),
        ((0.60, 0.75, 0.55), (0.16, 0.26, 0.12), (1.00, 0.98, 0.85)),
        ((0.99, 0.75, 0.35), (0.40, 0.12, 0.10), (1.00, 0.98, 0.80)),
        ((0.15, 0.45, 0.60), (0.02, 0.12, 0.20), (0.75, 0.95, 1.00))
    ]

    static func references() -> [WallpaperReference] {
        let tags = [["sunset", "mountains"], ["lake", "morning"], ["night", "stars"], ["desert", "dunes"],
                    ["coast", "mist"], ["dusk", "valley"], ["moonrise"], ["snow", "minimal"],
                    ["twilight", "peaks"], ["meadow", "spring"], ["canyon", "golden hour"], ["ocean", "blue hour"]]
        let sizes = [(3840, 2160), (5120, 2880), (2560, 1600), (3840, 2160), (6016, 3384), (2560, 1440),
                     (3840, 2400), (1920, 1200), (3440, 1440), (3840, 2160), (5120, 2880), (2880, 1800)]
        return (0..<12).map { index in
            let id = "fx\(String(format: "%02d", index + 1))a\(index)"
            return WallpaperReference(
                providerIdentifier: "wallhaven", wallpaperID: id,
                sourcePageURL: URL(string: "https://wallhaven.cc/w/\(id)")!,
                originalURL: URL(string: "https://w.wallhaven.cc/full/fx/wallhaven-\(id).jpg")!,
                previewURL: URL(string: "https://th.wallhaven.cc/lg/fx/\(id).jpg")!,
                thumbnailURL: URL(string: "https://th.wallhaven.cc/small/fx/\(id).jpg")!,
                width: sizes[index].0, height: sizes[index].1,
                uploader: ["northlight", "atlas_studio", "m.k."][index % 3],
                tags: tags[index], cachedLocalPath: nil)
        }
    }

    static func image(index: Int, size: NSSize = NSSize(width: 960, height: 600)) -> NSImage {
        let p = palettes[index % palettes.count]
        let w = Int(size.width), h = Int(size.height)
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: p.sky.0, green: p.sky.1, blue: p.sky.2, alpha: 1),
            CGColor(red: p.sky.0 * 0.55, green: p.sky.1 * 0.6, blue: min(1, p.sky.2 * 1.1), alpha: 1)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        context.setFillColor(CGColor(red: p.sun.0, green: p.sun.1, blue: p.sun.2, alpha: 0.95))
        let sunX = CGFloat(w) * (0.25 + 0.5 * CGFloat((index * 37) % 10) / 10), sunY = CGFloat(h) * 0.62
        context.fillEllipse(in: CGRect(x: sunX - 46, y: sunY - 46, width: 92, height: 92))
        for layer in 0..<3 {
            let t = CGFloat(layer) / 3
            let color = CGColor(red: p.ground.0 + (p.sky.0 - p.ground.0) * (0.55 - t * 0.5),
                                green: p.ground.1 + (p.sky.1 - p.ground.1) * (0.55 - t * 0.5),
                                blue: p.ground.2 + (p.sky.2 - p.ground.2) * (0.55 - t * 0.5), alpha: 1)
            context.setFillColor(color)
            context.move(to: CGPoint(x: 0, y: 0))
            let base = CGFloat(h) * (0.42 - t * 0.12)
            for x in stride(from: 0, through: w, by: 8) {
                let fx = CGFloat(x) / CGFloat(w)
                let y = base + sin(fx * (5 + CGFloat(layer * 3 + index % 4)) + CGFloat(index)) * CGFloat(h) * (0.07 + 0.03 * t)
                    + sin(fx * 17 + CGFloat(layer)) * CGFloat(h) * 0.02
                context.addLine(to: CGPoint(x: CGFloat(x), y: y))
            }
            context.addLine(to: CGPoint(x: w, y: 0))
            context.closePath(); context.fillPath()
        }
        return NSImage(cgImage: context.makeImage()!, size: size)
    }
}

/// Answers every thumbnail request synchronously with the procedural image for that wallpaper ID.
final class CaptureThumbnails: RemoteThumbnailProvider {
    private var images: [String: NSImage] = [:]
    override func requestThumbnail(for url: URL, maximumPixelSize: Int = 420, completion: @escaping (NSImage?) -> Void) {
        let name = url.deletingPathExtension().lastPathComponent
        guard let index = Int(name.dropFirst(2).prefix(2)) else { return completion(nil) }
        if images[name] == nil { images[name] = CaptureFixtures.image(index: index - 1) }
        completion(images[name])
    }
    override func reset() {}
}

final class CaptureScreen: NSScreen {
    override var localizedName: String { "Studio Display" }
    override var frame: NSRect { NSRect(x: 0, y: 0, width: 1440, height: 900) }
    override var backingScaleFactor: CGFloat { 2 }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: 501)]
    }
}

/// Behaves as the key window without the test app having to activate.
final class KeyTestWindow: NSWindow {
    /// Tests may set this false to model the window losing key status, then post the matching notification.
    var isKey = true
    override var isKeyWindow: Bool { isKey }
}

/// Requests never answer until cancelled: a search that is still loading.
final class HangingNetwork: NetworkClient {
    private(set) var downloads = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(nanoseconds: 120_000_000_000); throw CancellationError()
    }
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        downloads += 1
        try await Task.sleep(nanoseconds: 120_000_000_000); throw CancellationError()
    }
}

/// Offline, and counts original downloads (which previewing must never start).
final class DownloadCountingNetwork: NetworkClient {
    private(set) var downloads = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        downloads += 1; throw URLError(.notConnectedToInternet)
    }
}

/// Every data request fails as if offline; downloads are never expected.
final class OfflineNetwork: NetworkClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}

extension WallpierTests {
    static var captureDirectory: URL? {
        ProcessInfo.processInfo.environment["WALLPIER_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// Captures the real window including its title bar and toolbar, plus any attached
    /// windows (a popover) composited at their on-screen positions.
    @MainActor
    func captureWindow(_ window: NSWindow, named name: String, including others: [NSWindow] = []) {
        guard let directory = Self.captureDirectory else { return }
        // Capture as the user sees it: the active, key window.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func image(_ window: NSWindow) -> CGImage? {
            CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        }
        guard let base = image(window) else { return }
        let scale = CGFloat(base.width) / window.frame.width
        let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for other in others where other.isVisible {
            guard let overlay = image(other) else { continue }
            let origin = CGPoint(x: (other.frame.minX - window.frame.minX) * scale, y: (other.frame.minY - window.frame.minY) * scale)
            context.draw(overlay, in: CGRect(origin: origin, size: CGSize(width: overlay.width, height: overlay.height)))
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    @MainActor
    func makeCaptureController(root: URL, size: NSSize, appearance: NSAppearance.Name, network: NetworkClient = OfflineNetwork(),
                               openverse: NetworkClient = OfflineNetwork(), cma: NetworkClient = OfflineNetwork(),
                               windowClass: NSWindow.Type = NSWindow.self, desktop: WallpaperService? = nil,
                               thumbnails: RemoteThumbnailProvider? = nil, page: RemoteSearchPage? = nil, screens: [NSScreen]? = nil,
                               defaults: UserDefaults = .standard, configure: (inout WallpaperState) -> Void) -> (MainWindowController, NSWindow) {
        let references = CaptureFixtures.references()
        let store = WallpaperStateStore(stateURL: root.appendingPathComponent("state.json"))
        var state = WallpaperState()
        state.currentSource = .favorites
        state.wallhavenSearch.usesDisplayMinimum = false
        state.wallhavenSearch.query = "landscape"
        state.selectedDisplayID = "501"
        state.favorites = [references[1], references[3], references[4], references[7], references[9], references[11]]
        state.collections = [WallpaperCollection(name: "Evening Light", wallpapers: [references[0], references[5], references[8], references[10], references[6]]),
                             WallpaperCollection(name: "Quiet Mornings", wallpapers: [references[1], references[4]])]
        state.selectedCollectionID = state.collections[0].id
        state.selectedRemoteIdentity = references[3].identityKey
        configure(&state)
        XCTAssertTrue(store.save(state))
        let window = windowClass.init(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Wallpier"
        window.appearance = NSAppearance(named: appearance)
        let originals = root.appendingPathComponent("Originals")
        let controller = MainWindowController(window: window, wallpaperService: desktop ?? SetAuditWallpaperService(), stateStore: store,
            provider: WallhavenProvider(client: network), openverseProvider: OpenverseProvider(client: openverse),
            cmaProvider: CMAProvider(client: cma), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: root.appendingPathComponent("Rollback")),
            remoteThumbnailProvider: thumbnails ?? CaptureThumbnails(), availableScreens: { screens ?? [CaptureScreen()] }, defaults: defaults)
        let page = page ?? RemoteSearchPage(wallpapers: references, currentPage: 1, lastPage: 54, total: 1_284,
            rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil))
        controller.prepareForVisualCapture(discoverPage: page)
        return (controller, window)
    }

    @MainActor
    func testCaptureScenarios() throws {
        try XCTSkipIf(Self.captureDirectory == nil, "Set WALLPIER_CAPTURE_DIR to write captures")
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let root = try historyTestFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let (controller, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: appearance) { _ in }
            defer { window.close() }
            controller.showDiscover(nil)
            captureWindow(window, named: "01-discover-\(suffix)")
            controller.toggleViewer(nil)
            captureWindow(window, named: "02-selected-\(suffix)")
            controller.toggleViewer(nil)
            controller.showFavorites(nil)
            captureWindow(window, named: "04-favorites-\(suffix)")
            controller.showCollections(nil)
            captureWindow(window, named: "05-collection-\(suffix)")
            let interval = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            interval.tag = RotationInterval.allCases.firstIndex(of: .oneHour)!
            controller.setRotationInterval(interval)
            let source = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            source.representedObject = controller.state.collections[0].id
            controller.useForRotation(source)
            controller.showRotationSettings(nil)
            let popover = controller.rotationPopover.contentViewController?.view.window
            captureWindow(window, named: "06-rotation-\(suffix)", including: popover.map { [$0] } ?? [])
            controller.rotationPopover.close()
            interval.tag = 0
            controller.setRotationInterval(interval)
            controller.showDiscover(nil)
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
            captureWindow(window, named: "03-minimum-\(suffix)")
            controller.toggleViewer(nil)
            captureWindow(window, named: "03b-minimum-preview-\(suffix)")
            controller.toggleViewer(nil)
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1120, height: 720)), display: true)
            controller.showLocal(nil)
            captureWindow(window, named: "07a-empty-local-\(suffix)")
            controller.search(nil)
            let failed = expectation(description: "offline search settles")
            Task { await controller.searchTask?.value; failed.fulfill() }
            wait(for: [failed], timeout: 5)
            captureWindow(window, named: "07b-error-offline-\(suffix)")

            let loadingRoot = try historyTestFolder()
            defer { try? FileManager.default.removeItem(at: loadingRoot) }
            let (loading, loadingWindow) = makeCaptureController(root: loadingRoot, size: NSSize(width: 1120, height: 720),
                                                                 appearance: appearance, network: HangingNetwork()) { _ in }
            defer { loadingWindow.close() }
            loading.search(nil)
            captureWindow(loadingWindow, named: "07c-loading-\(suffix)")
            loading.searchTask?.cancel()
        }
    }
}



// MARK: - Batch 1: text commands, membership Undo and an honest selection
//
// Keys travel the real application path. The hosted app is activated with the production menu bar,
// and each key is a Quartz keyboard event (translated by the keyboard layout) queued with
// NSApp.postEvent, then dispatched by nextEvent/sendEvent: window key equivalents, the menu bar,
// then the first responder. window.sendEvent alone skips the menu bar and cannot prove ⌘⌫ or ⌘Z.
// Posting to the window server instead would need Accessibility trust, which the tests never ask for.
// Every run uses isolated state, offline or hanging networking and the recording wallpaper service.
// AppKit closes per-event Undo groups only in the top-level event loop, which nested test dispatch
// never reaches, so consecutive commands within one test share an Undo step.

@MainActor
private final class ActiveApp {
    let controller: MainWindowController
    let window: NSWindow
    let desktop = SetAuditWallpaperService()
    let root: URL
    let prior: URL
    private let savedMenu = NSApp.mainMenu

    init(test: WallpierTests, root: URL, network: NetworkClient = OfflineNetwork(), configure: (inout WallpaperState) -> Void = { _ in }) throws {
        self.root = root
        prior = root.appendingPathComponent("prior.png")
        let replacement = root.appendingPathComponent("replacement.png")
        for (url, width) in [(prior, 3), (replacement, 5)] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        }
        // A restorable wallpaper change, so a misrouted ⌘Z would have something to roll back.
        let entry = HistoryEntry(previous: DisplayAssignment(displayID: "501", displayName: "Studio Display", imagePath: prior.path, scaling: .fit),
                                 replacement: DisplayAssignment(displayID: "501", displayName: "Studio Display", imagePath: replacement.path, scaling: .fill),
                                 timestamp: Date())
        (controller, window) = test.makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                          network: network, desktop: desktop) { state in
            state.history = [entry]
            configure(&state)
        }
        AppDelegate().configureMainMenu(for: controller)
        _ = controller.perform(NSSelectorFromString("refreshUndoAvailability"))
        activate()
        pump(5) { self.controller.undoButton.isEnabled }       // Undo history is validated asynchronously.
    }

    /// Active, with the fixture window or a sheet attached to it (a naming prompt, say) as the key window.
    var isActiveAndKey: Bool { NSApp.isActive && ownsKeyWindow }
    private var ownsKeyWindow: Bool {
        var candidate = NSApp.keyWindow
        while let current = candidate { if current === window { return true }; candidate = current.sheetParent }
        return false
    }

    // Activation and the key window belong to the window server: another app, the user or a tiling window manager
    // can take them at any moment. Native events are only meaningful while this app is active with its window key.
    var environment: String {
        "frontmost app \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"), Wallpier active \(NSApp.isActive), " +
        "key window \(NSApp.keyWindow.map { $0 === window ? "fixture" : ownsKeyWindow ? "fixture sheet" : "other: \($0.title)" } ?? "none")"
    }

    /// Bounded re-activation, waiting on the observable condition itself: up to three attempts of two seconds.
    @discardableResult
    func activate() -> Bool {
        for _ in 0..<3 where !isActiveAndKey {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            pump(2) { self.isActiveAndKey }
        }
        return isActiveAndKey
    }

    /// Before each native event: if the session can't give this app activation, say so explicitly as an environmental
    /// limitation (and post nothing), rather than letting a misdirected event look like a product failure.
    func ensureReady(_ step: String, file: StaticString, line: UInt) -> Bool {
        if isActiveAndKey || activate() { return true }
        XCTFail("ENVIRONMENT: the test app isn't active with its window key before \(step) (\(environment)). " +
                "Native menu and key dispatch can't be verified in this GUI session.", file: file, line: line)
        return false
    }

    func close() {
        [controller.downloadTask, controller.searchTask, controller.detailTask, controller.undoValidationTask].forEach { $0?.cancel() }
        window.close()
        NSApp.mainMenu = savedMenu
    }

    /// Runs the application's own event dispatch until `condition` holds or time runs out.
    func pump(_ seconds: TimeInterval = 0.25, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func post(_ quartz: CGEvent) { NSApp.postEvent(NSEvent(cgEvent: quartz)!, atStart: false) }

    /// One key press on the ANSI layout (z 6, Delete 51, Return 36, Space 49, Escape 53, → 124, ← 123).
    func press(_ key: CGKeyCode, _ flags: CGEventFlags = [], expecting characters: String? = nil,
               file: StaticString = #filePath, line: UInt = #line) {
        guard ensureReady("key \(key)", file: file, line: line) else { return }
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let quartz = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
            quartz.flags = flags
            if down, let characters {
                XCTAssertEqual(NSEvent(cgEvent: quartz)?.charactersIgnoringModifiers, characters, "keyboard layout", file: file, line: line)
            }
            post(quartz)
        }
        pump()
    }

    func commandZ(file: StaticString = #filePath, line: UInt = #line) { press(6, .maskCommand, expecting: "z", file: file, line: line) }
    func shiftCommandZ(file: StaticString = #filePath, line: UInt = #line) { press(6, [.maskCommand, .maskShift], file: file, line: line) }
    func commandDelete(file: StaticString = #filePath, line: UInt = #line) { press(51, .maskCommand, expecting: "\u{7f}", file: file, line: line) }

    func type(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard ensureReady("typing", file: file, line: line) else { return }
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let quartz = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)!
                quartz.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(quartz)
            }
        }
        pump()
    }

    func click(_ point: NSPoint, file: StaticString = #filePath, line: UInt = #line) {
        guard ensureReady("click", file: file, line: line) else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                               pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
        }
        pump()
    }

    func focus(_ responder: NSResponder) {
        XCTAssertTrue(window.makeFirstResponder(responder))
        pump(0.1)
    }

    func select(_ index: Int) {
        controller.collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        controller.collectionView(controller.collectionView, didSelectItemsAt: [IndexPath(item: index, section: 0)])
        focus(controller.collectionView)
    }

    func menuItem(_ menu: String, _ action: Selector) -> NSMenuItem? {
        let submenu = NSApp.mainMenu?.items.first { $0.submenu?.title == menu }?.submenu
        submenu?.update()
        return submenu?.items.first { $0.action == action }
    }

    var searchText: String { controller.searchField.currentEditor()?.string ?? controller.searchField.stringValue }
    var storedHistory: [HistoryEntry] { WallpaperStateStore(stateURL: root.appendingPathComponent("state.json")).load().history }
}

extension WallpierTests {
    @MainActor
    private func activeApp(network: NetworkClient = OfflineNetwork(), configure: (inout WallpaperState) -> Void = { _ in }) throws -> ActiveApp {
        let root = try historyTestFolder()
        let app = try ActiveApp(test: self, root: root, network: network, configure: configure)
        addTeardownBlock {
            await MainActor.run { app.close() }
            try? FileManager.default.removeItem(at: root)
        }
        // An environmental failure stops the test at once, instead of cascading into misleading product assertions.
        continueAfterFailure = false
        _ = try XCTUnwrap(app.isActiveAndKey ? app : nil,
                          "ENVIRONMENT: the test app couldn't become active with its window key (\(app.environment)). " +
                          "Native menu and key dispatch can't be verified in this GUI session.")
        XCTAssertTrue(app.controller.undoButton.isEnabled, "Fixture needs restorable wallpaper history")
        return app
    }

    /// Ring, apply bar, preview caption and menu availability all name the same Set target, or none.
    @MainActor
    private func assertHonestSelection(_ controller: MainWindowController, _ context: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let view = controller.collectionView
        let selected = view.selectionIndexPaths
        let set = NSMenuItem(title: "", action: #selector(MainWindowController.setWallpaper(_:)), keyEquivalent: "")
        let preview = NSMenuItem(title: "", action: #selector(MainWindowController.toggleViewer(_:)), keyEquivalent: "")
        let summary = controller.selectionLabel.stringValue
        if view.numberOfItems(inSection: 0) == 0 {
            XCTAssertTrue(selected.isEmpty, "\(context): an empty source has no selection", file: file, line: line)
        } else {
            XCTAssertEqual(selected.count, 1, "\(context): a nonempty gallery always shows its target", file: file, line: line)
        }
        guard let indexPath = selected.first else {
            XCTAssertEqual(summary, "No Wallpaper Selected", "\(context)", file: file, line: line)
            XCTAssertEqual(controller.previewTitleLabel.stringValue, "No Wallpaper Selected", "\(context)", file: file, line: line)
            XCTAssertFalse(controller.validateMenuItem(set), "\(context): Set has no target", file: file, line: line)
            XCTAssertFalse(controller.setWallpaperButton.isEnabled, "\(context)", file: file, line: line)
            XCTAssertFalse(controller.validateMenuItem(preview), "\(context)", file: file, line: line)
            return
        }
        view.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
        view.layoutSubtreeIfNeeded()
        let item = view.item(at: indexPath) as? WallpaperCollectionViewItem
        XCTAssertEqual(item?.showsSelectionRing, true, "\(context): ring on the target", file: file, line: line)
        let title = item?.view.accessibilityLabel() ?? "?"
        XCTAssertTrue(summary.hasPrefix(title), "\(context): apply bar shows \(summary), ring shows \(title)", file: file, line: line)
        XCTAssertEqual(controller.previewTitleLabel.stringValue, title, "\(context)", file: file, line: line)
        XCTAssertTrue(controller.validateMenuItem(preview), "\(context)", file: file, line: line)
    }

    // D1: text editing owns ⌘⌫, ⌘Z and ⇧⌘Z; library and desktop stay untouched.
    @MainActor
    func testSearchFieldOwnsCommandDeleteUndoAndRedoThroughTheMenuBar() throws {
        let app = try activeApp()
        let c = app.controller
        c.showFavorites(nil)
        let original = c.state.favorites
        // A library removal waits on the window's Undo stack while the user edits search text.
        app.select(0)
        app.commandDelete()
        let favorites = c.state.favorites
        XCTAssertEqual(favorites, Array(original.dropFirst()))
        app.focus(c.searchField)
        XCTAssertEqual(app.searchText, "landscape")
        c.searchField.currentEditor()?.selectAll(nil)
        app.type("forest")
        XCTAssertEqual(app.searchText, "forest")

        app.commandDelete()
        XCTAssertEqual(app.searchText, "", "⌘⌫ deletes to the start of the line")
        XCTAssertEqual(c.state.favorites, favorites, "⌘⌫ while typing must not remove a Favorite")
        XCTAssertEqual(app.menuItem("Edit", Selector(("undo:")))?.title, "Undo Typing")
        app.commandZ()
        XCTAssertEqual(app.searchText, "landscape", "⌘Z undoes the text edits")
        app.shiftCommandZ()
        XCTAssertEqual(app.searchText, "", "⇧⌘Z redoes them")
        app.commandZ()
        // Past the text history, ⌘Z and ⇧⌘Z in the field still reach nothing but text.
        for _ in 0..<3 { app.commandZ() }
        for _ in 0..<4 { app.shiftCommandZ() }
        XCTAssertTrue(c.window?.firstResponder is NSText, "Focus stayed in the search field")
        XCTAssertEqual(c.state.favorites, favorites, "Text Undo never restores or removes library membership")
        XCTAssertTrue(app.desktop.calls.isEmpty, "Text Undo must never change the desktop")
        XCTAssertEqual(c.state.history.count, 1)
        XCTAssertEqual(app.storedHistory.count, 1)
        XCTAssertNil(c.downloadTask)

        // The named rollback is unchanged: no ⌘Z, in the Wallpaper menu, enabled, and it restores.
        let rollback = try XCTUnwrap(app.menuItem("Wallpaper", #selector(MainWindowController.undoWallpaperChange(_:))))
        XCTAssertEqual(rollback.title, "Undo Wallpaper Change")
        XCTAssertEqual(rollback.keyEquivalent, "")
        XCTAssertTrue(rollback.isEnabled)
        XCTAssertEqual(app.menuItem("Edit", Selector(("undo:")))?.keyEquivalent, "z")
        XCTAssertNotNil(app.menuItem("Edit", Selector(("undo:"))))
        XCTAssertNil(app.menuItem("Edit", Selector(("undo:")))?.target, "Edit ▸ Undo follows the responder chain")
        rollback.menu?.performActionForItem(at: rollback.menu!.index(of: rollback))
        app.pump(5) { c.downloadTask == nil && !app.desktop.calls.isEmpty }
        XCTAssertEqual(app.desktop.calls.map(\.image.path), [app.prior.path])
        XCTAssertTrue(c.state.history.isEmpty)

        // Back in the gallery, ⌘Z reaches the library removal, untouched by the text edits.
        app.focus(c.collectionView)
        app.commandZ()
        XCTAssertEqual(c.state.favorites, original)
        XCTAssertEqual(app.desktop.calls.count, 1)
    }

    // D1 + removal Undo: ⌘⌫ in the gallery removes the selected Favorite; ⌘Z/⇧⌘Z restore and repeat it in place.
    @MainActor
    func testCommandDeleteAndUndoRedoFavoriteRemovalInGalleryAndPreview() throws {
        let app = try activeApp()
        let c = app.controller
        c.showFavorites(nil)
        let favorites = c.state.favorites
        app.select(2)

        app.commandZ()
        XCTAssertTrue(app.desktop.calls.isEmpty, "⌘Z in the gallery is not wallpaper rollback")
        XCTAssertEqual(c.state.history.count, 1)

        app.commandDelete()
        XCTAssertEqual(c.state.favorites.map(\.identityKey), favorites.enumerated().filter { $0.offset != 2 }.map(\.element.identityKey))
        XCTAssertEqual(c.collectionView.selectionIndexPaths, [IndexPath(item: 2, section: 0)], "Selection keeps its place")
        XCTAssertEqual(c.state.selectedRemoteIdentity, favorites[3].identityKey)
        assertHonestSelection(c, "after removal")
        XCTAssertEqual(app.menuItem("Edit", Selector(("undo:")))?.title, "Undo Remove from Favorites")

        app.commandZ()
        XCTAssertEqual(c.state.favorites, favorites, "Undo restores the Favorite at its position")
        XCTAssertEqual(WallpaperStateStore(stateURL: app.root.appendingPathComponent("state.json")).load().favorites, favorites)
        XCTAssertEqual(c.state.selectedRemoteIdentity, favorites[2].identityKey, "The restored wallpaper is selected")
        assertHonestSelection(c, "after undo")
        XCTAssertEqual(app.menuItem("Edit", Selector(("redo:")))?.title, "Redo Remove from Favorites")
        app.shiftCommandZ()
        XCTAssertFalse(c.state.isFavorite(favorites[2]))
        app.commandZ()
        XCTAssertEqual(c.state.favorites, favorites)

        // The preview is a browsing context too; plain Delete in the grid is undoable the same way.
        c.toggleViewer(nil)
        app.pump()
        XCTAssertTrue(c.isViewerVisible)
        XCTAssertTrue(c.window?.firstResponder === c.viewerView)
        app.commandDelete()
        XCTAssertFalse(c.state.isFavorite(favorites[2]))
        app.commandZ()
        XCTAssertEqual(c.state.favorites, favorites)
        c.toggleViewer(nil)
        app.select(0)
        app.press(51, expecting: "\u{7f}")
        XCTAssertFalse(c.state.isFavorite(favorites[0]))
        app.commandZ()
        XCTAssertEqual(c.state.favorites, favorites)

        XCTAssertTrue(app.desktop.calls.isEmpty, "Membership Undo never calls the wallpaper service")
        XCTAssertEqual(app.storedHistory.count, 1)
    }

    @MainActor
    func testCollectionRemovalUndoRestoresOrderAndSheetTextKeepsItsCommands() throws {
        let app = try activeApp()
        let c = app.controller
        c.showCollections(nil)
        let original = try XCTUnwrap(c.state.collections.first).wallpapers
        XCTAssertEqual(original.count, 5)
        app.select(1)
        XCTAssertEqual(app.menuItem("Wallpaper", #selector(MainWindowController.removeSelected(_:)))?.title, "Remove from “Evening Light”")
        app.commandDelete()
        XCTAssertEqual(c.state.collections[0].wallpapers, [original[0], original[2], original[3], original[4]])
        XCTAssertEqual(app.menuItem("Edit", Selector(("undo:")))?.title, "Undo Remove from “Evening Light”")
        app.commandZ()
        XCTAssertEqual(c.state.collections[0].wallpapers, original, "Undo puts the member back in place")
        // Two removals from different places come back in the original order.
        app.select(1); app.commandDelete()
        app.select(2); app.commandDelete()
        XCTAssertEqual(c.state.collections[0].wallpapers, [original[0], original[2], original[4]])
        app.commandZ()
        XCTAssertEqual(c.state.collections[0].wallpapers, original, "Undo restores the original order")
        XCTAssertEqual(WallpaperStateStore(stateURL: app.root.appendingPathComponent("state.json")).load().collections[0].wallpapers, original)
        app.shiftCommandZ()
        XCTAssertEqual(c.state.collections[0].wallpapers, [original[0], original[2], original[4]])
        app.commandZ()
        XCTAssertEqual(c.state.collections[0].wallpapers, original)
        assertHonestSelection(c, "after collection undo")

        // A sheet's text field is key while the gallery keeps its selection behind it.
        c.renameCollection(nil)
        app.pump(3) { NSApp.keyWindow === c.window?.attachedSheet }
        let sheet = try XCTUnwrap(c.window?.attachedSheet)
        XCTAssertTrue(NSApp.keyWindow === sheet)
        XCTAssertEqual(app.menuItem("Wallpaper", #selector(MainWindowController.removeSelected(_:)))?.isEnabled, false)
        app.type(" Sky")
        app.commandDelete()
        XCTAssertEqual((sheet.firstResponder as? NSText)?.string, "", "⌘⌫ edits the sheet's text")
        XCTAssertEqual(c.state.collections[0].wallpapers, original, "…and leaves the collection alone")
        c.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        app.pump(2) { NSApp.keyWindow === c.window }
        XCTAssertEqual(c.state.collections[0].name, "Evening Light")
        XCTAssertTrue(app.desktop.calls.isEmpty)
    }

    @MainActor
    func testLastItemRemovalLeavesNoTargetAndUndoBringsItBack() throws {
        let app = try activeApp { state in
            state.collections[1] = WallpaperCollection(id: state.collections[1].id, name: "Single", wallpapers: [state.collections[1].wallpapers[0]])
            state.selectedCollectionID = state.collections[1].id
        }
        let c = app.controller
        c.showCollections(nil)
        let only = c.state.collections[1].wallpapers[0]
        app.select(0)
        assertHonestSelection(c, "single member")
        app.commandDelete()
        XCTAssertTrue(c.state.collections[1].wallpapers.isEmpty)
        XCTAssertFalse(c.emptyStateView.isHidden)
        assertHonestSelection(c, "emptied collection")
        XCTAssertEqual(app.menuItem("Wallpaper", #selector(MainWindowController.removeSelected(_:)))?.isEnabled, false)
        XCTAssertEqual(app.menuItem("Wallpaper", #selector(MainWindowController.setWallpaper(_:)))?.isEnabled, false)
        XCTAssertEqual(app.menuItem("Wallpaper", #selector(MainWindowController.toggleFavorite(_:)))?.isEnabled, false)
        app.press(36, expecting: "\r")
        XCTAssertNil(c.downloadTask, "Return with nothing selected sets nothing")
        app.commandZ()
        XCTAssertEqual(c.state.collections[1].wallpapers, [only], "⌘Z still reaches the removal after the gallery emptied")
        XCTAssertTrue(c.emptyStateView.isHidden)
        assertHonestSelection(c, "restored last member")
        XCTAssertTrue(c.setWallpaperButton.isEnabled)
        XCTAssertTrue(app.desktop.calls.isEmpty)
    }

    // D2: a blank click keeps the ring and the Set target together, and arrow keys then follow AppKit's
    // own navigation over the gallery as actually laid out: Right moves within a row and stops at its end,
    // Down moves one row. Expectations come from the laid-out columns, exercised at two, three and four or
    // more of them (window width and thumbnail size are set directly, so no preference is written), in two
    // sources so navigation is also checked after a source change. Down is only asserted into complete rows.
    @MainActor
    // Deterministic dispatch: real mouse and key NSEvents through window.sendEvent to a window that reports itself key
    // (never ordered on screen, so no window manager can tile or defocus it). The gallery's own native navigation
    // handles them; no menu-bar semantics are under test here, so no activated application is needed.
    func testBlankGalleryClickKeepsTheVisibleSetTarget() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                windowClass: KeyTestWindow.self) { _ in }
        defer { window.close() }
        let view = c.collectionView
        func select(_ index: Int) {
            view.selectionIndexPaths = [IndexPath(item: index, section: 0)]
            c.collectionView(view, didSelectItemsAt: [IndexPath(item: index, section: 0)])
            XCTAssertTrue(window.makeFirstResponder(view))
        }
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        var columnCounts: [Int] = []
        let configurations = [(window.minSize.width, GalleryLayout.thumbnailWidths[2]),
                              (window.minSize.width, GalleryLayout.thumbnailWidths[1]),
                              (CGFloat(1060), GalleryLayout.thumbnailWidths[1]),
                              (CGFloat(1120), GalleryLayout.thumbnailWidths[0])]
        for (width, thumbnail) in configurations {
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: 720)), display: true)
            c.galleryLayoutForTesting.targetWidth = thumbnail
            for source in [LibrarySource.favorites, .discover] {
                if source == .favorites { c.showFavorites(nil) } else { c.showDiscover(nil) }
                c.window?.contentView?.layoutSubtreeIfNeeded()
                let identities = source == .favorites ? c.state.favorites.map(\.identityKey) : c.remoteResults.map(\.identityKey)
                let count = view.numberOfItems(inSection: 0)
                let firstRow = view.frameForItem(at: 0).minY
                let columns = (0..<count).filter { view.frameForItem(at: $0).minY == firstRow }.count
                let context = "\(columns) columns in \(source.rawValue) (window \(Int(window.frame.width)) pt, thumbnails \(Int(thumbnail)) pt)"
                columnCounts.append(columns)
                // Floor-based columns: the large size may be a single column at the minimum width.
                XCTAssertGreaterThanOrEqual(columns, 1, context)
                view.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .top)
                select(1)
                func expectSelection(_ index: Int, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
                    XCTAssertEqual(view.selectionIndexPaths, [IndexPath(item: index, section: 0)], "\(context): \(step)", file: file, line: line)
                    XCTAssertEqual(c.state.selectedRemoteIdentity, identities[index], "\(context): \(step)", file: file, line: line)
                    assertHonestSelection(c, "\(context): \(step)", file: file, line: line)
                }

                // The gutter between the first two pictures is empty space at every column count.
                let first = view.frameForItem(at: 0), second = view.frameForItem(at: 1)
                // With one column there is no gutter between neighbors; the outer margin beside the cell is blank instead.
                let blank = columns > 1 ? NSPoint(x: (first.maxX + second.minX) / 2, y: first.midY)
                                        : NSPoint(x: first.maxX + 6, y: first.midY)
                XCTAssertNil(view.indexPathForItem(at: blank), "\(context): the click point must be empty gallery space")
                click(at: view.convert(blank, to: nil), in: window)
                XCTAssertTrue(c.window?.firstResponder === view, "\(context): the click reached the gallery")
                expectSelection(1, "blank click keeps the Set target")
                XCTAssertTrue(c.setWallpaperButton.isEnabled, context)

                // Right moves within the first row and stops at its end (item 1 ends a two-column row).
                key(right, code: 124, in: window)
                let afterRight = columns > 2 ? 2 : 1
                expectSelection(afterRight, "Right")

                // Down moves exactly one row, when that row is complete.
                let below = afterRight + columns
                if (below / columns + 1) * columns <= count {
                    key(down, code: 125, in: window)
                    expectSelection(below, "Down")
                }

                // The ring is accent exactly while keys reach the gallery (first responder in the key window) and
                // stays, in gray, otherwise. This window is always key; the window losing key status is driven
                // deterministically by testSelectionRingIsEmphasizedOnlyWhileTheGalleryHasKeyboardFocus.
                let ring = { (view.selectionIndexPaths.first.flatMap { view.item(at: $0) }) as? WallpaperCollectionViewItem }
                XCTAssertEqual(ring()?.isEmphasized, true, "\(context): gallery focused")
                XCTAssertTrue(window.makeFirstResponder(c.searchField))
                XCTAssertEqual(ring()?.isEmphasized, false, "\(context): search field focused")
                XCTAssertEqual(ring()?.showsSelectionRing, true, context)
                XCTAssertTrue(window.makeFirstResponder(view))
                XCTAssertEqual(ring()?.isEmphasized, true, "\(context): gallery refocused")
            }
        }
        XCTAssertTrue(columnCounts.contains(1), "Exercised \(columnCounts)")
        XCTAssertTrue(columnCounts.contains(2), "Exercised \(columnCounts)")
        XCTAssertTrue(columnCounts.contains(3), "Exercised \(columnCounts)")
        XCTAssertTrue(columnCounts.contains { $0 >= 4 }, "Exercised \(columnCounts)")
    }

    @MainActor
    func testSelectionStaysHonestAcrossSourcesEmptySourcesReloadAndBusySet() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Local")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTestImage(to: folder.appendingPathComponent("a.png"))
        try writeTestImage(to: folder.appendingPathComponent("b.png"))
        let network = HangingNetwork()
        let desktop = SetAuditWallpaperService()
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                network: network, desktop: desktop) { state in
            state.collections.append(WallpaperCollection(name: "Empty"))
            state.folderPath = folder.path
        }
        defer { c.downloadTask?.cancel(); c.searchTask?.cancel(); window.close() }
        func waitFor(_ condition: @autoclosure () -> Bool, _ message: String) {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            XCTAssertTrue(condition(), message)
        }
        func showCollection(_ index: Int) {
            let row = c.sidebarForTesting.outlineView.row(forItem: c.sidebarForTesting.rows.first { $0.title == c.state.collections[index].name })
            c.sidebarForTesting.outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }

        c.showFavorites(nil); assertHonestSelection(c, "favorites")
        showCollection(0); assertHonestSelection(c, "collection")
        showCollection(2); assertHonestSelection(c, "empty collection")
        XCTAssertTrue(c.collectionView.selectionIndexPaths.isEmpty)
        c.showDiscover(nil); assertHonestSelection(c, "discover")
        c.showLocal(nil)
        waitFor(c.collectionView.numberOfItems(inSection: 0) == 2, "folder loads")
        assertHonestSelection(c, "folder")

        // Reloading a folder never leaves the previous wallpaper named in the apply bar.
        c.restoreState()
        assertHonestSelection(c, "folder reloading")
        waitFor(c.collectionView.numberOfItems(inSection: 0) == 2, "folder loads")
        assertHonestSelection(c, "folder loaded")
        XCTAssertEqual(c.state.selectedImagePath.map { URL(fileURLWithPath: $0).lastPathComponent }, "a.png")

        // While a Set is busy, browsing stays truthful, removal works, and nothing else mutates the desktop.
        c.showFavorites(nil)
        c.setWallpaper(nil)
        waitFor(network.downloads == 1, "Set reached its download")
        XCTAssertFalse(c.setWallpaperButton.isEnabled)
        let favorites = c.state.favorites
        c.removeSelected(nil)
        XCTAssertEqual(c.state.favorites.count, favorites.count - 1)
        assertHonestSelection(c, "removal during busy Set")
        XCTAssertFalse(c.setWallpaperButton.isEnabled, "Still busy")
        showCollection(2); assertHonestSelection(c, "empty during busy Set")
        c.showDiscover(nil); assertHonestSelection(c, "discover during busy Set")
        c.downloadTask?.cancel()
        waitFor(c.downloadTask == nil, "Set finished")
        XCTAssertTrue(c.setWallpaperButton.isEnabled)
        XCTAssertTrue(desktop.calls.isEmpty)
    }

    /// Return, Space, arrows and Escape through the activated app and production menu bar.
    @MainActor
    func testActivatedReturnSpaceArrowsAndEscapeKeepTheirMeanings() throws {
        let network = HangingNetwork()
        let app = try activeApp(network: network)
        let c = app.controller
        c.showFavorites(nil)
        app.select(0)
        app.press(49, expecting: " ")
        XCTAssertTrue(c.isViewerVisible, "Space previews")
        app.press(124)
        XCTAssertEqual(c.state.selectedRemoteIdentity, c.state.favorites[1].identityKey, "→ browses in the preview")
        XCTAssertEqual(c.previewTitleLabel.stringValue, c.state.favorites[1].wallpaperID)
        app.press(36, expecting: "\r")
        XCTAssertNotNil(c.downloadTask, "Return sets from the preview")
        app.pump(3) { network.downloads == 1 }
        app.commandZ()
        XCTAssertEqual(network.downloads, 1)
        XCTAssertTrue(app.desktop.calls.isEmpty, "⌘Z during a busy Set does not touch the desktop")
        c.downloadTask?.cancel()
        app.pump(3) { c.downloadTask == nil }
        app.press(53)
        XCTAssertFalse(c.isViewerVisible, "Escape returns to the gallery")
        XCTAssertEqual(c.collectionView.selectionIndexPaths, [IndexPath(item: 1, section: 0)])
        XCTAssertTrue(c.window?.firstResponder === c.collectionView)
        app.press(36)
        XCTAssertNotNil(c.downloadTask, "Return sets from the gallery")
        c.downloadTask?.cancel()
        app.pump(3) { c.downloadTask == nil }
        app.focus(c.searchField)
        app.press(36)
        XCTAssertNil(c.downloadTask, "Return in the search field searches")
        XCTAssertNotNil(c.searchTask)
        XCTAssertEqual(c.state.currentSource, .discover)
        XCTAssertTrue(app.desktop.calls.isEmpty)
    }
}

// MARK: - Batch 1 repair: committed additions retire obsolete removal Redo

extension WallpierTests {
    @MainActor
    private func addToCollectionItem(_ id: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(MainWindowController.addToCollection(_:)), keyEquivalent: "")
        item.representedObject = id
        return item
    }

    /// Remove B, undo, then add F by each supported path: the old "Redo Remove" must be gone,
    /// and the addition itself undoes and redoes to the exact membership.
    @MainActor
    func testCommittedAdditionsRetireObsoleteRemovalRedo() throws {
        let redo = Selector(("redo:")), undo = Selector(("undo:"))
        for addition in ["heart", "Add to Collection", "drop", "New Collection"] {
            let app = try activeApp()
            let c = app.controller
            c.showFavorites(nil)
            let favorites = c.state.favorites, collections = c.state.collections
            let b = favorites[1], quiet = collections[1]
            app.select(1); app.commandDelete(); app.commandZ()
            XCTAssertEqual(c.state.favorites, favorites, addition)
            XCTAssertEqual(app.menuItem("Edit", redo)?.title, "Redo Remove from Favorites", addition)

            c.showDiscover(nil); app.select(0)
            let f = c.remoteResults[0]
            XCTAssertFalse(c.state.isFavorite(f)); XCTAssertFalse(quiet.wallpapers.contains(f))
            let name: String
            switch addition {
            case "heart":
                c.favoriteButton.performClick(nil); name = "Favorites"
            case "Add to Collection":
                c.addToCollection(addToCollectionItem(quiet.id)); name = "“Quiet Mornings”"
            case "drop":
                XCTAssertEqual(c.sidebarForTesting.onDrop?(.collection(quiet.id), [f.identityKey]), true); name = "“Quiet Mornings”"
            default:
                let item = NSMenuItem(title: "", action: #selector(MainWindowController.createCollection(_:)), keyEquivalent: "")
                item.representedObject = "withSelection"
                c.createCollection(item)
                app.pump(3) { NSApp.keyWindow === c.window?.attachedSheet }
                app.type("Picks"); app.press(36)
                app.pump(3) { c.window?.attachedSheet == nil }
                name = "“Picks”"
            }
            app.pump()
            let added = (c.state.favorites, c.state.collections)
            XCTAssertNotEqual(added.0 + added.1.flatMap(\.wallpapers), favorites + collections.flatMap(\.wallpapers), "\(addition) committed")
            XCTAssertEqual(app.menuItem("Edit", redo)?.isEnabled, false, "\(addition) retires the obsolete Redo")
            app.shiftCommandZ()
            XCTAssertTrue(c.state.isFavorite(b), "\(addition): ⇧⌘Z must not remove B again")
            XCTAssertEqual(c.state.favorites, added.0, addition)
            XCTAssertEqual(c.state.collections, added.1, addition)

            // The addition is a real, named step that restores exact membership both ways.
            XCTAssertEqual(app.menuItem("Edit", undo)?.title, "Undo Add to \(name)", addition)
            app.commandZ()
            XCTAssertEqual(c.state.favorites, favorites, addition)
            XCTAssertEqual(Array(c.state.collections.prefix(2)), collections, addition)
            XCTAssertTrue(c.state.collections.dropFirst(2).allSatisfy(\.wallpapers.isEmpty), "\(addition): the new collection keeps no member")
            app.shiftCommandZ()
            XCTAssertEqual(c.state.favorites, added.0, addition)
            XCTAssertEqual(c.state.collections, added.1, addition)
            XCTAssertEqual(WallpaperStateStore(stateURL: app.root.appendingPathComponent("state.json")).load().collections, added.1, addition)
            XCTAssertTrue(app.desktop.calls.isEmpty, addition)
            app.close()
        }
    }

    @MainActor
    func testNoOpAdditionsKeepRedoAndMultiItemDropIsOneExactStep() throws {
        let redo = Selector(("redo:")), undo = Selector(("undo:"))
        let app = try activeApp()
        let c = app.controller
        c.showFavorites(nil)
        let favorites = c.state.favorites, quiet = c.state.collections[1]
        app.select(1); app.commandDelete(); app.commandZ()

        // Adding what is already there changes nothing and keeps the valid Redo.
        XCTAssertEqual(c.sidebarForTesting.onDrop?(.favorites, [favorites[0].identityKey]), true)
        XCTAssertEqual(c.sidebarForTesting.onDrop?(.collection(quiet.id), [quiet.wallpapers[0].identityKey]), true)
        app.select(0)
        c.addToCollection(addToCollectionItem(quiet.id))   // favorites[0] is already in Quiet Mornings
        app.pump()
        XCTAssertEqual(c.state.favorites, favorites)
        XCTAssertEqual(c.state.collections[1], quiet)
        XCTAssertEqual(app.menuItem("Edit", redo)?.title, "Redo Remove from Favorites")
        app.shiftCommandZ()
        XCTAssertFalse(c.state.isFavorite(favorites[1]), "The still-valid Redo works")
        app.commandZ()
        XCTAssertEqual(c.state.favorites, favorites)

        // One drop of several wallpapers is one step, undone and redone exactly, in drop order.
        let x = c.remoteResults[0], y = c.remoteResults[5]
        XCTAssertEqual(c.sidebarForTesting.onDrop?(.collection(quiet.id), [x.identityKey, y.identityKey, x.identityKey]), true)
        XCTAssertEqual(c.state.collections[1].wallpapers, quiet.wallpapers + [x, y])
        XCTAssertEqual(app.menuItem("Edit", undo)?.title, "Undo Add to “Quiet Mornings”")
        app.commandZ()
        XCTAssertEqual(c.state.collections[1], quiet)
        XCTAssertEqual(c.state.favorites, favorites)
        app.shiftCommandZ()
        XCTAssertEqual(c.state.collections[1].wallpapers, quiet.wallpapers + [x, y])

        // Deleting the collection leaves no Undo that could resurrect its members.
        let delete = NSMenuItem(title: "", action: #selector(MainWindowController.deleteCollection(_:)), keyEquivalent: "")
        delete.representedObject = quiet.id
        c.deleteCollection(delete)
        app.pump(3) { NSApp.keyWindow === c.window?.attachedSheet }
        app.press(36)
        app.pump(3) { c.window?.attachedSheet == nil }
        XCTAssertFalse(c.state.collections.contains { $0.id == quiet.id })
        XCTAssertEqual(app.menuItem("Edit", undo)?.isEnabled, false)
        app.commandZ()
        XCTAssertFalse(c.state.collections.contains { $0.id == quiet.id })
        XCTAssertTrue(app.desktop.calls.isEmpty)
    }
}

// MARK: - Batch 2: truthful preview, bounded requests and honest Discover state
//
// Offline and deterministic. Wallhaven JSON is generated with real thumbnail geometry, the network
// records every request it starts, thumbnails are drawn from a position-coded pattern, and the desktop
// is the recording service. Nothing reaches Wallhaven, the user's state or the desktop.

/// Wallhaven thumbnail geometry: `lg` is a 432×243 centre crop, `orig` keeps the source's
/// proportions on a 300-pixel long edge, `small` is a 300×200 crop.
enum CompositionFixtures {
    static let shapes: [(name: String, id: String, width: Int, height: Int)] = [
        ("16:9", "cmp169", 3840, 2160), ("16:10", "cmp1610", 2560, 1600), ("square", "cmpsq", 2000, 2000),
        ("portrait", "cmpport", 1200, 2133), ("21:9", "cmp219", 3440, 1440), ("32:9", "cmp329", 5120, 1440)]

    static func listing(id: String, width: Int, height: Int, original: Bool = true,
                        uploader: String? = nil, tags: [String]? = nil) -> [String: Any] {
        var thumbs = ["large": "https://th.wallhaven.cc/lg/cm/\(id).jpg", "small": "https://th.wallhaven.cc/small/cm/\(id).jpg"]
        if original { thumbs["original"] = "https://th.wallhaven.cc/orig/cm/\(id).jpg" }
        var item: [String: Any] = ["id": id, "url": "https://wallhaven.cc/w/\(id)", "path": "https://w.wallhaven.cc/full/cm/wallhaven-\(id).png",
                                   "dimension_x": width, "dimension_y": height, "thumbs": thumbs]
        if let uploader { item["uploader"] = ["username": uploader] }
        if let tags { item["tags"] = tags.map { ["name": $0] } }
        return item
    }

    static func shapeListings() -> [[String: Any]] { shapes.map { listing(id: $0.id, width: $0.width, height: $0.height) } }

    static func searchJSON(_ items: [[String: Any]], page: Int = 1, lastPage: Int = 2, total: Int = 40) -> Data {
        try! JSONSerialization.data(withJSONObject: ["data": items,
            "meta": ["current_page": page, "last_page": lastPage, "per_page": 24, "total": total]])
    }

    static func detailJSON(_ item: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: ["data": item]) }

    /// Red is the horizontal position in the original (0 left … 1 right) and green the vertical one
    /// (0 top … 1 bottom), so every pixel of any crop or scale names the part of the original it shows.
    static var framesEdges = false

    static func pattern(original: CGSize, canvas: CGSize) -> CGImage {
        let w = Int(canvas.width), h = Int(canvas.height)
        let scale = max(canvas.width / original.width, canvas.height / original.height)
        let shown = CGSize(width: original.width * scale, height: original.height * scale)
        let offset = CGPoint(x: (canvas.width - shown.width) / 2, y: (canvas.height - shown.height) / 2)
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let u = (CGFloat(x) + 0.5 - offset.x) / shown.width, v = (CGFloat(y) + 0.5 - offset.y) / shown.height
                let i = (y * w + x) * 4
                bytes[i] = UInt8(max(0, min(1, u)) * 255); bytes[i + 1] = UInt8(max(0, min(1, v)) * 255); bytes[i + 2] = 128
                // Captures only: a white border on the original's edges makes any cropping visible at a glance.
                let border = 0.035
                if framesEdges, min(u, 1 - u) * original.width < border * min(original.width, original.height)
                    || min(v, 1 - v) * original.height < border * min(original.width, original.height) {
                    bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255
                }
            }
        }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    static func canvas(for url: URL, original: CGSize) -> CGSize {
        switch url.pathComponents.dropFirst().first {
        case "lg": return CGSize(width: 432, height: 243)
        case "orig":
            return original.width >= original.height
                ? CGSize(width: 300, height: (300 * original.height / original.width).rounded())
                : CGSize(width: (300 * original.width / original.height).rounded(), height: 300)
        default: return CGSize(width: 300, height: 200)
        }
    }

    /// A small stand-in for a full original, with the original's proportions.
    static func writeOriginal(_ size: CGSize, to url: URL) throws {
        let canvas = size.width >= size.height ? CGSize(width: 480, height: (480 * size.height / size.width).rounded())
                                               : CGSize(width: (480 * size.width / size.height).rounded(), height: 480)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pattern(original: size, canvas: canvas), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// Serves each thumbnail URL as the pattern cropped exactly as Wallhaven crops that kind of thumbnail,
/// remembers which URL every image came from, and can hold callbacks to deliver them late.
final class CompositionThumbnails: RemoteThumbnailProvider {
    var sizes: [String: CGSize] = [:]
    var holds = false
    private var held: [(url: URL, completion: (NSImage?) -> Void)] = []
    private var served: [(image: NSImage, url: URL)] = []

    override func requestThumbnail(for url: URL, maximumPixelSize: Int = 420, completion: @escaping (NSImage?) -> Void) {
        if holds { held.append((url, completion)); return }
        completion(image(for: url))
    }

    private func image(for url: URL) -> NSImage? {
        guard let original = sizes[url.deletingPathExtension().lastPathComponent] else { return nil }
        let canvas = CompositionFixtures.canvas(for: url, original: original)
        let image = NSImage(cgImage: CompositionFixtures.pattern(original: original, canvas: canvas), size: canvas)
        served.append((image, url))
        return image
    }

    func releaseHeld() {
        let pending = held
        held = []
        pending.forEach { $0.completion(image(for: $0.url)) }
    }

    /// The thumbnail kind ("lg", "orig", "small") an image was served as; nil for anything else, such as a decoded original.
    func kind(of image: NSImage?) -> String? {
        guard let image, let url = served.first(where: { $0.image === image })?.url else { return nil }
        return url.pathComponents[1]
    }

    override func reset() {}
}

/// Answers Wallhaven's API and original downloads from fixtures and records every request it starts.
@MainActor
final class Batch2Network: NetworkClient {
    var pageItems: [[String: Any]] = []
    var lastPage = 2
    var details: [String: [String: Any]] = [:]
    var apiStatus = 200
    var apiHeaders: [String: String] = [:]
    var downloadStatus = 200
    var downloadHeaders: [String: String] = [:]
    var originalFile: URL?
    fileprivate var downloadGate: SetAuditGate<Void>?
    /// Every search request, in order: its page and where it is. With `holdsSearches`, requests wait (with no hidden
    /// timeout) until the test releases them, so a test can tell "never started" from "held" from "answered".
    enum SearchState: Equatable { case held, answered, failed }
    private(set) var searchJournal: [(page: Int, state: SearchState)] = []
    var holdsSearches = false
    /// Filled synchronously by the continuation's body before the request suspends, so a held request can always be released.
    private final class Hold { var continuation: CheckedContinuation<Void, Error>? }
    private var heldSearches: [Int: Hold] = [:]
    private(set) var searches: [URLComponents] = []

    func searchState(page: Int) -> SearchState? { searchJournal.last { $0.page == page }?.state }

    /// Answers the held request for `page` (normally, or with `error`); false when none is held.
    @discardableResult
    func releaseSearch(page: Int, failingWith error: Error? = nil) -> Bool {
        guard let entry = searchJournal.lastIndex(where: { $0.page == page && $0.state == .held }),
              let continuation = heldSearches.removeValue(forKey: entry)?.continuation else { return false }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        return true
    }

    func releaseAllHeldSearches() {
        let pending = heldSearches; heldSearches = [:]
        pending.values.forEach { $0.continuation?.resume(throwing: CancellationError()) }
    }
    private(set) var detailRequests: [String] = []
    private(set) var downloads: [URL] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body: Data
        if url.path.hasSuffix("/search") {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            searches.append(components)
            let page = Int(components.queryItems?.first { $0.name == "page" }?.value ?? "1") ?? 1
            let entry = searchJournal.count
            searchJournal.append((page, holdsSearches ? .held : .answered))
            if holdsSearches {
                do {
                    let hold = Hold()
                    heldSearches[entry] = hold
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in hold.continuation = continuation }
                    searchJournal[entry].state = .answered
                } catch {
                    searchJournal[entry].state = .failed
                    throw error
                }
            }
            let items = pageItems.map { item -> [String: Any] in
                var copy = item
                if page > 1 { copy["id"] = "\(item["id"]!)p\(page)" }
                return copy
            }
            body = CompositionFixtures.searchJSON(items, page: page, lastPage: lastPage)
        } else {
            detailRequests.append(url.lastPathComponent)
            body = details[url.lastPathComponent].map(CompositionFixtures.detailJSON) ?? Data()
        }
        return (body, HTTPURLResponse(url: url, statusCode: apiStatus, httpVersion: "HTTP/1.1", headerFields: apiHeaders)!)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        downloads.append(request.url!)
        if let gate = downloadGate { try await gate.value() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("wallpier-batch2-\(UUID()).png")
        if let originalFile, downloadStatus == 200 { try FileManager.default.copyItem(at: originalFile, to: temporary) }
        else { try Data().write(to: temporary) }
        return (temporary, HTTPURLResponse(url: request.url!, statusCode: downloadStatus, httpVersion: "HTTP/1.1", headerFields: downloadHeaders)!)
    }
}

final class SizedScreen: NSScreen {
    private let number: Int
    var size: NSSize, scale: CGFloat
    init(_ number: Int, _ size: NSSize, scale: CGFloat) { self.number = number; self.size = size; self.scale = scale; super.init() }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var localizedName: String { "Display \(number)" }
    override var frame: NSRect { NSRect(origin: .zero, size: size) }
    override var backingScaleFactor: CGFloat { scale }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] { [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: number)] }
}

extension WallpierTests {
    @MainActor
    private func batch2Controller(_ network: Batch2Network, _ thumbnails: CompositionThumbnails = CompositionThumbnails(),
                                  items: [[String: Any]] = CompositionFixtures.shapeListings(), screens: [NSScreen]? = nil,
                                  desktop: WallpaperService = SetAuditWallpaperService(),
                                  configure: (inout WallpaperState) -> Void = { _ in }) async throws -> (MainWindowController, NSWindow, URL) {
        network.pageItems = items
        for item in items {
            thumbnails.sizes[item["id"] as! String] = CGSize(width: item["dimension_x"] as! Int, height: item["dimension_y"] as! Int)
        }
        let decoded = try await WallhavenProvider(client: StubNetworkClient(data: CompositionFixtures.searchJSON(items)))
            .search(options: WallhavenSearchOptions(), page: 1)
        let page = RemoteSearchPage(wallpapers: decoded.wallpapers, currentPage: 1, lastPage: network.lastPage, total: 40,
                                    rateLimit: decoded.rateLimit)
        let root = try historyTestFolder()
        let (controller, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                         network: network, desktop: desktop, thumbnails: thumbnails, page: page,
                                                         screens: screens, configure: configure)
        addTeardownBlock {
            let tasks = await MainActor.run { () -> [Task<Void, Never>] in
                let tasks = [controller.downloadTask, controller.searchTask, controller.detailTask, controller.undoValidationTask].compactMap { $0 }
                tasks.forEach { $0.cancel() }
                network.downloadGate?.release(.failure(CancellationError()))
                network.releaseAllHeldSearches()
                while let sheet = window.attachedSheet { window.endSheet(sheet) }
                window.close()
                return tasks
            }
            for task in tasks { await task.value }
            try? FileManager.default.removeItem(at: root)
        }
        return (controller, window, root)
    }

    @MainActor
    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    @MainActor
    private func pause(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    @MainActor
    private func notice(_ controller: MainWindowController) -> String {
        controller.approximatePreviewNotice.isHidden ? "" : controller.approximatePreviewNotice.accessibilityLabel() ?? ""
    }

    private func value(_ components: URLComponents?, _ name: String) -> String? {
        components?.queryItems?.first { $0.name == name }?.value
    }

    /// Renders the stage's current source with production drawing and checks, on a grid, that each
    /// pixel shows the part of the original that the display would show at that point.
    @MainActor
    private func compositionErrors(_ stage: DesktopPreviewView, _ scaling: ScalingMode) -> [String] {
        let view = DesktopPreviewView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        view.image = stage.image
        view.imagePixelSize = stage.imagePixelSize
        view.displayPixelSize = stage.displayPixelSize
        view.scaling = scaling
        // Draw into an sRGB bitmap, the pattern's own space, so pixels are read back without colour conversion.
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        guard view.image != nil, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ["no image"] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let imageRect = DesktopPreviewView.imageRect(in: view.stageRect, image: view.imagePixelSize, display: view.displayPixelSize, scaling: scaling)
        let area = view.stageRect.insetBy(dx: 5, dy: 5).intersection(imageRect.insetBy(dx: 3, dy: 3))
        var errors: [String] = []
        for fx in [0.0, 0.25, 0.5, 0.75, 1.0] {
            for fy in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let point = CGPoint(x: area.minX + area.width * fx, y: area.minY + area.height * fy)
                let u = (point.x - imageRect.minX) / imageRect.width, v = (imageRect.maxY - point.y) / imageRect.height
                let offset = (height - 1 - Int(point.y)) * context.bytesPerRow + Int(point.x) * 4
                let red = CGFloat(pixels[offset]) / 255, green = CGFloat(pixels[offset + 1]) / 255
                if abs(red - u) > 0.05 || abs(green - v) > 0.05 {
                    errors.append(String(format: "original (%.2f, %.2f) drawn as (%.2f, %.2f)", u, v, red, green))
                }
            }
        }
        return errors
    }

    // MARK: Preview (D3)

    // Each shape is drawn from a thumbnail that holds the whole original: Fill, Fit and Center then show
    // the region of the original the display would. 16:9 keeps the sharper 432-pixel crop, which is whole.
    @MainActor
    func testPreviewDrawsTheWholeCompositionForSixSourceShapes() async throws {
        let network = Batch2Network(), thumbnails = CompositionThumbnails()
        let (c, _, _) = try await batch2Controller(network, thumbnails)
        c.showDiscover(nil)
        c.toggleViewer(nil)
        for (index, shape) in CompositionFixtures.shapes.enumerated() {
            if index > 0 { c.nextWallpaper(nil) }
            XCTAssertEqual(c.previewTitleLabel.stringValue, shape.id)
            let shown = await eventually { thumbnails.kind(of: c.stageView.image) != nil }
            XCTAssertTrue(shown, shape.name)
            XCTAssertEqual(thumbnails.kind(of: c.stageView.image), shape.name == "16:9" ? "lg" : "orig", "\(shape.name) preview source")
            XCTAssertTrue(notice(c).hasPrefix("Low-resolution preview"), "\(shape.name): \(notice(c))")
            for mode in ScalingMode.allCases {
                let errors = compositionErrors(c.stageView, mode)
                XCTAssertTrue(errors.isEmpty, "\(shape.name) \(mode): \(errors.prefix(3))")
            }
        }
        XCTAssertTrue(network.downloads.isEmpty, "Previewing never downloads an original")
    }

    // Without an aspect-preserving thumbnail the cropped one is labelled as such; the selected item's
    // details supply the missing thumbnail and the preview upgrades in place, or stays labelled.
    @MainActor
    func testMissingUncroppedThumbnailIsLabelledThenUpgradedFromDetails() async throws {
        let network = Batch2Network(), thumbnails = CompositionThumbnails()
        network.details = ["cmpmiss": CompositionFixtures.listing(id: "cmpmiss", width: 3440, height: 1440, uploader: "u", tags: ["t"]),
                           "cmpnone": CompositionFixtures.listing(id: "cmpnone", width: 1200, height: 2133, original: false, uploader: "u", tags: ["t"])]
        let (c, _, _) = try await batch2Controller(network, thumbnails, items: [
            CompositionFixtures.listing(id: "cmpmiss", width: 3440, height: 1440, original: false),
            CompositionFixtures.listing(id: "cmpnone", width: 1200, height: 2133, original: false)])
        c.showDiscover(nil)
        c.toggleViewer(nil)
        XCTAssertEqual(thumbnails.kind(of: c.stageView.image), "lg")
        XCTAssertTrue(notice(c).localizedCaseInsensitiveContains("cropped"), notice(c))
        let upgraded = await eventually { thumbnails.kind(of: c.stageView.image) == "orig" }
        XCTAssertTrue(upgraded, "The selected wallpaper's details supply its uncropped thumbnail")
        XCTAssertTrue(notice(c).hasPrefix("Low-resolution preview"), notice(c))
        XCTAssertTrue(compositionErrors(c.stageView, .fit).isEmpty)

        c.nextWallpaper(nil)
        _ = await eventually { network.detailRequests.contains("cmpnone") }
        await pause(0.3)
        XCTAssertEqual(thumbnails.kind(of: c.stageView.image), "lg")
        XCTAssertTrue(notice(c).localizedCaseInsensitiveContains("cropped"), "Still a cropped approximation: \(notice(c))")
    }

    // References saved before thumbs.original was kept still decode, preview as a labelled crop, and
    // gain (and persist) the uncropped thumbnail once their details are fetched.
    @MainActor
    func testLegacyFavoriteDecodesAndGainsItsUncroppedThumbnail() async throws {
        let legacy = """
        {"providerIdentifier":"wallhaven","wallpaperID":"cmp329","sourcePageURL":"https://wallhaven.cc/w/cmp329",
         "originalURL":"https://w.wallhaven.cc/full/cm/wallhaven-cmp329.png","previewURL":"https://th.wallhaven.cc/lg/cm/cmp329.jpg",
         "thumbnailURL":"https://th.wallhaven.cc/small/cm/cmp329.jpg","width":5120,"height":1440,"tags":[]}
        """
        let reference = try JSONDecoder().decode(WallpaperReference.self, from: Data(legacy.utf8))
        let network = Batch2Network(), thumbnails = CompositionThumbnails()
        network.details = ["cmp329": CompositionFixtures.listing(id: "cmp329", width: 5120, height: 1440, uploader: "u", tags: ["wide"])]
        let (c, _, root) = try await batch2Controller(network, thumbnails) { state in
            state.favorites = [reference]
            state.selectedRemoteIdentity = reference.identityKey
        }
        c.showFavorites(nil)
        c.toggleViewer(nil)
        XCTAssertTrue(notice(c).localizedCaseInsensitiveContains("cropped"), notice(c))
        let upgraded = await eventually { thumbnails.kind(of: c.stageView.image) == "orig" }
        XCTAssertTrue(upgraded)
        XCTAssertTrue(notice(c).hasPrefix("Low-resolution preview"), notice(c))
        let saved = try String(contentsOf: root.appendingPathComponent("state.json"))
        XCTAssertTrue(saved.replacingOccurrences(of: "\\/", with: "/").contains("th.wallhaven.cc/orig/cm/cmp329.jpg"))
    }

    // A validated cached original is the preview, even for a fresh search result that doesn't know its
    // cached path; a saved path to a damaged file is not trusted.
    @MainActor
    func testCachedOriginalTakesPrecedenceAndADamagedPathFallsBack() async throws {
        let network = Batch2Network(), thumbnails = CompositionThumbnails()
        let references = try await WallhavenProvider(client: StubNetworkClient(data: CompositionFixtures.searchJSON(CompositionFixtures.shapeListings())))
            .search(options: WallhavenSearchOptions(), page: 1).wallpapers
        let elsewhere = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let damaged = elsewhere.appendingPathComponent("damaged.png")
        try Data("not an image".utf8).write(to: damaged)
        var favorite = references[4]
        favorite.cachedLocalPath = damaged.path
        let (c, _, root) = try await batch2Controller(network, thumbnails) { state in
            state.favorites = [favorite]
            state.selectedRemoteIdentity = favorite.identityKey
        }
        let wide = c.remoteResults[5]
        XCTAssertNil(wide.cachedLocalPath)
        try CompositionFixtures.writeOriginal(CGSize(width: 5120, height: 1440),
                                              to: root.appendingPathComponent("Originals").appendingPathComponent(RemoteWallpaperCache.filename(for: wide)))
        c.showDiscover(nil)
        for _ in 0..<6 where c.previewTitleLabel.stringValue != wide.wallpaperID { c.nextWallpaper(nil) }
        XCTAssertEqual(c.previewTitleLabel.stringValue, wide.wallpaperID)
        c.toggleViewer(nil)
        let original = await eventually { c.stageView.image != nil && thumbnails.kind(of: c.stageView.image) == nil }
        XCTAssertTrue(original, "The cached original is drawn")
        XCTAssertEqual(notice(c), "")
        for mode in ScalingMode.allCases { XCTAssertTrue(compositionErrors(c.stageView, mode).isEmpty, "\(mode)") }

        // A saved path to a damaged file: the uncropped thumbnail, honestly labelled.
        c.showFavorites(nil)
        c.toggleViewer(nil)
        let fallback = await eventually { thumbnails.kind(of: c.stageView.image) == "orig" }
        XCTAssertTrue(fallback)
        XCTAssertTrue(notice(c).hasPrefix("Low-resolution preview"), notice(c))
        XCTAssertTrue(network.downloads.isEmpty)
    }

    // A Set that downloads the original refreshes the preview only while that wallpaper is still
    // selected; late thumbnail callbacks never replace an original with a thumbnail.
    @MainActor
    func testDownloadedOriginalRefreshesOnlyTheStillSelectedPreview() async throws {
        let network = Batch2Network(), thumbnails = CompositionThumbnails(), desktop = SetAuditWallpaperService()
        let (c, _, root) = try await batch2Controller(network, thumbnails, desktop: desktop)
        let ultrawide = root.appendingPathComponent("ultrawide.png"), superwide = root.appendingPathComponent("superwide.png")
        try CompositionFixtures.writeOriginal(CGSize(width: 3440, height: 1440), to: ultrawide)
        try CompositionFixtures.writeOriginal(CGSize(width: 5120, height: 1440), to: superwide)
        c.showDiscover(nil)
        for _ in 0..<4 { c.nextWallpaper(nil) }
        thumbnails.holds = true
        c.toggleViewer(nil)
        XCTAssertEqual(c.previewTitleLabel.stringValue, "cmp219")

        network.originalFile = ultrawide
        c.setWallpaper(nil)
        try await finishAuditTask(c.downloadTask)
        XCTAssertEqual(desktop.calls.count, 1)
        let refreshed = await eventually { c.stageView.image != nil && thumbnails.kind(of: c.stageView.image) == nil }
        XCTAssertTrue(refreshed, "The still-selected preview shows the downloaded original")
        XCTAssertEqual(notice(c), "")
        thumbnails.holds = false
        thumbnails.releaseHeld()
        XCTAssertNil(thumbnails.kind(of: c.stageView.image), "A late thumbnail must not replace the original")
        XCTAssertEqual(notice(c), "")
        XCTAssertTrue(compositionErrors(c.stageView, .fit).isEmpty)

        // The selection moves on while the next download runs: each preview keeps its own source.
        c.nextWallpaper(nil)
        XCTAssertEqual(c.previewTitleLabel.stringValue, "cmp329")
        let gate = SetAuditGate<Void>()
        network.downloadGate = gate
        network.originalFile = superwide
        c.setWallpaper(nil)
        await fulfillment(of: [gate.started], timeout: 2)
        c.previousWallpaper(nil)
        let back = await eventually { c.stageView.image != nil && thumbnails.kind(of: c.stageView.image) == nil }
        XCTAssertTrue(back)
        let shownBefore = c.stageView.image
        gate.release(.success(()))
        try await finishAuditTask(c.downloadTask)
        await pause(0.3)
        XCTAssertEqual(c.previewTitleLabel.stringValue, "cmp219")
        XCTAssertTrue(c.stageView.image === shownBefore, "The other wallpaper's download leaves this preview alone")
        c.nextWallpaper(nil)
        let cached = await eventually { c.stageView.image != nil && thumbnails.kind(of: c.stageView.image) == nil }
        XCTAssertTrue(cached, "Returning to the downloaded wallpaper shows its original")
        XCTAssertEqual(notice(c), "")
        XCTAssertEqual(network.downloads.count, 2)
    }

    // MARK: Network (D4)

    // The gallery shows no detail metadata, so browsing it fetches none; arrowing through the preview
    // fetches only the wallpaper the user stops on; reselecting it doesn't fetch again.
    @MainActor
    func testRapidSelectionStartsDetailRequestsOnlyForTheSettledPreview() async throws {
        let network = Batch2Network()
        // Details for both result pages: Discover's preview stops at the loaded results and loads the next page
        // instead of wrapping, so browsing reaches page 2 (whose wallpaper IDs end in "p2").
        network.details = Dictionary(uniqueKeysWithValues: CompositionFixtures.shapes.flatMap { shape in
            [shape.id, "\(shape.id)p2"].map { ($0, CompositionFixtures.listing(id: $0, width: shape.width, height: shape.height, tags: [])) }
        })
        let (c, _, _) = try await batch2Controller(network)
        c.showDiscover(nil)
        for _ in 0..<30 { c.nextWallpaper(nil); await pause(0.005) }
        await pause(0.7)
        XCTAssertEqual(network.detailRequests, [], "Gallery browsing starts no detail requests")
        c.toggleViewer(nil)
        for _ in 0..<30 { c.nextWallpaper(nil); await pause(0.005) }
        let settled = c.previewTitleLabel.stringValue
        _ = await eventually { !network.detailRequests.isEmpty }
        await pause(0.5)
        XCTAssertEqual(network.detailRequests, [settled], "Only the settled preview's details are requested")
        // Clicking the same wallpaper again or reopening the preview doesn't repeat it, even without tags.
        let index = try XCTUnwrap(c.collectionView.selectionIndexPaths.first)
        for _ in 0..<3 { c.collectionView(c.collectionView, didSelectItemsAt: [index]) }
        c.toggleViewer(nil)
        c.toggleViewer(nil)
        await pause(0.5)
        XCTAssertEqual(network.detailRequests, [settled])
    }

    // A metadata 429 keeps throttling metadata, but doesn't stop Set downloading an uncached original;
    // a second Set while one runs never starts a second download.
    @MainActor
    func testMetadataRateLimitDoesNotBlockAnEligibleOriginalDownload() async throws {
        let network = Batch2Network(), desktop = SetAuditWallpaperService()
        let (c, window, root) = try await batch2Controller(network, desktop: desktop)
        network.originalFile = root.appendingPathComponent("download.png")
        try CompositionFixtures.writeOriginal(CGSize(width: 3840, height: 2160), to: try XCTUnwrap(network.originalFile))
        network.apiStatus = 429
        network.apiHeaders = ["Retry-After": "60"]
        c.showDiscover(nil)
        c.toggleViewer(nil)
        let asked = await eventually { network.detailRequests.count == 1 }
        XCTAssertTrue(asked)
        await pause(0.1)
        let gate = SetAuditGate<Void>()
        network.downloadGate = gate
        c.setWallpaper(nil)
        await fulfillment(of: [gate.started], timeout: 2)
        c.setWallpaper(nil)
        gate.release(.success(()))
        try await finishAuditTask(c.downloadTask)
        while let sheet = window.attachedSheet { window.endSheet(sheet) }
        XCTAssertEqual(network.downloads.count, 1, c.statusLabel.stringValue)
        XCTAssertEqual(desktop.calls.count, 1, c.statusLabel.stringValue)
        // Metadata stays throttled: neither another preview's details nor a search reach Wallhaven.
        c.nextWallpaper(nil)
        c.search(nil)
        await pause(0.6)
        XCTAssertEqual(network.detailRequests.count, 1)
        XCTAssertTrue(network.searches.isEmpty)
    }

    // A successful API response that exhausts the quota throttles metadata, not originals.
    @MainActor
    func testExhaustedMetadataQuotaStillAllowsAnOriginalDownload() async throws {
        let network = Batch2Network(), desktop = SetAuditWallpaperService()
        let (c, _, root) = try await batch2Controller(network, desktop: desktop)
        network.originalFile = root.appendingPathComponent("download.png")
        try CompositionFixtures.writeOriginal(CGSize(width: 3840, height: 2160), to: try XCTUnwrap(network.originalFile))
        network.details = ["cmp169": CompositionFixtures.listing(id: "cmp169", width: 3840, height: 2160, uploader: "u", tags: ["t"])]
        network.apiHeaders = ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(Date().timeIntervalSince1970) + 60)]
        c.showDiscover(nil)
        c.toggleViewer(nil)
        let detailed = await eventually { c.previewMetadataLabel.stringValue.contains("by u") }
        XCTAssertTrue(detailed)
        c.setWallpaper(nil)
        try await finishAuditTask(c.downloadTask)
        XCTAssertEqual(network.downloads.count, 1)
        XCTAssertEqual(desktop.calls.count, 1, c.statusLabel.stringValue)
        c.nextWallpaper(nil)
        await pause(0.6)
        XCTAssertEqual(network.detailRequests, ["cmp169"], "The exhausted quota still holds back metadata")
    }

    // A genuine original-download 429 is honoured for originals only; the failed Set releases its guard,
    // metadata keeps working, and Set recovers once Retry-After has passed.
    @MainActor
    func testOriginalRateLimitIsHonouredSeparatelyAndRecovers() async throws {
        let network = Batch2Network(), desktop = SetAuditWallpaperService()
        let (c, window, root) = try await batch2Controller(network, desktop: desktop)
        network.originalFile = root.appendingPathComponent("download.png")
        try CompositionFixtures.writeOriginal(CGSize(width: 3840, height: 2160), to: try XCTUnwrap(network.originalFile))
        network.details = ["cmp169": CompositionFixtures.listing(id: "cmp169", width: 3840, height: 2160, uploader: "u", tags: ["t"]),
                           "cmp1610": CompositionFixtures.listing(id: "cmp1610", width: 2560, height: 1600, uploader: "u", tags: ["t"])]
        network.downloadStatus = 429
        network.downloadHeaders = ["Retry-After": "3"]
        c.showDiscover(nil)
        c.setWallpaper(nil)
        try await finishAuditTask(c.downloadTask)
        while let sheet = window.attachedSheet { window.endSheet(sheet) }
        XCTAssertEqual(network.downloads.count, 1)
        XCTAssertTrue(desktop.calls.isEmpty)
        XCTAssertNil(c.downloadTask)
        XCTAssertTrue(c.setWallpaperButton.isEnabled, "A failed Set releases its guard")
        XCTAssertTrue(c.statusLabel.stringValue.contains("rate-limiting"), c.statusLabel.stringValue)
        c.setWallpaper(nil)
        try await finishAuditTask(c.downloadTask)
        while let sheet = window.attachedSheet { window.endSheet(sheet) }
        XCTAssertEqual(network.downloads.count, 1, "Within Retry-After no second original request starts")

        c.toggleViewer(nil)
        c.nextWallpaper(nil)
        let detailed = await eventually { network.detailRequests.contains("cmp1610") }
        XCTAssertTrue(detailed, "Metadata is a different origin and stays available: \(network.detailRequests)")

        await pause(3.1)
        network.downloadStatus = 200
        network.downloadHeaders = [:]
        c.setWallpaper(nil)
        try await finishAuditTask(c.downloadTask)
        XCTAssertEqual(network.downloads.count, 2)
        XCTAssertEqual(desktop.calls.count, 1, c.statusLabel.stringValue)
    }

    // A cached original needs no network: it sets while metadata is throttled.
    @MainActor
    func testCachedOriginalSetsWithoutNetworkDuringMetadataThrottling() async throws {
        let network = Batch2Network(), desktop = SetAuditWallpaperService()
        let (c, _, root) = try await batch2Controller(network, desktop: desktop)
        try CompositionFixtures.writeOriginal(CGSize(width: 3840, height: 2160), to: root.appendingPathComponent("Originals")
            .appendingPathComponent(RemoteWallpaperCache.filename(for: c.remoteResults[0])))
        network.apiStatus = 429
        network.apiHeaders = ["Retry-After": "60"]
        c.showDiscover(nil)
        c.toggleViewer(nil)
        _ = await eventually { network.detailRequests.count == 1 }
        c.setWallpaper(nil)
        try await finishAuditTask(c.downloadTask)
        XCTAssertTrue(network.downloads.isEmpty)
        XCTAssertEqual(desktop.calls.count, 1, c.statusLabel.stringValue)
    }

    // MARK: Discover (D5)

    // Edited search text leaves the results described by the query that produced them, and scrolling
    // extends them with that same query until Return applies the new one.
    @MainActor
    func testEditedQueryKeepsResultsDescribedAndPaginatesWithTheAppliedQuery() async throws {
        let network = Batch2Network()
        network.lastPage = 30
        let (c, window, _) = try await batch2Controller(network)
        c.showDiscover(nil)
        await pause(0.3)
        XCTAssertTrue(window.subtitle.contains("“landscape”"), window.subtitle)
        c.searchField.stringValue = "forest"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
        let shown = c.remoteResults.count
        XCTAssertGreaterThanOrEqual(shown, 6)
        XCTAssertTrue(window.subtitle.contains("“landscape”"), "Results still name their query: \(window.subtitle)")
        XCTAssertFalse(c.pendingSearchLabel.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(c.pendingSearchLabel.stringValue, "Showing “landscape”")
        XCTAssertFalse(c.updateResultsButton.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(c.updateResultsButton.toolTip, "Search Wallhaven for “forest”")
        let before = network.searches.count
        c.collectionView.scroll(NSPoint(x: 0, y: c.collectionView.frame.height))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: c.galleryScrollForTesting.contentView)
        let paged = await eventually { network.searches.count > before && c.remoteResults.count > shown }
        XCTAssertTrue(paged, "Scrolling keeps extending the visible results")
        XCTAssertEqual(Set(network.searches.map { value($0, "q") }), ["landscape"], "Pages match the results' own query")

        c.updateResultsButton.performClick(nil)
        let applied = await eventually { window.subtitle.contains("“forest”") }
        XCTAssertTrue(applied, window.subtitle)
        XCTAssertTrue(c.pendingSearchLabel.isHidden)
        XCTAssertTrue(c.updateResultsButton.isHidden)
        let forest = network.searches.filter { value($0, "q") == "forest" }
        XCTAssertEqual(value(forest.first, "page"), "1")
        XCTAssertEqual(c.state.wallhavenSearch.query, "forest")
    }

    // A display-derived minimum change keeps the results, which paginate with their own minimum until
    // the search is applied again.
    @MainActor
    func testDisplayDerivedMinimumChangeKeepsResultsAndTheirMinimum() async throws {
        let network = Batch2Network()
        network.lastPage = 30
        let screens = [SizedScreen(601, NSSize(width: 1440, height: 900), scale: 2), SizedScreen(602, NSSize(width: 1920, height: 1080), scale: 1)]
        let (c, _, _) = try await batch2Controller(network, screens: screens) { state in
            state.selectedDisplayID = "601"
            state.wallhavenSearch.usesDisplayMinimum = true
            state.wallhavenSearch.minimumWidth = 2880
            state.wallhavenSearch.minimumHeight = 1800
        }
        c.showDiscover(nil)
        await pause(0.3)
        c.displayPopUp.selectItem(at: 1)
        c.displaySelectionChanged()
        XCTAssertEqual(c.state.wallhavenSearch.minimumResolution, "1920x1080")
        XCTAssertEqual(c.pendingSearchLabel.stringValue, "Showing results for the previous display size")
        XCTAssertFalse(c.updateResultsButton.isHidden)
        let shown = c.remoteResults.count, before = network.searches.count
        c.collectionView.scroll(NSPoint(x: 0, y: c.collectionView.frame.height))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: c.galleryScrollForTesting.contentView)
        let paged = await eventually { network.searches.count > before && c.remoteResults.count > shown }
        XCTAssertTrue(paged)
        XCTAssertEqual(Set(network.searches.map { value($0, "atleast") }), ["2880x1800"])
        c.search(nil)
        let applied = await eventually { network.searches.contains { value($0, "atleast") == "1920x1080" } }
        XCTAssertTrue(applied)
        XCTAssertEqual(value(network.searches.first { value($0, "atleast") == "1920x1080" }, "page"), "1")
        let settled = await eventually { c.searchTask != nil && c.pendingSearchLabel.isHidden }
        XCTAssertTrue(settled)
    }

    // Leaving Discover and coming back keeps its results and their description without searching again.
    @MainActor
    func testSwitchingSourcesKeepsDiscoverResultsAndTheirDescription() async throws {
        let network = Batch2Network()
        let (c, window, _) = try await batch2Controller(network)
        c.showDiscover(nil)
        await pause(0.3)
        c.searchField.stringValue = "forest"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
        let results = c.remoteResults, before = network.searches.count
        c.showFavorites(nil)
        c.showDiscover(nil)
        await pause(0.3)
        XCTAssertEqual(network.searches.count, before)
        XCTAssertEqual(c.remoteResults, results)
        XCTAssertEqual(c.searchField.stringValue, "forest")
        XCTAssertTrue(window.subtitle.contains("“landscape”"), window.subtitle)
        XCTAssertEqual(c.pendingSearchLabel.stringValue, "Showing “landscape”")
        XCTAssertFalse(c.pendingSearchLabel.isHiddenOrHasHiddenAncestor)
    }

    // Filters apply at once, together with any edited text, and the results then describe exactly that request.
    @MainActor
    func testFilterChangeSearchesImmediatelyWithTheVisibleControls() async throws {
        let network = Batch2Network()
        let (c, window, _) = try await batch2Controller(network)
        c.showDiscover(nil)
        await pause(0.3)
        c.searchField.stringValue = "forest"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
        c.categoryPopUp.selectItem(at: WallhavenCategory.allCases.firstIndex(of: .general)!)
        NSApp.sendAction(try XCTUnwrap(c.categoryPopUp.action), to: c.categoryPopUp.target, from: c.categoryPopUp)
        let applied = await eventually { window.subtitle.contains("“forest”") }
        XCTAssertTrue(applied, window.subtitle)
        let first = try XCTUnwrap(network.searches.first { value($0, "categories") == "100" })
        XCTAssertEqual(value(first, "q"), "forest")
        XCTAssertEqual(value(first, "page"), "1")
        XCTAssertEqual(c.remoteResults.first?.wallpaperID, "cmp169")
        XCTAssertTrue(c.pendingSearchLabel.isHidden)
        XCTAssertTrue(network.searches.allSatisfy { value($0, "categories") == "100" && value($0, "q") == "forest" })
    }

    // Search is Wallhaven's: typing outside Discover says where Return will take it, and gallery
    // cells describe their wallpaper's size and orientation, not only its opaque ID.
    @MainActor
    func testSearchScopeAndGalleryDescriptionsAreExplicit() async throws {
        let network = Batch2Network()
        let (c, window, _) = try await batch2Controller(network)
        c.showDiscover(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let portrait = try XCTUnwrap(c.collectionView.item(at: IndexPath(item: 3, section: 0)))
        XCTAssertEqual(portrait.view.accessibilityLabel(), "cmpport")
        XCTAssertEqual(portrait.view.accessibilityHelp(), "Wallhaven cmpport — 1200 × 2133, portrait")
        XCTAssertEqual(c.collectionView.item(at: IndexPath(item: 2, section: 0))?.view.accessibilityHelp(), "Wallhaven cmpsq — 2000 × 2000, square")
        c.showFavorites(nil)
        c.searchField.stringValue = "forest"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
        XCTAssertEqual(c.statusLabel.stringValue, "Press Return to search Wallhaven in Discover.")
        XCTAssertEqual(c.state.currentSource, .favorites, "Typing never filters the library")
        XCTAssertTrue(window.subtitle.hasSuffix("wallpapers"))
    }

    // Wallhaven has no relevance order without search text; the request asks for this month's top
    // wallpapers, and that is what the results say they are.
    @MainActor
    func testEmptyQueryRelevanceIsPresentedAsTheTopListItRequests() async throws {
        let network = Batch2Network()
        let (c, window, _) = try await batch2Controller(network) { state in
            state.wallhavenSearch.query = ""
            state.wallhavenSearch.sorting = .relevance
        }
        c.showDiscover(nil)
        c.search(nil)
        let done = await eventually { network.searches.count >= 1 && c.searchTask != nil && !window.subtitle.isEmpty }
        XCTAssertTrue(done)
        await pause(0.3)
        XCTAssertEqual(value(network.searches.first, "sorting"), "toplist")
        XCTAssertEqual(value(network.searches.first, "topRange"), "1M")
        XCTAssertTrue(window.subtitle.contains("Top This Month"), window.subtitle)
    }

    // ⌘F elsewhere opens Discover with the draft search, without searching again.
    @MainActor
    func testFindFromAnotherSourceOpensDiscoverWithTheDraftSearch() async throws {
        let network = Batch2Network()
        let (c, _, _) = try await batch2Controller(network)
        XCTAssertEqual(c.state.currentSource, .favorites)
        c.focusSearch(nil)
        XCTAssertEqual(c.state.currentSource, .discover)
        XCTAssertEqual(c.searchField.stringValue, "landscape")
        await pause(0.3)
        XCTAssertTrue(network.searches.isEmpty)
        XCTAssertFalse(c.remoteResults.isEmpty)
    }

    // MARK: Batch 2 repairs

    // Malformed throttle headers fall back to the default wait instead of an infinite, negative or absurd
    // one; valid seconds, HTTP dates and reset timestamps keep their meaning, and every message formats.
    func testMalformedThrottleHeadersFallBackToTheDefaultWait() async throws {
        let url = URL(string: "https://wallhaven.cc/api/v1/search")!
        func throttle(_ headers: [String: String]) async throws -> (delay: TimeInterval, messages: [String]) {
            let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: headers)!
            let provider = WallhavenProvider(client: SequencedNetworkClient(responses: [(Data(), response)]))
            do { _ = try await provider.search(options: WallhavenSearchOptions(), page: 1) }
            catch RemoteProviderError.rateLimited(let delay?) {
                // The provider's own backoff then reports the remaining wait, which must format too.
                do { _ = try await provider.search(options: WallhavenSearchOptions(), page: 2) }
                catch { return (delay, [RemoteProviderError.rateLimited(retryAfter: delay).localizedDescription, error.localizedDescription]) }
            }
            XCTFail("Expected a held rate limit for \(headers)")
            return (0, [])
        }
        func httpDate(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
            return formatter.string(from: date)
        }
        let malformed: [[String: String]] = ["inf", "-inf", "nan", "1e309", "-5", "soon", "", "99999999", "Fri, 31 Dec 9999 23:59:59 GMT"]
            .map { ["Retry-After": $0] } + [[:], ["x-ratelimit-reset": "inf"], ["x-ratelimit-reset": "1e309"], ["ratelimit-reset": "nan"]]
        for headers in malformed {
            let (delay, messages) = try await throttle(headers)
            XCTAssertEqual(delay, 60, "\(headers)")
            XCTAssertEqual(messages.count, 2)
            messages.forEach { XCTAssertTrue($0.contains("about 60 seconds") || $0.contains("about 59 seconds"), "\(headers): \($0)") }
        }
        let valid: [([String: String], ClosedRange<TimeInterval>)] = [
            (["Retry-After": "7"], 7...7),
            (["Retry-After": httpDate(Date().addingTimeInterval(30))], 28...30),
            (["Retry-After": "Thu, 01 Jan 1970 00:00:00 GMT"], 1...1),
            (["x-ratelimit-reset": String(Int(Date().timeIntervalSince1970) + 20)], 18...20),
        ]
        for (headers, range) in valid {
            let delay = try await throttle(headers).delay
            XCTAssertTrue(range.contains(delay), "\(headers): \(delay)")
        }
        for delay in [TimeInterval.infinity, -.infinity, .nan, 1e300, -1e300] {
            XCTAssertNotNil(RemoteProviderError.rateLimited(retryAfter: delay).errorDescription)
        }
    }

    // An exhausted quota with a malformed reset never suppresses requests; a valid throttle holds back only
    // its own origin and lets the next request through once it has passed.
    @MainActor
    func testMalformedResetNeverSuppressesAndAValidThrottleRecovers() async throws {
        let url = URL(string: "https://wallhaven.cc/api/v1/search")!
        let ok = try fixtureData(named: "wallhaven-search")
        for reset in ["inf", "1e309", "nan", "-inf"] {
            let exhausted = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                            headerFields: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": reset])!
            let client = SequencedNetworkClient(responses: [(ok, exhausted)])
            let provider = WallhavenProvider(client: client, cacheLifetime: 0)
            let page = try await provider.search(options: WallhavenSearchOptions(), page: 1)
            XCTAssertNil(page.rateLimit.resetDate, reset)
            _ = try await provider.search(options: WallhavenSearchOptions(), page: 1)
            XCTAssertEqual(client.requestCount, 2, reset)
        }

        let limited = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "1"])!
        let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let client = SequencedNetworkClient(responses: [(Data(), limited), (ok, success)])
        let provider = WallhavenProvider(client: client, cacheLifetime: 0)
        for _ in 0..<2 {
            do { _ = try await provider.search(options: WallhavenSearchOptions(), page: 1); XCTFail("Expected the valid throttle") }
            catch RemoteProviderError.rateLimited { }
        }
        XCTAssertEqual(client.requestCount, 1, "A valid Retry-After holds the API back")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = try await provider.search(options: WallhavenSearchOptions(), page: 1)
        XCTAssertEqual(client.requestCount, 2, "and lets it through once it has passed")

        // A malformed original-download throttle uses the default wait for originals only.
        let network = Batch2Network()
        network.downloadStatus = 429
        network.downloadHeaders = ["Retry-After": "inf"]
        let downloads = WallhavenProvider(client: network, cacheLifetime: 0)
        for _ in 0..<2 {
            do { _ = try await downloads.downloadOriginal(for: remoteReference(id: "abc")); XCTFail("Expected a rate limit") }
            catch RemoteProviderError.rateLimited(let delay) { XCTAssertLessThanOrEqual(delay ?? .infinity, 60) }
        }
        XCTAssertEqual(network.downloads.count, 1)
        _ = try await downloads.search(options: WallhavenSearchOptions(), page: 1)
        XCTAssertEqual(network.searches.count, 1, "The API is a separate origin")
    }

    // Closing the preview during the metadata dwell starts no request; reopening still fetches what's
    // missing, fetched details stay, and only the current selection in a visible preview is eligible.
    @MainActor
    func testClosingThePreviewDuringTheDwellStartsNoDetailRequest() async throws {
        let network = Batch2Network()
        network.details = Dictionary(uniqueKeysWithValues: CompositionFixtures.shapes.map {
            ($0.id, CompositionFixtures.listing(id: $0.id, width: $0.width, height: $0.height, uploader: "u", tags: ["t"]))
        })
        let (c, _, _) = try await batch2Controller(network)
        c.showDiscover(nil)
        let first = c.previewTitleLabel.stringValue
        c.toggleViewer(nil)
        await pause(0.1)
        c.toggleViewer(nil)
        await pause(0.6)
        XCTAssertEqual(network.detailRequests, [], "Closed before the dwell ended")

        c.toggleViewer(nil)
        let loaded = await eventually { c.previewMetadataLabel.stringValue.contains("by u") }
        XCTAssertTrue(loaded, "Reopening fetches the details the cancelled request missed")
        XCTAssertEqual(network.detailRequests, [first])
        c.toggleViewer(nil)
        c.toggleViewer(nil)
        await pause(0.6)
        XCTAssertEqual(network.detailRequests, [first], "Fetched details aren't requested again")
        XCTAssertTrue(c.previewMetadataLabel.stringValue.contains("by u"))

        c.nextWallpaper(nil)
        c.nextWallpaper(nil)
        let current = c.previewTitleLabel.stringValue
        _ = await eventually { network.detailRequests.count > 1 }
        await pause(0.4)
        XCTAssertEqual(network.detailRequests, [first, current], "Only the selection that settled is requested")

        c.nextWallpaper(nil)
        c.showFavorites(nil)
        await pause(0.6)
        XCTAssertEqual(network.detailRequests, [first, current], "A preview left for another source starts nothing")
    }

    // A display reconfiguration that changes the derived minimum keeps the results, marks them as the
    // previous display size's and offers Update Results without searching; paging keeps their minimum.
    // A reconfiguration that leaves the minimum alone marks nothing.
    @MainActor
    func testDisplayRefreshThatChangesTheMinimumMarksResultsAsPrevious() async throws {
        let network = Batch2Network()
        network.lastPage = 30
        let screen = SizedScreen(601, NSSize(width: 1440, height: 900), scale: 2)
        let (c, _, _) = try await batch2Controller(network, screens: [screen]) { state in
            state.selectedDisplayID = "601"
            state.wallhavenSearch.usesDisplayMinimum = true
            state.wallhavenSearch.minimumWidth = 2880
            state.wallhavenSearch.minimumHeight = 1800
        }
        c.showDiscover(nil)
        await pause(0.3)
        let results = c.remoteResults, draft = c.state.wallhavenSearch
        c.refreshDisplays()
        XCTAssertTrue(c.pendingSearchLabel.isHidden, "The same display leaves the results current")
        XCTAssertTrue(c.updateResultsButton.isHidden)

        screen.size = NSSize(width: 3840, height: 2160)
        screen.scale = 1
        c.refreshDisplays()
        XCTAssertEqual(c.state.wallhavenSearch.minimumResolution, "3840x2160")
        XCTAssertEqual(c.pendingSearchLabel.stringValue, "Showing results for the previous display size")
        XCTAssertFalse(c.pendingSearchLabel.isHidden)
        XCTAssertFalse(c.updateResultsButton.isHidden)
        XCTAssertEqual(c.remoteResults, results)
        XCTAssertEqual(c.state.wallhavenSearch.query, draft.query)
        XCTAssertEqual(c.state.wallhavenSearch.category, draft.category)
        XCTAssertEqual(c.state.wallhavenSearch.sorting, draft.sorting)
        await pause(0.3)
        XCTAssertTrue(network.searches.isEmpty, "A display change doesn't search by itself")

        let shown = c.remoteResults.count
        c.collectionView.scroll(NSPoint(x: 0, y: c.collectionView.frame.height))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: c.galleryScrollForTesting.contentView)
        let paged = await eventually { !network.searches.isEmpty && c.remoteResults.count > shown }
        XCTAssertTrue(paged)
        XCTAssertEqual(Set(network.searches.map { value($0, "atleast") }), ["2880x1800"])
        c.search(nil)
        let applied = await eventually { network.searches.contains { value($0, "atleast") == "3840x2160" } }
        XCTAssertTrue(applied)
        let settled = await eventually { c.searchTask != nil && c.pendingSearchLabel.isHidden }
        XCTAssertTrue(settled)
    }
}


extension WallpierTests {
    // Batch 2 captures: preview sources and notices for difficult shapes, and Discover's pending state,
    // in light and dark and at the minimum window size. Written only when WALLPIER_CAPTURE_DIR is set.
    @MainActor
    func testCaptureBatch2Scenarios() async throws {
        try XCTSkipIf(Self.captureDirectory == nil, "Set WALLPIER_CAPTURE_DIR to write captures")
        CompositionFixtures.framesEdges = true
        defer { CompositionFixtures.framesEdges = false }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let network = Batch2Network(), thumbnails = CompositionThumbnails()
            var items = CompositionFixtures.shapeListings()
            items.append(CompositionFixtures.listing(id: "cmpmiss", width: 3440, height: 1440, original: false))
            let (c, window, root) = try await batch2Controller(network, thumbnails, items: items)
            window.appearance = NSAppearance(named: appearance)
            try CompositionFixtures.writeOriginal(CGSize(width: 2560, height: 1600), to: root.appendingPathComponent("Originals")
                .appendingPathComponent(RemoteWallpaperCache.filename(for: c.remoteResults[1])))
            func show(_ id: String, _ scaling: ScalingMode, _ name: String) async {
                for _ in 0..<items.count where c.previewTitleLabel.stringValue != id { c.nextWallpaper(nil) }
                c.scalingPopUp.selectItem(at: ScalingMode.allCases.firstIndex(of: scaling)!)
                c.scalingSelectionChanged()
                _ = await eventually { c.stageView.image != nil }
                await pause(0.3)
                captureWindow(window, named: "b2-\(name)-\(suffix)")
            }
            c.showDiscover(nil)
            c.toggleViewer(nil)
            await show("cmp169", .fill, "01-preview-16x9-large-thumbnail")
            await show("cmpport", .fit, "02-preview-portrait-fit")
            await show("cmp329", .fit, "03-preview-32x9-fit")
            await show("cmp329", .fill, "04-preview-32x9-fill")
            await show("cmpsq", .center, "05-preview-square-center")
            await show("cmpmiss", .fit, "06-preview-21x9-cropped-fallback")
            await show("cmp1610", .fit, "07-preview-16x10-cached-original")
            c.toggleViewer(nil)
            c.searchField.stringValue = "forest"
            c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
            captureWindow(window, named: "b2-08-discover-pending-query-\(suffix)")
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
            captureWindow(window, named: "b2-09-discover-pending-minimum-\(suffix)")
            c.toggleViewer(nil)
            await show("cmp329", .fit, "10-preview-32x9-minimum")
            c.toggleViewer(nil)
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1120, height: 720)), display: true)
            c.searchField.stringValue = ""
            c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
            c.search(nil)
            _ = await eventually { window.subtitle.hasPrefix("Top This Month") }
            await pause(0.3)
            captureWindow(window, named: "b2-11-discover-empty-query-top-list-\(suffix)")
            c.showFavorites(nil)
            c.searchField.stringValue = "forest"
            c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
            captureWindow(window, named: "b2-12-search-scope-outside-discover-\(suffix)")
        }
    }
}

// MARK: - Deterministic rotation proof
//
// These tests drive the real production rotation orchestration. The only seam is the DEBUG-only
// `rotationTimerFactoryForTesting`, which lets the harness capture the exact Timer the production
// code schedules and invoke `Timer.fire()` to deliver the real callback. Production still wires
// its own handler; the interval popup action and startup `restoreState()` are used unchanged.
// All timers are real `Timer` objects, never slept, and invalidated by teardown.

@MainActor
private final class RotationHarness {
    let controller: MainWindowController
    let network = SetAuditNetwork()
    let desktop = SetAuditWallpaperService()
    let thumbnails = SetAuditThumbnails()
    let store: WallpaperStateStore
    let root: URL
    let incoming: URL
    let prior: URL
    let originals: URL
    private final class ScreenList { var screens: [NSScreen] = [] }
    private let displayList: ScreenList
    let x = SetAuditScreen(101)
    let y = SetAuditScreen(202)
    private(set) var scheduledTimers: [Timer] = []
    private(set) var scheduledIntervals: [TimeInterval] = []

    var rollbackRoot: URL { root.appendingPathComponent("Rollback") }

    init(root: URL, references: [WallpaperReference], interval: RotationInterval,
         shuffle: Bool, localImages: Int, favorites: [WallpaperReference] = [],
         extraCollections: [WallpaperCollection] = [],
         historyLimit: Int64 = WallpaperHistoryStore.maximumSizeBytes) throws {
        precondition(localImages > 0 || !references.isEmpty)
        self.root = root
        incoming = root.appendingPathComponent("incoming.png")
        prior = root.appendingPathComponent("prior.png")
        originals = root.appendingPathComponent("Originals")
        store = WallpaperStateStore(stateURL: root.appendingPathComponent("state.json"))
        var state = WallpaperState()
        state.rotationInterval = interval
        state.shuffleEnabled = shuffle
        state.selectedDisplayID = "101"
        state.favorites = favorites
        if localImages > 0 {
            let folder = root.appendingPathComponent("Folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<localImages {
                try Data([1]).write(to: folder.appendingPathComponent(String(format: "wall-%02d.jpg", index)))
            }
            state.currentSource = .local
            state.folderPath = folder.path
            state.selectedImagePath = folder.appendingPathComponent("wall-00.jpg").path
            // Batch 3: rotation's place is its own cursor. Seed it as the folder scan reports the path.
            state.rotationCursor = try SupportedWallpaperFiles.images(in: folder.standardizedFileURL).first?.path
        } else {
            state.currentSource = .collections
            state.collections = [WallpaperCollection(name: "Rotation", wallpapers: references)]
            state.selectedCollectionID = state.collections[0].id
            state.activeRotationCollectionID = state.collections[0].id
            state.selectedRemoteIdentity = references.first?.identityKey
            // Batch 3: rotation's place is its own cursor, seeded where GLM seeded the shared selection.
            state.rotationCursor = references.first?.identityKey
            state.collections += extraCollections
        }
        XCTAssertTrue(store.save(state))
        // Capture a separate box so all dependencies exist before constructing the controller.
        let displayList = ScreenList()
        displayList.screens = [x, y]
        controller = MainWindowController(window: nil, wallpaperService: desktop, stateStore: store,
            provider: WallhavenProvider(client: network), openverseProvider: OpenverseProvider(client: network), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: root.appendingPathComponent("Rollback"), maximumSizeBytes: historyLimit),
            remoteThumbnailProvider: thumbnails, availableScreens: { displayList.screens })
        self.displayList = displayList
        desktop.current = prior
        controller.rotationTimerFactoryForTesting = { [weak self] interval, handler in
            guard let self else { preconditionFailure("Rotation harness outlived its test") }
            let timer = Timer(timeInterval: interval, repeats: true) { _ in handler() }
            self.scheduledTimers.append(timer)
            self.scheduledIntervals.append(interval)
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
        controller.scalingPopUp.addItems(withTitles: ScalingMode.allCases.map(\.displayName))
        controller.scalingPopUp.selectItem(at: 0)
        controller.rotationPopUp.addItems(withTitles: RotationInterval.allCases.map(\.displayName))
        if localImages == 0 {
            controller.refreshDisplays()
            controller.showCollections(nil)
        }
    }

    func selectRotationInterval(_ interval: RotationInterval) {
        controller.rotationPopUp.selectItem(at: RotationInterval.allCases.firstIndex(of: interval)!)
        controller.rotationSelectionChanged()
    }

    func cached(_ reference: WallpaperReference) -> URL {
        originals.appendingPathComponent(RemoteWallpaperCache.filename(for: reference))
    }
    func owned(_ reference: WallpaperReference) -> URL {
        rollbackRoot.appendingPathComponent(RemoteWallpaperCache.filename(for: reference))
    }

    /// A new controller over the same persisted state and isolated dependencies, through the real startup path.
    func relaunch() -> MainWindowController {
        let relaunched = MainWindowController(window: nil, wallpaperService: desktop, stateStore: store,
            provider: WallhavenProvider(client: network), openverseProvider: OpenverseProvider(client: network), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: rollbackRoot),
            remoteThumbnailProvider: thumbnails, availableScreens: { [displayList] in displayList.screens })
        relaunched.rotationTimerFactoryForTesting = controller.rotationTimerFactoryForTesting
        relaunched.scalingPopUp.addItems(withTitles: ScalingMode.allCases.map(\.displayName))
        relaunched.rotationPopUp.addItems(withTitles: RotationInterval.allCases.map(\.displayName))
        relaunched.restoreState()
        return relaunched
    }
}

extension WallpierTests {
    @MainActor
    private func rotationHarness(references: [WallpaperReference] = [], interval: RotationInterval = .off,
                                 shuffle: Bool = false, localImages: Int = 0,
                                 favorites: [WallpaperReference] = [],
                                 extraCollections: [WallpaperCollection] = [],
                                 historyLimit: Int64 = WallpaperHistoryStore.maximumSizeBytes) throws -> RotationHarness {
        let root = try historyTestFolder()
        let harness = try RotationHarness(root: root, references: references, interval: interval,
                                          shuffle: shuffle, localImages: localImages, favorites: favorites,
                                          extraCollections: extraCollections, historyLimit: historyLimit)
        try writeTestImage(to: harness.incoming)
        try writeTestImage(to: harness.prior, width: 3)
        addTeardownBlock {
            let tasks = await MainActor.run {
                harness.scheduledTimers.forEach { $0.invalidate() }
                let tasks = [harness.controller.downloadTask, harness.controller.rotationTask,
                             harness.controller.searchTask, harness.controller.detailTask,
                             harness.controller.undoValidationTask].compactMap { $0 }
                tasks.forEach { $0.cancel() }
                harness.network.downloadGate.release(.failure(CancellationError()))
                harness.network.pendingDataGates.forEach { $0.release(.failure(CancellationError())) }
                return tasks
            }
            for task in tasks { await task.value }
            try FileManager.default.removeItem(at: root)
        }
        return harness
    }

    private func rotationReferences(_ ids: String...) -> [WallpaperReference] {
        ids.map { remoteReference(id: $0) }
    }

    // Bounded ordered wait for the asynchronous local-folder scan; no sleeps.
    @MainActor
    private func waitUntil(_ message: String, timeout: TimeInterval = 5,
                           _ condition: @escaping @MainActor () -> Bool) async {
        let reached = expectation(description: message)
        let poller = Task { @MainActor in
            while !Task.isCancelled, !condition() { await Task.yield() }
            if !Task.isCancelled { reached.fulfill() }
        }
        await fulfillment(of: [reached], timeout: timeout)
        poller.cancel()
    }

    // MARK: A — one active timer, replaced by interval changes, removed by Off

    @MainActor
    func testRotationScheduleIsSingleReplacedAndStoppedByIntervalChanges() throws {
        let h = try rotationHarness(references: rotationReferences("aaaaaa", "bbbbbb"), interval: .fifteenMinutes)
        // Startup restores exactly one schedule.
        h.controller.restoreState()
        XCTAssertEqual(h.scheduledIntervals, [900])
        XCTAssertEqual(h.scheduledTimers.count, 1)
        XCTAssertTrue(h.scheduledTimers[0].isValid)
        // Changing the interval invalidates the previous schedule; exactly one remains.
        h.selectRotationInterval(.oneHour)
        XCTAssertEqual(h.scheduledIntervals, [900, 3_600])
        XCTAssertFalse(h.scheduledTimers[0].isValid)
        XCTAssertTrue(h.scheduledTimers[1].isValid)
        XCTAssertEqual(h.scheduledTimers.filter(\.isValid).count, 1)
        // Off stops the schedule without creating another one.
        h.selectRotationInterval(.off)
        XCTAssertEqual(h.scheduledTimers.count, 2)
        XCTAssertFalse(h.scheduledTimers[1].isValid)
        XCTAssertEqual(h.scheduledTimers.filter(\.isValid).count, 0)
    }

    // MARK: B — one fire = exactly one rotation attempt

    @MainActor
    func testSingleTimerFireProducesExactlyOneRotationAttempt() async throws {
        let h = try rotationHarness(references: rotationReferences("aaaaaa", "bbbbbb"))
        h.selectRotationInterval(.fifteenMinutes)
        XCTAssertEqual(h.scheduledTimers.count, 1)
        let next = h.controller.state.collections[0].wallpapers[1]
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        XCTAssertEqual(h.network.downloads, [next.originalURL])
        XCTAssertEqual(h.desktop.calls.count, 0, "A pending download must not mutate the wallpaper yet")
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.count, 1)
        // A later fire of the same repeating timer begins exactly one more attempt.
        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        XCTAssertEqual(h.network.downloads.count, 2)
        XCTAssertEqual(h.desktop.calls.count, 1, "A single fire must not start a second concurrent attempt")
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.count, 2)
        XCTAssertEqual(h.store.load().history.count, 2)
    }

    // MARK: C — a tick during an in-flight rotation is excluded until the slot is released

    @MainActor
    func testRotationTickWhileRotationInFlightIsExcludedAndLaterTickRecovers() async throws {
        let h = try rotationHarness(references: rotationReferences("aaaaaa", "bbbbbb"))
        h.selectRotationInterval(.fifteenMinutes)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        XCTAssertEqual(h.network.downloads.count, 1)
        // Second tick while the previous rotation is still suspended: the existing policy is to
        // skip it entirely — no second download and no second mutation attempt.
        h.scheduledTimers[0].fire()
        XCTAssertEqual(h.network.downloads.count, 1)
        XCTAssertEqual(h.desktop.calls.count, 0)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.count, 1)
        XCTAssertEqual(h.network.downloads.count, 1, "The skipped tick must not have queued a second attempt")
        XCTAssertEqual(h.store.load().history.count, 1)
        // Once the slot is released a later tick rotates again.
        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        XCTAssertEqual(h.network.downloads.count, 2)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.count, 2)
        XCTAssertEqual(h.store.load().history.count, 2)
    }

    // MARK: D — only the selected next original is downloaded, on demand

    @MainActor
    func testRotationDownloadsOnlyTheSelectedNextOriginalOnDemand() async throws {
        let refs = rotationReferences("rotate-0", "rotate-1", "rotate-2", "rotate-3")
        let h = try rotationHarness(references: refs)
        h.selectRotationInterval(.fifteenMinutes)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        XCTAssertEqual(h.network.downloads, [refs[1].originalURL])
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.network.downloads.count, 1, "No eager downloads of the remaining collection items")
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.owned(refs[1])])
        // The following tick downloads exactly the next selected original and nothing else.
        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        XCTAssertEqual(h.network.downloads, [refs[1].originalURL, refs[2].originalURL])
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.network.downloads.count, 2)
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.owned(refs[1]), h.owned(refs[2])])
    }

    // MARK: E — download failure keeps wallpaper and history intact and recovers

    @MainActor
    func testRotationDownloadFailureLeavesWallpaperAndHistoryUntouchedAndRecovers() async throws {
        let h = try rotationHarness(references: rotationReferences("aaaaaa", "bbbbbb"))
        h.selectRotationInterval(.fifteenMinutes)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        h.network.downloadGate.release(.failure(URLError(.notConnectedToInternet)))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertTrue(h.desktop.calls.isEmpty, "The wallpaper boundary must not be called after a failed download")
        XCTAssertTrue(h.store.load().history.isEmpty)
        XCTAssertNil(h.store.load().assignment(for: "101"))
        XCTAssertTrue(h.controller.statusLabel.stringValue.contains("Automatic rotation failed"))
        XCTAssertTrue(h.controller.setWallpaperButton.isEnabled, "The pending-operation state must be released")
        // A later timer fire can attempt and succeed.
        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.count, 1)
        XCTAssertEqual(h.store.load().history.count, 1)
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, h.desktop.current?.path)
    }

    // MARK: F — wallpaper-boundary failure does not commit and cleans prepared rollback

    @MainActor
    func testRotationWallpaperBoundaryFailureDoesNotCommitAndRecovers() async throws {
        let h = try rotationHarness(references: rotationReferences("aaaaaa", "bbbbbb"))
        h.selectRotationInterval(.fifteenMinutes)
        h.desktop.failure = CocoaError(.fileReadUnknown)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.count, 1)
        XCTAssertEqual(h.desktop.current, h.prior, "The current wallpaper must remain intact")
        XCTAssertTrue(h.store.load().history.isEmpty, "No false success may be recorded")
        XCTAssertNil(h.store.load().assignment(for: "101"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.rollbackRoot.path), [],
                       "The prepared rollback snapshot is cleaned after the failed attempt")
        XCTAssertTrue(h.controller.statusLabel.stringValue.contains("Automatic rotation failed"))
        // Later rotation remains possible.
        h.desktop.failure = nil
        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.count, 2)
        XCTAssertEqual(h.store.load().history.count, 1)
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, h.desktop.current?.path)
    }

    // MARK: G — successful rotation commits through the shared Set path

    @MainActor
    func testSuccessfulCollectionRotationUsesSharedSetPathAndCommitsCoherently() async throws {
        let h = try rotationHarness(references: rotationReferences("aaaaaa", "bbbbbb"))
        h.selectRotationInterval(.fifteenMinutes)
        h.controller.scalingPopUp.selectItem(at: 1)
        h.controller.scalingSelectionChanged()
        let next = h.controller.state.collections[0].wallpapers[1]
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls, [SetAuditWallpaperService.Call(image: h.owned(next), display: "101", scaling: .fit)])
        let entry = try XCTUnwrap(h.store.load().history.last)
        XCTAssertEqual(entry.replacement.imagePath, h.owned(next).path)
        XCTAssertEqual(entry.replacement.displayID, "101")
        XCTAssertEqual(entry.replacement.scaling, .fit)
        XCTAssertEqual(entry.previous.imagePath, h.prior.path, "The prior image is captured through the shared path")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(entry.rollbackPath))), try Data(contentsOf: h.prior))
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, h.owned(next).path)
        // Batch 3 supersedes GLM's `selectedRemoteIdentity == next`: rotation advances its own
        // cursor and leaves the browsing selection where the user left it.
        XCTAssertEqual(h.controller.state.rotationCursor, next.identityKey)
        XCTAssertEqual(h.controller.state.selectedRemoteIdentity, h.controller.state.collections[0].wallpapers[0].identityKey)
        XCTAssertTrue(h.controller.statusLabel.stringValue.hasPrefix("Set "))
        XCTAssertTrue(h.controller.statusLabel.stringValue.contains("on Display 101"))
        XCTAssertTrue(h.controller.setWallpaperButton.isEnabled)
    }

    @MainActor
    func testSuccessfulLocalFolderRotationUsesSharedSetPath() async throws {
        let h = try rotationHarness(localImages: 3)
        h.controller.restoreState()
        await waitUntil("local folder loaded") { h.controller.statusLabel.stringValue == "Loaded 3 local wallpapers." }
        h.selectRotationInterval(.fifteenMinutes)
        XCTAssertEqual(h.scheduledTimers.count, 1)
        let browsed = h.controller.state.selectedImagePath
        h.scheduledTimers[0].fire()
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.count, 1)
        let applied = h.desktop.calls[0]
        XCTAssertEqual(applied.image.lastPathComponent, "wall-01.jpg", "Rotation advances to the next folder image")
        // /var and /private/var name the same temporary folder; compare the resolved locations.
        XCTAssertEqual(applied.image.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: try XCTUnwrap(h.controller.state.folderPath)).resolvingSymlinksInPath().path)
        XCTAssertEqual(applied.display, "101")
        // Fit by default supersedes GLM's `applied.scaling == .fill`: restoreState() loads the default (now Fit), and
        // rotation applies the mode the controls show. Deliberate Fill and Center are covered by the scaling-choice test.
        XCTAssertEqual(applied.scaling, .fit)
        XCTAssertEqual(applied.scaling, h.controller.state.scalingMode)
        let entry = try XCTUnwrap(h.store.load().history.last)
        XCTAssertEqual(entry.replacement.imagePath, applied.image.path)
        XCTAssertEqual(entry.previous.imagePath, h.prior.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(entry.rollbackPath))), try Data(contentsOf: h.prior))
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, applied.image.path)
        // Batch 3 supersedes GLM's `selectedImagePath == applied`: rotation advances its own
        // cursor and leaves the browsing selection where the user left it.
        XCTAssertEqual(h.controller.state.rotationCursor, applied.image.path)
        XCTAssertEqual(h.controller.state.selectedImagePath, browsed)
        XCTAssertTrue(h.controller.statusLabel.stringValue.hasPrefix("Set "))
        XCTAssertTrue(h.network.downloads.isEmpty, "Local rotation must not touch the network")
    }

    // MARK: H — Off stops scheduled and in-flight work; invalidated callbacks cannot fire

    @MainActor
    func testRotationOffStopsInFlightWorkAndInvalidatedCallbackCannotFire() async throws {
        let h = try rotationHarness(references: rotationReferences("aaaaaa", "bbbbbb"))
        h.selectRotationInterval(.fifteenMinutes)
        XCTAssertEqual(h.scheduledTimers.count, 1)
        let timer = h.scheduledTimers[0]
        timer.fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        // Off while the tick's rotation is still suspended.
        h.selectRotationInterval(.off)
        XCTAssertFalse(timer.isValid, "Off must invalidate the stored schedule")
        XCTAssertEqual(h.scheduledTimers.count, 1, "Off must not create a replacement schedule")
        XCTAssertEqual(h.scheduledTimers.filter(\.isValid).count, 0)
        // Real Timer semantics: an invalidated timer cannot be invoked, even explicitly.
        timer.fire()
        XCTAssertEqual(h.network.downloads.count, 1)
        XCTAssertEqual(h.desktop.calls.count, 0, "A stale invalidated callback cannot mutate the wallpaper")
        // The in-flight tick was cancelled; it must not mutate the wallpaper either.
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertTrue(h.desktop.calls.isEmpty)
        XCTAssertTrue(h.store.load().history.isEmpty)
        XCTAssertNil(h.store.load().assignment(for: "101"))
        // Rotation can be re-enabled and a later tick succeeds.
        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        h.selectRotationInterval(.fifteenMinutes)
        XCTAssertEqual(h.scheduledTimers.count, 2)
        XCTAssertTrue(h.scheduledTimers[1].isValid)
        h.scheduledTimers[1].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.count, 1)
        XCTAssertEqual(h.store.load().history.count, 1)
    }

    // MARK: Shuffle — the chosen item is honored; selections stay valid members

    @MainActor
    func testShuffleRotationAlternatesDeterministicallyForTwoItems() async throws {
        let refs = rotationReferences("aaaaaa", "bbbbbb")
        let h = try rotationHarness(references: refs, shuffle: true)
        try FileManager.default.createDirectory(at: h.originals, withIntermediateDirectories: true)
        try writeTestImage(to: h.cached(refs[0]), width: 9)
        try writeTestImage(to: h.cached(refs[1]), width: 10)
        h.selectRotationInterval(.fifteenMinutes)
        var applied: [URL] = []
        for _ in 0..<4 {
            h.scheduledTimers[0].fire()
            try await finishAuditTask(h.controller.rotationTask)
            applied.append(try XCTUnwrap(h.desktop.calls.last?.image))
        }
        // With two members the shuffled result is always the other item: fully deterministic.
        XCTAssertEqual(applied, [h.owned(refs[1]), h.owned(refs[0]), h.owned(refs[1]), h.owned(refs[0])])
        XCTAssertTrue(h.network.downloads.isEmpty, "Cached members rotate without downloads")
        XCTAssertEqual(h.store.load().history.count, 4)
    }

    @MainActor
    func testShuffleRotationAlwaysSelectsAValidDifferentMember() async throws {
        let refs = rotationReferences("shuffle-0", "shuffle-1", "shuffle-2")
        let h = try rotationHarness(references: refs, shuffle: true)
        try FileManager.default.createDirectory(at: h.originals, withIntermediateDirectories: true)
        for (index, ref) in refs.enumerated() { try writeTestImage(to: h.cached(ref), width: 9 + index) }
        h.selectRotationInterval(.fifteenMinutes)
        var previous: WallpaperReference?
        for _ in 0..<6 {
            h.scheduledTimers[0].fire()
            try await finishAuditTask(h.controller.rotationTask)
            let appliedPath = try XCTUnwrap(h.desktop.calls.last?.image).path
            let member = refs.first { h.owned($0).path == appliedPath }
            XCTAssertNotNil(member, "The applied wallpaper must be a valid collection member")
            XCTAssertNotEqual(member?.identityKey, previous?.identityKey, "Shuffle never repeats the current member")
            previous = member
        }
        XCTAssertEqual(h.desktop.calls.count, 6)
        XCTAssertTrue(h.network.downloads.isEmpty)
    }
}

// MARK: - Batch 3: rotation's place is its own (D6); a finished change keeps newer choices (D7)
//
// Same harnesses and gates as the rotation proof above. Each timer tick is delivered with
// Timer.fire(); nothing sleeps, touches the desktop, the network, or real user state.

extension WallpierTests {
    @MainActor
    private func visibleSelection(_ controller: MainWindowController) -> [Int] {
        controller.collectionView.selectionIndexPaths.map(\.item).sorted()
    }

    /// One tick of the live schedule whose original download completes with `result`.
    @MainActor
    private func tick(_ h: RotationHarness, _ result: Result<URL, Error>) async throws {
        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        try XCTUnwrap(h.scheduledTimers.last { $0.isValid }).fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        h.network.downloadGate.release(result)
        try await finishAuditTask(h.controller.rotationTask)
    }

    /// One tick of the live schedule for members whose originals are already cached.
    @MainActor
    private func cachedTick(_ h: RotationHarness, _ controller: MainWindowController? = nil) async throws {
        try XCTUnwrap(h.scheduledTimers.last { $0.isValid }).fire()
        try await finishAuditTask((controller ?? h.controller).rotationTask)
    }

    @MainActor
    private func cacheOriginals(_ h: RotationHarness, _ refs: [WallpaperReference]) throws {
        try FileManager.default.createDirectory(at: h.originals, withIntermediateDirectories: true)
        for (index, ref) in refs.enumerated() { try writeTestImage(to: h.cached(ref), width: 9 + index) }
    }

    // MARK: D6 — browsing never moves rotation, and rotation never moves browsing

    @MainActor
    func testRotationSequenceIsIndependentOfBrowsingAndNavigation() async throws {
        let refs = rotationReferences("seq-a", "seq-b", "seq-c")
        let favorite = remoteReference(id: "unrelated")
        let h = try rotationHarness(references: refs, favorites: [favorite])
        h.selectRotationInterval(.fifteenMinutes)
        XCTAssertEqual(visibleSelection(h.controller), [0])
        // Navigate the rotating collection while its rotation is still downloading.
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        h.controller.previousWallpaper(nil)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.owned(refs[1])])
        XCTAssertEqual(visibleSelection(h.controller), [2], "Rotation must not move the visible selection")
        XCTAssertEqual(h.controller.state.selectedRemoteIdentity, refs[2].identityKey, "…nor the remembered one")
        // Browse an unrelated favorite: the next tick continues after the last rotated member.
        h.controller.showFavorites(nil)
        XCTAssertEqual(h.controller.state.selectedRemoteIdentity, favorite.identityKey)
        try await tick(h, .success(h.incoming))
        XCTAssertEqual(h.network.downloads, [refs[1].originalURL, refs[2].originalURL])
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.owned(refs[1]), h.owned(refs[2])])
        XCTAssertEqual(h.controller.state.selectedRemoteIdentity, favorite.identityKey)
        XCTAssertEqual(visibleSelection(h.controller), [0])
        try await tick(h, .success(h.incoming))
        XCTAssertEqual(h.desktop.calls.last?.image, h.owned(refs[0]), "The sequence wraps around")
        XCTAssertEqual(h.store.load().history.count, 3)
    }

    @MainActor
    func testShuffleNeverRepeatsTheLastRotatedMemberWhileBrowsingElsewhere() async throws {
        let refs = rotationReferences("shuf-a", "shuf-b")
        let h = try rotationHarness(references: refs, shuffle: true, favorites: [remoteReference(id: "elsewhere")])
        try cacheOriginals(h, refs)
        h.selectRotationInterval(.fifteenMinutes)
        h.controller.showFavorites(nil)
        var applied: [URL] = []
        for _ in 0..<6 {
            try await cachedTick(h)
            applied.append(try XCTUnwrap(h.desktop.calls.last?.image))
            h.controller.showCollections(nil)
            h.controller.showFavorites(nil)
        }
        // With two members, never repeating the last rotated one fully determines the order.
        XCTAssertEqual(applied, [1, 0, 1, 0, 1, 0].map { h.owned(refs[$0]) })
    }

    @MainActor
    func testLocalRotationSequenceIsIndependentOfLocalBrowsing() async throws {
        let h = try rotationHarness(localImages: 4)
        h.controller.restoreState()
        await waitUntil("local folder loaded") { h.controller.statusLabel.stringValue == "Loaded 4 local wallpapers." }
        h.selectRotationInterval(.fifteenMinutes)
        try await cachedTick(h)
        XCTAssertEqual(visibleSelection(h.controller), [0])
        h.controller.previousWallpaper(nil)
        let browsed = h.controller.state.selectedImagePath
        XCTAssertEqual(browsed.map { URL(fileURLWithPath: $0).lastPathComponent }, "wall-03.jpg")
        try await cachedTick(h)
        XCTAssertEqual(h.desktop.calls.map(\.image.lastPathComponent), ["wall-01.jpg", "wall-02.jpg"])
        XCTAssertEqual(visibleSelection(h.controller), [3])
        XCTAssertEqual(h.controller.state.selectedImagePath, browsed)
    }

    @MainActor
    func testRotationSourceChangeStartsTheNewSourceFromItsFirstMember() async throws {
        let refs = rotationReferences("src-a", "src-b", "src-c")
        let other = WallpaperCollection(name: "Other", wallpapers: rotationReferences("src-p", "src-q"))
        let h = try rotationHarness(references: refs, extraCollections: [other])
        try cacheOriginals(h, refs + other.wallpapers)
        h.controller.restoreState() // Startup fills the rotation source menu that useForRotation selects in.
        h.selectRotationInterval(.fifteenMinutes)
        let first = h.controller.state.collections[0].id
        func use(_ id: UUID) {
            let item = NSMenuItem(); item.representedObject = id
            h.controller.useForRotation(item)
        }
        try await cachedTick(h)
        use(other.id)
        try await cachedTick(h)
        try await cachedTick(h)
        use(first)
        try await cachedTick(h)
        use(first) // Choosing the active source again keeps its place.
        try await cachedTick(h)
        XCTAssertEqual(h.desktop.calls.map(\.image),
                       [refs[1], other.wallpapers[0], other.wallpapers[1], refs[0], refs[1]].map(h.owned))
        XCTAssertTrue(h.network.downloads.isEmpty)
    }

    @MainActor
    func testRemovingTheLastRotatedMemberContinuesWithTheMemberAfterIt() async throws {
        let refs = rotationReferences("rm-a", "rm-b", "rm-c", "rm-d")
        let h = try rotationHarness(references: refs)
        try cacheOriginals(h, refs)
        h.selectRotationInterval(.fifteenMinutes)
        try await cachedTick(h)
        // Remove the last rotated member, b, from the rotating collection being viewed.
        h.controller.nextWallpaper(nil)
        h.controller.removeSelected(nil)
        XCTAssertEqual(h.controller.state.collections[0].wallpapers.map(\.identityKey), [refs[0], refs[2], refs[3]].map(\.identityKey))
        try await cachedTick(h)
        // Removing a member that was not last rotated leaves the sequence alone.
        XCTAssertEqual(visibleSelection(h.controller), [1])
        h.controller.nextWallpaper(nil)
        h.controller.removeSelected(nil)
        XCTAssertEqual(h.controller.state.collections[0].wallpapers.map(\.identityKey), [refs[0], refs[2]].map(\.identityKey))
        try await cachedTick(h)
        XCTAssertEqual(h.desktop.calls.map(\.image), [refs[1], refs[2], refs[0]].map(h.owned))
    }

    @MainActor
    func testFailedRotationAttemptsAdvancePastTheFailingMember() async throws {
        let refs = rotationReferences("fail-a", "fail-b", "fail-c")
        let h = try rotationHarness(references: refs)
        h.selectRotationInterval(.fifteenMinutes)
        try await tick(h, .failure(URLError(.notConnectedToInternet)))
        XCTAssertTrue(h.desktop.calls.isEmpty)
        try await tick(h, .success(h.incoming))
        XCTAssertEqual(h.network.downloads, [refs[1].originalURL, refs[2].originalURL],
                       "A failed member is not retried on the next tick")
        h.desktop.failure = CocoaError(.fileReadUnknown)
        try await tick(h, .success(h.incoming))
        h.desktop.failure = nil
        try await tick(h, .success(h.incoming))
        XCTAssertEqual(h.desktop.calls.map(\.image), [refs[2], refs[0], refs[1]].map(h.owned))
        XCTAssertEqual(h.store.load().history.map(\.replacement.imagePath), [refs[2], refs[1]].map { h.owned($0).path })
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, h.owned(refs[1]).path)
    }

    @MainActor
    func testRotationSequenceContinuesAfterRelaunch() async throws {
        let refs = rotationReferences("relaunch-a", "relaunch-b", "relaunch-c")
        let h = try rotationHarness(references: refs, favorites: [remoteReference(id: "relaunch-f")])
        try cacheOriginals(h, refs)
        h.selectRotationInterval(.fifteenMinutes)
        try await cachedTick(h)
        h.controller.showFavorites(nil)
        h.scheduledTimers[0].invalidate()
        let relaunched = h.relaunch()
        XCTAssertEqual(h.scheduledTimers.filter(\.isValid).count, 1, "Startup restores exactly one schedule")
        XCTAssertEqual(relaunched.state.currentSource, .favorites)
        try await cachedTick(h, relaunched)
        XCTAssertEqual(h.desktop.calls.map(\.image), [refs[1], refs[2]].map(h.owned))
        XCTAssertEqual(relaunched.state.selectedRemoteIdentity, h.controller.state.favorites[0].identityKey)
    }

    // MARK: Batch 3 repair — a local rotation place belongs to the folder it was made in

    @MainActor
    private func makeFolder(_ h: RotationHarness, _ name: String, images: Int) throws -> URL {
        let folder = h.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<images { try Data([1]).write(to: folder.appendingPathComponent(String(format: "\(name)-%02d.jpg", index))) }
        return folder
    }

    /// Opens `folder` through the folder picker's completion path and waits for its load to finish.
    @MainActor
    private func open(_ controller: MainWindowController, _ folder: URL, status: String) async {
        controller.statusLabel.stringValue = ""
        controller.openFolder(folder)
        await waitUntil("folder load finished: \(status)") { controller.statusLabel.stringValue.hasPrefix(status) }
    }

    @MainActor
    func testReturningToAnEarlierLocalFolderStartsItFromItsFirstImage() async throws {
        let h = try rotationHarness(localImages: 4)
        let a = URL(fileURLWithPath: try XCTUnwrap(h.store.load().folderPath))
        let b = try makeFolder(h, "Other", images: 2)
        h.controller.restoreState()
        await waitUntil("local folder loaded") { h.controller.statusLabel.stringValue == "Loaded 4 local wallpapers." }
        h.selectRotationInterval(.fifteenMinutes)
        try await cachedTick(h)
        // A → B → A with no tick in between: A's old place must not come back.
        await open(h.controller, b, status: "Loaded 2 ")
        XCTAssertNil(h.store.load().rotationCursor, "A different folder starts from its first image")
        await open(h.controller, a, status: "Loaded 4 ")
        XCTAssertNil(h.controller.state.rotationCursor)
        try await cachedTick(h)
        XCTAssertEqual(h.desktop.calls.map(\.image.lastPathComponent), ["wall-01.jpg", "wall-00.jpg"])
        // Folder and place are saved together, and a fresh controller continues from them.
        let saved = h.store.load()
        XCTAssertEqual(saved.folderPath, h.controller.state.folderPath)
        XCTAssertEqual(saved.rotationCursor, h.desktop.calls.last?.image.path)
        h.scheduledTimers.forEach { $0.invalidate() }
        let relaunched = h.relaunch()
        await waitUntil("relaunched folder loaded") { relaunched.statusLabel.stringValue == "Loaded 4 local wallpapers." }
        try await cachedTick(h, relaunched)
        XCTAssertEqual(h.desktop.calls.map(\.image.lastPathComponent), ["wall-01.jpg", "wall-00.jpg", "wall-01.jpg"])
    }

    @MainActor
    func testReselectingTheSameFolderOrAFailedFolderLoadKeepsTheLocalRotationPlace() async throws {
        let h = try rotationHarness(localImages: 4)
        let a = URL(fileURLWithPath: try XCTUnwrap(h.store.load().folderPath))
        h.controller.restoreState()
        await waitUntil("local folder loaded") { h.controller.statusLabel.stringValue == "Loaded 4 local wallpapers." }
        h.selectRotationInterval(.fifteenMinutes)
        try await cachedTick(h)
        // Reselect the same folder through a path that standardizes to it, with rotation off and back on around it.
        h.selectRotationInterval(.off)
        await open(h.controller, a.appendingPathComponent("..").appendingPathComponent(a.lastPathComponent), status: "Loaded 4 ")
        XCTAssertEqual(h.controller.state.folderPath, a.path)
        h.selectRotationInterval(.fifteenMinutes)
        try await cachedTick(h)
        let place = try XCTUnwrap(h.desktop.calls.last).image.path
        // A folder that can't be read leaves the configured folder and its place alone, in memory and on disk.
        await open(h.controller, h.root.appendingPathComponent("Missing"), status: "Could Not Open Folder")
        for state in [h.controller.state, h.store.load()] {
            XCTAssertEqual(state.folderPath, a.path)
            XCTAssertEqual(state.rotationCursor, place)
        }
        h.scheduledTimers.forEach { $0.invalidate() }
        let relaunched = h.relaunch()
        await waitUntil("relaunched folder loaded") { relaunched.statusLabel.stringValue == "Loaded 4 local wallpapers." }
        try await cachedTick(h, relaunched)
        XCTAssertEqual(h.desktop.calls.map(\.image.lastPathComponent), ["wall-01.jpg", "wall-02.jpg", "wall-03.jpg"])
    }

    @MainActor
    func testChangingTheBrowsingFolderLeavesTheCollectionRotationPlaceAlone() async throws {
        let refs = rotationReferences("own-a", "own-b", "own-c")
        let h = try rotationHarness(references: refs)
        try cacheOriginals(h, refs)
        let folder = try makeFolder(h, "Browse", images: 2)
        h.controller.restoreState()
        h.selectRotationInterval(.fifteenMinutes)
        try await cachedTick(h)
        await open(h.controller, folder, status: "Loaded 2 ")
        XCTAssertEqual(h.store.load().rotationCursor, refs[1].identityKey, "The collection still owns the rotation place")
        try await cachedTick(h)
        h.scheduledTimers.forEach { $0.invalidate() }
        let relaunched = h.relaunch()
        await waitUntil("relaunched folder loaded") { relaunched.statusLabel.stringValue == "Loaded 2 local wallpapers." }
        try await cachedTick(h, relaunched)
        XCTAssertEqual(h.desktop.calls.map(\.image), [refs[1], refs[2], refs[0]].map(h.owned))
        XCTAssertTrue(h.network.downloads.isEmpty)
    }

    // MARK: D7 — a finished change records what it captured and keeps the newer choices

    @MainActor
    func testInFlightSetKeepsNewerDisplayAndScalingPreferences() async throws {
        let h = try setAuditHarness()
        let a = h.controller.state.favorites[0]
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        h.controller.displayPopUp.selectItem(at: 1)
        h.controller.displaySelectionChanged()
        h.controller.scalingPopUp.selectItem(at: 1)
        h.controller.scalingSelectionChanged()
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        // The change applied, assigned and recorded what it captured…
        XCTAssertEqual(h.desktop.calls, [.init(image: h.owned(a), display: "101", scaling: .fill)])
        let saved = h.store.load()
        XCTAssertEqual(saved.assignment(for: "101")?.scaling, .fill)
        XCTAssertNil(saved.assignment(for: "202"))
        XCTAssertEqual(saved.history.last?.replacement.displayID, "101")
        XCTAssertEqual(saved.history.last?.replacement.scaling, .fill)
        // …while the newer choices stay selected: in memory, on disk and in the controls.
        for state in [h.controller.state, saved] {
            XCTAssertEqual(state.selectedDisplayID, "202")
            XCTAssertEqual(state.scalingMode, .fit)
        }
        XCTAssertEqual(h.controller.displayPopUp.indexOfSelectedItem, 1)
        XCTAssertEqual(h.controller.scalingPopUp.indexOfSelectedItem, 1)
        // The next Set uses them.
        h.controller.setWallpaper(nil)
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(h.desktop.calls.last, .init(image: h.owned(a), display: "202", scaling: .fit))
        // A relaunch restores them.
        let screens: [NSScreen] = [h.x, h.y]
        let originals = h.root.appendingPathComponent("Originals")
        let relaunched = MainWindowController(window: nil, wallpaperService: h.desktop, stateStore: h.store,
            provider: WallhavenProvider(client: h.network), openverseProvider: OpenverseProvider(client: h.network), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: h.root.appendingPathComponent("Rollback")),
            remoteThumbnailProvider: h.thumbnails, availableScreens: { screens })
        // The harness state rotates hourly; an unscheduled Timer keeps that schedule inert.
        relaunched.rotationTimerFactoryForTesting = { interval, _ in Timer(timeInterval: interval, repeats: true) { _ in } }
        relaunched.scalingPopUp.addItems(withTitles: ScalingMode.allCases.map(\.displayName))
        relaunched.rotationPopUp.addItems(withTitles: RotationInterval.allCases.map(\.displayName))
        relaunched.restoreState()
        XCTAssertEqual(relaunched.displayPopUp.indexOfSelectedItem, 1)
        XCTAssertEqual(relaunched.scalingPopUp.indexOfSelectedItem, 1)
        XCTAssertEqual(relaunched.stageView.scaling, .fit)
    }

    @MainActor
    func testInFlightRotationKeepsNewerDisplayAndScalingPreferences() async throws {
        let refs = rotationReferences("pref-a", "pref-b", "pref-c")
        let h = try rotationHarness(references: refs)
        h.selectRotationInterval(.fifteenMinutes)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        h.controller.displayPopUp.selectItem(at: 1)
        h.controller.displaySelectionChanged()
        h.controller.scalingPopUp.selectItem(at: 1)
        h.controller.scalingSelectionChanged()
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls, [.init(image: h.owned(refs[1]), display: "101", scaling: .fill)])
        XCTAssertEqual(h.store.load().history.last?.replacement.displayID, "101")
        XCTAssertEqual(h.store.load().history.last?.replacement.scaling, .fill)
        for state in [h.controller.state, h.store.load()] {
            XCTAssertEqual(state.selectedDisplayID, "202")
            XCTAssertEqual(state.scalingMode, .fit)
        }
        XCTAssertEqual(h.controller.displayPopUp.indexOfSelectedItem, 1)
        XCTAssertEqual(h.controller.scalingPopUp.indexOfSelectedItem, 1)
        // The next tick targets the newer choices.
        try await tick(h, .success(h.incoming))
        XCTAssertEqual(h.desktop.calls.last, .init(image: h.owned(refs[2]), display: "202", scaling: .fit))
        let relaunched = h.relaunch()
        XCTAssertEqual(relaunched.displayPopUp.indexOfSelectedItem, 1)
        XCTAssertEqual(relaunched.scalingPopUp.indexOfSelectedItem, 1)
    }
}

// MARK: - Visual craft captures
//
// One offline fixture for matched before/after captures: photographic stand-ins in every shape the
// gallery meets (16:9 to 32:9, square, portrait), a cached original, long and short names, empty,
// loading and offline states, at the default, minimum and a large window size, in light and dark.
// Written only when WALLPIER_CAPTURE_DIR is set; nothing reaches the network or the desktop.

enum CraftFixtures {
    static let shapes: [(Int, Int)] = [(3840, 2160), (2560, 1600), (3440, 1440), (1200, 2133), (5120, 2880), (2000, 2000), (2880, 1800),
                                       (5120, 1440), (3840, 2160), (3000, 2000), (2560, 1440), (1440, 2560), (3840, 2400), (1920, 1080)]
    static let tags = [["sunset", "mountains"], ["lake", "morning"], ["night", "stars"], ["desert", "dunes"], ["coast", "mist"],
                       ["dusk", "valley", "long exposure", "patagonia", "torres del paine", "golden hour"], ["moonrise"], ["snow", "minimal"],
                       ["twilight", "peaks"], ["meadow", "spring"], ["canyon"], ["ocean", "blue hour"], ["aurora"], ["fog", "forest"]]

    static func references() -> [WallpaperReference] {
        shapes.enumerated().map { index, shape in
            let id = String(format: "cr%02d", index + 1)
            return WallpaperReference(
                providerIdentifier: "wallhaven", wallpaperID: id,
                sourcePageURL: URL(string: "https://wallhaven.cc/w/\(id)")!,
                originalURL: URL(string: "https://w.wallhaven.cc/full/cr/wallhaven-\(id).jpg")!,
                previewURL: URL(string: "https://th.wallhaven.cc/lg/cr/\(id).jpg")!,
                thumbnailURL: URL(string: "https://th.wallhaven.cc/small/cr/\(id).jpg")!,
                width: shape.0, height: shape.1,
                uploader: ["northlight", "aleksandra.wisniewska-kowalczyk", "m.k.", "atlas_studio"][index % 4],
                tags: tags[index], cachedLocalPath: nil,
                uncroppedPreviewURL: URL(string: "https://th.wallhaven.cc/orig/cr/\(id).jpg")!)
        }
    }

    static func png(index: Int, size: NSSize) -> Data {
        let image = CaptureFixtures.image(index: index, size: size)
        return NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!).representation(using: .png, properties: [:])!
    }
}

/// Serves each thumbnail kind in the proportions Wallhaven serves it, drawn as the fixture's landscape.
final class CraftThumbnails: RemoteThumbnailProvider {
    override func requestThumbnail(for url: URL, maximumPixelSize: Int = 420, completion: @escaping (NSImage?) -> Void) {
        let name = url.deletingPathExtension().lastPathComponent
        guard let number = Int(name.dropFirst(2)), CraftFixtures.shapes.indices.contains(number - 1) else { return completion(nil) }
        let shape = CraftFixtures.shapes[number - 1]
        let canvas = CompositionFixtures.canvas(for: url, original: CGSize(width: shape.0, height: shape.1))
        completion(CaptureFixtures.image(index: number - 1, size: canvas))
    }
    override func reset() {}
}

extension WallpierTests {
    func testShapeNamesOnlyTheShapesThatThumbnailsCrop() {
        XCTAssertEqual(WallpaperShape.summary(width: 3840, height: 2160), "3840 × 2160")
        XCTAssertEqual(WallpaperShape.summary(width: 2560, height: 1600), "2560 × 1600")
        XCTAssertEqual(WallpaperShape.summary(width: 1200, height: 2133), "1200 × 2133 · Portrait")
        XCTAssertEqual(WallpaperShape.summary(width: 2000, height: 2000), "2000 × 2000 · Square")
        XCTAssertEqual(WallpaperShape.summary(width: 3440, height: 1440), "3440 × 1440 · Ultrawide")
        XCTAssertEqual(WallpaperShape.summary(width: 5120, height: 1440), "5120 × 1440 · Ultrawide")
        XCTAssertNil(WallpaperShape.name(width: 0, height: 1080))
    }

    /// The ring is accent-colored only while arrow keys reach the gallery; elsewhere it stays, in gray.
    @MainActor
    func testSelectionRingIsEmphasizedOnlyWhileTheGalleryHasKeyboardFocus() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                windowClass: KeyTestWindow.self) { _ in }
        defer { window.close() }
        c.showFavorites(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        func selected() -> WallpaperCollectionViewItem? {
            c.collectionView.selectionIndexPaths.first.flatMap { c.collectionView.item(at: $0) as? WallpaperCollectionViewItem }
        }
        XCTAssertTrue(window.makeFirstResponder(c.collectionView))
        XCTAssertEqual(selected()?.isEmphasized, true)
        XCTAssertEqual(selected()?.showsSelectionRing, true)
        XCTAssertTrue(window.makeFirstResponder(c.searchField))
        XCTAssertEqual(selected()?.isEmphasized, false)
        XCTAssertEqual(selected()?.showsSelectionRing, true, "Losing focus never hides which wallpaper Set applies")
        c.showCollections(nil)  // Reloads the gallery with new, reused cells while focus stays in the search field.
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(selected()?.isEmphasized, false, "Reused cells take the gallery's current focus state")
        XCTAssertTrue(window.makeFirstResponder(c.collectionView))
        XCTAssertEqual(selected()?.isEmphasized, true)
        // An inactive window: the gallery keeps first responder, but keys go to another window.
        let keyWindow = try XCTUnwrap(window as? KeyTestWindow)
        keyWindow.isKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertEqual(selected()?.isEmphasized, false)
        XCTAssertEqual(selected()?.showsSelectionRing, true)
        keyWindow.isKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(selected()?.isEmphasized, true)
    }
}

/// A tiling window manager (an Accessibility client) may resize standard windows as they appear, which
/// would make matched captures differ in size. Window managers float dialogs, so captures present as one.
final class FloatingCaptureWindow: NSWindow {
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
}

extension WallpierTests {
    @MainActor
    func testCaptureVisualCraftScenarios() async throws {
        try XCTSkipIf(Self.captureDirectory == nil, "Set WALLPIER_CAPTURE_DIR to write captures")
        let refs = CraftFixtures.references()
        let page = RemoteSearchPage(wallpapers: refs, currentPage: 1, lastPage: 92, total: 2_196,
                                    rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil))
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let root = try historyTestFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = root.appendingPathComponent("Pictures")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, (name, size)) in [("IMG_20250914_183022_HDR_portrait_edited_edited", NSSize(width: 540, height: 960)),
                                          ("Torres del Paine at first light", NSSize(width: 960, height: 600)),
                                          ("dune", NSSize(width: 960, height: 540)),
                                          ("Lofoten blue hour — final export v12 [approved]", NSSize(width: 1280, height: 360)),
                                          ("Quiet harbour", NSSize(width: 800, height: 800)),
                                          ("Kyoto, Arashiyama — bamboo grove", NSSize(width: 960, height: 640))].enumerated() {
                try CraftFixtures.png(index: index + 3, size: size).write(to: folder.appendingPathComponent("\(name).png"))
            }
            let originals = root.appendingPathComponent("Originals")
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            try CraftFixtures.png(index: 0, size: NSSize(width: 1920, height: 1080))
                .write(to: originals.appendingPathComponent(RemoteWallpaperCache.filename(for: refs[0])))
            let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: appearance,
                                                    windowClass: FloatingCaptureWindow.self, thumbnails: CraftThumbnails(), page: page) { state in
                state.selectedRemoteIdentity = refs[0].identityKey
                state.favorites = [1, 3, 5, 6, 9, 11].map { refs[$0] }
                state.collections = [WallpaperCollection(name: "Evening Light", wallpapers: [0, 4, 7, 8, 2].map { refs[$0] }),
                                     WallpaperCollection(name: "Long Exposure Studies from Patagonia and Tierra del Fuego", wallpapers: [3, 11, 5].map { refs[$0] }),
                                     WallpaperCollection(name: "Solo", wallpapers: [refs[12]])]
                state.selectedCollectionID = state.collections[0].id
            }
            defer { window.close() }
            var size = NSSize(width: 1120, height: 720)
            func shot(_ name: String) async {
                resize(size)
                await pause(0.25)
                XCTAssertEqual(window.frame.size, size, "vc-\(name)")
                captureWindow(window, named: "vc-\(name)-\(suffix)")
            }
            func show(_ id: String, _ scaling: ScalingMode) async {
                for _ in 0..<c.remoteResults.count where c.previewTitleLabel.stringValue != id { c.nextWallpaper(nil) }
                c.scalingPopUp.selectItem(at: ScalingMode.allCases.firstIndex(of: scaling)!)
                c.scalingSelectionChanged()
                _ = await eventually { c.stageView.image != nil }
            }
            func resize(_ newSize: NSSize) {
                size = newSize
                window.setFrame(NSRect(origin: NSPoint(x: 20, y: 30), size: newSize), display: true)
            }
            c.showDiscover(nil)
            window.makeFirstResponder(c.collectionView)
            await shot("01-discover")
            for _ in refs where c.previewTitleLabel.stringValue != "cr04" { c.nextWallpaper(nil) }
            await shot("02-discover-portrait-selected")
            c.toggleViewer(nil)
            await show("cr01", .fill); await shot("03-preview-cached-original")
            await show("cr04", .fit); await shot("04-preview-portrait-fit")
            await show("cr06", .fit); await shot("05-preview-square-fit")
            await show("cr08", .fill); await shot("06-preview-ultrawide-fill")
            await show("cr06", .fill)
            c.toggleViewer(nil)
            c.showFavorites(nil); await shot("07-favorites")
            c.showCollections(nil); await shot("08-collection")
            let sidebar = c.sidebarForTesting
            let long = sidebar.rows.first { $0.title.hasPrefix("Long Exposure") }
            sidebar.outlineView.selectRowIndexes([sidebar.outlineView.row(forItem: long)], byExtendingSelection: false)
            await shot("09-collection-long-name")
            c.showDiscover(nil)
            resize(NSSize(width: 1400, height: 800)); await shot("10-discover-large")
            c.toggleViewer(nil); await shot("11-preview-large"); c.toggleViewer(nil)
            resize(window.minSize); await shot("12-discover-minimum")
            c.toggleViewer(nil); await shot("13-preview-minimum"); c.toggleViewer(nil)
            resize(NSSize(width: 1120, height: 720))
            c.openFolder(folder)
            _ = await eventually { c.statusLabel.stringValue.hasPrefix("Loaded") }
            await pause(0.5); await shot("14-folder")
            for _ in 0..<6 where !c.previewTitleLabel.stringValue.hasPrefix("IMG_") { c.nextWallpaper(nil) }
            c.toggleViewer(nil)
            _ = await eventually { c.stageView.image != nil }
            await shot("15-folder-preview-long-name")
            c.toggleViewer(nil)

            let emptyRoot = try historyTestFolder()
            defer { try? FileManager.default.removeItem(at: emptyRoot) }
            let (e, emptyWindow) = makeCaptureController(root: emptyRoot, size: NSSize(width: 1120, height: 720), appearance: appearance,
                                                         windowClass: FloatingCaptureWindow.self, thumbnails: CraftThumbnails(), page: page) { state in
                state.favorites = []
                state.collections = []
            }
            defer { emptyWindow.close() }
            func emptyShot(_ name: String) async {
                emptyWindow.setFrame(NSRect(x: 20, y: 30, width: 1120, height: 720), display: true)
                await pause(0.25); captureWindow(emptyWindow, named: "vc-\(name)-\(suffix)")
            }
            await emptyShot("16-empty-favorites")
            e.showLocal(nil); await emptyShot("17-empty-folder")
            e.search(nil)
            _ = await eventually { e.emptyStateView.title.hasPrefix("Couldn") }
            await emptyShot("18-offline")

            let loadingRoot = try historyTestFolder()
            defer { try? FileManager.default.removeItem(at: loadingRoot) }
            let (l, loadingWindow) = makeCaptureController(root: loadingRoot, size: NSSize(width: 1120, height: 720), appearance: appearance,
                                                           network: HangingNetwork(), windowClass: FloatingCaptureWindow.self,
                                                           thumbnails: CraftThumbnails(), page: page) { _ in }
            defer { loadingWindow.close() }
            l.search(nil)
            loadingWindow.setFrame(NSRect(x: 20, y: 30, width: 1120, height: 720), display: true)
            await pause(0.25); captureWindow(loadingWindow, named: "vc-19-loading-\(suffix)")
            l.searchTask?.cancel()
        }
    }
}

extension WallpierTests {
    // Matched captures for the preview's caption contrast and display rim: landscape (16:9, cached original),
    // portrait, square and 32:9 in Fill, Fit and Center, light and dark. Written only when WALLPIER_CAPTURE_DIR is set.
    @MainActor
    func testCaptureContrastCorrections() async throws {
        try XCTSkipIf(Self.captureDirectory == nil, "Set WALLPIER_CAPTURE_DIR to write captures")
        let refs = CraftFixtures.references()
        let page = RemoteSearchPage(wallpapers: refs, currentPage: 1, lastPage: 92, total: 2_196,
                                    rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil))
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let root = try historyTestFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let originals = root.appendingPathComponent("Originals")
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            try CraftFixtures.png(index: 0, size: NSSize(width: 1920, height: 1080))
                .write(to: originals.appendingPathComponent(RemoteWallpaperCache.filename(for: refs[0])))
            let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: appearance,
                                                    windowClass: FloatingCaptureWindow.self, thumbnails: CraftThumbnails(), page: page) { _ in }
            defer { window.close() }
            c.showDiscover(nil)
            c.toggleViewer(nil)
            for (id, shape) in [("cr01", "landscape"), ("cr04", "portrait"), ("cr06", "square"), ("cr08", "ultrawide")] {
                for _ in refs where c.previewTitleLabel.stringValue != id { c.nextWallpaper(nil) }
                for scaling in ScalingMode.allCases {
                    c.scalingPopUp.selectItem(at: ScalingMode.allCases.firstIndex(of: scaling)!)
                    c.scalingSelectionChanged()
                    // cr01's cached original replaces its thumbnail asynchronously and retires the notice; wait for it.
                    _ = await eventually { c.stageView.image != nil && (id != "cr01" || c.approximatePreviewNotice.isHidden) }
                    window.setFrame(NSRect(x: 20, y: 30, width: 1120, height: 720), display: true)
                    await pause(0.25)
                    XCTAssertEqual(window.frame.size, NSSize(width: 1120, height: 720))
                    captureWindow(window, named: "cc-\(shape)-\(scaling.rawValue)-\(suffix)")
                }
            }
        }
    }
}

extension WallpierTests {
    // Matched captures for small secondary text outside the preview caption: apply-bar detail, informational and
    // error status, folder path, and empty-state explanations, light and dark, plus a live appearance switch.
    // Written only when WALLPIER_CAPTURE_DIR is set.
    @MainActor
    func testCaptureSecondaryTextContrast() async throws {
        try XCTSkipIf(Self.captureDirectory == nil, "Set WALLPIER_CAPTURE_DIR to write captures")
        let refs = CraftFixtures.references()
        let page = RemoteSearchPage(wallpapers: refs, currentPage: 1, lastPage: 92, total: 2_196,
                                    rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil))
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let root = try historyTestFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = root.appendingPathComponent("Pictures")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, name) in ["Torres del Paine at first light", "dune", "Quiet harbour"].enumerated() {
                try CraftFixtures.png(index: index + 3, size: NSSize(width: 960, height: 600)).write(to: folder.appendingPathComponent("\(name).png"))
            }
            func shot(_ window: NSWindow, _ name: String) async {
                window.setFrame(NSRect(x: 20, y: 30, width: 1120, height: 720), display: true)
                await pause(0.25)
                captureWindow(window, named: "st-\(name)-\(suffix)")
            }
            func typeSearch(_ c: MainWindowController, _ text: String) {
                c.searchField.stringValue = text
                c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
            }

            let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: appearance,
                                                    windowClass: FloatingCaptureWindow.self, thumbnails: CraftThumbnails(), page: page) { state in
                state.favorites = [1, 3, 5, 7].map { refs[$0] }
                state.selectedRemoteIdentity = refs[1].identityKey
            }
            defer { window.close() }
            c.showFavorites(nil)
            c.nextWallpaper(nil)                       // Apply-bar detail after a selection change: "1200 × 2133 · Portrait".
            typeSearch(c, "forest")                    // Informational status outside Discover.
            await shot(window, "01-applybar-detail-and-info-status")
            typeSearch(c, "")
            c.openFolder(folder)
            _ = await eventually { c.statusLabel.stringValue.hasPrefix("Loaded") }
            await shot(window, "02-folder-path-and-info-status")
            if appearance == .aqua {
                window.appearance = NSAppearance(named: .darkAqua)   // Switched while the views stay open.
                await shot(window, "03-folder-live-switch-to-dark")
            }

            let emptyRoot = try historyTestFolder()
            defer { try? FileManager.default.removeItem(at: emptyRoot) }
            let (e, emptyWindow) = makeCaptureController(root: emptyRoot, size: NSSize(width: 1120, height: 720), appearance: appearance,
                                                         windowClass: FloatingCaptureWindow.self, thumbnails: CraftThumbnails(), page: page) { state in
                state.favorites = []
                state.collections = []
            }
            defer { emptyWindow.close() }
            e.showFavorites(nil)
            await shot(emptyWindow, "04-empty-favorites")
            e.setWallpaper(nil)                         // Nothing selected: an error status.
            await shot(emptyWindow, "05-error-status")
            typeSearch(e, "forest")                     // Informational status after an error.
            await shot(emptyWindow, "06-info-status-after-error")
            typeSearch(e, "")
            e.showCollections(nil)
            await shot(emptyWindow, "07-empty-collections")
            e.search(nil)
            _ = await eventually { e.emptyStateView.title.hasPrefix("Couldn") }
            await shot(emptyWindow, "08-discover-offline")
        }
    }
}

extension WallpierTests {
    /// WCAG 2 contrast of a (possibly translucent) foreground composited over an opaque background, resolved in `appearance`.
    private func contrast(_ foreground: NSColor, on background: NSColor, in appearance: NSAppearance.Name) -> CGFloat {
        var ratio: CGFloat = 0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let f = foreground.usingColorSpace(.sRGB)!, b = background.usingColorSpace(.sRGB)!, a = f.alphaComponent
            func luminance(_ r: CGFloat, _ g: CGFloat, _ bl: CGFloat) -> CGFloat {
                func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(bl)
            }
            let top = luminance(f.redComponent * a + b.redComponent * (1 - a), f.greenComponent * a + b.greenComponent * (1 - a),
                                f.blueComponent * a + b.blueComponent * (1 - a))
            let bottom = luminance(b.redComponent, b.greenComponent, b.blueComponent)
            ratio = (max(top, bottom) + 0.05) / (min(top, bottom) + 0.05)
        }
        return ratio
    }

    func testSecondaryTextMeetsSmallTextContrastOnItsBackgrounds() {
        let appearances: [(NSAppearance.Name, NSAppearance.Name)] = [
            (.aqua, .accessibilityHighContrastAqua), (.darkAqua, .accessibilityHighContrastDarkAqua)
        ]
        for (standard, increased) in appearances {
            for background in [NSColor.windowBackgroundColor, Theme.canvas, Theme.stageBackdrop] {
                let normalContrast = contrast(.secondaryText, on: background, in: standard)
                XCTAssertGreaterThanOrEqual(normalContrast, 5, standard.rawValue)
                XCTAssertGreaterThan(contrast(.secondaryText, on: background, in: increased), normalContrast, increased.rawValue)
            }
            XCTAssertGreaterThan(contrast(Theme.inkPrimary, on: Theme.canvas, in: standard),
                                 contrast(.secondaryText, on: Theme.canvas, in: standard) * 1.8, standard.rawValue)
            XCTAssertGreaterThanOrEqual(contrast(Theme.statusError, on: .windowBackgroundColor, in: standard), 4.5, standard.rawValue)
            XCTAssertGreaterThanOrEqual(contrast(.white, on: Theme.accentFill, in: standard), 4.5, standard.rawValue)
        }
    }

    @MainActor
    func testSmallSecondaryTextUsesTheReadableColorThroughNormalOperations() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Pictures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTestImage(to: folder.appendingPathComponent("a.png"))
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua) { state in
            state.favorites = []
            state.collections = []
        }
        defer { window.close() }
        func typeSearch(_ text: String) {
            c.searchField.stringValue = text
            c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
        }
        func detailColor() -> NSColor? {
            let text = c.selectionLabel.attributedStringValue
            guard text.length > 0 else { return nil }
            return text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? NSColor
        }
        func labels(in view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels(in: $0) } }
        func emptyMessageColor() -> NSColor? {
            labels(in: c.emptyStateView).first { $0.stringValue == c.emptyStateView.message }?.textColor
        }

        // Apply-bar detail, before and after a selection change.
        c.showDiscover(nil)
        XCTAssertTrue(detailColor() === NSColor.secondaryText)
        c.nextWallpaper(nil)
        XCTAssertTrue(detailColor() === NSColor.secondaryText, "after a selection change")
        // Informational status, then an error, then information again: the error keeps its red, information never
        // falls back to the under-contrast system secondary label.
        c.showCollections(nil)                      // Empty: nothing selected. Search text outside Discover is informational.
        typeSearch("forest")
        XCTAssertFalse(c.statusLabel.isHidden)
        XCTAssertTrue(c.statusLabel.textColor === NSColor.secondaryText)
        c.setWallpaper(nil)
        XCTAssertEqual(c.statusLabel.stringValue, "Select a wallpaper first.")
        XCTAssertEqual(c.statusLabel.textColor, Theme.statusError)
        typeSearch("forest dusk")
        XCTAssertTrue(c.statusLabel.textColor === NSColor.secondaryText, "information after an error")
        typeSearch("")
        // Empty-state explanations.
        XCTAssertEqual(c.emptyStateView.title, "No Collections")
        XCTAssertTrue(emptyMessageColor() === NSColor.secondaryText, "empty Collections")
        c.showFavorites(nil)
        XCTAssertEqual(c.emptyStateView.title, "No Favorites Yet")
        XCTAssertTrue(emptyMessageColor() === NSColor.secondaryText, "empty Favorites")
        // Folder path after choosing, and after reloading, a folder.
        for pass in ["chosen", "reloaded"] {
            c.openFolder(folder)
            let loaded = expectation(description: "folder \(pass)")
            let poll = Task { @MainActor in
                while !c.statusLabel.stringValue.hasPrefix("Loaded") { await Task.yield() }
                loaded.fulfill()
            }
            wait(for: [loaded], timeout: 5); poll.cancel()
            XCTAssertTrue(c.statusLabel.textColor === NSColor.secondaryText, "folder \(pass) status")
            let path = labels(in: try XCTUnwrap(window.contentView)).first { $0.toolTip == folder.standardizedFileURL.path }
            XCTAssertNotNil(path, "folder bar shows the \(pass) folder")
            XCTAssertTrue(path?.textColor === NSColor.secondaryText, "folder path, \(pass)")
            c.statusLabel.stringValue = ""
        }
        // Appearance changes while the views stay open: the same color object resolves to each appearance's value.
        for name in [NSAppearance.Name.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua] {
            window.appearance = NSAppearance(named: name)
            var resolved: (NSColor, NSColor)!
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = (c.statusLabel.textColor!.usingColorSpace(.sRGB)!, Theme.inkSecondary.usingColorSpace(.sRGB)!)
            }
            XCTAssertEqual(resolved.0, resolved.1, name.rawValue)
        }
    }
}

// MARK: - Preview experience captures
//
// Real wallpaper imagery for matched captures: the macOS system wallpapers (read-only, local, not user state),
// each cropped to a different wallpaper shape so the gallery and preview meet 16:9 through 32:9, portrait and
// square. Decoded once at no more than 1,000 px. Skipped where the system set differs (captures only).

enum SystemWallpaperFixtures {
    static let directory = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
    static let entries: [(file: String, width: Int, height: Int)] = [
        ("Monterey Graphic", 3840, 2160), ("Chroma Red", 1440, 2560), ("Motion Green", 5120, 1440), ("Ventura Graphic", 2560, 1600),
        ("Radial Purple", 2000, 2000), ("Big Sur Graphic", 3440, 1440), ("Hello Metallic Orange", 3840, 2160), ("Chroma Blue", 2880, 1800),
        ("Studio Color", 3000, 2000), ("Grid Magenta", 3840, 2160), ("hello Blue", 2560, 1440), ("Radial Green", 3840, 2400)]
    static var isAvailable: Bool { entries.allSatisfy { FileManager.default.fileExists(atPath: url($0.file).path) } }
    static func url(_ file: String) -> URL { directory.appendingPathComponent("\(file).heic") }

    static func references() -> [WallpaperReference] {
        entries.enumerated().map { index, entry in
            let id = String(format: "sw%02d", index + 1)
            return WallpaperReference(
                providerIdentifier: "wallhaven", wallpaperID: id,
                sourcePageURL: URL(string: "https://wallhaven.cc/w/\(id)")!,
                originalURL: URL(string: "https://w.wallhaven.cc/full/sw/wallhaven-\(id).jpg")!,
                previewURL: URL(string: "https://th.wallhaven.cc/lg/sw/\(id).jpg")!,
                thumbnailURL: URL(string: "https://th.wallhaven.cc/small/sw/\(id).jpg")!,
                width: entry.width, height: entry.height,
                uploader: ["northlight", "atlas_studio", "m.k."][index % 3],
                tags: [entry.file.lowercased(), "abstract"], cachedLocalPath: nil,
                uncroppedPreviewURL: URL(string: "https://th.wallhaven.cc/orig/sw/\(id).jpg")!)
        }
    }

    private static var decoded: [Int: CGImage] = [:]

    /// The wallpaper itself: the system image centre-cropped to the entry's shape.
    static func wallpaper(_ index: Int) -> CGImage {
        if let image = decoded[index] { return image }
        let entry = entries[index]
        let source = CGImageSourceCreateWithURL(url(entry.file) as CFURL, nil)!
        let full = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)!
        let crop = DesktopPreviewView.cropRect(of: CGSize(width: full.width, height: full.height),
                                               toAspectOf: CGSize(width: entry.width, height: entry.height))
        let image = full.cropping(to: crop.integral)!
        decoded[index] = image
        return image
    }

    /// Wallhaven's thumbnail kinds: `lg` is a 16:9 crop, `small` a 3:2 crop, `orig` the whole picture.
    static func thumbnail(_ index: Int, for url: URL) -> NSImage {
        let entry = entries[index], picture = wallpaper(index)
        let canvas = CompositionFixtures.canvas(for: url, original: CGSize(width: entry.width, height: entry.height))
        let crop = DesktopPreviewView.cropRect(of: CGSize(width: picture.width, height: picture.height), toAspectOf: canvas)
        return NSImage(cgImage: picture.cropping(to: crop.integral)!, size: canvas)
    }

    static func writeOriginal(_ index: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, wallpaper(index), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// Serves system-wallpaper thumbnails; can hold callbacks (a slow network) or fail chosen wallpapers.
final class SystemWallpaperThumbnails: RemoteThumbnailProvider {
    var holds = false
    var failing: Set<String> = []
    private var held: [(URL, (NSImage?) -> Void)] = []
    override func requestThumbnail(for url: URL, maximumPixelSize: Int = 420, completion: @escaping (NSImage?) -> Void) {
        if holds { held.append((url, completion)); return }
        let id = url.deletingPathExtension().lastPathComponent
        guard !failing.contains(id), let number = Int(id.dropFirst(2)), SystemWallpaperFixtures.entries.indices.contains(number - 1)
        else { return completion(nil) }
        completion(SystemWallpaperFixtures.thumbnail(number - 1, for: url))
    }
    func releaseHeld() { let pending = held; held = []; holds = false; pending.forEach { requestThumbnail(for: $0.0, completion: $0.1) } }
    override func reset() {}
}

extension WallpierTests {
    @MainActor
    func testCapturePreviewExperience() async throws {
        try XCTSkipIf(Self.captureDirectory == nil, "Set WALLPIER_CAPTURE_DIR to write captures")
        try XCTSkipUnless(SystemWallpaperFixtures.isAvailable, "This macOS has a different system wallpaper set")
        let refs = SystemWallpaperFixtures.references()
        let page = RemoteSearchPage(wallpapers: refs, currentPage: 1, lastPage: 92, total: 2_196,
                                    rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil))
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let root = try historyTestFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let originals = root.appendingPathComponent("Originals")
            for index in [0, 1, 2] { try SystemWallpaperFixtures.writeOriginal(index, to: originals.appendingPathComponent(RemoteWallpaperCache.filename(for: refs[index]))) }
            let thumbnails = SystemWallpaperThumbnails()
            let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: appearance,
                                                    windowClass: FloatingCaptureWindow.self, thumbnails: thumbnails, page: page) { state in
                state.favorites = [3, 4, 7, 8, 9, 11].map { refs[$0] }
                state.selectedRemoteIdentity = refs[0].identityKey
            }
            defer { window.close() }
            var size = NSSize(width: 1120, height: 720)
            func shot(_ name: String) async {
                window.setFrame(NSRect(origin: NSPoint(x: 20, y: 30), size: size), display: true)
                await pause(0.3)
                captureWindow(window, named: "pe-\(name)-\(suffix)")
            }
            func show(_ id: String, _ scaling: ScalingMode, settled: Bool = true) async {
                // Step towards the wallpaper: Discover doesn't wrap while Wallhaven has more pages.
                func position(_ wallpaperID: String) -> Int { c.remoteResults.firstIndex { $0.wallpaperID == wallpaperID } ?? 0 }
                for _ in refs where c.previewTitleLabel.stringValue != id {
                    if position(c.previewTitleLabel.stringValue) < position(id) { c.nextWallpaper(nil) } else { c.previousWallpaper(nil) }
                }
                c.scalingPopUp.selectItem(at: ScalingMode.allCases.firstIndex(of: scaling)!)
                c.scalingSelectionChanged()
                if settled { _ = await eventually { c.stageView.image != nil && (Int(id.dropFirst(2))! > 3 || c.approximatePreviewNotice.isHidden) } }
            }
            c.showDiscover(nil)
            window.makeFirstResponder(c.collectionView)
            await shot("01-discover-gallery")
            c.toggleViewer(nil)
            await show("sw01", .fill); await shot("02-preview-landscape-original")
            await show("sw02", .fit); await shot("03-preview-portrait-fit")
            await show("sw03", .fill); await shot("04-preview-ultrawide-fill")
            await show("sw12", .fill); await shot("05-preview-last-loaded")
            size = window.minSize
            await show("sw04", .fill); await shot("06-preview-minimum")
            size = NSSize(width: 1120, height: 720)
            thumbnails.holds = true
            c.nextWallpaper(nil)                         // sw05, not yet cached: the slow first frame.
            await pause(0.5); await shot("07-preview-slow-first-frame")
            thumbnails.releaseHeld()
            thumbnails.failing = ["sw06"]
            c.nextWallpaper(nil)                         // sw06: its preview thumbnail fails.
            await pause(0.5); await shot("08-preview-thumbnail-failed")
            c.toggleViewer(nil)
            c.showFavorites(nil)
            c.toggleViewer(nil)
            c.nextWallpaper(nil)
            _ = await eventually { c.stageView.image != nil }
            await shot("09-favorites-preview")

            let emptyRoot = try historyTestFolder()
            defer { try? FileManager.default.removeItem(at: emptyRoot) }
            let (e, emptyWindow) = makeCaptureController(root: emptyRoot, size: NSSize(width: 1120, height: 720), appearance: appearance,
                                                         windowClass: FloatingCaptureWindow.self, thumbnails: SystemWallpaperThumbnails(), page: page) { state in
                state.favorites = []
            }
            defer { emptyWindow.close() }
            e.showFavorites(nil)
            emptyWindow.setFrame(NSRect(x: 20, y: 30, width: 1120, height: 720), display: true)
            await pause(0.3); captureWindow(emptyWindow, named: "pe-10-empty-favorites-\(suffix)")
        }
    }
}

// MARK: - Preview experience: pointer navigation, gallery controls, first frame, empty Favorites

extension WallpierTests {
    /// A real click on a view's centre.
    @MainActor
    private func click(_ view: NSView, in window: NSWindow) {
        click(at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), in: window)
    }

    /// A real click at a window point: the view's own mouse handling receives the queued mouse-up, as with a user's click.
    @MainActor
    private func click(at point: NSPoint, in window: NSWindow) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        // The button's tracking loop consumes the mouse-up; never leave one behind for a later test.
        while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
    }

    @MainActor
    private func key(_ characters: String, code: UInt16, in window: NSWindow) {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
    }

    @MainActor
    func testPreviewButtonsAndKeysShareOneNavigationPathInCompleteSources() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                windowClass: KeyTestWindow.self) { state in
            state.collections[1] = WallpaperCollection(name: "Solo", wallpapers: [state.favorites[0]])   // One wallpaper.
        }
        defer { window.close() }
        window.orderFront(nil)
        let favorites = c.state.favorites
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let previous = NSMenuItem(title: "", action: #selector(MainWindowController.previousWallpaper(_:)), keyEquivalent: "")
        let next = NSMenuItem(title: "", action: #selector(MainWindowController.nextWallpaper(_:)), keyEquivalent: "")
        func expect(_ index: Int, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(c.collectionView.selectionIndexPaths, [IndexPath(item: index, section: 0)], step, file: file, line: line)
            XCTAssertEqual(c.state.selectedRemoteIdentity, favorites[index].identityKey, step, file: file, line: line)
            XCTAssertEqual(c.previewTitleLabel.stringValue, favorites[index].wallpaperID, step, file: file, line: line)
            XCTAssertEqual(c.previewPositionLabel.stringValue, "\(index + 1) of \(favorites.count)", step, file: file, line: line)
        }

        c.showFavorites(nil)
        c.toggleViewer(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.firstResponder === c.viewerView)
        expect(1, "opened")
        // Pointer: the visible buttons. Keyboard focus stays in the preview, so arrow keys keep working.
        XCTAssertTrue(c.previewNextButton.refusesFirstResponder)
        click(c.previewNextButton, in: window); expect(2, "clicked Next")
        XCTAssertTrue(window.firstResponder === c.viewerView, "a click doesn't take keyboard focus")
        key(right, code: 124, in: window); expect(3, "→ after a click")
        c.nextWallpaper(next); expect(4, "⌘]")
        click(c.previewNextButton, in: window); expect(5, "clicked Next")
        // A complete source wraps at both ends, by pointer and by key alike.
        click(c.previewNextButton, in: window); expect(0, "Next wraps after the last")
        click(c.previewPreviousButton, in: window); expect(5, "Previous wraps before the first")
        key(left, code: 123, in: window); expect(4, "←")
        XCTAssertTrue(c.previewPreviousButton.isEnabled && c.previewNextButton.isEnabled)
        XCTAssertTrue(c.validateMenuItem(previous) && c.validateMenuItem(next))
        // Return still sets the wallpaper on show, from the preview, after pointer navigation.
        XCTAssertTrue(window.defaultButtonCell === c.setWallpaperButton.cell)

        // A source switch closes the preview; the one-wallpaper collection has nowhere to go.
        let only = c.state.collections[1]
        let row = c.sidebarForTesting.outlineView.row(forItem: c.sidebarForTesting.rows.first { $0.title == only.name })
        c.sidebarForTesting.outlineView.selectRowIndexes([row], byExtendingSelection: false)
        XCTAssertFalse(c.isViewerVisible, "switching sources returns to the gallery")
        c.toggleViewer(nil)
        XCTAssertEqual(c.previewPositionLabel.stringValue, "1 of 1")
        XCTAssertFalse(c.previewPreviousButton.isEnabled); XCTAssertFalse(c.previewNextButton.isEnabled)
        XCTAssertFalse(c.validateMenuItem(previous)); XCTAssertFalse(c.validateMenuItem(next))
        key(right, code: 124, in: window)
        XCTAssertEqual(c.state.selectedRemoteIdentity, only.wallpapers[0].identityKey)

        // An empty source: no preview, no target, nothing to navigate.
        c.showLocal(nil)
        XCTAssertFalse(c.isViewerVisible)
        XCTAssertEqual(c.previewPositionLabel.stringValue, "")
        XCTAssertFalse(c.previewPreviousButton.isEnabled); XCTAssertFalse(c.previewNextButton.isEnabled)
        XCTAssertFalse(c.validateMenuItem(previous)); XCTAssertFalse(c.validateMenuItem(next))
    }

    @MainActor
    func testDiscoverPreviewStopsAtLoadedResultsAndFinishesTheMoveWhenThePageArrives() async throws {
        let network = Batch2Network()
        network.lastPage = 2
        let (c, window, _) = try await batch2Controller(network)
        let previous = NSMenuItem(title: "", action: #selector(MainWindowController.previousWallpaper(_:)), keyEquivalent: "")
        c.showDiscover(nil)
        c.toggleViewer(nil)
        let first = c.remoteResults.map(\.identityKey)
        XCTAssertEqual(first.count, 6)
        XCTAssertEqual(network.searchJournal.count, 0, "precondition: no page request before the boundary")
        XCTAssertEqual(c.previewPositionLabel.stringValue, "1 of 6 loaded", "loaded results are not the whole Wallhaven set")
        XCTAssertNotNil(c.previewPositionLabel.toolTip)
        // No wrapping while Wallhaven has more: Previous at the first result is unavailable.
        XCTAssertFalse(c.previewPreviousButton.isEnabled)
        XCTAssertFalse(c.validateMenuItem(previous))
        c.previousWallpaper(nil)
        XCTAssertEqual(c.state.selectedRemoteIdentity, first[0])
        for _ in 0..<5 { c.previewNextButton.performClick(nil) }
        XCTAssertEqual(c.previewPositionLabel.stringValue, "6 of 6 loaded")
        XCTAssertTrue(c.previewNextButton.isEnabled, "Next at the last loaded result loads more")
        let searches = network.searches.count
        c.previewNextButton.performClick(nil)
        XCTAssertFalse(c.previewNextButton.isEnabled, "one page request at a time")
        XCTAssertEqual(c.state.selectedRemoteIdentity, first[5], "Next waits while the page loads")
        let loaded = await eventually { c.remoteResults.count == 12 }
        XCTAssertEqual(network.searches.count, searches + 1)
        XCTAssertEqual(network.searches.last?.queryItems?.first { $0.name == "page" }?.value, "2")
        XCTAssertTrue(loaded)
        XCTAssertTrue(c.isViewerVisible)
        // The Next that asked for the page completes once it arrives (guards: see the cancellation test).
        XCTAssertEqual(c.state.selectedRemoteIdentity, c.remoteResults[6].identityKey)
        XCTAssertEqual(c.collectionView.selectionIndexPaths, [IndexPath(item: 6, section: 0)])
        XCTAssertEqual(c.previewPositionLabel.stringValue, "7 of 12", "every page is loaded now")
        // A complete Discover set wraps, as other sources do.
        for _ in 0..<5 { c.nextWallpaper(nil) }
        XCTAssertEqual(c.previewPositionLabel.stringValue, "12 of 12")
        c.previewNextButton.performClick(nil)
        XCTAssertEqual(c.state.selectedRemoteIdentity, first[0])
        XCTAssertEqual(network.searches.count, searches + 1, "no further requests")
        window.close()
    }

    @MainActor
    func testPreviewNavigationDuringAnInFlightSetLeavesTheCapturedTarget() async throws {
        let network = Batch2Network(), desktop = SetAuditWallpaperService()
        let (c, window, root) = try await batch2Controller(network, desktop: desktop)
        window.orderFront(nil)
        let download = root.appendingPathComponent("download.png")
        try CompositionFixtures.writeOriginal(CGSize(width: 3840, height: 2160), to: download)
        network.originalFile = download
        c.showDiscover(nil)
        c.nextWallpaper(nil)                                         // Second result: Previous and Next both lead somewhere.
        c.toggleViewer(nil)
        let captured = c.remoteResults[1]
        let gate = SetAuditGate<Void>()
        network.downloadGate = gate
        c.setWallpaper(nil)
        await fulfillment(of: [gate.started], timeout: 2)
        click(c.previewNextButton, in: window)                       // Browsing stays free while the original downloads.
        XCTAssertEqual(c.state.selectedRemoteIdentity, c.remoteResults[2].identityKey)
        XCTAssertTrue(c.previewPreviousButton.isEnabled && c.previewNextButton.isEnabled, "navigation isn't blocked by a Set")
        XCTAssertFalse(c.setWallpaperButton.isEnabled, "one Set at a time")
        gate.release(.success(()))
        try await finishAuditTask(c.downloadTask)
        XCTAssertEqual(desktop.calls.map(\.image.path),
                       [root.appendingPathComponent("Rollback").appendingPathComponent(RemoteWallpaperCache.filename(for: captured)).path],
                       "the Set applies the wallpaper it captured")
        XCTAssertEqual(c.state.selectedRemoteIdentity, c.remoteResults[2].identityKey, "and leaves the browsed one selected")
        XCTAssertEqual(c.previewPositionLabel.stringValue, "3 of 6 loaded")
    }

    @MainActor
    func testPreviewSetsGalleryControlsAsideAndExplicitSearchesReturnToTheGallery() async throws {
        let network = Batch2Network()
        let (c, window, root) = try await batch2Controller(network)
        c.showDiscover(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(c.categoryPopUp.isHiddenOrHasHiddenAncestor, "filters belong to the gallery")
        c.nextWallpaper(nil); c.nextWallpaper(nil)
        let inspected = c.state.selectedRemoteIdentity
        c.toggleViewer(nil)
        XCTAssertTrue(c.categoryPopUp.isHiddenOrHasHiddenAncestor, "and step aside in the preview")
        XCTAssertTrue(c.updateResultsButton.isHiddenOrHasHiddenAncestor)
        // A draft query and ⌘F keep the preview and its wallpaper; no request starts.
        let searches = network.searches.count
        c.searchField.stringValue = "forest"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
        c.focusSearch(nil)
        XCTAssertTrue(c.isViewerVisible)
        XCTAssertEqual(c.state.selectedRemoteIdentity, inspected)
        XCTAssertEqual(network.searches.count, searches)
        // Return (or Update Results) is an explicit new search: back to the gallery, which shows the new results.
        c.search(nil)
        XCTAssertFalse(c.isViewerVisible, "returns to the gallery before the results change")
        XCTAssertFalse(c.categoryPopUp.isHiddenOrHasHiddenAncestor)
        _ = await eventually { !c.remoteResults.isEmpty }
        XCTAssertFalse(c.isViewerVisible)
        XCTAssertEqual(network.searches.last?.queryItems?.first { $0.name == "q" }?.value, "forest")
        // A filter command while previewing (not reachable by pointer now) behaves the same way.
        c.toggleViewer(nil)
        c.categoryPopUp.selectItem(at: 1)
        _ = NSApp.sendAction(c.categoryPopUp.action!, to: c.categoryPopUp.target, from: c.categoryPopUp)
        XCTAssertFalse(c.isViewerVisible)
        _ = await eventually { !c.remoteResults.isEmpty }

        // The folder bar steps aside in a folder's preview too.
        let folder = root.appendingPathComponent("Pictures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTestImage(to: folder.appendingPathComponent("a.png")); try writeTestImage(to: folder.appendingPathComponent("b.png"))
        c.openFolder(folder)
        _ = await eventually { c.statusLabel.stringValue.hasPrefix("Loaded") }
        func folderBar() -> NSView? {
            func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
            return all(window.contentView!).first { ($0 as? NSTextField)?.toolTip == folder.standardizedFileURL.path }
        }
        XCTAssertEqual(folderBar()?.isHiddenOrHasHiddenAncestor, false)
        c.toggleViewer(nil)
        XCTAssertEqual(folderBar()?.isHiddenOrHasHiddenAncestor, true)
        XCTAssertEqual(c.previewPositionLabel.stringValue, "1 of 2")
        c.toggleViewer(nil)
        XCTAssertEqual(folderBar()?.isHiddenOrHasHiddenAncestor, false)
    }

    @MainActor
    func testEmptyStageSaysLoadingOrUnavailableButNeverShowsAStandIn() async throws {
        let network = Batch2Network(), thumbnails = CompositionThumbnails()
        let (c, _, _) = try await batch2Controller(network, thumbnails)
        c.showDiscover(nil)
        // Slow first frame: nothing at first, then a spinner, never a substitute picture.
        thumbnails.holds = true
        c.toggleViewer(nil)
        XCTAssertNil(c.stageView.image)
        XCTAssertEqual(c.stageView.placeholder, .loading)
        XCTAssertFalse(c.stageView.isShowingLoadingIndicator, "no spinner flash for a quick load")
        let opened = Date()
        let spinning = await eventually(2) { c.stageView.isShowingLoadingIndicator }
        XCTAssertTrue(spinning, "a spinner once loading takes a moment")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(opened), DesktopPreviewView.loadingIndicatorDelay - 0.02, "not before the delay")
        XCTAssertNil(c.stageView.image)
        thumbnails.releaseHeld()
        XCTAssertNotNil(c.stageView.image)
        XCTAssertEqual(c.stageView.placeholder, .none)
        XCTAssertFalse(c.stageView.isShowingLoadingIndicator)
        // Cached pictures arrive at once: browsing back never shows a placeholder.
        thumbnails.holds = false
        c.nextWallpaper(nil); c.previousWallpaper(nil)
        XCTAssertNotNil(c.stageView.image)
        XCTAssertEqual(c.stageView.placeholder, .none)
        // A preview that can't load says so instead of showing an empty display.
        let failing = c.remoteResults[2].wallpaperID
        thumbnails.sizes.removeValue(forKey: failing)
        c.nextWallpaper(nil); c.nextWallpaper(nil)
        XCTAssertEqual(c.previewTitleLabel.stringValue, failing)
        XCTAssertNil(c.stageView.image)
        XCTAssertEqual(c.stageView.placeholder, .unavailable)
        XCTAssertEqual(c.stageView.accessibilityValue() as? String, "Preview unavailable")
        XCTAssertFalse(c.approximatePreviewNotice.isHidden == false && c.stageView.image == nil, "no fidelity notice without a picture")
        // A stale failure for a wallpaper no longer shown changes nothing.
        thumbnails.holds = true
        c.nextWallpaper(nil)
        let shown = c.previewTitleLabel.stringValue
        thumbnails.releaseHeld()
        XCTAssertEqual(c.previewTitleLabel.stringValue, shown)
        XCTAssertNotNil(c.stageView.image)
        XCTAssertEqual(c.stageView.placeholder, .none)
    }

    @MainActor
    func testEmptyFavoritesLeadsToDiscover() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua) { state in
            state.favorites = []
        }
        defer { window.close() }
        c.showFavorites(nil)
        XCTAssertEqual(c.emptyStateView.title, "No Favorites Yet")
        XCTAssertFalse(c.emptyStateView.actionButton.isHidden)
        XCTAssertEqual(c.emptyStateView.actionButton.title, "Browse Discover")
        c.emptyStateView.actionButton.performClick(nil)
        XCTAssertEqual(c.state.currentSource, .discover)
        XCTAssertFalse(c.remoteResults.isEmpty)
    }
}

// MARK: - Fit by default, and preview acceptance repairs

extension WallpierTests {
    /// A controller over an existing state file, through the real startup path, as a relaunch would.
    @MainActor
    private func relaunchCapture(root: URL, desktop: WallpaperService) -> (MainWindowController, NSWindow) {
        let window = KeyTestWindow(contentRect: NSRect(x: 20, y: 30, width: 1120, height: 720),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let originals = root.appendingPathComponent("Originals")
        let controller = MainWindowController(window: window, wallpaperService: desktop,
            stateStore: WallpaperStateStore(stateURL: root.appendingPathComponent("state.json")),
            provider: WallhavenProvider(client: OfflineNetwork()), openverseProvider: OpenverseProvider(client: OfflineNetwork()), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: root.appendingPathComponent("Rollback")),
            remoteThumbnailProvider: CaptureThumbnails(), availableScreens: { [CaptureScreen()] })
        controller.prepareForVisualCapture(discoverPage: RemoteSearchPage(wallpapers: [], currentPage: 1, lastPage: 1, total: 0,
            rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil)))
        return (controller, window)
    }

    @MainActor
    private func setAndRotate(_ c: MainWindowController) async throws {
        _ = await eventually { c.statusLabel.stringValue.hasPrefix("Loaded") }
        c.setWallpaper(nil)
        try await finishAuditTask(c.downloadTask)
        c.rotateWallpaper()
        try await finishAuditTask(c.rotationTask)
    }

    func testNewStateAndMissingSavedValuesDefaultToFit() throws {
        XCTAssertEqual(WallpaperState().scalingMode, .fit)
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(WallpaperStateStore(stateURL: root.appendingPathComponent("absent.json")).load().scalingMode, .fit, "first launch")
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(WallpaperState.self, from: Data("{}".utf8)).scalingMode, .fit, "no saved choice")
        XCTAssertEqual(try decoder.decode(WallpaperState.self, from: Data(#"{"scalingMode":"fill"}"#.utf8)).scalingMode, .fill,
                       "a saved Fill is kept: it can't be told apart from a deliberate choice")
        XCTAssertEqual(try decoder.decode(WallpaperState.self, from: Data(#"{"scalingMode":"center"}"#.utf8)).scalingMode, .center)
    }

    @MainActor
    func testANewInstallationSetsAndRotatesWithFit() async throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Pictures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] { try writeTestImage(to: folder.appendingPathComponent("\(name).png")) }
        let desktop = SetAuditWallpaperService()
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                windowClass: KeyTestWindow.self, desktop: desktop) { state in
            state.currentSource = .local
            state.folderPath = folder.path
        }
        defer { window.close() }
        XCTAssertEqual(c.scalingPopUp.titleOfSelectedItem, "Fit to Screen")
        XCTAssertEqual(c.stageView.scaling, .fit, "the preview estimates the same mode")
        try await setAndRotate(c)
        XCTAssertEqual(desktop.calls.map(\.scaling), [.fit, .fit], "manual Set and rotation request Fit")
        XCTAssertEqual(c.state.history.last?.replacement.scaling, .fit)
        // After a relaunch the default is still Fit, and still used.
        window.close()
        let (relaunched, second) = relaunchCapture(root: root, desktop: desktop)
        defer { second.close() }
        XCTAssertEqual(relaunched.scalingPopUp.titleOfSelectedItem, "Fit to Screen")
        try await setAndRotate(relaunched)
        XCTAssertEqual(desktop.calls.map(\.scaling), [.fit, .fit, .fit, .fit])
    }

    @MainActor
    func testADeliberateScalingChoiceIsKeptAcrossRelaunchesSetsAndRotation() async throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Pictures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] { try writeTestImage(to: folder.appendingPathComponent("\(name).png")) }
        let desktop = SetAuditWallpaperService()
        // An existing installation whose saved state says Fill (deliberately or by the old default).
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                windowClass: KeyTestWindow.self, desktop: desktop) { state in
            state.currentSource = .local
            state.folderPath = folder.path
            state.scalingMode = .fill
        }
        XCTAssertEqual(c.scalingPopUp.titleOfSelectedItem, "Fill Screen", "a saved choice isn't overwritten")
        try await setAndRotate(c)
        XCTAssertEqual(desktop.calls.map(\.scaling), [.fill, .fill])
        // Switching to Fit once is kept from then on.
        c.scalingPopUp.selectItem(withTitle: "Fit to Screen"); c.scalingSelectionChanged()
        try await setAndRotate(c)
        window.close()
        for expected in [ScalingMode.fit, .fit] {
            let (relaunched, next) = relaunchCapture(root: root, desktop: desktop)
            XCTAssertEqual(relaunched.state.scalingMode, expected)
            try await setAndRotate(relaunched)
            next.close()
        }
        XCTAssertEqual(desktop.calls.map(\.scaling), [.fill, .fill, .fit, .fit, .fit, .fit, .fit, .fit])
        // Center, chosen deliberately, is kept too.
        let (centered, third) = relaunchCapture(root: root, desktop: desktop)
        centered.scalingPopUp.selectItem(withTitle: "Center"); centered.scalingSelectionChanged()
        third.close()
        let (again, fourth) = relaunchCapture(root: root, desktop: desktop)
        defer { fourth.close() }
        XCTAssertEqual(again.state.scalingMode, .center)
        try await setAndRotate(again)
        XCTAssertEqual(desktop.calls.suffix(2).map(\.scaling), [.center, .center])
    }

    @MainActor
    func testDiscoverPageFailureLetsNextRetryOnceTheCooldownEnds() async throws {
        let network = Batch2Network()
        let (c, window, _) = try await batch2Controller(network)
        defer { window.close() }
        c.showDiscover(nil)
        c.toggleViewer(nil)
        for _ in 0..<5 { c.nextWallpaper(nil) }
        network.apiStatus = 500
        c.previewNextButton.performClick(nil)
        let failed = await eventually { c.statusLabel.stringValue.hasPrefix("Couldn’t load more results") }
        XCTAssertTrue(failed)
        XCTAssertFalse(c.previewNextButton.isEnabled, "a short cooldown after a failed page")
        network.apiStatus = 200
        let ready = await eventually(8) { c.previewNextButton.isEnabled }
        XCTAssertTrue(ready, "Next becomes available again when the cooldown ends, without any other event")
        c.previewNextButton.performClick(nil)
        let advanced = await eventually { c.remoteResults.count == 12 && c.state.selectedRemoteIdentity == c.remoteResults[6].identityKey }
        XCTAssertTrue(advanced, "the retried Next loads the page and moves on")
    }

    @MainActor
    func testClickingThePagerReturnsKeyboardFocusToThePreview() throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                windowClass: KeyTestWindow.self) { _ in }
        defer { window.close() }
        window.orderFront(nil)
        c.showDiscover(nil)
        c.toggleViewer(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let start = try XCTUnwrap(c.collectionView.selectionIndexPaths.first?.item)
        // Find: the search field edits a draft while the preview stays.
        c.focusSearch(nil)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate === c.searchField)
        editor.insertText("forest", replacementRange: editor.selectedRange())
        XCTAssertTrue(c.isViewerVisible)
        // Clicking Next moves on and gives the keyboard back to the preview, so → navigates rather than editing text.
        click(c.previewNextButton, in: window)
        XCTAssertEqual(c.collectionView.selectionIndexPaths.first?.item, start + 1)
        XCTAssertTrue(window.firstResponder === c.viewerView)
        key(String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), code: 124, in: window)
        XCTAssertEqual(c.collectionView.selectionIndexPaths.first?.item, start + 2)
        XCTAssertEqual(c.searchField.stringValue, "forest", "the draft is kept, not searched")
        XCTAssertTrue(c.isViewerVisible)
    }

    /// Discover's preview at the last loaded result (6 of 6; Wallhaven has page 2), with every search request held.
    @MainActor
    private func boundaryPreview(_ network: Batch2Network, file: StaticString = #filePath, line: UInt = #line) async throws
        -> (MainWindowController, NSWindow) {
        network.holdsSearches = true
        let (c, window, _) = try await batch2Controller(network)
        c.showDiscover(nil)
        c.toggleViewer(nil)
        for _ in 0..<5 { c.nextWallpaper(nil) }
        // Stated, not assumed: nothing (such as gallery pagination) has asked for page 2 before the boundary.
        XCTAssertEqual(network.searchJournal.map(\.page), [], "precondition: no page request before the boundary", file: file, line: line)
        XCTAssertNil(c.searchTask, "precondition: no page request in flight before the boundary", file: file, line: line)
        XCTAssertEqual(c.previewPositionLabel.stringValue, "6 of 6 loaded", file: file, line: line)
        return (c, window)
    }

    /// Clicks Next at the boundary and waits, on the network journal, for the page-2 request to arrive and be held.
    /// Returns the controller's page task, or nil after recording exactly why the request didn't start.
    @MainActor
    private func startBoundaryRequest(_ c: MainWindowController, _ network: Batch2Network,
                                      file: StaticString = #filePath, line: UInt = #line) async -> Task<Void, Never>? {
        guard c.previewNextButton.isEnabled else {
            XCTFail("never started: Next is unavailable at the boundary" +
                    (c.searchTask != nil ? " because a page request is already in flight (it began before the boundary)" : ""),
                    file: file, line: line)
            return nil
        }
        c.previewNextButton.performClick(nil)
        guard let task = c.searchTask else {
            XCTFail("never started: the boundary Next began no page request", file: file, line: line); return nil
        }
        // A bound, not a pace: the held page normally arrives at once, but a loaded Intel host has taken over 2 s.
        guard await eventually(10, { network.searchState(page: 2) == .held }) else {
            XCTFail("never started: page 2 didn't reach the network (journal \(network.searchJournal.map { "\($0.page) \($0.state)" }))",
                    file: file, line: line)
            return nil
        }
        return task
    }

    @MainActor
    func testNextAtTheLastLoadedResultFinishesItsMoveWhenThePageArrives() async throws {
        let network = Batch2Network()
        let (c, window) = try await boundaryPreview(network)
        defer { window.close() }
        let last = try XCTUnwrap(c.state.selectedRemoteIdentity)
        guard let task = await startBoundaryRequest(c, network) else { return }
        // Started and held: nothing moves yet.
        XCTAssertEqual(c.state.selectedRemoteIdentity, last, "waits for the page")
        XCTAssertEqual(c.statusLabel.stringValue, "Loading more results from Wallhaven…")
        XCTAssertFalse(c.previewNextButton.isEnabled, "one page request at a time")
        // Completed: the controller's page task has applied the page.
        XCTAssertTrue(network.releaseSearch(page: 2))
        await task.value
        XCTAssertEqual(network.searchState(page: 2), .answered)
        XCTAssertEqual(c.remoteResults.count, 12)
        XCTAssertEqual(c.state.selectedRemoteIdentity, c.remoteResults[6].identityKey, "the Next that asked for the page completes")
        XCTAssertEqual(c.previewPositionLabel.stringValue, "7 of 12")
        XCTAssertNotEqual(c.statusLabel.stringValue, "Loading more results from Wallhaven…", "the loading status is cleared")
        // Exactly once: later run-loop turns move nothing, and the next Next is an ordinary step.
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(c.collectionView.selectionIndexPaths, [IndexPath(item: 6, section: 0)])
        c.nextWallpaper(nil)
        XCTAssertEqual(c.state.selectedRemoteIdentity, c.remoteResults[7].identityKey)
        XCTAssertEqual(network.searchJournal.count, 1, "no further requests")
    }

    @MainActor
    func testAPendingBoundaryMoveIsCancelledByAnythingThatChangesTheContext() async throws {
        enum Interruption: String, CaseIterable { case selection, closePreview, source, query, failure }
        for interruption in Interruption.allCases {
            let network = Batch2Network()
            let (c, window) = try await boundaryPreview(network)
            defer { window.close() }
            let context = interruption.rawValue
            guard let task = await startBoundaryRequest(c, network) else { continue }
            switch interruption {
            case .selection: c.previousWallpaper(nil)
            case .closePreview: c.toggleViewer(nil)
            case .source: c.showFavorites(nil)
            case .query:
                c.searchField.stringValue = "forest"
                c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.searchField))
            case .failure: break
            }
            let expected = c.state.selectedRemoteIdentity
            XCTAssertTrue(network.releaseSearch(page: 2, failingWith: interruption == .failure ? URLError(.notConnectedToInternet) : nil))
            await task.value                                             // The completion has run to its end.
            XCTAssertEqual(network.searchState(page: 2), interruption == .failure ? .failed : .answered, context)
            switch interruption {
            case .selection, .closePreview:
                XCTAssertEqual(c.remoteResults.count, 12, "\(context): the page itself still arrives")
            case .source, .query:
                XCTAssertEqual(c.remoteResults.count, 6, "\(context): the superseded request's results are discarded")
            case .failure:
                XCTAssertTrue(c.statusLabel.stringValue.hasPrefix("Couldn’t load more results"), context)
            }
            XCTAssertEqual(c.state.selectedRemoteIdentity, expected, "\(context): completed, and the cancelled move never advances")
            if interruption == .failure {
                // A later gallery pagination attempt (inside the cooldown) neither requests nor moves anything.
                c.toggleViewer(nil)
                c.galleryScrollForTesting.contentView.scroll(to: NSPoint(x: 0, y: 10_000))
                NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: c.galleryScrollForTesting.contentView)
                XCTAssertEqual(network.searchJournal.count, 1, "\(context): no request during the cooldown")
                XCTAssertEqual(c.state.selectedRemoteIdentity, expected)
            }
        }
    }

    @MainActor
    func testClosingThePreviewStopsItsLoadingStateAndIgnoresLateCallbacks() async throws {
        let network = Batch2Network(), thumbnails = CompositionThumbnails()
        let (c, window, _) = try await batch2Controller(network, thumbnails)
        defer { window.close() }
        c.showDiscover(nil)
        thumbnails.holds = true
        c.toggleViewer(nil)
        XCTAssertEqual(c.stageView.placeholder, .loading)
        c.toggleViewer(nil)
        XCTAssertEqual(c.stageView.placeholder, .none, "closing ends the loading state")
        await pause(DesktopPreviewView.loadingIndicatorDelay + 0.3)
        XCTAssertFalse(c.stageView.isShowingLoadingIndicator, "the delayed spinner was cancelled")
        thumbnails.sizes.removeAll()                       // The late answer is a failure.
        thumbnails.releaseHeld()
        XCTAssertEqual(c.stageView.placeholder, .none, "a late callback can't resurrect a placeholder")
        XCTAssertFalse(c.stageView.isShowingLoadingIndicator)
    }
}

extension WallpierTests {
    /// What Wallpier asks NSWorkspace for (what macOS then renders is verified only by the opt-in physical check).
    func testFitAsksNSWorkspaceForProportionalScalingWithoutClipping() {
        func options(_ mode: ScalingMode) -> (scaling: UInt?, clipping: Bool?) {
            let o = WallpaperService.desktopImageOptions(for: mode)
            return ((o[.imageScaling] as? UInt) ?? (o[.imageScaling] as? NSNumber)?.uintValue,
                    (o[.allowClipping] as? Bool) ?? (o[.allowClipping] as? NSNumber)?.boolValue)
        }
        XCTAssertEqual(options(.fit).scaling, NSImageScaling.scaleProportionallyUpOrDown.rawValue)
        XCTAssertEqual(options(.fit).clipping, false, "Fit never crops")
        XCTAssertEqual(options(.fill).scaling, NSImageScaling.scaleProportionallyUpOrDown.rawValue)
        XCTAssertEqual(options(.fill).clipping, true)
        XCTAssertEqual(options(.center).scaling, NSImageScaling.scaleNone.rawValue)
        XCTAssertNotEqual(options(.fit).scaling, NSImageScaling.scaleProportionallyDown.rawValue, "not the down-only substitute")
        // Reading the options back (for Undo's record of the previous wallpaper) gives the same mode.
        for mode in ScalingMode.allCases {
            let o = WallpaperService.desktopImageOptions(for: mode).mapValues { value -> Any in
                (value as? Bool).map { NSNumber(value: $0) } ?? (value as? UInt).map { NSNumber(value: $0) } ?? value
            }
            XCTAssertEqual(WallpaperService.scalingMode(from: o), mode)
        }
    }
}

extension WallpierTests {
    /// Existing installations keep their saved scaling (an old saved Fill can't be told from a deliberate one), so Help
    /// says how to switch once.
    @MainActor
    func testHelpExplainsThatSavedScalingIsKeptAndHowToSwitchToFit() {
        let help = MainWindowController.helpText
        XCTAssertTrue(help.contains("Fit to Screen is the default for new installations. Existing scaling choices are preserved. " +
                                    "If your wallpapers are cropped, select Fit to Screen once; Wallpier remembers your choice."), help)
        // And the preserved choices really are preserved: a saved Fill or Center loads unchanged.
        for saved in ["fill", "center"] {
            let state = try? JSONDecoder().decode(WallpaperState.self, from: Data(#"{"scalingMode":"\#(saved)"}"#.utf8))
            XCTAssertEqual(state?.scalingMode.rawValue, saved)
        }
    }
}

extension WallpierTests {
    // MARK: Release Candidate 1: wallpaper durability
    //
    // ~/Library/Caches is purgeable. Removing the Originals folder simulates macOS reclaiming it.

    @MainActor
    func testActiveRemoteWallpaperAndUndoSurviveCachePurge() async throws {
        let h = try setAuditHarness()
        let originals = h.root.appendingPathComponent("Originals")
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        let first = try XCTUnwrap(h.desktop.calls.last?.image)
        let firstBytes = try Data(contentsOf: first)
        XCTAssertFalse(first.path.hasPrefix(originals.path), "The desktop must not reference purgeable cache storage")
        XCTAssertEqual(first.lastPathComponent, h.cached(h.controller.state.favorites[0]).lastPathComponent)

        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        h.controller.nextWallpaper(nil)
        h.controller.setWallpaper(nil)
        await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.downloadTask)
        let second = try XCTUnwrap(h.desktop.calls.last?.image)
        XCTAssertNotEqual(first, second)

        try FileManager.default.removeItem(at: originals)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: second.path), "The active wallpaper survives a cache purge")
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, second.path)

        // A relaunch reads the same state; Undo still restores the first wallpaper's bytes.
        try await finishAuditTask(h.controller.undoValidationTask)
        XCTAssertTrue(h.controller.undoButton.isEnabled)
        h.controller.undoWallpaperChange(nil)
        try await finishAuditTask(h.controller.downloadTask)
        let restored = try XCTUnwrap(h.desktop.calls.last?.image)
        XCTAssertEqual(try Data(contentsOf: restored), firstBytes)

        // Only what the saved assignments and history reference stays owned; nothing else accumulates.
        let rollback = h.root.appendingPathComponent("Rollback")
        let referenced = h.store.load().protectedCachePaths.filter { $0.hasPrefix(rollback.path + "/") }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: rollback.path)),
                       Set(referenced.map { URL(fileURLWithPath: $0).lastPathComponent }))
    }
}

// MARK: - RC1 P1: retention fails closed (#1)

/// Reproducible owned-storage failures, all inside an isolated fixture root.
enum RetentionFault: CaseIterable {
    /// An unreferenced file already fills the (small) owned budget.
    case budgetExhausted
    /// The owned-storage root is an ordinary file, so its directory can't be created.
    case rootIsAFile

    static let limit: Int64 = 1_048_576

    func inject(at rollback: URL) throws {
        switch self {
        case .budgetExhausted:
            try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
            try Data(count: Int(Self.limit)).write(to: rollback.appendingPathComponent("filler.bin"))
        case .rootIsAFile:
            try Data("not a folder".utf8).write(to: rollback)
        }
    }

    func clear(at rollback: URL) throws {
        switch self {
        case .budgetExhausted: try FileManager.default.removeItem(at: rollback.appendingPathComponent("filler.bin"))
        case .rootIsAFile: try FileManager.default.removeItem(at: rollback)
        }
    }
}

extension WallpierTests {
    private func assertRetentionThrows(_ store: WallpaperHistoryStore, _ url: URL, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let returned = try await store.retain(url)
            XCTFail("retain must throw, returned \(returned.path)", file: file, line: line)
        } catch {
            XCTAssertTrue(error is RetentionError, "Unexpected \(error)", file: file, line: line)
        }
    }

    private func entries(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testRetentionBudgetExhaustionThrowsAndKeepsReferencedOriginals() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("wallhaven-a.png"), b = folder.appendingPathComponent("wallhaven-b.png")
        try writeTestImage(to: a); try writeTestImage(to: b, red: 0.9)
        let size = Int64(try Data(contentsOf: a).count)
        let root = folder.appendingPathComponent("Rollback")
        let store = WallpaperHistoryStore(root: root, maximumSizeBytes: size + size / 2)
        let owned = try await store.retain(a)
        let ownedBytes = try Data(contentsOf: owned)
        await assertRetentionThrows(store, b)
        XCTAssertEqual(try entries(root), ["wallhaven-a.png"], "Only this call's partial copy may be removed")
        XCTAssertEqual(try Data(contentsOf: owned), ownedBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path), "The cached source is never touched")
        // An already owned original is still reused when the budget is full.
        let reused = try await store.retain(a)
        XCTAssertEqual(reused, owned)
    }

    func testRetentionIOFailuresThrowWithoutDeletingWhatIsThere() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cached = folder.appendingPathComponent("wallhaven-a.png")
        try writeTestImage(to: cached)
        // Root is an ordinary file.
        let fileRoot = folder.appendingPathComponent("FileRoot")
        try Data("keep".utf8).write(to: fileRoot)
        await assertRetentionThrows(WallpaperHistoryStore(root: fileRoot), cached)
        XCTAssertEqual(try Data(contentsOf: fileRoot), Data("keep".utf8))
        // A directory occupies the destination name; it and its contents survive.
        let root = folder.appendingPathComponent("Rollback")
        let collision = root.appendingPathComponent("wallhaven-a.png")
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: collision.appendingPathComponent("inner.txt"))
        await assertRetentionThrows(WallpaperHistoryStore(root: root), cached)
        XCTAssertEqual(try entries(root), ["wallhaven-a.png"])
        XCTAssertEqual(try Data(contentsOf: collision.appendingPathComponent("inner.txt")), Data("inner".utf8))
    }

    func testRetentionRejectsInvalidImageAndRecoversWithAValidOne() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cached = folder.appendingPathComponent("wallhaven-a.png")
        try Data(repeating: 0x42, count: 512).write(to: cached)
        let root = folder.appendingPathComponent("Rollback")
        let store = WallpaperHistoryStore(root: root)
        await assertRetentionThrows(store, cached)
        XCTAssertEqual(try entries(root), [], "No partial or invalid copy is left behind")
        // A truncated (incomplete) image is rejected too.
        try writeTestImage(to: cached, width: 64)
        let full = try Data(contentsOf: cached)
        try full.prefix(full.count / 2).write(to: cached)
        await assertRetentionThrows(store, cached)
        XCTAssertEqual(try entries(root), [])
        try writeTestImage(to: cached)
        let owned = try await store.retain(cached)
        XCTAssertEqual(owned, root.appendingPathComponent("wallhaven-a.png"))
        XCTAssertEqual(try Data(contentsOf: owned), try Data(contentsOf: cached))
    }

    func testRetentionHonoursCancellation() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cached = folder.appendingPathComponent("wallhaven-a.png")
        try writeTestImage(to: cached)
        let root = folder.appendingPathComponent("Rollback")
        let store = WallpaperHistoryStore(root: root)
        let task = Task { () -> Result<URL, Error> in
            withUnsafeCurrentTask { $0?.cancel() }
            do { return .success(try await store.retain(cached)) } catch { return .failure(error) }
        }
        let result = await task.value
        guard case .failure(let error) = result else { return XCTFail("Cancelled retain must throw") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testRemoteSetRetentionFailureDoesNotMutateAndRecovers() async throws {
        for fault in RetentionFault.allCases {
            let h = try setAuditHarness(historyLimit: RetentionFault.limit)
            let rollback = h.root.appendingPathComponent("Rollback")
            try fault.inject(at: rollback)
            h.controller.setWallpaper(nil)
            await fulfillment(of: [h.network.downloadGate.started], timeout: 2)
            h.network.downloadGate.release(.success(h.incoming))
            try await finishAuditTask(h.controller.downloadTask)
            XCTAssertTrue(h.desktop.calls.isEmpty, "\(fault): no wallpaper mutation")
            XCTAssertEqual(h.desktop.current, h.prior)
            XCTAssertTrue(h.store.load().history.isEmpty, "\(fault): no history entry")
            XCTAssertNil(h.store.load().assignment(for: "101"), "\(fault): no display assignment")
            let status = h.controller.statusLabel.stringValue
            XCTAssertTrue(status.hasPrefix("Could Not Set Wallpaper:"), "\(fault): \(status)")
            XCTAssertTrue(status.contains("the desktop was not changed"), "\(fault): \(status)")
            XCTAssertNil(h.controller.downloadTask)
            XCTAssertTrue(h.controller.setWallpaperButton.isEnabled)
            // Recovery: the next explicit Set uses the established download cache and an owned copy.
            try fault.clear(at: rollback)
            h.controller.setWallpaper(nil)
            try await finishAuditTask(h.controller.downloadTask)
            let a = h.controller.state.favorites[0]
            XCTAssertEqual(h.desktop.calls.map(\.image), [h.owned(a)], "\(fault)")
            XCTAssertEqual(h.network.downloads.count, 1, "\(fault): cached original is reused")
            XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, h.owned(a).path)
            XCTAssertEqual(h.store.load().history.count, 1)
        }
    }

    @MainActor
    func testRotationRetentionFailureReportsReleasesGuardAndRecovers() async throws {
        for fault in RetentionFault.allCases {
            let h = try rotationHarness(references: rotationReferences("aaaaaa", "bbbbbb"), historyLimit: RetentionFault.limit)
            try fault.inject(at: h.rollbackRoot)
            h.selectRotationInterval(.fifteenMinutes)
            h.scheduledTimers[0].fire()
            await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
            h.network.downloadGate.release(.success(h.incoming))
            try await finishAuditTask(h.controller.rotationTask)
            XCTAssertTrue(h.desktop.calls.isEmpty, "\(fault): no wallpaper mutation")
            XCTAssertEqual(h.desktop.current, h.prior)
            XCTAssertTrue(h.store.load().history.isEmpty, "\(fault)")
            XCTAssertNil(h.store.load().assignment(for: "101"), "\(fault)")
            XCTAssertTrue(h.controller.statusLabel.stringValue.contains("Automatic rotation failed"), "\(fault)")
            XCTAssertNil(h.controller.rotationTask, "\(fault): busy guard released")
            XCTAssertEqual(h.store.load().rotationCursor, h.controller.state.collections[0].wallpapers[1].identityKey)
            XCTAssertTrue(h.controller.setWallpaperButton.isEnabled)
            // The failed attempt (bbbbbb) still advanced rotation's cursor, as before; the next tick wraps to aaaaaa.
            try fault.clear(at: h.rollbackRoot)
            h.network.downloadGate = SetAuditGate<URL>()
            try writeTestImage(to: h.incoming, width: 5)
            h.scheduledTimers[0].fire()
            await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
            h.network.downloadGate.release(.success(h.incoming))
            try await finishAuditTask(h.controller.rotationTask)
            let next = h.controller.state.collections[0].wallpapers[0]
            XCTAssertEqual(h.desktop.calls.map(\.image), [h.owned(next)], "\(fault)")
            XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, h.owned(next).path)
            XCTAssertEqual(h.store.load().history.count, 1)
        }
    }
}

extension WallpierTests {
    @MainActor
    func testThumbnailProviderCancellationSkipsCallbackAndPreservesLiveAndSyncRequests() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.png")
        let b = folder.appendingPathComponent("b.png")
        try writeTestImage(to: a, red: 0.2, width: 16)
        try writeTestImage(to: b, red: 0.9, width: 24)

        let provider = ThumbnailProvider()

        // Cancelled operation does not invoke its completion and deallocates without leaking.
        var cancelledCallbackFired = false
        weak var weakCancelledOp: Operation?
        do {
            let op = provider.requestThumbnail(for: a, maximumPixelSize: 1800) { _ in
                cancelledCallbackFired = true
            }
            XCTAssertNotNil(op)
            weakCancelledOp = op
            op?.cancel()
        }

        // Unretained live request (gallery caller pattern) still delivers, caches, and deallocates.
        let delivered = expectation(description: "live request delivered")
        var liveImage: NSImage?
        weak var weakLiveOp: Operation?
        do {
            let op = provider.requestThumbnail(for: b, maximumPixelSize: 360) { image in
                liveImage = image
                delivered.fulfill()
            }
            weakLiveOp = op
        }
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(liveImage?.size, NSSize(width: 24, height: 8))

        // Cached request completes synchronously and returns nil (no pending operation).
        var syncImage: NSImage?
        let cachedOp = provider.requestThumbnail(for: b, maximumPixelSize: 360) { image in
            syncImage = image
        }
        XCTAssertNil(cachedOp)
        XCTAssertNotNil(syncImage)
        XCTAssertEqual(syncImage?.size, NSSize(width: 24, height: 8))

        let deallocated = await eventually(2) { weakCancelledOp == nil && weakLiveOp == nil }
        XCTAssertTrue(deallocated, "Cancelled and completed thumbnail operations must deallocate")
        XCTAssertFalse(cancelledCallbackFired, "Cancelled request must not invoke completion")
    }

    @MainActor
    func testLocalPreviewCancelsSupersededRequestsAndSupportsReopenAndWarmRevisit() async throws {
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pictures = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("Pictures")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let img1 = pictures.appendingPathComponent("01.png")
        let img2 = pictures.appendingPathComponent("02.png")
        let img3 = pictures.appendingPathComponent("03.png")
        try writeTestImage(to: img1, red: 0.1, width: 12)
        try writeTestImage(to: img2, red: 0.5, width: 20)
        try writeTestImage(to: img3, red: 0.9, width: 28)

        let h = SetAuditHarness(root: root, references: [])
        h.controller.openFolder(pictures)
        let loaded = await eventually {
            h.controller.state.selectedImagePath.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            } == img1.path
        }
        XCTAssertTrue(loaded)

        // Rapid step 01 -> 02 -> 03 settles on 03 with exact dimensions and no late overwrite.
        h.controller.toggleViewer(nil)
        h.controller.nextWallpaper(nil)
        h.controller.nextWallpaper(nil)
        let arrived3 = await eventually { h.controller.stageView.image != nil }
        XCTAssertTrue(arrived3)
        XCTAssertEqual(h.controller.previewTitleLabel.stringValue, "03")
        XCTAssertEqual(h.controller.stageView.image?.size, NSSize(width: 28, height: 8))
        let settled3 = h.controller.stageView.image
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(h.controller.stageView.image === settled3, "Superseded decode must not overwrite settled selection")

        // Close and reopen same selection uses cached image cleanly.
        h.controller.toggleViewer(nil)
        XCTAssertFalse(h.controller.isViewerVisible)
        h.controller.toggleViewer(nil)
        XCTAssertTrue(h.controller.isViewerVisible)
        XCTAssertNotNil(h.controller.stageView.image)
        XCTAssertEqual(h.controller.stageView.image?.size, NSSize(width: 28, height: 8))

        // Settled 03 -> 02 -> 03 warm revisit completes synchronously with exact image.
        h.controller.previousWallpaper(nil)
        let arrived2 = await eventually { h.controller.stageView.image != nil }
        XCTAssertTrue(arrived2)
        XCTAssertEqual(h.controller.stageView.image?.size, NSSize(width: 20, height: 8))
        h.controller.nextWallpaper(nil)
        XCTAssertNotNil(h.controller.stageView.image, "Warm revisit should complete synchronously from cache")
        XCTAssertEqual(h.controller.stageView.image?.size, NSSize(width: 28, height: 8))
    }
}

// MARK: - Issue #8: Openverse as a second source
//
// Deterministic and offline: fixture JSON, fake networks and the recording wallpaper service. Nothing reaches
// Openverse, an image host, the user's state or the desktop.

/// Answers Openverse API requests with generated pages and records them; with `holds`, each request waits for the test.
@MainActor
final class OpenverseFakeNetwork: NetworkClient {
    var pageCount = 2
    var status = 200
    var headers: [String: String] = [:]
    var holds = false
    /// Every result fails verification (an image host outside the allowlist).
    var untrustedOnly = false
    var untrustedPages: Set<Int> = []
    private(set) var requests: [URLComponents] = []
    private(set) var downloads: [URL] = []
    private final class Hold { var continuation: CheckedContinuation<Void, Error>? }
    private var held: [Hold] = []
    var heldCount: Int { held.count }

    func releaseNext() { if !held.isEmpty { held.removeFirst().continuation?.resume() } }
    func releaseAll() { let pending = held; held = []; pending.forEach { $0.continuation?.resume(throwing: CancellationError()) } }

    static func id(page: Int, index: Int) -> String { String(format: "%08x-0000-4000-8000-%012x", page, index) }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        requests.append(components)
        if holds {
            let hold = Hold()
            held.append(hold)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in hold.continuation = continuation }
        }
        let page = Int(components.queryItems?.first { $0.name == "page" }?.value ?? "1") ?? 1
        let results: [[String: Any]] = (0..<2).map { index in
            var item: [String: Any] = [
                "id": Self.id(page: page, index: index), "title": "Fixture \(page)-\(index)",
                "foreign_landing_url": "https://commons.wikimedia.org/w/index.php?curid=\(page * 10 + index)",
                "url": "https://upload.wikimedia.org/wikipedia/commons/a/aa/Fixture_\(page)_\(index).jpg",
                "creator": "Fixture Photographer", "license": "cc0", "license_version": "1.0",
                "license_url": "https://creativecommons.org/publicdomain/zero/1.0/", "source": "wikimedia",
                "mature": false, "width": 3840, "height": 2160, "tags": [["name": "ridge"]]
            ]
            if index == 1 {
                item["license"] = "pdm"; item["license_url"] = NSNull(); item["creator"] = NSNull()
            }
            if untrustedOnly || untrustedPages.contains(page) { item["url"] = "https://images.example.org/\(page)_\(index).jpg" }
            return item
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "result_count": pageCount * 2, "page_count": pageCount, "page_size": 20, "page": page, "results": results
        ])
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        downloads.append(request.url!)
        throw URLError(.notConnectedToInternet)
    }
}

/// Serves original downloads with a configurable final URL, status and headers, and records each request.
private final class OpenverseDownloadClient: NetworkClient {
    var finalURL: URL?
    var status = 200
    var headers = ["Content-Type": "image/jpeg"]
    var failure: Error?
    var body = Data([0xFF, 0xD8, 0xFF])
    private(set) var downloads: [URL] = []
    private(set) var temporaries: [URL] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        downloads.append(request.url!)
        if let failure { throw failure }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("wallpier-openverse-\(UUID()).img")
        try body.write(to: temporary)
        temporaries.append(temporary)
        return (temporary, HTTPURLResponse(url: finalURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

/// Records which thumbnail URLs were requested and answers each with a small image.
final class RecordingThumbnails: RemoteThumbnailProvider {
    private(set) var requested: [URL] = []
    override func requestThumbnail(for url: URL, maximumPixelSize: Int = 420, completion: @escaping (NSImage?) -> Void) {
        requested.append(url)
        completion(NSImage(size: NSSize(width: 64, height: 36)))
    }
    override func reset() {}
}

extension WallpierTests {
    /// Dimensions default to the 32×18 images these tests generate, so the record matches the file it describes.
    private func openverseReference(_ number: Int, source: String? = "wikimedia", original: String? = nil,
                                    width: Int = 32, height: Int = 18) -> WallpaperReference {
        let id = String(format: "%08x-0000-4000-8000-000000000000", number)
        let thumbnail = OpenverseEndpoint.thumbnailURL(id: UUID(uuidString: id)!)
        return WallpaperReference(
            providerIdentifier: "openverse", wallpaperID: id,
            sourcePageURL: URL(string: "https://commons.wikimedia.org/w/index.php?curid=\(number)")!,
            originalURL: URL(string: original ?? "https://upload.wikimedia.org/wikipedia/commons/a/aa/Fixture_\(number).jpg")!,
            previewURL: thumbnail, thumbnailURL: thumbnail, width: width, height: height,
            uploader: "Fixture Photographer", tags: [], cachedLocalPath: nil,
            title: "Fixture \(number)", sourceName: source, license: "cc0", licenseVersion: "1.0",
            licenseURL: URL(string: "https://creativecommons.org/publicdomain/zero/1.0/"))
    }

    @MainActor
    private func openverseCaptureController(_ openverse: OpenverseFakeNetwork, thumbnails: RemoteThumbnailProvider? = nil)
        throws -> (MainWindowController, NSWindow, URL) {
        let root = try historyTestFolder()
        let (controller, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                         openverse: openverse, thumbnails: thumbnails) { _ in }
        addTeardownBlock {
            let tasks = await MainActor.run { () -> [Task<Void, Never>] in
                let tasks = [controller.downloadTask, controller.searchTask, controller.detailTask, controller.undoValidationTask].compactMap { $0 }
                tasks.forEach { $0.cancel() }
                openverse.releaseAll()
                while let sheet = window.attachedSheet { window.endSheet(sheet) }
                window.close()
                return tasks
            }
            for task in tasks { await task.value }
            try? FileManager.default.removeItem(at: root)
        }
        return (controller, window, root)
    }

    // MARK: Provider: URLs, decoding, pagination

    func testOpenverseURLConstructionUsesConservativeDocumentedFilters() throws {
        func items(_ url: URL) throws -> [String: String] {
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "https")
            XCTAssertEqual(components.host, "api.openverse.org")
            XCTAssertEqual(components.path, "/v1/images/")
            return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        let url = OpenverseEndpoint.searchURL(options: OpenverseSearchOptions(query: "  misty forest "), page: 3)
        XCTAssertEqual(try items(url), ["q": "misty forest", "page": "3", "page_size": "20", "extension": "jpg,jpeg",
                                        "aspect_ratio": "wide", "size": "large", "license": "cc0,pdm", "mature": "false",
                                        "source": "wikimedia"])
        // A literal + is escaped, so the API doesn't read it as a space.
        let plus = OpenverseEndpoint.searchURL(options: OpenverseSearchOptions(query: "c++ sky"), page: 1)
        XCTAssertTrue(plus.absoluteString.contains("q=c%2B%2B%20sky"), plus.absoluteString)
        XCTAssertEqual(try items(plus)["q"], "c++ sky")
        // No search text: no `q`. Never a page below 1. Each license choice stays within CC0/public domain.
        let empty = try items(OpenverseEndpoint.searchURL(options: OpenverseSearchOptions(query: " "), page: 0))
        XCTAssertNil(empty["q"]); XCTAssertEqual(empty["page"], "1")
        XCTAssertEqual(try items(OpenverseEndpoint.searchURL(options: OpenverseSearchOptions(license: .cc0), page: 1))["license"], "cc0")
        XCTAssertEqual(try items(OpenverseEndpoint.searchURL(options: OpenverseSearchOptions(license: .publicDomainMark), page: 1))["license"], "pdm")
        XCTAssertFalse(url.absoluteString.contains("filter_dead"), "filter_dead keeps the API's default (true)")
        let id = try XCTUnwrap(UUID(uuidString: "0AFF3595-8168-440B-83FF-7A80B65DEA42"))
        XCTAssertEqual(OpenverseEndpoint.detailsURL(id: id).absoluteString, "https://api.openverse.org/v1/images/0aff3595-8168-440b-83ff-7a80b65dea42/")
        XCTAssertEqual(OpenverseEndpoint.thumbnailURL(id: id).absoluteString, "https://api.openverse.org/v1/images/0aff3595-8168-440b-83ff-7a80b65dea42/thumb/")
    }

    func testOpenverseSearchFixtureDecodesOnlyVerifiedResultsWithAttribution() async throws {
        let provider = OpenverseProvider(client: StubNetworkClient(data: try fixtureData(named: "openverse-search")))
        let page = try await provider.search(options: OpenverseSearchOptions(query: "ridge"), page: 1)
        XCTAssertEqual(page.currentPage, 1); XCTAssertEqual(page.lastPage, 12); XCTAssertEqual(page.total, 4000)
        XCTAssertTrue(page.hasMorePages)
        // Untrusted host, non-public-domain license, missing license, plain HTTP, missing size, bad id,
        // malformed width, mature and a script landing page are all hidden, and counted.
        XCTAssertEqual(page.wallpapers.count, 2)
        XCTAssertEqual(page.hiddenCount, 9)
        let ridge = page.wallpapers[0]
        XCTAssertEqual(ridge.identityKey, "openverse:0aff3595-8168-440b-83ff-7a80b65dea42")
        XCTAssertEqual(ridge.title, "Fixture Ridge at Dawn")
        XCTAssertEqual(ridge.uploader, "Fixture Photographer")
        XCTAssertEqual(ridge.sourceName, "wikimedia")
        XCTAssertEqual(ridge.sourceDisplayName, "Wikimedia Commons")
        XCTAssertEqual(ridge.sourcePageURL.absoluteString, "https://commons.wikimedia.org/w/index.php?curid=100001")
        XCTAssertEqual(ridge.originalURL.absoluteString, "https://upload.wikimedia.org/wikipedia/commons/a/aa/Fixture_Ridge.jpg")
        XCTAssertEqual(ridge.licenseDescription, "CC0 1.0")
        XCTAssertEqual(ridge.licenseURL?.absoluteString, "https://creativecommons.org/publicdomain/zero/1.0/")
        XCTAssertEqual(ridge.tags, ["mountain", "dawn"])
        XCTAssertEqual(ridge.width, 3840); XCTAssertEqual(ridge.height, 2400)
        XCTAssertEqual(ridge.remotePreview?.url, ridge.thumbnailURL)
        XCTAssertEqual(ridge.remotePreview?.fidelity, .lowResolution, "Openverse thumbnails are resized, not cropped")
        XCTAssertTrue(ridge.licenseIsConsistent, "cc0 with the canonical CC0 1.0 deed")
        XCTAssertFalse(ridge.blocksUse)
        let meadow = page.wallpapers[1]
        XCTAssertNil(meadow.title, "An empty title is absent, not invented"); XCTAssertEqual(meadow.displayTitle, meadow.wallpaperID)
        XCTAssertNil(meadow.uploader)
        XCTAssertNil(meadow.licenseURL, "A missing license URL stays missing")
        XCTAssertFalse(meadow.licenseIsConsistent, "Browse-only until the source is reviewed")
        XCTAssertTrue(meadow.blocksUse)
        XCTAssertEqual(meadow.licenseDescription, "Public Domain Mark 1.0")
        XCTAssertEqual(meadow.sourceDisplayName, "Wikimedia Commons")
        XCTAssertEqual(meadow.thumbnailURL.absoluteString,
                       "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/bb/Fixture_Meadow.jpg/500px-Fixture_Meadow.jpg",
                       "The response's own thumbnail URL is never used")
        // A last page has no more.
        let last = try JSONSerialization.data(withJSONObject: ["result_count": 1, "page_count": 1, "page": 1, "results": []])
        let lastPage = try await OpenverseProvider(client: StubNetworkClient(data: last)).search(options: OpenverseSearchOptions(), page: 1)
        XCTAssertFalse(lastPage.hasMorePages); XCTAssertTrue(lastPage.wallpapers.isEmpty)
    }

    func testOpenverseDetailDecodesAndNeverPatchesChangedMetadata() async throws {
        let ridge = openverseReference(1)
        let detailJSON = try fixtureData(named: "openverse-detail")
        var listed = try XCTUnwrap(try JSONSerialization.jsonObject(with: detailJSON) as? [String: Any])
        listed["id"] = ridge.wallpaperID
        var cached = ridge; cached.cachedLocalPath = "/tmp/cached.jpg"
        let detailed = try await OpenverseProvider(client: StubNetworkClient(data: try JSONSerialization.data(withJSONObject: listed)))
            .fetchDetails(for: cached)
        XCTAssertEqual(detailed.identityKey, ridge.identityKey)
        XCTAssertEqual(detailed.tags, ["mountain", "dawn", "ridge"])
        XCTAssertEqual(detailed.cachedLocalPath, "/tmp/cached.jpg")
        // A license that no longer verifies is an error, never substituted.
        listed["license"] = "by-nc"
        do {
            _ = try await OpenverseProvider(client: StubNetworkClient(data: try JSONSerialization.data(withJSONObject: listed))).fetchDetails(for: ridge)
            XCTFail("A changed license must not be accepted")
        } catch { XCTAssertEqual(error as? RemoteProviderError, .invalidData) }
        // A different work answering for this identity is rejected.
        listed["license"] = "cc0"; listed["id"] = openverseReference(2).wallpaperID
        do {
            _ = try await OpenverseProvider(client: StubNetworkClient(data: try JSONSerialization.data(withJSONObject: listed))).fetchDetails(for: ridge)
            XCTFail("A mismatched identity must not be accepted")
        } catch { XCTAssertEqual(error as? RemoteProviderError, .invalidData) }
        // A saved reference with a non-UUID identifier never builds a request.
        let client = SequencedNetworkClient(responses: [(Data(), HTTPURLResponse(url: URL(string: "https://api.openverse.org/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)])
        var bogus = ridge
        bogus = WallpaperReference(providerIdentifier: "openverse", wallpaperID: "../../v1/other", sourcePageURL: bogus.sourcePageURL,
                                   originalURL: bogus.originalURL, previewURL: bogus.previewURL, thumbnailURL: bogus.thumbnailURL,
                                   width: 1, height: 1, uploader: nil, tags: [], cachedLocalPath: nil)
        do { _ = try await OpenverseProvider(client: client).fetchDetails(for: bogus); XCTFail("Expected invalid data") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .invalidData) }
        XCTAssertEqual(client.requestCount, 0)
    }

    // MARK: Provider: security, failures, throttling

    func testOpenverseURLPolicyAllowsOnlyCuratedHTTPSHostsAndSameSourceRedirects() throws {
        func url(_ string: String) -> URL { URL(string: string)! }
        let wikimedia = url("https://upload.wikimedia.org/wikipedia/commons/a/aa/A.jpg")
        XCTAssertTrue(OpenverseURLPolicy.isAllowedImageURL(wikimedia, source: "wikimedia"))
        XCTAssertTrue(OpenverseURLPolicy.isAllowedImageURL(url("https://live.staticflickr.com/1/2_b.jpg"), source: "flickr"))
        XCTAssertTrue(OpenverseURLPolicy.isAllowedImageURL(url("https://farm4.staticflickr.com/1/2_b.jpg"), source: "flickr"))
        XCTAssertTrue(OpenverseURLPolicy.isAllowedImageURL(url("https://cdn.stocksnap.io/img-thumbs/a.jpg"), source: "stocksnap"))
        for rejected in ["http://upload.wikimedia.org/a.jpg", "https://user:pw@upload.wikimedia.org/a.jpg",
                         "https://upload.wikimedia.org:8443/a.jpg", "https://upload.wikimedia.org.evil.example/a.jpg",
                         "https://localhost/a.jpg", "https://127.0.0.1/a.jpg", "https://10.0.0.5/a.jpg", "https://[::1]/a.jpg",
                         "file:///etc/passwd", "https://staticflickr.com.evil.example/a.jpg"] {
            XCTAssertFalse(OpenverseURLPolicy.isAllowedImageURL(url(rejected), source: "wikimedia"), rejected)
            XCTAssertFalse(OpenverseURLPolicy.isAllowedImageURL(url(rejected), source: "flickr"), rejected)
        }
        XCTAssertFalse(OpenverseURLPolicy.isAllowedImageURL(wikimedia, source: "flickr"), "Hosts are per source")
        XCTAssertFalse(OpenverseURLPolicy.isAllowedImageURL(wikimedia, source: "unknown"))
        // Redirects keep the same policy.
        XCTAssertTrue(OpenverseURLPolicy.allowsRedirect(from: wikimedia, to: url("https://upload.wikimedia.org/b.jpg")))
        XCTAssertFalse(OpenverseURLPolicy.allowsRedirect(from: wikimedia, to: url("https://live.staticflickr.com/b.jpg")))
        XCTAssertFalse(OpenverseURLPolicy.allowsRedirect(from: wikimedia, to: url("http://upload.wikimedia.org/b.jpg")))
        XCTAssertFalse(OpenverseURLPolicy.allowsRedirect(from: wikimedia, to: url("https://169.254.169.254/latest/meta-data")))
        XCTAssertFalse(OpenverseURLPolicy.allowsRedirect(from: url("https://images.example.org/a.jpg"), to: wikimedia))
        let api = url("https://api.openverse.org/v1/images/x/thumb/")
        XCTAssertTrue(OpenverseURLPolicy.allowsRedirect(from: api, to: url("https://api.openverse.org/v1/images/x/thumb")))
        XCTAssertFalse(OpenverseURLPolicy.allowsRedirect(from: api, to: wikimedia))
        // The URLSession delegate that enforces it refuses the redirect (returning nil keeps the 3xx as final).
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let delegate = RedirectPolicyDelegate(allows: OpenverseURLPolicy.allowsRedirect)
        func follow(_ from: URL, _ to: URL) -> URLRequest? {
            var result: URLRequest?? = .none
            delegate.urlSession(session, task: session.dataTask(with: from),
                                willPerformHTTPRedirection: HTTPURLResponse(url: from, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                                newRequest: URLRequest(url: to)) { result = .some($0) }
            return result ?? nil
        }
        XCTAssertNil(follow(wikimedia, url("https://127.0.0.1/admin")))
        XCTAssertEqual(follow(wikimedia, url("https://upload.wikimedia.org/b.jpg"))?.url, url("https://upload.wikimedia.org/b.jpg"))
    }

    func testOpenverseDownloadRejectsUntrustedURLsRedirectsNonImagesAndFailures() async throws {
        let ridge = openverseReference(1)
        func attempt(_ reference: WallpaperReference, _ configure: (OpenverseDownloadClient) -> Void = { _ in })
            async -> (Result<URL, Error>, OpenverseDownloadClient) {
            let client = OpenverseDownloadClient(); configure(client)
            let provider = OpenverseProvider(client: client)
            do { return (.success(try await provider.downloadOriginal(for: reference)), client) }
            catch { return (.failure(error), client) }
        }
        func failure(_ result: Result<URL, Error>) -> Error? { if case .failure(let error) = result { return error }; return nil }

        // Saved references are re-checked at the download boundary: an untrusted host, a missing source,
        // or a Wallhaven reference is never requested.
        var unconfirmed = openverseReference(5); unconfirmed.licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")
        let (review, reviewClient) = await attempt(unconfirmed)
        XCTAssertEqual(failure(review) as? RemoteProviderError, .licenseNeedsReview)
        XCTAssertTrue(reviewClient.downloads.isEmpty)
        for reference in [openverseReference(2, original: "https://images.example.org/a.jpg"), openverseReference(3, source: nil),
                          openverseReference(4, original: "https://127.0.0.1/a.jpg"), remoteReference(id: "notours")] {
            let (result, client) = await attempt(reference)
            XCTAssertEqual(failure(result) as? RemoteProviderError, .untrustedURL)
            XCTAssertTrue(client.downloads.isEmpty, "\(reference.originalURL) must never be requested")
        }
        // A redirect that ended elsewhere, a non-image body, a missing original and a network failure all fail closed
        // and remove the temporary file.
        let cases: [(String, (OpenverseDownloadClient) -> Void, RemoteProviderError?)] = [
            ("redirected", { $0.finalURL = URL(string: "https://evil.example/a.jpg") }, .untrustedURL),
            ("html", { $0.headers = ["Content-Type": "text/html"] }, .invalidData),
            ("404", { $0.status = 404 }, .originalUnavailable),
            ("refused redirect", { $0.status = 302 }, .untrustedURL),
            ("500", { $0.status = 500 }, .httpStatus(500)),
            ("not an image", { _ in }, .invalidData),
            ("wrong shape", { $0.body = Self.pngData(width: 20, height: 20) }, .invalidData),
            ("downsized, same shape", { $0.body = Self.pngData(width: 16, height: 9) }, .invalidData),
            ("oversized", { $0.body = Self.pngData(width: 32, height: 18); $0.headers["Content-Length"] = "999999999999" }, .invalidData)
        ]
        for (name, configure, expected) in cases {
            let (result, client) = await attempt(ridge, configure)
            XCTAssertEqual(failure(result) as? RemoteProviderError, expected, name)
            XCTAssertEqual(client.downloads, [ridge.originalURL], name)
            XCTAssertFalse(client.temporaries.contains { FileManager.default.fileExists(atPath: $0.path) }, "\(name): temporary removed")
        }
        let (offline, _) = await attempt(ridge) { $0.failure = URLError(.notConnectedToInternet) }
        XCTAssertEqual((failure(offline) as? URLError)?.code, .notConnectedToInternet)
        // A valid original on its own CDN is returned for the cache to validate and install.
        let (valid, client) = await attempt(ridge) { $0.body = Self.pngData(width: 32, height: 18) }
        let file = try valid.get()
        XCTAssertTrue(OpenverseProvider.isFaithfulOriginal(at: file, for: ridge))
        // Orientation is respected: portrait pixels tagged to display rotated match a landscape report, untagged don't.
        let rotated = FileManager.default.temporaryDirectory.appendingPathComponent("wallpier-rotated-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: rotated) }
        try Self.imageData(width: 18, height: 32, type: "public.jpeg", orientation: 6).write(to: rotated)
        XCTAssertTrue(OpenverseProvider.isFaithfulOriginal(at: rotated, for: ridge))
        try Self.imageData(width: 18, height: 32, type: "public.jpeg").write(to: rotated)
        XCTAssertFalse(OpenverseProvider.isFaithfulOriginal(at: rotated, for: ridge))
        XCTAssertEqual(client.downloads, [ridge.originalURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: file)
        // A 429 on originals holds further downloads back without another request.
        let throttled = OpenverseDownloadClient(); throttled.status = 429; throttled.headers = ["Retry-After": "40"]
        let provider = OpenverseProvider(client: throttled)
        for _ in 0..<2 {
            do { _ = try await provider.downloadOriginal(for: ridge); XCTFail("Expected a rate limit") }
            catch RemoteProviderError.rateLimited(let delay) { XCTAssertLessThanOrEqual(delay ?? 0, 40) }
        }
        XCTAssertEqual(throttled.downloads.count, 1)
    }

    func testOpenverseRateLimitTransientRetryAndInvalidResponses() async throws {
        let url = URL(string: "https://api.openverse.org/v1/images/")!
        func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        }
        let ok = try fixtureData(named: "openverse-search")
        // 429 uses Retry-After and suppresses further searches locally.
        let limited = SequencedNetworkClient(responses: [(Data(), response(429, ["Retry-After": "7"]))])
        let provider = OpenverseProvider(client: limited)
        do { _ = try await provider.search(options: OpenverseSearchOptions(), page: 1); XCTFail("Expected 429") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .rateLimited(retryAfter: 7)) }
        do { _ = try await provider.search(options: OpenverseSearchOptions(), page: 2); XCTFail("Expected backoff") }
        catch RemoteProviderError.rateLimited { }
        XCTAssertEqual(limited.requestCount, 1, "No request is sent while throttled")
        XCTAssertTrue(RemoteProviderError.rateLimited(retryAfter: 7).localizedDescription.contains("rate-limiting"))
        // One bounded retry for a transient gateway failure.
        let transient = SequencedNetworkClient(responses: [(Data(), response(503)), (ok, response(200))])
        let page = try await OpenverseProvider(client: transient).search(options: OpenverseSearchOptions(), page: 1)
        XCTAssertEqual(page.wallpapers.count, 2); XCTAssertEqual(transient.requestCount, 2)
        let down = SequencedNetworkClient(responses: [(Data(), response(503))])
        do { _ = try await OpenverseProvider(client: down).search(options: OpenverseSearchOptions(), page: 1); XCTFail("Expected 503") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .httpStatus(503)) }
        XCTAssertEqual(down.requestCount, 2, "Exactly one retry")
        // Other statuses and unreadable bodies fail without retrying.
        for (status, body, expected) in [(500, ok, RemoteProviderError.httpStatus(500)), (200, Data("<html>".utf8), .invalidData),
                                         (200, Data(#"{"results": "x"}"#.utf8), .invalidData)] {
            let client = SequencedNetworkClient(responses: [(body, response(status))])
            do { _ = try await OpenverseProvider(client: client).search(options: OpenverseSearchOptions(), page: 1); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? RemoteProviderError, expected) }
            XCTAssertEqual(client.requestCount, 1)
        }
        // Openverse's daily quota: a Retry-After of hours is honoured (and described in hours); beyond a day is malformed.
        for (header, expected) in [("50000", 50_000.0), ("90000", 60.0)] {
            let client = SequencedNetworkClient(responses: [(Data(), response(429, ["Retry-After": header]))])
            do { _ = try await OpenverseProvider(client: client).search(options: OpenverseSearchOptions(), page: 1); XCTFail(header) }
            catch { XCTAssertEqual(error as? RemoteProviderError, .rateLimited(retryAfter: expected), header) }
        }
        XCTAssertTrue(RemoteProviderError.rateLimited(retryAfter: 50_000).localizedDescription.contains("about 14 hours"))
        // Wallhaven keeps its one-hour ceiling.
        let wallhaven = SequencedNetworkClient(responses: [(Data(), HTTPURLResponse(url: URL(string: "https://wallhaven.cc/api/v1/search")!,
                                                                                    statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "5000"])!)])
        do { _ = try await WallhavenProvider(client: wallhaven).search(options: WallhavenSearchOptions(), page: 1); XCTFail("429") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .rateLimited(retryAfter: 60)) }
        // A page other than the one requested never advances pagination.
        let wrongPage = try JSONSerialization.data(withJSONObject: ["result_count": 40, "page_count": 2, "page": 1, "results": []])
        do { _ = try await OpenverseProvider(client: StubNetworkClient(data: wrongPage)).search(options: OpenverseSearchOptions(), page: 2); XCTFail("page") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .invalidData) }
        // A network failure surfaces as itself.
        do { _ = try await OpenverseProvider(client: OfflineNetwork()).search(options: OpenverseSearchOptions(), page: 1); XCTFail("offline") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    // MARK: State: migration and provider-qualified references

    func testWallhavenOnlyStateMigratesAndMixedReferencesRoundTrip() throws {
        let collectionID = UUID()
        let saved = """
        {"version":2,"currentSource":"collections","selectedRemoteIdentity":"wallhaven:94x38z","selectedDisplayID":"101",
         "scalingMode":"fill","rotationInterval":"oneHour","shuffleEnabled":false,
         "wallhavenSearch":{"query":"forest","category":"100","usesDisplayMinimum":false,"minimumWidth":2560,"minimumHeight":1440,"aspectRatio":"16x9","sorting":"toplist"},
         "favorites":[{"providerIdentifier":"wallhaven","wallpaperID":"94x38z","sourcePageURL":"https://wallhaven.cc/w/94x38z",
           "originalURL":"https://w.wallhaven.cc/full/94/wallhaven-94x38z.jpg","previewURL":"https://th.wallhaven.cc/lg/94/94x38z.jpg",
           "thumbnailURL":"https://th.wallhaven.cc/small/94/94x38z.jpg","width":3840,"height":2160,"uploader":"someone","tags":["forest"],
           "cachedLocalPath":"/Caches/wallhaven-94x38z.jpg"}],
         "collections":[{"id":"\(collectionID.uuidString)","name":"Evening","wallpapers":[{"providerIdentifier":"wallhaven","wallpaperID":"abc123",
           "sourcePageURL":"https://wallhaven.cc/w/abc123","originalURL":"https://w.wallhaven.cc/full/ab/wallhaven-abc123.png",
           "previewURL":"https://th.wallhaven.cc/lg/ab/abc123.jpg","thumbnailURL":"https://th.wallhaven.cc/small/ab/abc123.jpg",
           "width":2560,"height":1440,"tags":[]}]}],
         "selectedCollectionID":"\(collectionID.uuidString)","activeRotationCollectionID":"\(collectionID.uuidString)",
         "rotationCursor":"wallhaven:abc123",
         "displayAssignments":[{"displayID":"101","displayName":"Display","imagePath":"/Rollback/wallhaven-abc123.png","scaling":"fill"}],
         "history":[{"previous":{"displayID":"101","displayName":"Display","imagePath":"/old.png","scaling":"fit"},
           "replacement":{"displayID":"101","displayName":"Display","imagePath":"/Rollback/wallhaven-abc123.png","scaling":"fill"},
           "timestamp":"2026-11-01T10:00:00Z","rollbackPath":"/Rollback/rollback-1.png"}]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var state = try decoder.decode(WallpaperState.self, from: Data(saved.utf8))
        XCTAssertEqual(state.discoverProvider, .wallhaven, "Existing installations keep Wallhaven's Discover")
        XCTAssertEqual(state.openverseSearch, OpenverseSearchOptions())
        XCTAssertEqual(state.wallhavenSearch.query, "forest"); XCTAssertEqual(state.wallhavenSearch.sorting, .toplist)
        XCTAssertEqual(state.wallhavenSearch.minimumResolution, "2560x1440")
        XCTAssertEqual(state.favorites.map(\.identityKey), ["wallhaven:94x38z"])
        XCTAssertEqual(state.favorites[0].cachedLocalPath, "/Caches/wallhaven-94x38z.jpg")
        XCTAssertEqual(state.favorites[0].provider, .wallhaven)
        XCTAssertNil(state.favorites[0].license); XCTAssertEqual(state.favorites[0].displayTitle, "94x38z")
        XCTAssertEqual(state.collections[0].wallpapers.map(\.identityKey), ["wallhaven:abc123"])
        XCTAssertEqual(state.activeRotationCollectionID, collectionID)
        XCTAssertEqual(state.rotationCursor, "wallhaven:abc123")
        XCTAssertEqual(state.assignment(for: "101")?.imagePath, "/Rollback/wallhaven-abc123.png")
        XCTAssertEqual(state.history.first?.rollbackPath, "/Rollback/rollback-1.png")
        XCTAssertEqual(state.history.first?.previous.imagePath, "/old.png")
        // Wallhaven references are re-saved without Openverse-only keys.
        let favorite = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(state.favorites[0])) as? [String: Any])
        XCTAssertEqual(Set(favorite.keys), ["providerIdentifier", "wallpaperID", "sourcePageURL", "originalURL", "previewURL",
                                            "thumbnailURL", "width", "height", "uploader", "tags", "cachedLocalPath"])
        // Both providers in one favorites list and collection, with distinct identities, survive a save and load.
        let openverse = openverseReference(7)
        state.favorites.append(openverse)
        state.collections[0].add(openverse)
        state.discoverProvider = .openverse
        state.openverseSearch = OpenverseSearchOptions(query: "lake", license: .cc0)
        let reloaded = try decoder.decode(WallpaperState.self, from: encoder.encode(state))
        XCTAssertEqual(reloaded, state)
        XCTAssertEqual(reloaded.collections[0].wallpapers.map(\.identityKey), ["wallhaven:abc123", "openverse:\(openverse.wallpaperID)"])
        XCTAssertEqual(reloaded.favorites[1].licenseURL, openverse.licenseURL)
        // A provider the build doesn't know, or a malformed Openverse search, never discards the rest of the state.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
        object["discoverProvider"] = "pexels"; object["openverseSearch"] = ["license": 42]
        let tolerant = try decoder.decode(WallpaperState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(tolerant.discoverProvider, .wallhaven)
        XCTAssertEqual(tolerant.openverseSearch.license, .cc0AndPublicDomain)
        XCTAssertEqual(tolerant.favorites, state.favorites)
        XCTAssertEqual(tolerant.collections, state.collections)
    }

    // MARK: Controller: search, pagination, switching, failures and attribution

    @MainActor
    func testOpenverseDiscoverPaginatesAndSwitchingSourcesNeverMixesResults() async throws {
        let openverse = OpenverseFakeNetwork(); openverse.holds = true
        let (c, window, root) = try openverseCaptureController(openverse)
        c.showDiscover(nil)
        let wallhaven = c.remoteResults.map(\.identityKey)
        XCTAssertFalse(wallhaven.isEmpty)
        XCTAssertEqual(c.searchField.placeholderString, "Search Wallhaven")
        XCTAssertFalse(c.categoryPopUp.isHidden)

        c.showOpenverse(nil)
        XCTAssertEqual(c.state.discoverProvider, .openverse)
        XCTAssertEqual(c.sidebarForTesting.selectedItem, .openverse)
        XCTAssertTrue(c.remoteResults.isEmpty)
        XCTAssertEqual(c.searchField.placeholderString, "Search Openverse")
        XCTAssertEqual(c.searchField.stringValue, "", "Each source keeps its own search text")
        XCTAssertTrue(c.categoryPopUp.isHidden, "Wallhaven's filters aren't offered for Openverse")
        XCTAssertFalse(c.openverseLicensePopUp.isHidden)
        XCTAssertFalse(c.openverseNoticeLabel.isHidden)
        XCTAssertTrue(c.openverseNoticeLabel.stringValue.contains("Powered by Openverse; not endorsed by Openverse"))
        var reached = await eventually { openverse.heldCount == 1 }
        XCTAssertTrue(reached)
        XCTAssertEqual(c.emptyStateView.title, "Searching Openverse…")
        XCTAssertEqual(value(openverse.requests.first, "source"), "wikimedia")
        XCTAssertEqual(value(openverse.requests.first, "mature"), "false")

        // Back to Wallhaven while Openverse is answering: Wallhaven's results, search and filters return untouched,
        // and the late Openverse answer is discarded.
        c.showWallhaven(nil)
        XCTAssertEqual(c.remoteResults.map(\.identityKey), wallhaven)
        XCTAssertEqual(c.searchField.stringValue, "landscape")
        openverse.releaseNext()
        await pause(0.3)
        XCTAssertEqual(c.remoteResults.map(\.identityKey), wallhaven, "A superseded Openverse response never reaches Wallhaven's results")
        XCTAssertTrue(c.remoteResults.allSatisfy { $0.provider == .wallhaven })

        // Openverse again: a fresh first page, then exactly the next page, and none past page_count.
        c.showOpenverse(nil)
        reached = await eventually { openverse.heldCount == 1 }
        XCTAssertTrue(reached)
        openverse.releaseNext()
        reached = await eventually { c.remoteResults.count == 2 }
        XCTAssertTrue(reached)
        await pause(0.3)
        XCTAssertEqual(openverse.heldCount, 0, "Openverse never loads pages by itself")
        XCTAssertFalse(c.loadMoreButton.isHidden); XCTAssertTrue(c.loadMoreButton.isEnabled)
        c.loadMoreResults(nil)
        reached = await eventually { openverse.heldCount == 1 }
        XCTAssertTrue(reached)
        openverse.releaseNext()
        reached = await eventually { c.remoteResults.count == 4 }
        XCTAssertTrue(reached)
        await pause(0.3)
        XCTAssertEqual(openverse.requests.map { value($0, "page") }, ["1", "1", "2"])
        XCTAssertTrue(c.loadMoreButton.isHidden, "No Load More past page_count")
        XCTAssertEqual(Set(c.remoteResults.map(\.identityKey)).count, 4)
        XCTAssertTrue(c.remoteResults.allSatisfy { $0.provider == .openverse })
        XCTAssertTrue(window.subtitle.contains("on Openverse"), window.subtitle)
        XCTAssertEqual(c.state.wallhavenSearch.query, "landscape", "Wallhaven's saved search is untouched")

        // Searching Openverse saves only Openverse's text.
        c.searchField.stringValue = "lake"
        c.search(nil)
        XCTAssertEqual(c.state.openverseSearch.query, "lake")
        XCTAssertEqual(c.state.wallhavenSearch.query, "landscape")
        reached = await eventually { openverse.heldCount == 1 }
        XCTAssertTrue(reached)
        XCTAssertEqual(value(openverse.requests.last, "q"), "lake")
        openverse.releaseNext()
        // The saved state reopens on Openverse with its own search.
        let saved = WallpaperStateStore(stateURL: root.appendingPathComponent("state.json")).load()
        XCTAssertEqual(saved.discoverProvider, .openverse)
        XCTAssertEqual(saved.openverseSearch.query, "lake")
        XCTAssertEqual(saved.wallhavenSearch.query, "landscape")
    }

    @MainActor
    func testOpenverseFailuresAndEmptyResultsAreTruthfulAndLeaveWallhavenIntact() async throws {
        let openverse = OpenverseFakeNetwork(); openverse.status = 429; openverse.headers = ["Retry-After": "30"]
        let (c, _, _) = try openverseCaptureController(openverse)
        c.showDiscover(nil)
        let wallhaven = c.remoteResults.map(\.identityKey)
        c.showOpenverse(nil)
        var reached = await eventually { c.emptyStateView.title == "Couldn’t Load Wallpapers" }
        XCTAssertTrue(reached)
        XCTAssertTrue(c.emptyStateView.message.contains("rate-limiting"), c.emptyStateView.message)
        // Trying again while throttled is answered locally, not sent.
        c.search(nil)
        reached = await eventually { c.emptyStateView.title == "Couldn’t Load Wallpapers" }
        XCTAssertTrue(reached)
        XCTAssertEqual(openverse.requests.count, 1)
        c.showWallhaven(nil)
        XCTAssertEqual(c.remoteResults.map(\.identityKey), wallhaven)

        // Nothing verifiable: an honest empty state that counts what was hidden, and no broadened retry.
        let untrusted = OpenverseFakeNetwork(); untrusted.untrustedOnly = true; untrusted.pageCount = 1
        let (e, _, _) = try openverseCaptureController(untrusted)
        e.showOpenverse(nil)
        reached = await eventually { e.emptyStateView.title == "No Results" }
        XCTAssertTrue(reached)
        XCTAssertTrue(e.emptyStateView.message.contains("2 results were hidden"), e.emptyStateView.message)
        XCTAssertEqual(untrusted.requests.count, 1)
        XCTAssertEqual(value(untrusted.requests[0], "license"), "cc0,pdm")
        XCTAssertTrue(untrusted.downloads.isEmpty)
    }

    @MainActor
    func testOpenverseSelectionShowsAttributionLinksAndAFaithfulLowResolutionPreview() async throws {
        let openverse = OpenverseFakeNetwork(); openverse.pageCount = 1
        let thumbnails = RecordingThumbnails()
        let (c, _, _) = try openverseCaptureController(openverse, thumbnails: thumbnails)
        c.showOpenverse(nil)
        let reached = await eventually { c.remoteResults.count == 2 }
        XCTAssertTrue(reached)
        let ridge = c.remoteResults[0], meadow = c.remoteResults[1]
        XCTAssertEqual(c.state.selectedRemoteIdentity, ridge.identityKey)
        let text = c.previewAttributionLabel.attributedStringValue
        XCTAssertFalse(c.previewAttributionLabel.isHidden)
        XCTAssertTrue(text.string.contains("CC0 1.0 as reported"), text.string)
        XCTAssertTrue(text.string.contains("Source: Wikimedia Commons"), text.string)
        XCTAssertFalse(c.previewAcknowledgementLabel.isHidden)
        XCTAssertTrue(c.previewAcknowledgementLabel.stringValue.contains("Powered by Openverse; not endorsed by Openverse"))
        XCTAssertTrue(c.previewAcknowledgementLabel.stringValue.contains("as reported, not verified"))
        XCTAssertTrue(c.reviewSourceButton.isHidden)
        XCTAssertTrue(c.setWallpaperButton.isEnabled)
        func link(_ fragment: String) -> URL? {
            let range = (text.string as NSString).range(of: fragment)
            return range.location == NSNotFound ? nil : text.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        }
        XCTAssertEqual(link("CC0 1.0"), ridge.licenseURL)
        XCTAssertEqual(link("Source:"), ridge.sourcePageURL)
        XCTAssertTrue(c.selectionLabel.stringValue.contains("Fixture 1-0"))
        XCTAssertTrue(c.selectionLabel.stringValue.contains("CC0 1.0"))
        XCTAssertEqual(c.previewMetadataLabel.stringValue, "3840 × 2160 · by Fixture Photographer")
        let menu = c.itemMenu().items.map(\.title)
        XCTAssertTrue(menu.contains("Open on Wikimedia Commons"), "\(menu)")
        XCTAssertTrue(menu.contains("View License (CC0 1.0)"), "\(menu)")

        // No creator, no license URL: nothing is invented.
        c.nextWallpaper(nil)
        let meadowText = c.previewAttributionLabel.attributedStringValue
        XCTAssertTrue(meadowText.string.contains("Public Domain Mark 1.0 · unconfirmed, review source"), meadowText.string)
        XCTAssertNil(meadowText.attribute(.link, at: 0, effectiveRange: nil), "No license link without a matching license URL")
        XCTAssertEqual(c.previewMetadataLabel.stringValue, "3840 × 2160")
        XCTAssertFalse(c.itemMenu().items.contains { $0.title.hasPrefix("View License") })
        XCTAssertTrue(c.itemMenu().items.contains { $0.title == "Review Original Source" })
        XCTAssertFalse(c.reviewSourceButton.isHidden, "A visible review affordance")
        XCTAssertFalse(c.setWallpaperButton.isEnabled, "Set is refused until the license is consistent")
        XCTAssertTrue(c.selectionLabel.stringValue.contains("License unconfirmed"))

        // The preview draws the uncropped Openverse thumbnail, says it is low resolution, and downloads nothing.
        c.toggleViewer(nil)
        let drawn = await eventually { c.stageView.image != nil }
        XCTAssertTrue(drawn)
        XCTAssertEqual(thumbnails.requested.last, meadow.thumbnailURL)
        XCTAssertTrue(notice(c).hasPrefix("Low-resolution preview"), notice(c))
        XCTAssertTrue(openverse.downloads.isEmpty, "Previewing never downloads an original")
        XCTAssertTrue(thumbnails.requested.allSatisfy { $0.host == "thumb.wikimedia.org" })

        // Wallhaven selections carry no Openverse attribution.
        c.showWallhaven(nil)
        XCTAssertTrue(c.previewAttributionLabel.isHidden)
        XCTAssertTrue(c.previewAcknowledgementLabel.isHidden)
        XCTAssertTrue(c.reviewSourceButton.isHidden)
    }

    // MARK: Controller: ownership, Set, rotation and Undo across both providers

    @MainActor
    func testUntrustedOpenverseOriginalIsNeverRequestedBySet() async throws {
        let root = try historyTestFolder()
        let harness = SetAuditHarness(root: root, references: [openverseReference(9, original: "https://images.example.org/a.jpg")])
        try writeTestImage(to: harness.prior, width: 3)
        addTeardownBlock {
            await MainActor.run { harness.network.downloadGate.release(.failure(CancellationError())) }
            try? FileManager.default.removeItem(at: root)
        }
        harness.controller.setWallpaper(nil)
        try await finishAuditTask(harness.controller.downloadTask)
        XCTAssertTrue(harness.network.downloads.isEmpty, "An untrusted image URL is never requested")
        XCTAssertTrue(harness.desktop.calls.isEmpty)
        XCTAssertTrue(harness.store.load().history.isEmpty)
        XCTAssertTrue(harness.controller.statusLabel.stringValue.contains("doesn’t download from"), harness.controller.statusLabel.stringValue)
        XCTAssertTrue(harness.controller.setWallpaperButton.isEnabled, "The pending-operation state is released")
    }

    @MainActor
    func testMixedProviderCollectionRotatesSetsOwnsAndUndoesThroughFakeServices() async throws {
        let wallhaven = remoteReference(id: "mixwh1"), openverse = openverseReference(11, width: 14, height: 8), wallhaven2 = remoteReference(id: "mixwh2")
        let h = try rotationHarness(references: [wallhaven, openverse, wallhaven2])
        try writeTestImage(to: h.incoming, width: 14)   // Exactly the Openverse member's reported 14×8.
        h.selectRotationInterval(.fifteenMinutes)
        // The cursor is on the first member: the next tick sets the Openverse member, downloading only its original.
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        XCTAssertEqual(h.network.downloads, [openverse.originalURL])
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.owned(openverse)], "The desktop references Wallpier-owned storage")
        XCTAssertTrue(h.owned(openverse).lastPathComponent.hasPrefix("openverse-\(openverse.wallpaperID)-"))
        let openverseBytes = try Data(contentsOf: h.owned(openverse))

        // Then the Wallhaven member, through Wallhaven's provider.
        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        XCTAssertEqual(h.network.downloads, [openverse.originalURL, wallhaven2.originalURL])
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.owned(openverse), h.owned(wallhaven2)])
        XCTAssertEqual(h.store.load().rotationCursor, wallhaven2.identityKey)

        // Undo restores the Openverse wallpaper's bytes even after the cache is purged.
        try FileManager.default.removeItem(at: h.originals)
        try await finishAuditTask(h.controller.undoValidationTask)
        h.controller.undoWallpaperChange(nil)
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(h.desktop.calls.last?.image)), openverseBytes)

        // Saved state keeps both identities and the Openverse attribution.
        let saved = h.store.load()
        XCTAssertEqual(saved.collections[0].wallpapers.map(\.identityKey), [wallhaven, openverse, wallhaven2].map(\.identityKey))
        XCTAssertEqual(saved.collections[0].wallpapers[1].license, "cc0")
        XCTAssertEqual(saved.collections[0].wallpapers[1].sourceName, "wikimedia")
        XCTAssertEqual(h.relaunch().state.collections[0].wallpapers.map(\.provider), [.wallhaven, .openverse, .wallhaven])
    }
}

// MARK: - Issue #8 review fixes

extension WallpierTests {
    static func imageData(width: Int, height: Int, type: String = "public.png", orientation: Int? = nil) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func pngData(width: Int, height: Int) -> Data { imageData(width: width, height: height) }

    // 1. Filtered Openverse pages are never traversed automatically; an empty page offers Load More.
    @MainActor
    func testOpenverseEmptyFilteredPageOffersLoadMoreAndNeverAutoPaginates() async throws {
        let openverse = OpenverseFakeNetwork(); openverse.pageCount = 3; openverse.untrustedPages = [1]
        let (c, _, _) = try openverseCaptureController(openverse)
        c.showOpenverse(nil)
        var reached = await eventually { c.emptyStateView.title == "No Verifiable Results Yet" }
        XCTAssertTrue(reached, c.emptyStateView.title)
        await pause(0.3)
        XCTAssertEqual(openverse.requests.count, 1, "An empty filtered page doesn't pull the next one")
        XCTAssertEqual(c.emptyStateView.actionButton.title, "Load More")
        XCTAssertTrue(c.emptyStateView.message.contains("2 results were hidden"), c.emptyStateView.message)
        c.emptyStateView.actionButton.performClick(nil)
        reached = await eventually { c.remoteResults.count == 2 }
        XCTAssertTrue(reached)
        XCTAssertEqual(c.state.selectedRemoteIdentity, c.remoteResults.first?.identityKey, "The first accepted page is selected")
        XCTAssertNotNil(c.collectionView.selectionIndexPaths.first)
        await pause(0.3)
        XCTAssertEqual(openverse.requests.map { value($0, "page") }, ["1", "2"])
        XCTAssertFalse(c.loadMoreButton.isHidden)
        // Preview Next at the last loaded result still asks for the next page.
        c.toggleViewer(nil)
        c.nextWallpaper(nil); c.nextWallpaper(nil)
        reached = await eventually { openverse.requests.count == 3 }
        XCTAssertTrue(reached)
        XCTAssertEqual(value(openverse.requests.last, "page"), "3")
    }

    // 2. Saved Openverse references never steer thumbnail requests; responses are bounded and must end on the API host.
    @MainActor
    func testSavedOpenverseThumbnailURLsAreIgnoredAndResponsesChecked() async throws {
        var tampered = openverseReference(21)
        tampered = WallpaperReference(providerIdentifier: "openverse", wallpaperID: tampered.wallpaperID, sourcePageURL: tampered.sourcePageURL,
                                      originalURL: tampered.originalURL, previewURL: URL(string: "https://127.0.0.1/admin.jpg")!,
                                      thumbnailURL: URL(string: "http://169.254.169.254/latest")!, width: 3840, height: 2160,
                                      uploader: nil, tags: [], cachedLocalPath: nil, title: "Tampered", sourceName: "wikimedia",
                                      license: "cc0", licenseVersion: "1.0", licenseURL: tampered.licenseURL)
        let canonical = try XCTUnwrap(OpenverseURLPolicy.commonsThumbnail(for: tampered.originalURL))
        XCTAssertEqual(tampered.galleryThumbnailURL(large: true), canonical)
        XCTAssertEqual(tampered.galleryThumbnailURL(large: false), canonical)
        XCTAssertEqual(tampered.remotePreview?.url, canonical)
        let badID = WallpaperReference(providerIdentifier: "openverse", wallpaperID: "../../x", sourcePageURL: tampered.sourcePageURL,
                                       originalURL: tampered.originalURL, previewURL: tampered.previewURL, thumbnailURL: tampered.thumbnailURL,
                                       width: 3840, height: 2160, uploader: nil, tags: [], cachedLocalPath: nil)
        XCTAssertNil(badID.galleryThumbnailURL(large: true)); XCTAssertNil(badID.remotePreview)
        let unknown = WallpaperReference(providerIdentifier: "pexels", wallpaperID: "1", sourcePageURL: tampered.sourcePageURL,
                                         originalURL: tampered.originalURL, previewURL: tampered.previewURL, thumbnailURL: tampered.thumbnailURL,
                                         width: 1, height: 1, uploader: nil, tags: [], cachedLocalPath: nil)
        XCTAssertNil(unknown.galleryThumbnailURL(large: true)); XCTAssertNil(unknown.remotePreview)

        let thumbnails = RecordingThumbnails()
        let root = try historyTestFolder()
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                thumbnails: thumbnails) { $0.favorites = [tampered, badID] }
        defer { window.close(); try? FileManager.default.removeItem(at: root) }
        c.showFavorites(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        c.collectionView.layoutSubtreeIfNeeded()
        c.toggleViewer(nil)
        let drawn = await eventually { c.stageView.image != nil }
        XCTAssertTrue(drawn)
        c.nextWallpaper(nil)
        await pause(0.2)
        XCTAssertFalse(thumbnails.requested.isEmpty)
        XCTAssertTrue(thumbnails.requested.allSatisfy { $0 == canonical }, "\(thumbnails.requested)")
        XCTAssertEqual(c.stageView.placeholder, .unavailable, "An unusable identifier shows no thumbnail")

        // Responses: bounded, and an Openverse thumbnail must have ended on its HTTPS API host.
        func response(_ url: String, _ status: Int = 200) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        XCTAssertTrue(RemoteThumbnailProvider.accepts(response(canonical.absoluteString), for: canonical, byteCount: 10))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(response("https://upload.wikimedia.org/a.jpg"), for: canonical, byteCount: 10))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(response(canonical.absoluteString), for: canonical, byteCount: 0))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(response(canonical.absoluteString), for: canonical,
                                                       byteCount: RemoteThumbnailProvider.maximumThumbnailBytes + 1))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(response(canonical.absoluteString, 302), for: canonical, byteCount: 10))
        let wallhaven = URL(string: "https://th.wallhaven.cc/small/ab/abc.jpg")!
        XCTAssertTrue(RemoteThumbnailProvider.accepts(response(wallhaven.absoluteString), for: wallhaven, byteCount: 10))
    }

    func testOpenverseThumbnailNegotiationAndCommonsRedirects() throws {
        let openverse = OpenverseEndpoint.thumbnailURL(id: UUID())
        XCTAssertEqual(RemoteThumbnailProvider.thumbnailRequest(for: openverse).value(forHTTPHeaderField: "Accept"), "*/*")
        let refused = try XCTUnwrap(HTTPURLResponse(url: openverse, statusCode: 406, httpVersion: nil, headerFields: nil))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(refused, for: openverse, byteCount: 57))

        let original = try XCTUnwrap(URL(string: "https://upload.wikimedia.org/wikipedia/commons/4/4f/Pass%2C_Ridge.jpg"))
        let commons = try XCTUnwrap(OpenverseURLPolicy.commonsThumbnail(for: original))
        XCTAssertEqual(commons.absoluteString, "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4f/Pass%2C_Ridge.jpg/500px-Pass%2C_Ridge.jpg")
        XCTAssertEqual(RemoteThumbnailProvider.thumbnailRequest(for: commons).value(forHTTPHeaderField: "Accept"), "image/*")
        let unrelated = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(unrelated, for: commons, byteCount: 1024))
        XCTAssertNil(OpenverseURLPolicy.commonsThumbnail(for: URL(string: "https://upload.wikimedia.org/wikipedia/commons/4/4f/file%2Fname.jpg")!))
    }

    func testStockSnapThumbnailCannotReachSetEvenWithMatchingLicense() async throws {
        let reference = openverseReference(60, source: "stocksnap",
            original: "https://cdn.stocksnap.io/img-thumbs/960w/RKS9M8PY0X.jpg", width: 2048, height: 1365)
        XCTAssertTrue(reference.licenseIsConsistent)
        XCTAssertEqual(reference.useRestriction, .originalUnavailable)
        let client = OpenverseDownloadClient()
        client.body = Self.pngData(width: 960, height: 640)
        do {
            _ = try await OpenverseProvider(client: client).downloadOriginal(for: reference)
            XCTFail("A known thumbnail URL was used as a full original")
        } catch {
            XCTAssertEqual(error as? RemoteProviderError, .originalUnavailable)
        }
        XCTAssertTrue(client.downloads.isEmpty)
        let smaller = FileManager.default.temporaryDirectory.appendingPathComponent("wallpier-stocksnap-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: smaller) }
        try client.body.write(to: smaller)
        XCTAssertFalse(OpenverseProvider.isFaithfulOriginal(at: smaller, for: reference))
    }

    // 4. License deeds, landing hosts and the acknowledgement at the minimum window width.
    @MainActor
    func testOpenverseLicenseConsistencyLandingHostsAndMinimumWidthAttribution() async throws {
        func consistent(_ url: String?, _ license: String?, _ version: String? = "1.0") -> Bool {
            OpenverseURLPolicy.isCanonicalLicenseURL(url.flatMap(URL.init(string:)), license: license, version: version)
        }
        XCTAssertTrue(consistent("https://creativecommons.org/publicdomain/zero/1.0/", "cc0"))
        XCTAssertTrue(consistent("https://creativecommons.org/publicdomain/zero/1.0", "CC0", nil))
        XCTAssertTrue(consistent("https://creativecommons.org/publicdomain/mark/1.0/", "pdm"))
        XCTAssertTrue(consistent("https://creativecommons.org/publicdomain/zero/1.0/deed.en/", "cc0"))
        XCTAssertFalse(consistent("https://creativecommons.org/publicdomain/mark/1.0/deed.en", "cc0"))
        XCTAssertFalse(consistent(nil, "cc0"), "missing")
        XCTAssertFalse(consistent("https://creativecommons.org/publicdomain/mark/1.0/", "cc0"), "mismatched code")
        XCTAssertFalse(consistent("https://creativecommons.org/licenses/by/4.0/", "cc0"))
        XCTAssertFalse(consistent("http://creativecommons.org/publicdomain/zero/1.0/", "cc0"))
        XCTAssertFalse(consistent("https://creativecommons.org.evil.example/publicdomain/zero/1.0/", "cc0"))
        XCTAssertFalse(consistent("https://creativecommons.org/publicdomain/zero/1.0/?x=1", "cc0"))
        XCTAssertFalse(consistent("https://creativecommons.org/publicdomain/zero/1.0/", "cc0", "2.0"), "version disagrees")
        XCTAssertFalse(consistent("https://creativecommons.org/publicdomain/zero/1.0/", nil))
        XCTAssertTrue(OpenverseURLPolicy.isAllowedLandingURL(URL(string: "https://www.flickr.com/photos/a/1")!, source: "flickr"))
        XCTAssertFalse(OpenverseURLPolicy.isAllowedLandingURL(URL(string: "https://evil.example/photos/a/1")!, source: "flickr"))
        XCTAssertFalse(OpenverseURLPolicy.isAllowedLandingURL(URL(string: "https://commons.wikimedia.org/x")!, source: "flickr"))
        XCTAssertFalse(OpenverseURLPolicy.isAllowedLandingURL(URL(string: "https://commons.wikimedia.org/x")!, source: nil))

        // A saved Openverse reference on an unknown landing host isn't linked.
        var offsite = openverseReference(31)
        offsite = WallpaperReference(providerIdentifier: "openverse", wallpaperID: offsite.wallpaperID,
                                     sourcePageURL: URL(string: "https://evil.example/landing")!, originalURL: offsite.originalURL,
                                     previewURL: offsite.previewURL, thumbnailURL: offsite.thumbnailURL, width: 3840, height: 2160,
                                     uploader: nil, tags: [], cachedLocalPath: nil, title: "Offsite", sourceName: "wikimedia",
                                     license: "cc0", licenseVersion: "1.0", licenseURL: offsite.licenseURL)
        let text = try XCTUnwrap(MainWindowController.attribution(for: offsite))
        let source = (text.string as NSString).range(of: "Source:")
        XCTAssertNil(text.attribute(.link, at: source.location, effectiveRange: nil))

        // At the minimum window width the bar's acknowledgement and the preview's attribution are whole.
        let openverse = OpenverseFakeNetwork(); openverse.pageCount = 2
        let (c, window, _) = try openverseCaptureController(openverse, thumbnails: RecordingThumbnails())
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
        c.showOpenverse(nil)
        let loaded = await eventually { c.remoteResults.count == 2 }
        XCTAssertTrue(loaded)
        window.contentView?.layoutSubtreeIfNeeded()
        func whole(_ label: NSTextField, _ name: String) {
            XCTAssertFalse(label.isHiddenOrHasHiddenAncestor, name)
            XCTAssertGreaterThanOrEqual(label.frame.width + 0.5, label.intrinsicContentSize.width, "\(name) is truncated")
        }
        whole(c.openverseNoticeLabel, "acknowledgement")
        XCTAssertFalse(c.loadMoreButton.isHiddenOrHasHiddenAncestor)
        c.toggleViewer(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        whole(c.previewAttributionLabel, "attribution"); whole(c.previewAcknowledgementLabel, "preview acknowledgement")
        whole(c.previewMetadataLabel, "creator")
        c.nextWallpaper(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        whole(c.previewAttributionLabel, "unconfirmed attribution")
        XCTAssertFalse(c.reviewSourceButton.isHiddenOrHasHiddenAncestor)
    }

    // 5. Attribution never outlives its Openverse selection.
    @MainActor
    func testOpenverseAttributionClearsForLocalEmptyAndWallhavenSelections() async throws {
        let openverse = OpenverseFakeNetwork(); openverse.pageCount = 1
        let (c, _, _) = try openverseCaptureController(openverse, thumbnails: RecordingThumbnails())
        c.showOpenverse(nil)
        let loaded = await eventually { c.remoteResults.count == 2 }
        XCTAssertTrue(loaded)
        c.toggleViewer(nil)
        XCTAssertFalse(c.previewAttributionLabel.isHidden)
        c.showLocal(nil)   // No folder chosen: an empty selection.
        XCTAssertNil(c.state.folderPath)
        XCTAssertTrue(c.previewAttributionLabel.isHidden)
        XCTAssertEqual(c.previewAttributionLabel.stringValue, "")
        XCTAssertTrue(c.previewAcknowledgementLabel.isHidden)
        XCTAssertTrue(c.reviewSourceButton.isHidden)
        c.showOpenverse(nil)
        XCTAssertFalse(c.previewAttributionLabel.isHidden)
        c.showFavorites(nil)   // Wallhaven favorites.
        XCTAssertTrue(c.previewAttributionLabel.isHidden)
        XCTAssertTrue(c.previewAcknowledgementLabel.isHidden)
    }

    // 6. Unsupported providers and unconfirmed licenses fail closed for Set and rotation, before any cache or network.
    @MainActor
    func testUnsupportedProviderAndUnconfirmedLicenseNeverReachNetworkSetOrRotation() async throws {
        var unconfirmed = openverseReference(41); unconfirmed.licenseURL = nil
        let unsupported = WallpaperReference(providerIdentifier: "pexels", wallpaperID: "777", sourcePageURL: URL(string: "https://www.pexels.com/photo/777")!,
                                             originalURL: URL(string: "https://images.pexels.com/777.jpg")!, previewURL: URL(string: "https://images.pexels.com/777s.jpg")!,
                                             thumbnailURL: URL(string: "https://images.pexels.com/777t.jpg")!, width: 3840, height: 2160,
                                             uploader: nil, tags: [], cachedLocalPath: nil)
        XCTAssertNil(unsupported.provider)
        for (reference, message) in [(unsupported, "doesn’t support"), (unconfirmed, "Review the original source")] {
            let root = try historyTestFolder()
            let harness = SetAuditHarness(root: root, references: [reference])
            try writeTestImage(to: harness.prior, width: 3)
            defer { harness.network.downloadGate.release(.failure(CancellationError())); try? FileManager.default.removeItem(at: root) }
            XCTAssertFalse(harness.controller.setWallpaperButton.isEnabled)
            harness.controller.setWallpaper(nil)
            try await finishAuditTask(harness.controller.downloadTask)
            XCTAssertTrue(harness.controller.statusLabel.stringValue.contains(message), harness.controller.statusLabel.stringValue)
            harness.controller.rotateWallpaper()
            try await finishAuditTask(harness.controller.rotationTask)
            XCTAssertTrue(harness.network.downloads.isEmpty, "\(reference.providerIdentifier): never requested")
            XCTAssertTrue(harness.desktop.calls.isEmpty)
            XCTAssertTrue(harness.store.load().history.isEmpty)
        }
        // And search results only keep wide, explicitly non-mature, sane-sized works under the selected license.
        let data = try fixtureData(named: "openverse-search")
        let cc0Only = try await OpenverseProvider(client: StubNetworkClient(data: data)).search(options: OpenverseSearchOptions(license: .cc0), page: 1)
        XCTAssertEqual(cc0Only.wallpapers.map(\.license), ["cc0"], "A pdm result isn't shown for a CC0-only search")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var results = try XCTUnwrap(object["results"] as? [[String: Any]])
        let base = results[0]
        let variants: [[String: Any?]] = [["width": 2000, "height": 2400], ["mature": nil], ["width": 800, "height": 450], ["width": 200_000]]
        results = variants.map { change in var item = base; for (k, v) in change { item[k] = v ?? NSNull() }; return item }
        object["results"] = results
        let filtered = try await OpenverseProvider(client: StubNetworkClient(data: JSONSerialization.data(withJSONObject: object)))
            .search(options: OpenverseSearchOptions(), page: 1)
        XCTAssertTrue(filtered.wallpapers.isEmpty, "portrait, unknown mature flag, too small, absurd size")
        XCTAssertEqual(filtered.hiddenCount, 4)
    }
}

extension WallpierTests {
    /// A cached Openverse file that isn't the exact reported original (stale or replaced by a downsized copy) is
    /// neither reused nor shown as the original: Set downloads the original and installs it beside the stale file.
    @MainActor
    func testStaleCachedOpenverseOriginalIsNotReusedOrAdvertised() async throws {
        let reference = openverseReference(51)
        let root = try historyTestFolder()
        let harness = SetAuditHarness(root: root, references: [reference])
        defer { harness.network.downloadGate.release(.failure(CancellationError())); try? FileManager.default.removeItem(at: root) }
        try writeTestImage(to: harness.prior, width: 3)
        let stale = harness.cached(reference)
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.pngData(width: 16, height: 9).write(to: stale)
        try Self.pngData(width: 32, height: 18).write(to: harness.incoming)
        let cache = RemoteWallpaperCache(rootURL: stale.deletingLastPathComponent())
        let unchecked = try await cache.cachedURL(for: reference)
        XCTAssertEqual(unchecked, stale, "The plain image check (Wallhaven's) is unchanged")
        let checked = try await cache.cachedURL(for: reference) { OpenverseProvider.isFaithfulOriginal(at: $0, for: reference) }
        XCTAssertNil(checked)

        harness.controller.setWallpaper(nil)
        await fulfillment(of: [harness.network.downloadGate.started], timeout: 5)
        XCTAssertEqual(harness.network.downloads, [reference.originalURL], "The stale file is not reused")
        harness.network.downloadGate.release(.success(harness.incoming))
        try await finishAuditTask(harness.controller.downloadTask)
        let applied = try XCTUnwrap(harness.desktop.calls.last?.image)
        XCTAssertTrue(OpenverseProvider.isFaithfulOriginal(at: applied, for: reference), "The desktop gets the full original")
        let saved = try XCTUnwrap(harness.store.load().favorites.first?.cachedLocalPath)
        XCTAssertNotEqual(saved, stale.path)
        XCTAssertTrue(OpenverseProvider.isFaithfulOriginal(at: URL(fileURLWithPath: saved), for: reference))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path), "The stale file is left, never overwritten")
    }
}

// MARK: - Issue #10: Cleveland Museum of Art creator discovery
//
// Deterministic and offline: fixture JSON, fake networks, the recording wallpaper service and temporary stores.
// Nothing reaches the museum, the user's preferences or the real desktop. The live walk at the end is opt-in.

/// Answers CMA API and media requests from fixtures and records every request, in order.
final class CMAFakeNetwork: NetworkClient, @unchecked Sendable {
    struct Route {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var finalURL: URL?
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var recorded: [String] = []
    private var recordedURLs: [URL] = []
    private var recordedTemporaries: [URL] = []
    var media = Route(headers: ["Content-Type": "image/jpeg"])
    /// A stream that reports this many bytes before finishing, to exercise the cap without allocating them.
    var streamedBytes: Int64?

    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return recordedURLs }
    var temporaries: [URL] { lock.lock(); defer { lock.unlock() }; return recordedTemporaries }
    var apiEvents: [String] { events.filter { $0.hasPrefix("api:") } }
    var mediaEvents: [String] { events.filter { $0.hasPrefix("media:") } }

    func setRoute(_ key: String, _ route: Route) { lock.lock(); routes[key] = route; lock.unlock() }

    /// `search:artists` and `search:q` for the two searches; the path for everything else.
    static func key(for url: URL) -> String {
        // URL.path drops the trailing slash on some SDKs; the encoded path keeps what was requested.
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard path == "/api/artworks/" || path == "/api/artworks" else { return path }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "artists" } ? "search:artists" : "search:q"
    }

    private func record(_ event: String, _ url: URL) { lock.lock(); recorded.append(event); recordedURLs.append(url); lock.unlock() }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let key = Self.key(for: url)
        record("api:\(key)", url)
        let found = lock.withLock { routes[key] }
        let route = found ?? Route(status: 404, body: Data(#"{"error":"Not found"}"#.utf8))
        return (route.body, HTTPURLResponse(url: route.finalURL ?? url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers)!)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let url = request.url!
        record("media:\(url.absoluteString)", url)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wallpier-cma-\(UUID().uuidString).jpg")
        try media.body.write(to: file)
        lock.withLock { recordedTemporaries.append(file) }
        return (file, HTTPURLResponse(url: media.finalURL ?? url, statusCode: media.status, httpVersion: "HTTP/1.1", headerFields: media.headers)!)
    }

    func boundedDownload(for request: URLRequest, maximumBytes: Int64, maximumRedirects: Int) async throws -> (URL, HTTPURLResponse) {
        if let streamedBytes, streamedBytes > maximumBytes {
            record("media:\(request.url!.absoluteString)", request.url!)
            throw RemoteProviderError.originalTooLarge
        }
        return try await download(for: request)
    }
}

/// A URLProtocol that scripts a streamed response, to drive the real bounded downloader without a network.
final class CMAStreamProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _script: ((CMAStreamProtocol) -> Void)?
    private static var _requested: [URL] = []
    private static var _chunks = 0
    private var _stopped = false

    static var script: ((CMAStreamProtocol) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _script }
        set { lock.lock(); _script = newValue; lock.unlock() }
    }
    static var requested: [URL] { lock.lock(); defer { lock.unlock() }; return _requested }
    static var chunksSent: Int { lock.lock(); defer { lock.unlock() }; return _chunks }
    static func reset() { lock.lock(); _requested = []; _chunks = 0; _script = nil; lock.unlock() }

    var stopped: Bool { Self.lock.lock(); defer { Self.lock.unlock() }; return _stopped }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self._requested.append(request.url!); let script = Self._script; Self.lock.unlock()
        script?(self)
    }
    override func stopLoading() { Self.lock.lock(); _stopped = true; Self.lock.unlock() }

    func respond(status: Int, headers: [String: String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
    }
    func send(_ data: Data) { Self.lock.lock(); Self._chunks += 1; Self.lock.unlock(); client?.urlProtocol(self, didLoad: data) }
    func finish() { client?.urlProtocolDidFinishLoading(self) }
    func redirect(to url: URL) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
        // If the loading system doesn't deliver the refused redirect itself, deliver it as the final response.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [self] in
            guard !stopped else { return }
            respond(status: 302, headers: ["Location": url.absoluteString]); finish()
        }
    }
}

extension WallpierTests {
    // MARK: Fixtures

    static func cmaJSON(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    static func cmaCreator(_ id: Int = 23328, _ description: String = "Katsushika Hokusai (Japanese, 1760–1849)",
                           role: String = "artist", qualifier: String = "") -> [String: Any] {
        ["id": id, "description": description, "role": role, "qualifier": qualifier]
    }

    /// A record as the API sends it: string dimensions, `url`, `creators`, `share_license_status` and `images`.
    static func cmaRow(_ id: Int, title: String? = "Fixture Work", creators: [[String: Any]]? = nil, license: String = "CC0",
                       web: (String, String)? = ("800", "500"), printSize: (String, String)? = ("2000", "1250"),
                       printFilesize: String = "9000000") -> [String: Any] {
        let accession = "1930.\(id)"
        func rendition(_ kind: String, _ size: (String, String), _ filesize: String) -> [String: Any] {
            ["url": "https://openaccess-cdn.clevelandart.org/\(accession)/\(accession)_\(kind).jpg", "width": size.0, "height": size.1,
             "filesize": filesize, "filename": "\(accession)_\(kind).jpg"]
        }
        var images: [String: Any] = [:]
        if let web { images["web"] = rendition("web", web, "100000") }
        if let printSize { images["print"] = rendition("print", printSize, printFilesize) }
        var row: [String: Any] = ["id": id, "creation_date": "about 1831", "accession_number": accession,
                                  "url": "https://clevelandart.org/art/\(accession)", "creators": creators ?? [cmaCreator()],
                                  "share_license_status": license, "images": images]
        if let title { row["title"] = title }
        return row
    }

    static func cmaReference(_ id: Int, title: String? = "Fixture Work", creators: [[String: Any]]? = nil, license: String = "CC0",
                             web: (String, String)? = ("800", "500"), printSize: (String, String)? = ("2000", "1250")) -> WallpaperReference {
        CMAParsing.reference(from: cmaRow(id, title: title, creators: creators, license: license, web: web, printSize: printSize))!
    }

    static func cmaEnvelope(_ rows: [[String: Any]], total: Int? = nil) -> CMAFakeNetwork.Route {
        let info: [String: Any] = ["total": total ?? rows.count, "parameters": [String: Any]()]
        let body: [String: Any] = ["info": info, "data": rows]
        return CMAFakeNetwork.Route(body: cmaJSON(body))
    }

    static func cmaDetailRoute(_ row: [String: Any]) -> CMAFakeNetwork.Route {
        let body: [String: Any] = ["data": row]
        return CMAFakeNetwork.Route(body: cmaJSON(body))
    }

    static func cmaCreatorDetailRoute(id: Int = 23328, name: String = "Katsushika Hokusai", stubs: [Int] = [111654, 152506, 900001, 900009]) -> CMAFakeNetwork.Route {
        let detail: [String: Any] = ["id": id, "name": name, "description": "\(name) (Japanese, 1760–1849)", "artworks": stubs.map { ["id": $0] }]
        let body: [String: Any] = ["data": detail]
        return CMAFakeNetwork.Route(body: cmaJSON(body))
    }

    /// Hokusai (23328): the anchor, plain works (one with a co-creator), a thumbnail-only work, a metadata-only work,
    /// and the rows that must be excluded: "attributed to", someone else's "after" derivative, a non-plain role, a
    /// different creator, and one record with no canonical link.
    static func cmaCreatorNetwork(allOpen: Bool = false) -> CMAFakeNetwork {
        let network = CMAFakeNetwork()
        let hokusai = [cmaCreator()]
        let plainOpen = cmaRow(900004, title: "Plain Open", creators: hokusai)
        let plainRestricted = cmaRow(900004, title: "Plain Copyrighted", creators: hokusai, license: "Copyrighted", web: nil, printSize: nil)
        let invalid: [String: Any] = ["id": 900005, "title": "No link"]
        let rows: [[String: Any]] = [
            cmaRow(111654, title: "The Great Wave", creators: hokusai),
            cmaRow(152506, title: "Fuji &amp; Waves", creators: [cmaCreator(), cmaCreator(999, "Nishimuraya Yohachi (Japanese)", role: "publisher")]),
            cmaRow(152507, title: "Red Fuji", creators: hokusai),
            cmaRow(152508, title: "Thumbnail Only", creators: hokusai, printSize: nil),
            allOpen ? plainOpen : plainRestricted,
            cmaRow(900001, title: "Attributed", creators: [cmaCreator(qualifier: "attributed to")]),
            cmaRow(900002, title: "After Hokusai", creators: [cmaCreator(1313, "Unknown Follower (Japanese)", qualifier: "after")]),
            cmaRow(900003, title: "Publisher Only", creators: [cmaCreator(role: "publisher")]),
            cmaRow(287051, title: "Kara Walker", creators: [cmaCreator(5000, "Kara Walker (American, born 1969)")],
                   license: "Copyrighted", web: nil, printSize: nil),
            invalid
        ]
        network.setRoute("/api/creators/23328", cmaCreatorDetailRoute())
        network.setRoute("search:artists", cmaEnvelope(rows, total: 250))
        for id in [111654, 152506, 152507] { network.setRoute("/api/artworks/\(id)", cmaDetailRoute(rows.first { ($0["id"] as? Int) == id }!)) }
        network.media = CMAFakeNetwork.Route(body: imageData(width: 2000, height: 1250, type: "public.jpeg"), headers: ["Content-Type": "image/jpeg"])
        return network
    }

    /// One settable work whose detail and print JPEG both verify.
    static func cmaDownloadNetwork(id: Int = 152506) -> CMAFakeNetwork {
        let network = CMAFakeNetwork()
        network.setRoute("/api/artworks/\(id)", cmaDetailRoute(cmaRow(id)))
        network.media = CMAFakeNetwork.Route(body: imageData(width: 2000, height: 1250, type: "public.jpeg"), headers: ["Content-Type": "image/jpeg"])
        return network
    }

    @MainActor
    private func cmaController(_ network: CMAFakeNetwork, desktop: WallpaperService? = nil, thumbnails: RemoteThumbnailProvider? = nil)
        throws -> (MainWindowController, NSWindow, URL, WallpaperReference) {
        let root = try historyTestFolder()
        let anchor = Self.cmaReference(111654, title: "The Great Wave")
        let (controller, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua, cma: network,
                                                         desktop: desktop, thumbnails: thumbnails ?? RecordingThumbnails()) { state in
            state.favorites = [anchor]; state.collections = []; state.selectedCollectionID = nil
            state.currentSource = .favorites; state.selectedRemoteIdentity = anchor.identityKey
        }
        addTeardownBlock {
            let tasks = await MainActor.run { () -> [Task<Void, Never>] in
                let tasks = [controller.downloadTask, controller.searchTask, controller.detailTask, controller.undoValidationTask,
                             controller.creatorTaskForTesting].compactMap { $0 }
                tasks.forEach { $0.cancel() }
                while let sheet = window.attachedSheet { window.endSheet(sheet) }
                window.close()
                return tasks
            }
            for task in tasks { await task.value }
            try? FileManager.default.removeItem(at: root)
        }
        return (controller, window, root, anchor)
    }

    @MainActor
    private func selectCMAItem(_ index: Int, in controller: MainWindowController) {
        let path = IndexPath(item: index, section: 0)
        controller.collectionView.selectionIndexPaths = [path]
        controller.collectionView(controller.collectionView, didSelectItemsAt: [path])
    }

    // MARK: Display text

    func testDisplayTextDecodesStripsAndBoundsInOrder() {
        XCTAssertEqual(DisplayText.clean("Wave &amp; Fuji &#x2014; &quot;Great&quot; &#8212;"), "Wave & Fuji — \"Great\" —")
        // Malformed entities stay literal; one decoding pass only.
        XCTAssertEqual(DisplayText.clean("AT&T &bogus; &#xZZ; &#99999999999; &#xD800; &amp"), "AT&T &bogus; &#xZZ; &#99999999999; &#xD800; &amp")
        XCTAssertEqual(DisplayText.clean("&amp;lt;b&amp;gt;"), "&lt;b&gt;")
        // Tag-like spans are removed as text, including ones an entity decoded into; prose with < or > is kept.
        XCTAssertEqual(DisplayText.clean("A <b>bold</b> <i>move</i>"), "A bold move")
        XCTAssertEqual(DisplayText.clean("&lt;script&gt;alert(1)&lt;/script&gt;Wave"), "alert(1)Wave")
        XCTAssertEqual(DisplayText.clean("<scr<b>ipt>x"), "x")
        XCTAssertEqual(DisplayText.clean("x < y and y > z"), "x < y and y > z")
        // Control and bidi-override characters go; whitespace collapses.
        XCTAssertEqual(DisplayText.clean("A\u{202E}BC\u{0007}D\u{200B}E\u{2066}F"), "ABCDEF")
        XCTAssertEqual(DisplayText.clean(" A\n\t  B\u{00A0}C "), "A B C")
        XCTAssertEqual(DisplayText.clean("&#0;Z&#8238;"), "Z")
        // NFC.
        XCTAssertEqual(Array(DisplayText.clean("e\u{0301}").unicodeScalars), [Unicode.Scalar(0x00E9)!])
        // Capped with an ellipsis.
        let capped = DisplayText.clean(String(repeating: "x", count: 300))
        XCTAssertEqual(capped.count, DisplayText.defaultLimit); XCTAssertTrue(capped.hasSuffix("…"))
        // Nothing displayable falls back.
        XCTAssertEqual(DisplayText.title("  <b></b> \u{202E}"), "Untitled"); XCTAssertEqual(DisplayText.title(nil), "Untitled")
        XCTAssertEqual(DisplayText.creator("&#0;"), "Unattributed")
        // Quote-aware: a “>” inside a quoted attribute doesn't end the tag. Prose comparisons stay.
        XCTAssertEqual(DisplayText.clean("A <a title=\"x > y\" href='#'>link</a> B"), "A link B")
        XCTAssertEqual(DisplayText.clean("1 < 2 and 3 > 2, <3"), "1 < 2 and 3 > 2, <3")
        // A truncated closing tag, or a recognizable opening tag cut short, is removed to the end.
        XCTAssertEqual(DisplayText.clean("Triumph </i"), "Triumph"); XCTAssertEqual(DisplayText.clean("Triumph </"), "Triumph")
        XCTAssertEqual(DisplayText.clean("Triumph <div class='fn"), "Triumph")
        // Structural line breaks separate text; inline tags don't add a gap.
        XCTAssertEqual(DisplayText.clean("Wave<br>Fuji<p>Sea</p>Sky"), "Wave Fuji Sea Sky")
        XCTAssertEqual(DisplayText.clean("Fu<b>ji</b>"), "Fuji")
        XCTAssertEqual(DisplayText.clean("Wave\nFuji"), "Wave Fuji")
        // The exact markup the live Openverse record 811e7030-bcad-4c4a-b497-30f892cc2d24 returned.
        XCTAssertEqual(DisplayText.clean("<div class='fn'> <i>Entry of Alexander the Great into Babylon, or The Triumph of Alexander </i></div>"),
                       "Entry of Alexander the Great into Babylon, or The Triumph of Alexander")
        // Joiners, combining marks and casing survive; bidi overrides and unsafe controls don't.
        let family = "👩\u{200D}👩\u{200D}👧", persian = "می\u{200C}خواهم", combined = "Ṩ̇ ÉCOLE İstanbul straße"
        XCTAssertEqual(DisplayText.clean(family + "\u{202E}"), family); XCTAssertEqual(DisplayText.clean(persian), persian)
        XCTAssertEqual(DisplayText.clean(combined), combined.precomposedStringWithCanonicalMapping)
    }

    func testOpenverseQualifiedCreditsReadAsReportedAndOrdinaryOnesStayBy() {
        var reference = openverseReference(8)
        XCTAssertEqual(reference.displayCredit, "by Fixture Photographer")
        reference.uploader = "after Charles Le Brun"
        XCTAssertEqual(reference.displayCredit, "after Charles Le Brun", "Never “by after …”")
        reference.uploader = "Attributed to &amp; Friends"
        XCTAssertEqual(reference.displayCredit, "Attributed to & Friends")
        reference.uploader = "Afterglow Studio"
        XCTAssertEqual(reference.displayCredit, "by Afterglow Studio", "Only a whole leading qualifier word is one")
        reference.uploader = nil
        XCTAssertNil(reference.displayCredit)
        var wallhaven = remoteReference(id: "abc123"); wallhaven.uploader = "after_dark"
        XCTAssertEqual(wallhaven.displayCredit, "by after_dark")
    }

    func testOpenverseOldSavedReferencesAreCleanedForDisplayOnlyAndRawMetadataIsKept() throws {
        var saved = openverseReference(7)
        saved.title = "Dawn &amp; <i>Dusk</i>\u{202E} &#x1F33F;"
        saved.uploader = "Ann &lt;3 Bob\u{200B}"
        XCTAssertEqual(saved.displayTitle, "Dawn & Dusk 🌿")
        XCTAssertEqual(saved.displayCreator, "Ann <3 Bob")
        // A reference saved by an older build decodes and reads the same way, and its raw text round-trips untouched.
        let decoded = try JSONDecoder().decode(WallpaperReference.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.title, "Dawn &amp; <i>Dusk</i>\u{202E} &#x1F33F;")
        XCTAssertEqual(decoded.uploader, "Ann &lt;3 Bob\u{200B}")
        XCTAssertEqual(decoded.displayTitle, saved.displayTitle)
        saved.title = "<b></b>"; saved.uploader = "&#0;"
        XCTAssertEqual(saved.displayTitle, "Untitled"); XCTAssertEqual(saved.displayCreator, "Unattributed")
        saved.title = nil; saved.uploader = nil
        XCTAssertEqual(saved.displayTitle, saved.wallpaperID, "An absent title is still absent, not invented")
        XCTAssertNil(saved.displayCreator)
        // Wallhaven is untouched.
        var wallhaven = remoteReference(id: "abc123"); wallhaven.uploader = "x&amp;y"
        XCTAssertEqual(wallhaven.displayTitle, "abc123"); XCTAssertEqual(wallhaven.displayCreator, "x&amp;y")
    }

    // MARK: URL policy and endpoints

    func testCMAURLPolicyAllowsOnlyDocumentedHostsPathsAndRedirects() throws {
        func url(_ string: String) -> URL { URL(string: string)! }
        let web = url("https://openaccess-cdn.clevelandart.org/1930.189/1930.189_web.jpg")
        let print = url("https://openaccess-cdn.clevelandart.org/1930.189/1930.189_print.jpg")
        XCTAssertTrue(CMAURLPolicy.isAllowedMediaURL(web, rendition: .web)); XCTAssertTrue(CMAURLPolicy.isAllowedMediaURL(print, rendition: .print))
        XCTAssertFalse(CMAURLPolicy.isAllowedMediaURL(print, rendition: .web), "The rendition must match its name")
        for rejected in ["http://openaccess-cdn.clevelandart.org/1930.189/1930.189_web.jpg", "https://evil.example/1930.189/1930.189_web.jpg",
                         "https://openaccess-cdn.clevelandart.org.evil.example/1930.189/1930.189_web.jpg",
                         "https://user:pw@openaccess-cdn.clevelandart.org/1930.189/1930.189_web.jpg",
                         "https://openaccess-cdn.clevelandart.org:8443/1930.189/1930.189_web.jpg",
                         "https://openaccess-cdn.clevelandart.org/1930.189/1930.189_web.jpg?x=1",
                         "https://openaccess-cdn.clevelandart.org/a/b/1930.189_web.jpg", "https://openaccess-cdn.clevelandart.org/1930.189_web.jpg",
                         "https://openaccess-cdn.clevelandart.org/../1930.189_web.jpg", "https://openaccess-cdn.clevelandart.org/1930.189/other_web.jpg",
                         "https://openaccess-cdn.clevelandart.org/1930.189/1930.189_web.tif", "https://clevelandart.org/1930.189/1930.189_web.jpg"] {
            XCTAssertFalse(CMAURLPolicy.isAllowedMediaURL(url(rejected), rendition: .web), rejected)
        }
        XCTAssertTrue(CMAURLPolicy.isAllowedPageURL(url("https://clevelandart.org/art/1930.189")))
        XCTAssertTrue(CMAURLPolicy.isAllowedPageURL(url("https://www.clevelandart.org/art/1930.189")))
        for rejected in ["http://clevelandart.org/art/1", "https://clevelandart.org.evil.example/art/1", "https://evil.example/art/1",
                         "https://openaccess-api.clevelandart.org/api/artworks/1"] {
            XCTAssertFalse(CMAURLPolicy.isAllowedPageURL(url(rejected)), rejected)
        }
        XCTAssertTrue(CMAURLPolicy.allowsRedirect(from: web, to: url("https://openaccess-cdn.clevelandart.org/1930.189/1930.189_web.jpg")))
        XCTAssertFalse(CMAURLPolicy.allowsRedirect(from: web, to: url("https://openaccess-cdn.clevelandart.org/other/x.jpg")), "Same item and rendition path only")
        XCTAssertFalse(CMAURLPolicy.allowsRedirect(from: web, to: url("https://openaccess-cdn.clevelandart.org/1930.189/1930.189_web.jpg?x=1")))
        XCTAssertFalse(CMAURLPolicy.allowsRedirect(from: web, to: print), "Not another rendition")
        XCTAssertFalse(CMAURLPolicy.allowsRedirect(from: web, to: url("http://openaccess-cdn.clevelandart.org/x.jpg")), "No HTTP downgrade")
        XCTAssertFalse(CMAURLPolicy.allowsRedirect(from: web, to: url("https://evil.example/x.jpg")))
        XCTAssertFalse(CMAURLPolicy.allowsRedirect(from: web, to: url("https://openaccess-api.clevelandart.org/api/artworks/1")))
        let api = url("https://openaccess-api.clevelandart.org/api/artworks/1")
        XCTAssertTrue(CMAURLPolicy.allowsRedirect(from: api, to: url("https://openaccess-api.clevelandart.org/api/artworks/2")))
        XCTAssertFalse(CMAURLPolicy.allowsRedirect(from: api, to: web)); XCTAssertFalse(CMAURLPolicy.allowsRedirect(from: url("https://evil.example/"), to: web))
        XCTAssertTrue(CMAURLPolicy.isCMAHost(url("https://www.clevelandart.org/x"))); XCTAssertFalse(CMAURLPolicy.isCMAHost(url("https://notclevelandart.org/x")))

        func items(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        let search = CMAEndpoint.searchURL(options: CMASearchOptions(query: " c++ sky "), page: 3)
        XCTAssertEqual(URLComponents(url: search, resolvingAgainstBaseURL: false)?.host, "openaccess-api.clevelandart.org")
        XCTAssertEqual(URLComponents(url: search, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/api/artworks/")
        XCTAssertEqual(items(search)["q"], "c++ sky"); XCTAssertTrue(search.absoluteString.contains("q=c%2B%2B%20sky"), search.absoluteString)
        XCTAssertNil(items(search)["cc0"], "Typed text searches all public records"); XCTAssertNil(items(search)["has_image"])
        XCTAssertEqual(items(search)["limit"], "20"); XCTAssertEqual(items(search)["skip"], "40")
        let blank = items(CMAEndpoint.searchURL(options: CMASearchOptions(), page: 0))
        XCTAssertNil(blank["q"]); XCTAssertEqual(blank["cc0"], "1"); XCTAssertEqual(blank["has_image"], "1"); XCTAssertEqual(blank["skip"], "0")
        let artist = CMAEndpoint.artistWorksURL(name: "Katsushika Hokusai")
        XCTAssertEqual(items(artist)["artists"], "Katsushika Hokusai"); XCTAssertEqual(items(artist)["limit"], "100")
        XCTAssertNil(items(artist)["skip"], "No pagination"); XCTAssertNil(items(artist)["cc0"])
        XCTAssertEqual(CMAEndpoint.creatorURL(id: 23328).absoluteString, "https://openaccess-api.clevelandart.org/api/creators/23328")
        XCTAssertEqual(CMAEndpoint.artworkURL(id: 111654).absoluteString, "https://openaccess-api.clevelandart.org/api/artworks/111654")
    }

    // MARK: Classification and credit

    func testCMAClassifiesEachRowOnceIntoSettableThumbnailOnlyAndMetadataOnly() throws {
        let settable = Self.cmaReference(111654, title: "The Great Wave")
        XCTAssertEqual(settable.cmaKind, .settable); XCTAssertFalse(settable.blocksUse); XCTAssertFalse(settable.isCMABrowseOnly)
        XCTAssertEqual(settable.identityKey, "cma:111654")
        XCTAssertEqual(settable.sourcePageURL.absoluteString, "https://clevelandart.org/art/1930.111654")
        XCTAssertEqual(settable.thumbnailURL.absoluteString, "https://openaccess-cdn.clevelandart.org/1930.111654/1930.111654_web.jpg")
        XCTAssertEqual(settable.originalURL.absoluteString, "https://openaccess-cdn.clevelandart.org/1930.111654/1930.111654_print.jpg")
        XCTAssertEqual(settable.galleryThumbnailURL(large: true), settable.thumbnailURL)
        XCTAssertEqual(settable.remotePreview?.url, settable.thumbnailURL)
        XCTAssertEqual(settable.width, 2000); XCTAssertEqual(settable.height, 1250)
        XCTAssertEqual(settable.cmaProvenance, "Katsushika Hokusai · Cleveland Museum of Art · CC0")
        XCTAssertEqual(settable.sourceDisplayName, "Cleveland Museum of Art")

        // CC0 with a web rendition but no valid print: a thumbnail and a link, nothing more.
        let thumbnailOnly = Self.cmaReference(2, printSize: nil)
        XCTAssertEqual(thumbnailOnly.cmaKind, .thumbnailOnly); XCTAssertEqual(thumbnailOnly.useRestriction, .browseOnly)
        XCTAssertNotNil(thumbnailOnly.galleryThumbnailURL(large: false)); XCTAssertNil(thumbnailOnly.remotePreview)
        for bad in [("ABC", "1250"), ("2000", "0"), ("99999999999999999999", "1250"), ("-5", "100"), ("20.5", "100"), ("", "")] {
            XCTAssertEqual(Self.cmaReference(3, printSize: bad).cmaKind, .thumbnailOnly, "Dimensions \(bad) reject the print")
        }
        // A print that metadata already shows can't be faithful is thumbnail-only, never an enabled Set.
        for (name, size) in [("same size as web", ("800", "500")), ("small", ("1500", "900")), ("huge", ("12000", "9000"))] {
            let row = Self.cmaReference(11, printSize: size)
            XCTAssertEqual(row.cmaKind, .thumbnailOnly, name); XCTAssertEqual(row.useRestriction, .browseOnly, name)
        }
        var oversizedFile = Self.cmaRow(12, printFilesize: "999999999")
        XCTAssertEqual(CMAParsing.reference(from: oversizedFile)?.cmaKind, .thumbnailOnly, "Reported size over the byte cap")
        oversizedFile["images"] = ["print": ["url": "https://openaccess-cdn.clevelandart.org/1930.12/1930.12_web.jpg", "width": "2000", "height": "1250"],
                                   "web": ["url": "https://openaccess-cdn.clevelandart.org/1930.12/1930.12_web.jpg", "width": "800", "height": "500"]]
        XCTAssertEqual(CMAParsing.reference(from: oversizedFile)?.cmaKind, .thumbnailOnly, "A web rendition path offered as the print")
        // A qualifier that is present but not text never reads as “no qualifier”.
        let malformedCreators: [[String: Any]] = [["id": 23328, "description": "H (Japanese)", "role": "artist", "qualifier": 7]]
        var malformed = Self.cmaRow(13); malformed["creators"] = malformedCreators
        XCTAssertNil(CMAParsing.reference(from: malformed)?.cmaPivot)
        // Not CC0, or no usable images (Kara Walker 287051): a text row. No image of any kind is ever derived from it.
        let walker = Self.cmaReference(287051, creators: [Self.cmaCreator(5000, "Kara Walker (American, born 1969)")], license: "Copyrighted", web: nil, printSize: nil)
        let copyrightedWithImages = Self.cmaReference(4, license: "Copyrighted")
        let noWeb = Self.cmaReference(5, web: nil)
        for reference in [walker, copyrightedWithImages, noWeb] {
            XCTAssertEqual(reference.cmaKind, .metadataOnly, reference.identityKey)
            XCTAssertNil(reference.galleryThumbnailURL(large: true)); XCTAssertNil(reference.remotePreview)
            XCTAssertEqual(reference.useRestriction, .browseOnly); XCTAssertEqual(reference.cmaUseRestriction, .browseOnly)
            XCTAssertTrue(reference.isCMABrowseOnly)
            XCTAssertEqual(reference.originalURL, reference.sourcePageURL, "A text row's media URLs are the inert record page, never an image")
        }
        // Images that aren't an object (PHP's empty array), a record page off the museum's site, and a bad ID.
        var odd = Self.cmaRow(6); odd["images"] = [Any]()
        XCTAssertEqual(CMAParsing.reference(from: odd)?.cmaKind, .metadataOnly)
        var offsite = Self.cmaRow(6); offsite["url"] = "https://evil.example/art/6"
        XCTAssertNil(CMAParsing.reference(from: offsite)); offsite["url"] = "http://clevelandart.org/art/6"; XCTAssertNil(CMAParsing.reference(from: offsite))
        var badID = Self.cmaRow(6); badID["id"] = "6; DROP"
        XCTAssertNil(CMAParsing.reference(from: badID))
        var foreignMedia = Self.cmaRow(6); foreignMedia["images"] = ["web": ["url": "https://evil.example/a/a_web.jpg", "width": "10", "height": "10"]]
        XCTAssertEqual(CMAParsing.reference(from: foreignMedia)?.cmaKind, .metadataOnly, "A rendition off the CDN is not media")
        // Only a plain creator role with no qualifier is credited as the maker.
        XCTAssertEqual(Self.cmaReference(8, creators: [Self.cmaCreator(qualifier: "attributed to")]).cmaCreditName, "attributed to Katsushika Hokusai")
        XCTAssertEqual(Self.cmaReference(8, creators: [Self.cmaCreator(role: "publisher")]).cmaCreditName, "Unattributed")
        XCTAssertEqual(Self.cmaReference(8, creators: []).cmaCreditName, "Unattributed")
        XCTAssertEqual(Self.cmaReference(9, creators: [Self.cmaCreator(), Self.cmaCreator(999, "Someone Else (French)", role: "publisher")]).cmaCreditName,
                       "Katsushika Hokusai and others")
        XCTAssertEqual(CMADisplay.name(fromDescription: " Foo &amp; Bar (French, 1900) "), "Foo & Bar")
        XCTAssertEqual(CMADisplay.name(fromDescription: "(Japanese)"), "(Japanese)")
        // The pivot is offered only when the record credits an ID plainly.
        XCTAssertEqual(settable.cmaPivot?.id, 23328); XCTAssertEqual(settable.cmaPivot?.name, "Katsushika Hokusai")
        XCTAssertNil(Self.cmaReference(8, creators: [Self.cmaCreator(qualifier: "after")]).cmaPivot)
        XCTAssertNil(Self.cmaReference(8, creators: [Self.cmaCreator(role: "publisher")]).cmaPivot)
        XCTAssertNil(Self.cmaReference(8, creators: [["description": "No ID (Japanese)", "role": "artist", "qualifier": ""]]).cmaPivot)
        XCTAssertNil(openverseReference(1).cmaPivot)
    }

    func testCMASearchUsesDocumentedFiltersAndClassifiesRowsWithoutAnyImageRequest() async throws {
        let network = CMAFakeNetwork()
        let rows: [[String: Any]] = [Self.cmaRow(1), Self.cmaRow(2, printSize: nil), Self.cmaRow(3, license: "Copyrighted", web: nil, printSize: nil),
                                     Self.cmaRow(1), ["id": 4]]
        network.setRoute("search:q", Self.cmaEnvelope(rows, total: 45))
        let page = try await CMAProvider(client: network).search(options: CMASearchOptions(query: "wave"), page: 2)
        XCTAssertEqual(page.wallpapers.map(\.identityKey), ["cma:1", "cma:2", "cma:3"], "A repeated ID and a record with no link aren't rows")
        XCTAssertEqual(page.hiddenCount, 2); XCTAssertEqual(page.currentPage, 2); XCTAssertEqual(page.lastPage, 3); XCTAssertEqual(page.total, 45)
        XCTAssertEqual(page.wallpapers.map(\.cmaKind), [.settable, .thumbnailOnly, .metadataOnly])
        XCTAssertEqual(network.apiEvents, ["api:search:q"]); XCTAssertEqual(network.mediaEvents, [])
        XCTAssertEqual(URLComponents(url: network.urls[0], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "skip" }?.value, "20")
        // An empty page ends pagination whatever the total says; a non-object envelope or an HTTP error is a failure.
        network.setRoute("search:q", Self.cmaEnvelope([], total: 900))
        let empty = try await CMAProvider(client: network).search(options: CMASearchOptions(), page: 4)
        XCTAssertFalse(empty.hasMorePages)
        network.setRoute("search:q", CMAFakeNetwork.Route(body: Data("[]".utf8)))
        do { _ = try await CMAProvider(client: network).search(options: CMASearchOptions(), page: 1); XCTFail("Expected invalid data") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .invalidData) }
        network.setRoute("search:q", CMAFakeNetwork.Route(status: 500))
        do { _ = try await CMAProvider(client: network).search(options: CMASearchOptions(), page: 1); XCTFail("Expected HTTP 500") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .httpStatus(500)) }
        // Overflow-prone or malformed pagination metadata fails the page.
        for total in [Any](arrayLiteral: 99_999_999_999_999, "99999999999999999999", -3, "many", 2.5) {
            let envelope: [String: Any] = ["info": ["total": total], "data": [Self.cmaRow(1)]]
            network.setRoute("search:q", CMAFakeNetwork.Route(body: Self.cmaJSON(envelope)))
            do { _ = try await CMAProvider(client: network).search(options: CMASearchOptions(), page: 1); XCTFail("Total \(total) must be rejected") }
            catch { XCTAssertEqual(error as? RemoteProviderError, .invalidData, "\(total)") }
        }
    }

    // MARK: Creator identity and fanout

    func testCMACreatorWorksIncludeOnlyExactIDPlainRoleAndEmptyQualifierInTwoRequests() async throws {
        let network = Self.cmaCreatorNetwork()
        let page = try await CMAProvider(client: network).creatorWorks(id: 23328)
        XCTAssertEqual(page.name, "Katsushika Hokusai")
        XCTAssertEqual(page.works.map(\.wallpaperID), ["111654", "152506", "152507", "152508", "900004"])
        XCTAssertEqual(page.works.map(\.cmaKind), [.settable, .settable, .settable, .thumbnailOnly, .metadataOnly])
        XCTAssertEqual(page.excluded, [900001: .qualifiedOrNonPlainRole, 900002: .otherCreator, 900003: .qualifiedOrNonPlainRole, 287051: .otherCreator])
        XCTAssertEqual(page.hiddenCount, 1); XCTAssertEqual(page.matchTotal, 250); XCTAssertEqual(page.returnedCount, 10)
        XCTAssertTrue(page.isTruncated); XCTAssertFalse(page.allOpenAccess, "A copyrighted row is in view, so it isn't all open access")
        XCTAssertEqual(page.stubIDs, [111654, 152506, 900001, 900009], "The creator's stub list is diagnostics only")
        XCTAssertEqual(network.apiEvents, ["api:/api/creators/23328", "api:search:artists"], "One creator detail and one search; no per-row details")
        XCTAssertEqual(network.mediaEvents, [])
        guard page.works.count == 5, network.urls.count == 2 else { return XCTFail("Unexpected creator page: \(page.works.count) works, \(network.urls.count) requests") }
        let search = URLComponents(url: network.urls[1], resolvingAgainstBaseURL: false)
        XCTAssertEqual(value(search, "artists"), "Katsushika Hokusai"); XCTAssertEqual(value(search, "limit"), "100")
        XCTAssertEqual(page.works[0].cmaCreditName, "Katsushika Hokusai")
        XCTAssertEqual(page.works[1].cmaCreditName, "Katsushika Hokusai and others", "Co-contributors are never named as authors")
        XCTAssertEqual(page.works[1].title, "Fuji &amp; Waves"); XCTAssertEqual(page.works[1].displayTitle, "Fuji & Waves")
        // All shown rows open access: the whole view can say so.
        let open = try await CMAProvider(client: Self.cmaCreatorNetwork(allOpen: true)).creatorWorks(id: 23328)
        XCTAssertTrue(open.allOpenAccess)

        // Creator 1313 and derivatives credited "after": nothing is included, though the name matches.
        let derivative = CMAFakeNetwork()
        derivative.setRoute("/api/creators/1313", Self.cmaCreatorDetailRoute(id: 1313, name: "Pieter Bruegel", stubs: [800001, 800002]))
        derivative.setRoute("search:artists", Self.cmaEnvelope([
            Self.cmaRow(800001, creators: [Self.cmaCreator(1313, "Pieter Bruegel (Flemish)", qualifier: "after")]),
            Self.cmaRow(800002, creators: [Self.cmaCreator(1313, "Pieter Bruegel (Flemish)", role: "after")]),
            Self.cmaRow(800003, creators: [Self.cmaCreator(77, "Pieter Bruegel (Flemish)")])]))
        let afterPage = try await CMAProvider(client: derivative).creatorWorks(id: 1313)
        XCTAssertTrue(afterPage.works.isEmpty)
        XCTAssertEqual(afterPage.excluded, [800001: .qualifiedOrNonPlainRole, 800002: .qualifiedOrNonPlainRole, 800003: .otherCreator], "Name text is never identity")
        XCTAssertFalse(afterPage.isTruncated)
    }

    func testCMACreatorFailuresAreReportedAndNeverBroadenTheRequest() async throws {
        // A different creator answering for this ID, an unknown creator, and a throttled or failing search.
        let mismatch = CMAFakeNetwork()
        mismatch.setRoute("/api/creators/23328", Self.cmaCreatorDetailRoute(id: 5))
        do { _ = try await CMAProvider(client: mismatch).creatorWorks(id: 23328); XCTFail("Expected invalid data") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .invalidData) }
        XCTAssertEqual(mismatch.apiEvents, ["api:/api/creators/23328"], "No search after an identity mismatch")

        let missing = CMAFakeNetwork()
        do { _ = try await CMAProvider(client: missing).creatorWorks(id: 23328); XCTFail("Expected 404") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .originalUnavailable) }
        XCTAssertEqual(missing.apiEvents.count, 1)

        let failing = Self.cmaCreatorNetwork()
        failing.setRoute("search:artists", CMAFakeNetwork.Route(status: 500))
        do { _ = try await CMAProvider(client: failing).creatorWorks(id: 23328); XCTFail("Expected HTTP 500") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .httpStatus(500)) }
        XCTAssertEqual(failing.apiEvents.count, 2, "A failed search isn't retried")

        let throttled = Self.cmaCreatorNetwork()
        throttled.setRoute("/api/creators/23328", CMAFakeNetwork.Route(status: 429, headers: ["Retry-After": "120"]))
        let provider = CMAProvider(client: throttled)
        do { _ = try await provider.creatorWorks(id: 23328); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .rateLimited(retryAfter: 120)) }
        do { _ = try await provider.creatorWorks(id: 23328); XCTFail("Expected backoff") } catch {}
        XCTAssertEqual(throttled.apiEvents.count, 1, "A throttle holds further requests back")

        // An API answer that ended off the API host is refused.
        let offHost = Self.cmaCreatorNetwork()
        offHost.setRoute("/api/creators/23328", CMAFakeNetwork.Route(body: Self.cmaCreatorDetailRoute().body, finalURL: URL(string: "https://evil.example/api/creators/23328")))
        do { _ = try await CMAProvider(client: offHost).creatorWorks(id: 23328); XCTFail("Expected untrusted URL") }
        catch { XCTAssertEqual(error as? RemoteProviderError, .untrustedURL) }
    }

    // MARK: Set-time media contract

    func testCMAPrintDownloadChecksEligibilityFirstRefreshesDetailAndValidatesMedia() async throws {
        let reference = Self.cmaReference(152506)
        func attempt(_ configure: (CMAFakeNetwork) -> Void = { _ in }, reference: WallpaperReference? = nil) async -> (Result<URL, Error>, CMAFakeNetwork) {
            let network = Self.cmaDownloadNetwork(); configure(network)
            do { return (.success(try await CMAProvider(client: network).downloadPrint(for: reference ?? Self.cmaReference(152506)).file), network) }
            catch { return (.failure(error), network) }
        }
        func failure(_ result: Result<URL, Error>) -> Error? { if case .failure(let error) = result { return error }; return nil }

        // Success: detail is refreshed before the print is requested; the file is a faithful JPEG.
        let (good, network) = await attempt()
        let file = try good.get()
        XCTAssertEqual(network.events, ["api:/api/artworks/152506", "media:\(reference.originalURL.absoluteString)"])
        XCTAssertTrue(CMAProvider.isFaithfulPrint(at: file, for: reference)); XCTAssertTrue(CMAProvider.startsWithJPEGMarker(file))
        try? FileManager.default.removeItem(at: file)

        // Browse-only and untrusted references are refused before any request at all.
        let metadataOnly = Self.cmaReference(287051, license: "Copyrighted", web: nil, printSize: nil)
        let thumbnailOnly = Self.cmaReference(2, printSize: nil)
        let tampered = WallpaperReference(providerIdentifier: "cma", wallpaperID: "152506", sourcePageURL: reference.sourcePageURL,
                                          originalURL: URL(string: "https://evil.example/1930.152506/1930.152506_print.jpg")!,
                                          previewURL: reference.previewURL, thumbnailURL: reference.thumbnailURL, width: 2000, height: 1250,
                                          uploader: nil, tags: [], cachedLocalPath: nil, title: "Tampered", cma: reference.cma)
        for (name, candidate, expected) in [("metadata-only", metadataOnly, RemoteProviderError.browseOnly), ("thumbnail-only", thumbnailOnly, .browseOnly),
                                            ("tampered original", tampered, .untrustedURL), ("other provider", remoteReference(id: "abc123"), .untrustedURL)] {
            let (result, untouched) = await attempt(reference: candidate)
            XCTAssertEqual(failure(result) as? RemoteProviderError, expected, name)
            XCTAssertEqual(untouched.events, [], "\(name): no API or media request")
        }

        // A refreshed record that no longer qualifies stops before the media request.
        let refreshCases: [(String, (CMAFakeNetwork) -> Void, RemoteProviderError)] = [
            ("no longer CC0", { $0.setRoute("/api/artworks/152506", Self.cmaDetailRoute(Self.cmaRow(152506, license: "Copyrighted"))) }, .notOpenAccess),
            ("print removed", { $0.setRoute("/api/artworks/152506", Self.cmaDetailRoute(Self.cmaRow(152506, printSize: nil))) }, .notOpenAccess),
            ("non-numeric dimensions", { $0.setRoute("/api/artworks/152506", Self.cmaDetailRoute(Self.cmaRow(152506, printSize: ("big", "1250")))) }, .notOpenAccess),
            ("print now too small", { $0.setRoute("/api/artworks/152506", Self.cmaDetailRoute(Self.cmaRow(152506, printSize: ("1800", "1100")))) }, .notOpenAccess),
            ("print now the web size", { $0.setRoute("/api/artworks/152506", Self.cmaDetailRoute(Self.cmaRow(152506, printSize: ("800", "500")))) }, .notOpenAccess),
            ("overflowing dimensions", { $0.setRoute("/api/artworks/152506", Self.cmaDetailRoute(Self.cmaRow(152506, printSize: ("99999999999999999999", "1250")))) }, .notOpenAccess),
            ("detail for another work", { $0.setRoute("/api/artworks/152506", Self.cmaDetailRoute(Self.cmaRow(152507))) }, .invalidData),
            ("detail gone", { $0.setRoute("/api/artworks/152506", CMAFakeNetwork.Route(status: 404)) }, .originalUnavailable)
        ]
        for (name, configure, expected) in refreshCases {
            let (result, refreshed) = await attempt(configure)
            XCTAssertEqual(failure(result) as? RemoteProviderError, expected, name)
            XCTAssertEqual(refreshed.mediaEvents, [], "\(name): the print is never requested")
        }

        // Bytes and pixels are checked before anything is kept.
        let mediaCases: [(String, (CMAFakeNetwork) -> Void, RemoteProviderError)] = [
            ("png content type", { $0.media.headers["Content-Type"] = "image/png" }, .mediaRejected),
            ("html content type", { $0.media.headers["Content-Type"] = "text/html" }, .mediaRejected),
            ("png bytes labelled jpeg", { $0.media.body = Self.imageData(width: 2000, height: 1250) }, .mediaRejected),
            ("wrong pixel size", { $0.media.body = Self.imageData(width: 2100, height: 1250, type: "public.jpeg") }, .mediaRejected),
            ("final path is another item", { $0.media.finalURL = URL(string: "https://openaccess-cdn.clevelandart.org/1930.1/1930.1_print.jpg") }, .untrustedURL),
            ("final path has a query", { $0.media.finalURL = URL(string: "https://openaccess-cdn.clevelandart.org/1930.152506/1930.152506_print.jpg?x=1") }, .untrustedURL),
            ("larger than the reported size allows", { $0.setRoute("/api/artworks/152506", Self.cmaDetailRoute(Self.cmaRow(152506, printFilesize: "100"))) }, .mediaRejected),
            ("oversized stream", { $0.streamedBytes = CMAURLPolicy.maximumDownloadBytes + 1 }, .originalTooLarge),
            ("off-host final URL", { $0.media.finalURL = URL(string: "https://evil.example/1930.152506/1930.152506_print.jpg") }, .untrustedURL),
            ("http downgrade", { $0.media.finalURL = URL(string: "http://openaccess-cdn.clevelandart.org/1930.152506/1930.152506_print.jpg") }, .untrustedURL),
            ("refused redirect", { $0.media.status = 302 }, .untrustedURL),
            ("gone", { $0.media.status = 404 }, .originalUnavailable),
            ("server error", { $0.media.status = 500 }, .httpStatus(500))
        ]
        for (name, configure, expected) in mediaCases {
            let (result, failed) = await attempt(configure)
            XCTAssertEqual(failure(result) as? RemoteProviderError, expected, name)
            XCTAssertEqual(failed.apiEvents, ["api:/api/artworks/152506"], "\(name): detail refreshed once")
            XCTAssertFalse(failed.temporaries.contains { FileManager.default.fileExists(atPath: $0.path) }, "\(name): temporary file removed")
        }
    }

    func testCMAPixelRulesRejectSubstitutedThumbnailsAndExcessiveSizes() {
        let tolerance = CMAURLPolicy.dimensionTolerance
        XCTAssertEqual(tolerance, 2)
        XCTAssertTrue(CMAProvider.acceptsDimensions(decoded: (3400, 2329), reported: (3400, 2329), web: (900, 617)))
        XCTAssertTrue(CMAProvider.acceptsDimensions(decoded: (3402, 2327), reported: (3400, 2329), web: nil), "±2 px")
        XCTAssertFalse(CMAProvider.acceptsDimensions(decoded: (3403, 2329), reported: (3400, 2329), web: nil))
        XCTAssertFalse(CMAProvider.acceptsDimensions(decoded: (900, 617), reported: (900, 617), web: (900, 617)), "The web thumbnail is not a print")
        XCTAssertFalse(CMAProvider.acceptsDimensions(decoded: (2000, 1250), reported: (2000, 1250), web: (2001, 1249)), "A print the size of its thumbnail")
        XCTAssertFalse(CMAProvider.acceptsDimensions(decoded: (1919, 1000), reported: (1919, 1000), web: nil), "Long edge under 1920")
        XCTAssertTrue(CMAProvider.acceptsDimensions(decoded: (1920, 1000), reported: (1920, 1000), web: nil))
        XCTAssertTrue(CMAProvider.acceptsDimensions(decoded: (10_000, 8_000), reported: (10_000, 8_000), web: nil), "Exactly 80 MP")
        XCTAssertFalse(CMAProvider.acceptsDimensions(decoded: (10_000, 8_001), reported: (10_000, 8_001), web: nil), "Over 80 MP")
        XCTAssertFalse(CMAProvider.acceptsDimensions(decoded: (0, 0), reported: (0, 0), web: nil))
        XCTAssertEqual(CMAURLPolicy.maximumDownloadBytes, 40 * 1_024 * 1_024)
    }

    /// Every scenario here ends: a finite body and EOF, or a stop by the downloader. A hung fake fails the test after ten seconds
    /// instead of blocking the run. Redirect refusal is asserted deterministically through `CMAURLPolicy` above.
    func testCMABoundedDownloaderStopsOversizedStreamsAtTheCapAndCleansUp() async throws {
        func downloader(_ url: URL, cap: Int64 = 3 * 1_048_576) -> BoundedDownloader {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CMAStreamProtocol.self]
            return BoundedDownloader(request: URLRequest(url: url), maximumBytes: cap, maximumRedirects: CMAURLPolicy.maximumRedirects,
                                     allowsRedirect: { from, to in to.host == from.host && to.scheme == "https" }, configuration: configuration)
        }
        func run(_ downloader: BoundedDownloader) async -> Result<(URL, HTTPURLResponse), Error> {
            let task = Task<Result<(URL, HTTPURLResponse), Error>, Never> {
                do { return .success(try await downloader.run()) } catch { return .failure(error) }
            }
            let watchdog = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); task.cancel() }
            let result = await task.value
            watchdog.cancel()
            return result
        }
        func partFiles() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
                .filter { $0.hasPrefix("wallpier-download-") }.count
        }
        let print = URL(string: "https://openaccess-cdn.clevelandart.org/1930.189/1930.189_print.jpg")!
        defer { CMAStreamProtocol.reset() }

        // A body within the cap streams to a file.
        CMAStreamProtocol.reset()
        CMAStreamProtocol.script = { proto in
            proto.respond(status: 200, headers: ["Content-Type": "image/jpeg"])
            for _ in 0..<3 { proto.send(Data(repeating: 7, count: 1_000)) }
            proto.finish()
        }
        guard case .success(let (file, response)) = await run(downloader(print)) else { return XCTFail("A body within the cap must complete") }
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue, 3_000)
        try? FileManager.default.removeItem(at: file)

        // A long stream is cut off at the cap and leaves nothing behind (it would otherwise end after 12 MB).
        let before = partFiles()
        CMAStreamProtocol.reset()
        CMAStreamProtocol.script = { proto in
            proto.respond(status: 200, headers: ["Content-Type": "image/jpeg"])
            DispatchQueue.global().async {
                for _ in 0..<12 where !proto.stopped { proto.send(Data(repeating: 1, count: 1_048_576)); Thread.sleep(forTimeInterval: 0.02) }
                if !proto.stopped { proto.finish() }
            }
        }
        if case .failure(let error) = await run(downloader(print)) { XCTAssertEqual(error as? RemoteProviderError, .originalTooLarge) }
        else { XCTFail("The cap must stop the transfer") }
        XCTAssertLessThan(CMAStreamProtocol.chunksSent, 12, "The stream was stopped, not drained")
        XCTAssertEqual(partFiles(), before, "The partial file is removed")

        // A declared length over the cap is refused, with a finite body and EOF behind it.
        CMAStreamProtocol.reset()
        CMAStreamProtocol.script = { proto in
            proto.respond(status: 200, headers: ["Content-Type": "image/jpeg", "Content-Length": "999999999"])
            proto.send(Data(repeating: 2, count: 100)); proto.finish()
        }
        if case .failure(let error) = await run(downloader(print)) { XCTAssertEqual(error as? RemoteProviderError, .originalTooLarge) }
        else { XCTFail("A declared oversize must stop") }
        XCTAssertEqual(partFiles(), before)
    }

    // MARK: Persistence and thumbnails

    func testCMAReferencesPersistInMixedFavoritesAndCollectionsAndThumbnailsAreCheckedAfterPersistence() throws {
        let root = try historyTestFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let museum = Self.cmaReference(111654, title: "The Great Wave &amp; More")
        let openverse = openverseReference(3)
        let wallhaven = remoteReference(id: "wh0001")
        var state = WallpaperState()
        state.favorites = [wallhaven, museum, openverse]
        state.collections = [WallpaperCollection(name: "Mixed", wallpapers: [openverse, museum, wallhaven])]
        state.cmaSearch.query = "wave"; state.discoverProvider = .cma
        let store = WallpaperStateStore(stateURL: root.appendingPathComponent("state.json"))
        XCTAssertTrue(store.save(state))
        let loaded = store.load()
        XCTAssertEqual(loaded.favorites, state.favorites); XCTAssertEqual(loaded.collections.first?.wallpapers, [openverse, museum, wallhaven])
        XCTAssertEqual(loaded.favorites.map(\.provider), [.wallhaven, .cma, .openverse])
        XCTAssertEqual(loaded.discoverProvider, .cma); XCTAssertEqual(loaded.cmaSearch.query, "wave")
        let reloaded = try XCTUnwrap(loaded.favorites.dropFirst().first)
        XCTAssertEqual(reloaded.cma, museum.cma); XCTAssertEqual(reloaded.cmaKind, .settable)
        XCTAssertEqual(reloaded.title, "The Great Wave &amp; More"); XCTAssertEqual(reloaded.displayTitle, "The Great Wave & More")
        XCTAssertEqual(reloaded.cmaProvenance, "Katsushika Hokusai · Cleveland Museum of Art · CC0")
        XCTAssertEqual(reloaded.cmaPageURL?.absoluteString, "https://clevelandart.org/art/1930.111654")
        // State saved before the museum source existed still loads.
        let legacy = try JSONDecoder().decode(WallpaperState.self, from: Data(#"{"discoverProvider":"museum-of-nothing"}"#.utf8))
        XCTAssertEqual(legacy.discoverProvider, .wallhaven); XCTAssertEqual(legacy.cmaSearch, CMASearchOptions())

        // A saved reference whose media addresses were edited fails closed: no thumbnail, no Set, no media request.
        func tampered(thumbnail: String, original: String) -> WallpaperReference {
            WallpaperReference(providerIdentifier: "cma", wallpaperID: "111654", sourcePageURL: museum.sourcePageURL,
                               originalURL: URL(string: original)!, previewURL: URL(string: thumbnail)!, thumbnailURL: URL(string: thumbnail)!,
                               width: 2000, height: 1250, uploader: nil, tags: [], cachedLocalPath: nil, title: "T", cma: museum.cma)
        }
        for bad in [tampered(thumbnail: "http://openaccess-cdn.clevelandart.org/1930.1/1930.1_web.jpg", original: museum.originalURL.absoluteString),
                    tampered(thumbnail: "https://evil.example/1930.1/1930.1_web.jpg", original: museum.originalURL.absoluteString),
                    tampered(thumbnail: museum.thumbnailURL.absoluteString, original: "https://evil.example/1930.1/1930.1_print.jpg")] {
            XCTAssertEqual(bad.useRestriction, .untrustedURL)
            if bad.thumbnailURL.host?.contains("evil") == true || bad.thumbnailURL.scheme == "http" { XCTAssertNil(bad.galleryThumbnailURL(large: true)) }
        }
        var edited = museum.cma!; edited.hasPrint = false
        let downgraded = WallpaperReference(providerIdentifier: "cma", wallpaperID: "1", sourcePageURL: museum.sourcePageURL, originalURL: museum.originalURL,
                                            previewURL: museum.thumbnailURL, thumbnailURL: museum.thumbnailURL, width: 1, height: 1,
                                            uploader: nil, tags: [], cachedLocalPath: nil, cma: edited)
        XCTAssertEqual(downgraded.useRestriction, .browseOnly)
        // A saved reference with no museum record at all is metadata-only: it never reaches an image request.
        let bare = WallpaperReference(providerIdentifier: "cma", wallpaperID: "1", sourcePageURL: museum.sourcePageURL, originalURL: museum.originalURL,
                                      previewURL: museum.thumbnailURL, thumbnailURL: museum.thumbnailURL, width: 1, height: 1, uploader: nil, tags: [], cachedLocalPath: nil)
        XCTAssertNil(bare.galleryThumbnailURL(large: true)); XCTAssertTrue(bare.blocksUse)

        // The thumbnail provider re-checks the requested and final URL and the content type.
        let requested = museum.thumbnailURL
        func response(_ url: URL, status: Int = 200, type: String? = "image/jpeg") -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: type.map { ["Content-Type": $0] })!
        }
        XCTAssertTrue(RemoteThumbnailProvider.accepts(response(requested), for: requested, byteCount: 1_000))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(response(requested, type: "text/html"), for: requested, byteCount: 1_000))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(response(requested, type: nil), for: requested, byteCount: 1_000))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(response(URL(string: "https://evil.example/a_web.jpg")!), for: requested, byteCount: 1_000))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(response(URL(string: "http://openaccess-cdn.clevelandart.org/1930.111654/1930.111654_web.jpg")!), for: requested, byteCount: 1_000))
        XCTAssertFalse(RemoteThumbnailProvider.accepts(response(requested, status: 404), for: requested, byteCount: 1_000))
        for invalid in ["https://clevelandart.org/art/1930.1", "http://openaccess-cdn.clevelandart.org/1930.1/1930.1_web.jpg", "https://www.clevelandart.org/x.jpg"] {
            var called = false; var image: NSImage? = NSImage()
            RemoteThumbnailProvider().requestThumbnail(for: URL(string: invalid)!) { image = $0; called = true }
            XCTAssertTrue(called, invalid); XCTAssertNil(image, "\(invalid) is never requested")
        }
    }

    // MARK: Native controller

    @MainActor
    func testCMAEncounterPivotBrowseOnlyRowsPreviewSetUndoFavoriteAndRelaunch() async throws {
        let network = Self.cmaCreatorNetwork()
        let desktop = SetAuditWallpaperService()
        let thumbnails = RecordingThumbnails()
        let (c, _, root, anchor) = try cmaController(network, desktop: desktop, thumbnails: thumbnails)
        let prior = root.appendingPathComponent("prior.png")
        try writeTestImage(to: prior); desktop.current = prior

        // Encounter: the anchor credits one creator plainly, so the pivot is offered, and browsing cost no request.
        XCTAssertEqual(c.selectedIdentityForTesting, anchor.identityKey)
        XCTAssertFalse(c.moreByButton.isHidden); XCTAssertEqual(c.moreByButton.title, "More by Katsushika Hokusai")
        XCTAssertEqual(network.events, [])
        c.moreByButton.performClick(nil)
        var reached = await eventually { c.visibleItemIdentitiesForTesting.count == 4 }
        guard reached else { return XCTFail("The creator view showed \(c.visibleItemIdentitiesForTesting) (\(c.emptyStateView.title))") }
        XCTAssertEqual(c.visibleItemIdentitiesForTesting, ["cma:152506", "cma:152507", "cma:152508", "cma:900004"], "Excluded rows are never shown; the anchor is the one left behind")
        XCTAssertEqual(network.apiEvents, ["api:/api/creators/23328", "api:search:artists"])
        XCTAssertEqual(c.creatorTitleLabel.stringValue, "Katsushika Hokusai"); XCTAssertEqual(c.window?.title, "Cleveland Museum of Art", "The toolbar names the source; the header names the creator")
        XCTAssertEqual(c.creatorSubtitleLabel.stringValue, "Works at Cleveland Museum of Art", "A copyrighted record is in view, so it isn't called open access")
        XCTAssertFalse(c.creatorBar.isHidden); XCTAssertTrue(c.moreByButton.isHidden, "One level only")
        XCTAssertEqual(c.creatorStatusLabel.stringValue, "Showing 4 works from the first 10 of 250 matches")
        XCTAssertFalse(c.creatorLinkButton.isHidden)

        // Thumbnail-only and metadata-only rows: shown and linkable, never previewed, set, favorited or requested.
        selectCMAItem(2, in: c)
        XCTAssertFalse(c.setWallpaperButton.isEnabled); XCTAssertTrue(c.favoriteButton.isHidden); XCTAssertFalse(c.viewOnMuseumButton.isHidden)
        c.toggleFavorite(nil); XCTAssertEqual(c.state.favorites.map(\.identityKey), [anchor.identityKey])
        c.toggleViewer(nil); XCTAssertFalse(c.isViewerVisible)
        c.setWallpaper(nil); XCTAssertNil(c.downloadTask)
        let badge = c.collectionView(c.collectionView, itemForRepresentedObjectAt: IndexPath(item: 2, section: 0)) as? WallpaperCollectionViewItem
        XCTAssertEqual(badge?.captionText, "No high-resolution JPEG")
        selectCMAItem(3, in: c)
        XCTAssertFalse(c.setWallpaperButton.isEnabled); XCTAssertFalse(c.viewOnMuseumButton.isHidden)
        c.toggleViewer(nil); XCTAssertFalse(c.isViewerVisible)
        let textRow = c.collectionView(c.collectionView, itemForRepresentedObjectAt: IndexPath(item: 3, section: 0)) as? WallpaperCollectionViewItem
        XCTAssertEqual(textRow?.captionText, "Plain Copyrighted\nabout 1831\nKatsushika Hokusai\nView on Cleveland Museum of Art ↗")
        XCTAssertFalse(thumbnails.requested.contains { $0.absoluteString.contains("900004") }, "A text row never asks for an image")
        XCTAssertEqual(network.mediaEvents, [])
        XCTAssertTrue(network.urls.allSatisfy { $0.host == "openaccess-api.clevelandart.org" })

        // A settable work: preview downloads nothing; the credit and the museum link are shown.
        selectCMAItem(0, in: c)
        XCTAssertTrue(c.setWallpaperButton.isEnabled); XCTAssertFalse(c.favoriteButton.isHidden)
        c.toggleViewer(nil); XCTAssertTrue(c.isViewerVisible)
        reached = await eventually { c.stageView.image != nil }
        XCTAssertTrue(reached)
        XCTAssertEqual(c.previewTitleLabel.stringValue, "Fuji & Waves")
        XCTAssertEqual(c.previewAttributionLabel.attributedStringValue.string, "Katsushika Hokusai and others · Cleveland Museum of Art · CC0")
        XCTAssertEqual(network.mediaEvents, [])
        c.toggleViewer(nil)

        // Set on the selected display: detail refreshed, then the print; a retained JPEG, not a cache file.
        c.setWallpaper(nil)
        XCTAssertEqual(c.statusLabel.stringValue, "Downloading high-resolution museum JPEG…")
        try await finishAuditTask(c.downloadTask)
        let events = network.events
        guard desktop.calls.count == 1 else { return XCTFail("Set did not reach the desktop: \(c.statusLabel.stringValue)") }
        XCTAssertEqual(Array(events.suffix(2)), ["api:/api/artworks/152506", "media:https://openaccess-cdn.clevelandart.org/1930.152506/1930.152506_print.jpg"])
        XCTAssertEqual(desktop.calls.count, 1)
        let applied = try XCTUnwrap(desktop.calls.first?.image)
        XCTAssertTrue(applied.path.hasPrefix(root.appendingPathComponent("Rollback").path), "The desktop references an owned copy")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(applied as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2000); XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1250)
        XCTAssertTrue(CMAProvider.startsWithJPEGMarker(applied))
        XCTAssertEqual(c.statusLabel.stringValue, "Set on Studio Display · High-resolution museum JPEG (CC0)")
        XCTAssertFalse(c.statusUndoButton.isHidden)

        // Undo restores the prior wallpaper.
        c.undoWallpaperChange(nil)
        try await finishAuditTask(c.downloadTask)
        let restored = try XCTUnwrap(desktop.calls.last?.image)
        XCTAssertEqual(try Data(contentsOf: restored), try Data(contentsOf: prior))
        XCTAssertTrue(c.state.history.isEmpty)

        // Favorite it; Favorites now mix providers and survive a relaunch with credit and link intact.
        selectCMAItem(0, in: c)
        c.toggleFavorite(nil)
        XCTAssertEqual(c.state.favorites.map(\.identityKey), [anchor.identityKey, "cma:152506"])
        let store = WallpaperStateStore(stateURL: root.appendingPathComponent("state.json"))
        let saved = store.load()
        XCTAssertEqual(saved.favorites.map(\.identityKey), [anchor.identityKey, "cma:152506"])
        XCTAssertNotNil(saved.favorites.last?.cachedLocalPath)
        c.closeCreator(nil)

        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1120, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { await MainActor.run { window.close() } }
        let relaunched = MainWindowController(
            window: window, wallpaperService: SetAuditWallpaperService(), stateStore: store,
            provider: WallhavenProvider(client: OfflineNetwork()), openverseProvider: OpenverseProvider(client: OfflineNetwork()),
            cmaProvider: CMAProvider(client: OfflineNetwork()), originalCache: RemoteWallpaperCache(rootURL: root.appendingPathComponent("Originals")),
            historyStore: WallpaperHistoryStore(root: root.appendingPathComponent("Rollback")), remoteThumbnailProvider: RecordingThumbnails(),
            availableScreens: { [CaptureScreen()] })
        relaunched.prepareForVisualCapture(discoverPage: RemoteSearchPage(wallpapers: [], currentPage: 1, lastPage: 1, total: 0,
                                                                          rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil)))
        relaunched.showFavorites(nil)
        XCTAssertEqual(relaunched.visibleItemIdentitiesForTesting, [anchor.identityKey, "cma:152506"])
        selectCMAItem(1, in: relaunched)
        let attribution = relaunched.previewAttributionLabel.attributedStringValue
        XCTAssertEqual(attribution.string, "Katsushika Hokusai and others · Cleveland Museum of Art · CC0")
        let linkAt = (attribution.string as NSString).range(of: "Cleveland").location
        guard linkAt != NSNotFound else { return XCTFail("No museum credit in “\(attribution.string)”") }
        XCTAssertEqual(attribution.attribute(.link, at: linkAt, effectiveRange: nil) as? URL, URL(string: "https://clevelandart.org/art/1930.152506"))
        XCTAssertFalse(relaunched.moreByButton.isHidden, "The creator can be reopened from a saved favorite")
        relaunched.window?.close()
    }

    @MainActor
    func testCMACreatorViewBackEscSourceSwitchAndRepeatedReopenNeverRepeatRequests() async throws {
        let network = Self.cmaCreatorNetwork(allOpen: true)
        network.setRoute("search:q", Self.cmaEnvelope([Self.cmaRow(111654, title: "The Great Wave"), Self.cmaRow(152509, title: "Another")], total: 2))
        let (c, window, _, anchor) = try cmaController(network)
        func escape() throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        }
        c.showCMA(nil)
        var reached = await eventually { c.visibleItemIdentitiesForTesting == ["cma:111654", "cma:152509"] }
        guard reached else { return XCTFail("Discover showed \(c.visibleItemIdentitiesForTesting) (\(c.emptyStateView.title))") }
        XCTAssertEqual(c.state.discoverProvider, .cma); XCTAssertEqual(c.sidebarForTesting.selectedItem, .cma)
        XCTAssertEqual(c.searchField.placeholderString, "Search Cleveland Museum of Art")
        XCTAssertFalse(c.cmaNoticeLabel.isHidden); XCTAssertTrue(c.categoryPopUp.isHidden); XCTAssertTrue(c.openverseLicensePopUp.isHidden)
        XCTAssertEqual(c.selectedIdentityForTesting, anchor.identityKey)
        let parentScroll = c.galleryScrollForTesting.contentView.bounds.origin.y

        // Open the creator; the header is the creator's, and every row is open access.
        c.moreByButton.performClick(nil)
        reached = await eventually { c.visibleItemIdentitiesForTesting.count == 4 }
        XCTAssertTrue(reached)
        XCTAssertEqual(c.creatorSubtitleLabel.stringValue, "Cleveland Museum of Art · Open-access works")
        XCTAssertEqual(c.window?.subtitle, "Open-access works")
        func creatorRequests() -> Int { network.apiEvents.filter { $0.contains("creators") || $0.contains("artists") }.count }
        XCTAssertEqual(creatorRequests(), 2)

        // Esc in the preview closes the preview first; Esc in the gallery then goes back, to the starting tile.
        selectCMAItem(1, in: c)
        c.toggleViewer(nil); XCTAssertTrue(c.isViewerVisible)
        c.viewerView.keyDown(with: try escape())
        XCTAssertFalse(c.isViewerVisible); XCTAssertTrue(c.isShowingCreatorViewForTesting)
        window.makeFirstResponder(c.collectionView)
        c.collectionView.keyDown(with: try escape())
        XCTAssertFalse(c.isShowingCreatorViewForTesting)
        XCTAssertEqual(c.visibleItemIdentitiesForTesting, ["cma:111654", "cma:152509"])
        XCTAssertEqual(c.selectedIdentityForTesting, anchor.identityKey)
        XCTAssertTrue(window.firstResponder === c.collectionView)
        XCTAssertEqual(c.galleryScrollForTesting.contentView.bounds.origin.y, parentScroll)
        XCTAssertEqual(c.window?.title, "Discover"); XCTAssertTrue(c.creatorBar.isHidden)
        c.collectionView.keyDown(with: try escape())
        XCTAssertFalse(c.isShowingCreatorViewForTesting, "Esc with nothing to leave does nothing")

        // Reopening the same creator reuses what's in memory: no request, and rows at once.
        c.moreByButton.performClick(nil)
        XCTAssertEqual(c.visibleItemIdentitiesForTesting.count, 4)
        XCTAssertEqual(creatorRequests(), 2); XCTAssertEqual(c.creatorCacheKeysForTesting, ["cma:23328"])
        selectCMAItem(2, in: c)
        // Source switching parks the creator view with its source, and returning restores it as it was.
        c.showOpenverse(nil)
        XCTAssertFalse(c.isShowingCreatorViewForTesting); XCTAssertEqual(c.parkedCreatorCountForTesting, 1)
        XCTAssertEqual(c.state.discoverProvider, .openverse)
        c.showCMA(nil)
        XCTAssertTrue(c.isShowingCreatorViewForTesting); XCTAssertEqual(c.parkedCreatorCountForTesting, 0)
        XCTAssertEqual(c.visibleItemIdentitiesForTesting.count, 4)
        XCTAssertEqual(c.selectedIdentityForTesting, "cma:152508")
        XCTAssertEqual(creatorRequests(), 2)
        XCTAssertEqual(network.apiEvents.filter { $0 == "api:search:q" }.count, 1, "The CMA results were parked, not searched again")

        // The ← Gallery button goes back like Esc; a new search drops the creator view.
        c.creatorBackButton.performClick(nil)
        XCTAssertFalse(c.isShowingCreatorViewForTesting)
        XCTAssertEqual(c.visibleItemIdentitiesForTesting, ["cma:111654", "cma:152509"]); XCTAssertEqual(c.selectedIdentityForTesting, anchor.identityKey)
        c.moreByButton.performClick(nil)
        XCTAssertTrue(c.isShowingCreatorViewForTesting)
        c.search(nil)
        XCTAssertFalse(c.isShowingCreatorViewForTesting); XCTAssertEqual(c.parkedCreatorCountForTesting, 0)
        reached = await eventually { network.apiEvents.filter { $0 == "api:search:q" }.count == 2 }
        XCTAssertTrue(reached)
    }

    @MainActor
    func testCMACreatorFailureOffersRetryThatClearsTheCachedEntry() async throws {
        let network = Self.cmaCreatorNetwork(allOpen: true)
        network.setRoute("/api/creators/23328", CMAFakeNetwork.Route(status: 500))
        let (c, _, _, _) = try cmaController(network)
        c.moreByButton.performClick(nil)
        let failed = await eventually { c.emptyStateView.title == "Couldn’t load works from Cleveland Museum of Art." }
        XCTAssertTrue(failed, c.emptyStateView.title)
        XCTAssertEqual(c.emptyStateView.actionButton.title, "Retry")
        XCTAssertEqual(c.creatorCacheKeysForTesting, [], "A failure is never cached")
        XCTAssertTrue(c.isShowingCreatorViewForTesting)
        network.setRoute("/api/creators/23328", Self.cmaCreatorDetailRoute())
        c.emptyStateView.actionButton.performClick(nil)
        let loaded = await eventually { c.visibleItemIdentitiesForTesting.count == 4 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(network.apiEvents, ["api:/api/creators/23328", "api:/api/creators/23328", "api:search:artists"])
        XCTAssertEqual(c.creatorCacheKeysForTesting, ["cma:23328"])
        // Retry clears the entry: after a second failure-free open there is exactly one more fetch only on Retry.
        c.creatorBackButton.performClick(nil)
        c.moreByButton.performClick(nil)
        XCTAssertEqual(network.apiEvents.count, 3)

        // A creator with nothing else to show says so.
        let lonely = CMAFakeNetwork()
        lonely.setRoute("/api/creators/23328", Self.cmaCreatorDetailRoute())
        lonely.setRoute("search:artists", Self.cmaEnvelope([Self.cmaRow(111654)]))
        let (alone, _, _, _) = try cmaController(lonely)
        alone.moreByButton.performClick(nil)
        let empty = await eventually { alone.emptyStateView.title == "No other open-access works available in Cleveland Museum of Art." }
        XCTAssertTrue(empty, alone.emptyStateView.title)
        XCTAssertEqual(alone.visibleItemIdentitiesForTesting, [])
        alone.creatorBackButton.performClick(nil)
        XCTAssertEqual(alone.selectedIdentityForTesting, "cma:111654")
    }

    @MainActor
    func testBracketShortcutsStillBindPreviousAndNextWallpaperAndNewMuseumCommandsAddNoShortcuts() throws {
        let network = CMAFakeNetwork()
        let (c, _, _, _) = try cmaController(network)
        let saved = NSApp.mainMenu
        defer { NSApp.mainMenu = saved }
        AppDelegate().configureMainMenu(for: c)
        let wallpaper = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Wallpaper")?.submenu)
        let previous = try XCTUnwrap(wallpaper.item(withTitle: "Previous Wallpaper")), next = try XCTUnwrap(wallpaper.item(withTitle: "Next Wallpaper"))
        XCTAssertEqual(previous.keyEquivalent, "["); XCTAssertEqual(previous.keyEquivalentModifierMask, .command)
        XCTAssertEqual(previous.action, #selector(MainWindowController.previousWallpaper(_:)))
        XCTAssertEqual(next.keyEquivalent, "]"); XCTAssertEqual(next.keyEquivalentModifierMask, .command)
        XCTAssertEqual(next.action, #selector(MainWindowController.nextWallpaper(_:)))
        let creator = try XCTUnwrap(wallpaper.item(withTitle: "More by Creator"))
        XCTAssertEqual(creator.keyEquivalent, ""); XCTAssertEqual(creator.action, #selector(MainWindowController.showCreator(_:)))
        let view = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "View")?.submenu)
        let sources = try XCTUnwrap(view.item(withTitle: "Discover Sources")?.submenu)
        XCTAssertEqual(sources.items.filter { $0.action != nil }.count, 9, "All nine sources are listed")
        let museum = try XCTUnwrap(sources.item(withTitle: "Cleveland Museum of Art"))
        XCTAssertEqual(museum.keyEquivalent, ""); XCTAssertEqual(museum.action, #selector(MainWindowController.showCMA(_:)))
        // The pivot's title follows the selection; it is enabled only when there is something to open.
        XCTAssertTrue(c.validateMenuItem(creator)); XCTAssertEqual(creator.title, "More by Katsushika Hokusai")
        c.moreByButton.performClick(nil)
        XCTAssertFalse(c.validateMenuItem(creator), "One level only")
        XCTAssertTrue(c.validateMenuItem(museum)); XCTAssertEqual(museum.state, .off)
    }

    // MARK: Live walk (opt-in)

    static var liveDirectory: URL? {
        let environment = ProcessInfo.processInfo.environment
        return (environment["WALLPIER_LIVE_TEST_DIR"] ?? environment["TEST_RUNNER_WALLPIER_LIVE_TEST_DIR"]).map { URL(fileURLWithPath: $0) }
    }

    /// Skipped unless `WALLPIER_LIVE_TEST_DIR` (or `TEST_RUNNER_WALLPIER_LIVE_TEST_DIR`) names an evidence folder. Binds the real
    /// museum provider and real thumbnails to the actual controller, with other providers offline, temporary stores and the
    /// recording wallpaper service; nothing touches the real desktop. Hokusai 111654 → creator 23328 → another real work:
    /// preview, Set, inspect the retained JPEG, Undo, Favorite, relaunch and reopen. Screenshots go to WALLPIER_CAPTURE_DIR if set.
    @MainActor
    func testLiveClevelandArtistDiscoveryWalk() async throws {
        try XCTSkipIf(Self.liveDirectory == nil, "Set WALLPIER_LIVE_TEST_DIR to run the live museum walk")
        let evidenceDirectory = try XCTUnwrap(Self.liveDirectory)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        var evidence: [String] = ["Wallpier live Cleveland Museum of Art walk · \(Date())"]
        func note(_ line: String) { evidence.append(line) }
        defer { try? evidence.joined(separator: "\n").appending("\n").write(to: evidenceDirectory.appendingPathComponent("evidence.txt"), atomically: true, encoding: .utf8) }
        func wait(_ task: Task<Void, Never>?, seconds: TimeInterval) async {
            guard let task else { return }
            let done = expectation(description: "task finished")
            Task { await task.value; done.fulfill() }
            await fulfillment(of: [done], timeout: seconds)
        }

        // Isolation: memory-only HTTP caches apart from the app's, memory-only thumbnails, a private defaults suite,
        // temporary state/cache/history folders, and the recording wallpaper service. Wallhaven is offline;
        // Cleveland's API and Openverse run live through their own ephemeral sessions.
        let cmaClient = URLSessionNetworkClient.isolated(allowsRedirect: CMAURLPolicy.allowsRedirect)
        let openverseClient = URLSessionNetworkClient.isolated(allowsRedirect: OpenverseURLPolicy.allowsRedirect)
        let provider = CMAProvider(client: cmaClient)
        let suite = "com.parth.Wallpier.live-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let desktop = SetAuditWallpaperService()
        let prior = root.appendingPathComponent("prior.png")
        try writeTestImage(to: prior); desktop.current = prior
        let (controller, window) = makeCaptureController(
            root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua, openverse: openverseClient, cma: cmaClient, desktop: desktop,
            thumbnails: RemoteThumbnailProvider(memoryOnly: true), defaults: defaults) { state in
            state.favorites = []; state.collections = []; state.selectedCollectionID = nil; state.currentSource = .favorites
        }
        defer {
            controller.creatorTaskForTesting?.cancel(); controller.searchTask?.cancel()
            controller.detailTask?.cancel(); controller.undoValidationTask?.cancel()
            window.close()
        }

        // A real Discover search for Hokusai, through the controller.
        controller.showCMA(nil)
        controller.searchField.stringValue = "Hokusai"
        controller.search(nil)
        var found = await eventually(60) { controller.visibleItemIdentitiesForTesting.contains("cma:111654") }
        for _ in 0..<3 where !found { controller.loadMoreResults(nil); found = await eventually(60) { controller.visibleItemIdentitiesForTesting.contains("cma:111654") } }
        note("typed search \"Hokusai\": \(controller.visibleItemIdentitiesForTesting.count) rows; notice: \(controller.cmaNoticeLabel.stringValue)")
        guard found else { return XCTFail("Record 111654 was not in the Hokusai search results: \(controller.visibleItemIdentitiesForTesting)") }
        let anchorIndex = try XCTUnwrap(controller.visibleItemIdentitiesForTesting.firstIndex(of: "cma:111654"))
        selectCMAItem(anchorIndex, in: controller)
        let anchor = try XCTUnwrap(controller.selectedReferenceForTesting)
        note("anchor \(anchor.identityKey) title=\"\(anchor.displayTitle)\" credit=\"\(anchor.cmaCreditName)\" kind=\(String(describing: anchor.cmaKind)) pivot=\(String(describing: anchor.cmaPivot?.id)) page=\(anchor.sourcePageURL) provenance=\"\(anchor.cmaProvenance)\"")
        XCTAssertEqual(anchor.cmaPivot?.id, 23328); XCTAssertEqual(anchor.cmaKind, .settable)
        XCTAssertEqual(anchor.cmaCreditName, "Katsushika Hokusai")
        let thumbnailsLoaded = await eventually(30) { (controller.collectionView.item(at: IndexPath(item: anchorIndex, section: 0)) as? WallpaperCollectionViewItem)?.hasThumbnail == true }
        note("real thumbnail drawn in the grid: \(thumbnailsLoaded)")
        XCTAssertTrue(thumbnailsLoaded, "The selected live artwork displays a thumbnail")
        captureWindow(window, named: "cma-01-discover-hokusai")

        controller.moreByButton.performClick(nil)
        let loaded = await eventually(60) { controller.visibleItemIdentitiesForTesting.count >= 3 }
        XCTAssertTrue(loaded, "At least three plain-role works are shown")
        let shown = controller.visibleItemIdentitiesForTesting
        note("creator view: \(controller.creatorTitleLabel.stringValue) · \(controller.creatorSubtitleLabel.stringValue) · \(controller.creatorStatusLabel.stringValue)")
        note("shown (\(shown.count)): \(shown.joined(separator: ", "))")
        captureWindow(window, named: "cma-02-creator")

        // The browse-only report, by artwork ID: what the creator's own list holds that the view doesn't show, and why.
        let page = try await provider.creatorWorks(id: 23328)
        let shownIDs = Set(page.works.compactMap { Int($0.wallpaperID) })
        let browseOnlyShown = page.works.filter(\.isCMABrowseOnly).map { "\($0.wallpaperID):\(String(describing: $0.cmaKind))" }
        note("browse-only rows shown: \(browseOnlyShown.isEmpty ? "none" : browseOnlyShown.joined(separator: ", "))")
        note("thumbnail-only rows found: \(page.works.filter { $0.cmaKind == .thumbnailOnly }.map(\.wallpaperID))")
        for stub in page.stubIDs where !shownIDs.contains(stub) {
            let reason = page.excluded[stub].map { "excluded: \($0.rawValue)" } ?? (page.isTruncated ? "outside the one bounded search page, or not returned by the name search" : "not returned by the name search")
            note("stub \(stub) not shown — \(reason)")
        }
        XCTAssertNotNil(page.excluded[126723], "126723 is credited to the creator only with a qualifier or another ID")
        XCTAssertFalse(shown.contains("cma:126723"), "An excluded record is never shown")
        XCTAssertEqual(page.name, "Katsushika Hokusai"); XCTAssertEqual(page.creatorID, 23328)
        note("excluded in the search page: \(page.excluded.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ", "))")
        note("search matches \(page.matchTotal.map { String($0) } ?? "unknown"), page rows \(page.returnedCount), shown \(page.works.count), hidden unverifiable \(page.hiddenCount)")

        // Another real work: the first settable row in the creator view.
        let ids = controller.visibleItemIdentitiesForTesting
        let index = try XCTUnwrap(ids.firstIndex { id in controller.creatorWorkForTesting(id)?.cmaKind == .settable }, "A settable work by the creator")
        selectCMAItem(index, in: controller)
        let target = try XCTUnwrap(controller.selectedReferenceForTesting)
        note("chosen \(target.identityKey) \"\(target.displayTitle)\" \(target.width)×\(target.height)")
        controller.toggleViewer(nil)
        let drawn = await eventually(30) { controller.stageView.image != nil }
        XCTAssertTrue(drawn, "The real thumbnail reaches the preview")
        captureWindow(window, named: "cma-03-preview")
        controller.toggleViewer(nil)

        controller.setWallpaper(nil)
        await wait(controller.downloadTask, seconds: 180)
        XCTAssertEqual(desktop.calls.count, 1, controller.statusLabel.stringValue)
        let applied = try XCTUnwrap(desktop.calls.first?.image)
        XCTAssertEqual(desktop.calls[0].scaling, .fit, "The recording service captured the scaling mode")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(applied as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: applied.path)[.size] as? NSNumber)?.int64Value ?? 0
        note("set on display \(desktop.calls[0].display): \(applied.lastPathComponent) \(CGImageSourceGetType(source) as String? ?? "?") \(width)×\(height) \(size) bytes SOI=\(CMAProvider.startsWithJPEGMarker(applied))")
        note("status: \(controller.statusLabel.stringValue)")
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg"); XCTAssertGreaterThanOrEqual(max(width, height), 1920)
        XCTAssertTrue(applied.path.hasPrefix(root.appendingPathComponent("Rollback").path))
        captureWindow(window, named: "cma-04-set")

        controller.undoWallpaperChange(nil)
        await wait(controller.downloadTask, seconds: 30)
        let restoredBytes = try? Data(contentsOf: try XCTUnwrap(desktop.calls.last?.image))
        note("undo restored the prior wallpaper: \(restoredBytes == (try? Data(contentsOf: prior)))")
        XCTAssertEqual(restoredBytes, try Data(contentsOf: prior))

        // Source restoration: another source parks the creator view; coming back restores it, without new requests.
        let selectedBefore = controller.selectedIdentityForTesting
        controller.showOpenverse(nil)
        XCTAssertFalse(controller.isShowingCreatorViewForTesting)
        controller.showCMA(nil)
        note("source restored: creator view \(controller.isShowingCreatorViewForTesting), selection \(String(describing: controller.selectedIdentityForTesting)), rows \(controller.visibleItemIdentitiesForTesting.count)")
        XCTAssertTrue(controller.isShowingCreatorViewForTesting); XCTAssertEqual(controller.selectedIdentityForTesting, selectedBefore)

        selectCMAItem(index, in: controller)
        controller.toggleFavorite(nil)
        let store = WallpaperStateStore(stateURL: root.appendingPathComponent("state.json"))
        let saved = store.load()
        note("favorites saved: \(saved.favorites.map(\.identityKey))")
        XCTAssertTrue(saved.favorites.contains { $0.identityKey == target.identityKey })
        controller.closeCreator(nil)
        controller.showFavorites(nil)

        let relaunchWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1120, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                      backing: .buffered, defer: false)
        relaunchWindow.isReleasedWhenClosed = false
        defer { relaunchWindow.close() }
        let relaunched = MainWindowController(
            window: relaunchWindow, wallpaperService: SetAuditWallpaperService(), stateStore: store,
            provider: WallhavenProvider(client: OfflineNetwork()), openverseProvider: OpenverseProvider(client: OfflineNetwork()),
            cmaProvider: provider, originalCache: RemoteWallpaperCache(rootURL: root.appendingPathComponent("Originals")),
            historyStore: WallpaperHistoryStore(root: root.appendingPathComponent("Rollback")), remoteThumbnailProvider: RemoteThumbnailProvider(memoryOnly: true),
            availableScreens: { [CaptureScreen()] }, defaults: defaults)
        relaunched.prepareForVisualCapture(discoverPage: RemoteSearchPage(wallpapers: [], currentPage: 1, lastPage: 1, total: 0,
                                                                          rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil)))
        relaunched.showFavorites(nil)
        let favoriteIndex = try XCTUnwrap(relaunched.visibleItemIdentitiesForTesting.firstIndex(of: target.identityKey))
        selectCMAItem(favoriteIndex, in: relaunched)
        let attribution = relaunched.previewAttributionLabel.attributedStringValue
        let linkAt = (attribution.string as NSString).range(of: "Cleveland").location
        guard linkAt != NSNotFound else { return XCTFail("No museum credit after relaunch: “\(attribution.string)”") }
        let link = attribution.attribute(.link, at: linkAt, effectiveRange: nil) as? URL
        note("after relaunch: \"\(attribution.string)\" link=\(String(describing: link))")
        XCTAssertEqual(link, target.sourcePageURL)
        XCTAssertTrue(attribution.string.contains("Cleveland Museum of Art"))
        captureWindow(relaunchWindow, named: "cma-05-relaunch")

        // A live browse-only report: Kara Walker's copyrighted record straight from the production API.
        // What the museum's own rights state allows is exactly one action — viewing it there — so the row
        // is text only: no thumbnail URL, no preview, no Set, no Favorite, no service write, no invented license.
        let serviceWritesBefore = desktop.calls.count
        controller.searchField.stringValue = "Kara Walker"
        controller.search(nil)
        var walkerFound = await eventually(60) { controller.visibleItemIdentitiesForTesting.contains("cma:287051") }
        for _ in 0..<3 where !walkerFound { controller.loadMoreResults(nil); walkerFound = await eventually(60) { controller.visibleItemIdentitiesForTesting.contains("cma:287051") } }
        note("typed search \"Kara Walker\": \(controller.visibleItemIdentitiesForTesting.count) rows; notice: \(controller.cmaNoticeLabel.stringValue)")
        guard walkerFound else {
            note("observed rows: \(controller.visibleItemIdentitiesForTesting.joined(separator: ", "))")
            return XCTFail("Record 287051 was not in the live Kara Walker search results")
        }
        let walkerIndex = try XCTUnwrap(controller.visibleItemIdentitiesForTesting.firstIndex(of: "cma:287051"),
                                        "cma:287051 was not in the live results: \(controller.visibleItemIdentitiesForTesting)")
        selectCMAItem(walkerIndex, in: controller)
        XCTAssertEqual(controller.selectedIdentityForTesting, "cma:287051", "Selection is closed-loop")
        let walker = try XCTUnwrap(controller.selectedReferenceForTesting)
        XCTAssertEqual(walker.identityKey, "cma:287051"); XCTAssertEqual(walker.provider, .cma)
        XCTAssertEqual(walker.cmaKind, .metadataOnly, "The live record still has no usable image")
        XCTAssertTrue(walker.isCMABrowseOnly); XCTAssertEqual(walker.useRestriction, .browseOnly)
        XCTAssertFalse(walker.cma?.isCC0 ?? true, "A browse-only record never gains an invented license")
        XCTAssertNil(walker.remotePreview); XCTAssertNil(walker.galleryThumbnailURL(large: true))
        XCTAssertEqual(walker.originalURL, walker.sourcePageURL, "A text row's media URLs are the inert record page, never an image")
        XCTAssertTrue(CMAURLPolicy.isAllowedPageURL(walker.sourcePageURL), "\(walker.sourcePageURL)")
        let walkerRow = try XCTUnwrap(controller.collectionView(controller.collectionView, itemForRepresentedObjectAt: IndexPath(item: walkerIndex, section: 0)) as? WallpaperCollectionViewItem)
        XCTAssertFalse(walkerRow.hasThumbnail, "A text row never draws or requests an image")
        let walkerCaption = walkerRow.captionText
        note("browse-only row \(walkerIndex): \"\(walkerCaption.replacingOccurrences(of: "\n", with: " / "))\" · summary \"\(controller.selectionLabel.stringValue)\" · page \(walker.sourcePageURL)")
        XCTAssertTrue(walkerCaption.contains(walker.cmaCreditName), walkerCaption)
        XCTAssertTrue(walkerCaption.contains("View on Cleveland Museum of Art ↗"), walkerCaption)
        XCTAssertTrue(controller.selectionLabel.stringValue.contains("View on Cleveland Museum of Art"), controller.selectionLabel.stringValue)
        XCTAssertFalse(controller.selectionLabel.stringValue.contains("CC0"), controller.selectionLabel.stringValue)
        XCTAssertFalse(controller.setWallpaperButton.isEnabled)
        XCTAssertTrue(controller.favoriteButton.isHidden); XCTAssertFalse(controller.viewOnMuseumButton.isHidden)
        XCTAssertTrue(controller.moreByButton.isHidden, "A browse-only record offers no creator pivot")
        controller.toggleFavorite(nil)
        XCTAssertFalse(controller.state.favorites.contains { $0.identityKey == walker.identityKey }, "A browse-only record is never favorited")
        controller.toggleViewer(nil)
        XCTAssertFalse(controller.isViewerVisible, "A browse-only record has no desktop preview")
        controller.setWallpaper(nil)
        XCTAssertNil(controller.downloadTask, "Set is refused before any download")
        XCTAssertEqual(desktop.calls.count, serviceWritesBefore, "No recording-service write for a browse-only record")
        // The one action, captured without launching anything: a fake click through the injected opener.
        var opened: [URL] = []
        controller.urlOpenerForTesting = { opened.append($0) }
        controller.viewOnMuseumButton.performClick(nil)
        XCTAssertEqual(try XCTUnwrap(opened.first), walker.sourcePageURL, "The click opens exactly the museum's own record page")
        XCTAssertEqual(try XCTUnwrap(opened.first), walker.cmaPageURL)
        XCTAssertTrue(opened.allSatisfy { CMAURLPolicy.isAllowedPageURL($0) })
        captureWindow(window, named: "cma-06-browse-only")

        // The live Openverse walk on the same controller: its injected client is now live. The record is the
        // documented first result of this typed search; the stored title keeps the source's markup and only
        // the display layer cleans it.
        controller.showOpenverse(nil)
        controller.searchField.stringValue = "Entry of Alexander the Great into Babylon"
        controller.search(nil)
        let liveID = "openverse:811e7030-bcad-4c4a-b497-30f892cc2d24"
        var triumphFound = await eventually(60) { controller.visibleItemIdentitiesForTesting.contains(liveID) }
        for _ in 0..<3 where !triumphFound { controller.loadMoreResults(nil); triumphFound = await eventually(60) { controller.visibleItemIdentitiesForTesting.contains(liveID) } }
        note("typed Openverse search: \(controller.visibleItemIdentitiesForTesting.count) rows; notice: \(controller.openverseNoticeLabel.stringValue)")
        guard triumphFound else {
            note("observed rows: \(controller.visibleItemIdentitiesForTesting.joined(separator: ", "))")
            return XCTFail("The live Openverse record was not returned for the typed search; the API may be unavailable")
        }
        let triumphIndex = try XCTUnwrap(controller.visibleItemIdentitiesForTesting.firstIndex(of: liveID),
                                         "openverse:811e7030-bcad-4c4a-b497-30f892cc2d24 was not in the live results: \(controller.visibleItemIdentitiesForTesting)")
        selectCMAItem(triumphIndex, in: controller)
        XCTAssertEqual(controller.selectedIdentityForTesting, liveID, "Selection is closed-loop")
        let triumph = try XCTUnwrap(controller.selectedReferenceForTesting)
        XCTAssertEqual(triumph.identityKey, liveID); XCTAssertEqual(triumph.provider, .openverse)
        XCTAssertEqual(triumph.sourceName, "wikimedia"); XCTAssertEqual(triumph.sourceDisplayName, "Wikimedia Commons")
        XCTAssertEqual(triumph.license, "cc0"); XCTAssertEqual(triumph.licenseVersion, "1.0")
        XCTAssertTrue(triumph.licenseIsConsistent, "\(String(describing: triumph.licenseURL))"); XCTAssertNil(triumph.useRestriction)
        let rawTitle = try XCTUnwrap(triumph.title, "The record keeps the source's own title")
        note("raw source title: \"\(rawTitle)\"")
        XCTAssertTrue(rawTitle.contains("<i>"), "The stored title keeps the source's markup: \(rawTitle)")
        XCTAssertTrue(rawTitle.contains("</i>"), rawTitle)
        XCTAssertTrue(rawTitle.contains("Entry of Alexander the Great into Babylon"), rawTitle)
        XCTAssertEqual(triumph.displayTitle, "Entry of Alexander the Great into Babylon, or The Triumph of Alexander")
        XCTAssertEqual(triumph.displayCreator, "after Charles Le Brun")
        XCTAssertEqual(triumph.displayCredit, "after Charles Le Brun", "A credit that carries its own qualifier is never re-prefixed with “by”")
        let triumphRow = try XCTUnwrap(controller.collectionView(controller.collectionView, itemForRepresentedObjectAt: IndexPath(item: triumphIndex, section: 0)) as? WallpaperCollectionViewItem)
        XCTAssertEqual(triumphRow.view.accessibilityLabel(), triumph.displayTitle, "The visible row shows the cleaned title")
        let thumbnailDrawn = await eventually(30) {
            (controller.collectionView.item(at: IndexPath(item: triumphIndex, section: 0)) as? WallpaperCollectionViewItem)?.hasThumbnail == true
        }
        note("real thumbnail drawn in the grid: \(thumbnailDrawn)")
        XCTAssertTrue(thumbnailDrawn, "A real thumbnail is decoded for the live record")
        captureWindow(window, named: "cma-07-openverse-discover")

        controller.toggleViewer(nil)
        let staged = await eventually(30) { controller.stageView.image != nil }
        XCTAssertTrue(staged, "The rendered preview draws the real thumbnail")
        XCTAssertEqual(controller.previewTitleLabel.stringValue, "Entry of Alexander the Great into Babylon, or The Triumph of Alexander")
        XCTAssertTrue(controller.previewMetadataLabel.stringValue.contains("after Charles Le Brun"), controller.previewMetadataLabel.stringValue)
        let triumphAttribution = controller.previewAttributionLabel.attributedStringValue
        func attributionLink(_ fragment: String) -> URL? {
            let range = (triumphAttribution.string as NSString).range(of: fragment)
            guard range.location != NSNotFound else { return nil }
            return triumphAttribution.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        }
        XCTAssertEqual(try XCTUnwrap(attributionLink("CC0 1.0"), "No license link in “\(triumphAttribution.string)”"), triumph.licenseURL)
        XCTAssertEqual(try XCTUnwrap(attributionLink("Source: Wikimedia Commons"), "No source link in “\(triumphAttribution.string)”"), triumph.sourcePageURL)
        XCTAssertTrue(triumphAttribution.string.contains("as reported"), triumphAttribution.string)
        XCTAssertTrue(controller.previewAcknowledgementLabel.stringValue.contains("Powered by Openverse; not endorsed by Openverse"))
        XCTAssertTrue(controller.setWallpaperButton.isEnabled, "CC0 as reported stays settable")
        XCTAssertTrue(controller.reviewSourceButton.isHidden, "A consistent license is never flagged for review")
        XCTAssertTrue(controller.selectionLabel.stringValue.contains("CC0 1.0"), controller.selectionLabel.stringValue)
        note("openverse attribution: \"\(triumphAttribution.string)\" · metadata \"\(controller.previewMetadataLabel.stringValue)\" · page \(triumph.sourcePageURL) · license \(triumph.licenseDescription ?? "none")")
        captureWindow(window, named: "cma-07-openverse")
    }
}

// Opt-in independent combined-provider native walk. No production profile or desktop service.
extension WallpierTests {
    @MainActor
    func testLiveCombinedCatalogNativeWalk() async throws {
        try XCTSkipIf(Self.liveDirectory == nil, "Set WALLPIER_LIVE_TEST_DIR to run the live catalog walk")
        let evidence = try XCTUnwrap(Self.liveDirectory)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let root = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.parth.Wallpier.catalog-live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let desktop = SetAuditWallpaperService()
        let prior = root.appendingPathComponent("prior.png")
        try writeTestImage(to: prior); desktop.current = prior
        let (c, window) = makeCaptureController(root: root, size: NSSize(width: 1120, height: 720), appearance: .aqua,
                                                 desktop: desktop, thumbnails: RemoteThumbnailProvider(memoryOnly: true), defaults: defaults) { state in
            state.favorites = []; state.collections = []; state.selectedCollectionID = nil; state.currentSource = .favorites
        }
        defer {
            c.creatorTaskForTesting?.cancel(); c.searchTask?.cancel(); c.detailTask?.cancel()
            c.downloadTask?.cancel(); c.undoValidationTask?.cancel(); window.close()
        }
        var notes = ["Combined native live walk · \(Date())"]
        var failures: [String] = []
        defer { try? notes.joined(separator: "\n").appending("\n").write(to: evidence.appendingPathComponent("combined-evidence.txt"), atomically: true, encoding: .utf8) }
        enum WalkError: Error { case failed(String) }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw WalkError.failed(message) }
        }
        let sources: [(RemoteProviderID, String, String?)] = [
            (.plasma, "Pastel Hills", nil), (.pepper, "Save Point", nil),
            (.met, "Wheat Field with Cypresses", "met:436535"), (.wellcome, "mountain photograph", "wellcome:x6f4u54f"),
            (.inaturalist, "butterfly", nil), (.nasa, "Earth horizon", nil)
        ]
        var savedIDs: [String] = []
        for (provider, query, preferred) in sources {
            do {
                c.showDiscover(provider: provider)
                c.searchField.stringValue = query
                c.search(nil)
                let search = c.searchTask
                var searchFinished = false
                Task { await search?.value; searchFinished = true }
                let loaded = await eventually(90) { searchFinished }
                try require(loaded && !c.visibleItemIdentitiesForTesting.isEmpty, "search unfinished or no results for \(query); status: \(c.statusLabel.stringValue)")
                let ids = c.visibleItemIdentitiesForTesting
                notes.append("\(provider.rawValue): query=\(query), results=\(ids.count), ids=\(ids.prefix(8))")
                // Inspect live eligibility on selection, preferring the reviewed exact record when present.
                let order = (preferred.flatMap { ids.firstIndex(of: $0) }.map { [$0] } ?? []) + ids.indices.filter { ids[$0] != preferred }
                var chosen: WallpaperReference?
                var chosenIndex = 0
                for index in order {
                    selectCMAItem(index, in: c)
                    guard let candidate = c.selectedReferenceForTesting else { continue }
                    notes.append("  candidate \(candidate.identityKey): title=\(candidate.displayTitle), restriction=\(String(describing: candidate.useRestriction)), page=\(candidate.sourcePageURL), creator=\(String(describing: candidate.catalog?.creator))")
                    if candidate.useRestriction == nil && candidate.galleryThumbnailURL(large: true) != nil {
                        chosen = candidate; chosenIndex = index; break
                    }
                }
                let reference = try XCTUnwrap(chosen, "\(provider.rawValue) has no usable selected record")
                c.collectionView.scrollToItems(at: [IndexPath(item: chosenIndex, section: 0)], scrollPosition: .nearestVerticalEdge)
                window.contentView?.layoutSubtreeIfNeeded()
                let thumb = await eventually(45) { (c.collectionView.item(at: IndexPath(item: chosenIndex, section: 0)) as? WallpaperCollectionViewItem)?.hasThumbnail == true }
                try require(thumb, "\(reference.identityKey): thumbnail did not draw")
                captureWindow(window, named: "combined-\(provider.rawValue)-grid")
                c.toggleViewer(nil)
                let staged = await eventually(45) { c.stageView.image != nil }
                try require(staged, "\(reference.identityKey): preview did not draw")
                let attribution = c.previewAttributionLabel.attributedStringValue
                notes.append("  preview: \(c.previewTitleLabel.stringValue); attribution=\(attribution.string)")
                try require(!attribution.string.isEmpty, "\(reference.identityKey): missing attribution")
                captureWindow(window, named: "combined-\(provider.rawValue)-preview")
                c.toggleViewer(nil)
                c.toggleFavorite(nil)
                try require(c.state.favorites.contains { $0.identityKey == reference.identityKey }, "favorite missing")
                let before = desktop.calls.count
                let previousBytes = desktop.current.flatMap { try? Data(contentsOf: $0) }
                c.setWallpaper(nil)
                let finished = await eventually(180) { c.downloadTask == nil }
                if !finished { c.downloadTask?.cancel() }
                try require(finished && desktop.calls.count == before + 1, "Set did not record: \(c.statusLabel.stringValue)")
                let applied = try XCTUnwrap(desktop.calls.last?.image)
                try require(applied.path.hasPrefix(root.appendingPathComponent("Rollback").path), "Set did not use owned file")
                try require(FileManager.default.fileExists(atPath: applied.path), "owned file missing")
                let size = CatalogLibrary.originalSize(applied)
                try require(size != nil, "owned file has no validated dimensions")
                notes.append("  recorded Set: \(applied.lastPathComponent), \(size!.width)×\(size!.height); \(c.statusLabel.stringValue)")
                c.undoWallpaperChange(nil)
                let undone = await eventually(45) { c.downloadTask == nil && desktop.calls.count == before + 2 }
                try require(undone, "Undo did not record")
                let restored = desktop.calls.last.flatMap { try? Data(contentsOf: $0.image) }
                try require(previousBytes != nil && restored == previousBytes, "Undo did not restore previous bytes")
                notes.append("  Undo recorded \(desktop.calls.last?.image.lastPathComponent ?? "missing")")
                savedIDs.append(reference.identityKey)
                if provider == .met || provider == .wellcome {
                    notes.append("  More by visible=\(!c.moreByButton.isHidden), creator=\(String(describing: reference.catalog?.creator))")
                    if reference.catalog?.creator != nil && !c.moreByButton.isHidden {
                        c.moreByButton.performClick(nil)
                        let pivot = await eventually(90) { c.isShowingCreatorViewForTesting && !c.visibleItemIdentitiesForTesting.isEmpty }
                        try require(pivot, "creator results did not load")
                        let subtitle = "\(provider.displayName) · Open-access works"
                        try require(c.window?.subtitle == subtitle && c.creatorSubtitleLabel.stringValue == subtitle,
                                    "creator title and gallery header must identify the active source")
                        let creatorID = reference.catalog?.creator?.id
                        try require(c.visibleItemIdentitiesForTesting.allSatisfy { c.creatorWorkForTesting($0)?.catalog?.creator?.id == creatorID }, "creator result ID mismatch")
                        notes.append("  creator results: \(c.visibleItemIdentitiesForTesting.prefix(8))")
                        captureWindow(window, named: "combined-\(provider.rawValue)-creator")
                        c.closeCreator(nil)
                    }
                }
            } catch {
                failures.append("\(provider.rawValue): \(error)")
                notes.append("FAIL \(provider.rawValue): \(error)")
                c.downloadTask?.cancel(); c.searchTask?.cancel(); c.creatorTaskForTesting?.cancel()
                while let sheet = window.attachedSheet { window.endSheet(sheet) }
                if c.isViewerVisible { c.toggleViewer(nil) }
                if c.isShowingCreatorViewForTesting { c.closeCreator(nil) }
            }
        }
        let store = WallpaperStateStore(stateURL: root.appendingPathComponent("state.json"))
        let saved = store.load()
        notes.append("saved mixed favorites: \(saved.favorites.map(\.identityKey))")
        for id in savedIDs {
            guard let persisted = saved.favorites.first(where: { $0.identityKey == id }),
                  let current = c.state.favorites.first(where: { $0.identityKey == id }) else { failures.append("saved favorite missing: \(id)"); continue }
            if persisted.catalog != current.catalog || persisted.license != current.license || persisted.licenseURL != current.licenseURL || persisted.sourcePageURL != current.sourcePageURL { failures.append("saved credit changed: \(id)") }
        }
        let cache = RemoteWallpaperCache(rootURL: root.appendingPathComponent("Originals"), maximumSizeBytes: 1)
        do {
            _ = try await cache.evictIfNeeded(protectedPaths: saved.protectedCachePaths)
            for ref in saved.favorites where savedIDs.contains(ref.identityKey) {
                guard let path = ref.cachedLocalPath else { failures.append("cached favorite path missing: \(ref.identityKey)"); continue }
                if !FileManager.default.fileExists(atPath: path) { failures.append("protected cache evicted: \(ref.identityKey)") }
            }
            notes.append("eviction protected favorites: \(saved.protectedCachePaths.count) paths")
        } catch { failures.append("eviction: \(error)") }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
