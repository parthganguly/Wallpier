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

    func testOwnedRemoteOriginalIsProtectedWithoutRollbackCopy() async throws {
        let folder = try historyTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let originals = folder.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let source = originals.appendingPathComponent("remote.png")
        try writeTestImage(to: source)
        let rollback = folder.appendingPathComponent("Rollback")
        let store = WallpaperHistoryStore(root: rollback, originalsRoot: originals)
        let entry = await store.prepare(previous: assignment(path: source.path), replacement: assignment(path: "next.png"))
        XCTAssertNil(entry.rollbackPath); XCTAssertNil(entry.undoUnavailableReason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollback.path))
        var state = WallpaperState(); state.appendHistory(entry)
        XCTAssertTrue(state.protectedCachePaths.contains(source.path))
        let cache = RemoteWallpaperCache(rootURL: originals, maximumSizeBytes: 1)
        let removed = try await cache.evictIfNeeded(protectedPaths: state.protectedCachePaths)
        XCTAssertTrue(removed.isEmpty)
        let restored = await store.undoAssignment(for: entry)
        XCTAssertEqual(restored?.imagePath, source.path)
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
        let store = WallpaperHistoryStore(root: folder.appendingPathComponent("Rollback"), originalsRoot: originals)
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

    init(root: URL, references: [WallpaperReference]) {
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
            provider: WallhavenProvider(client: network), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: root.appendingPathComponent("Rollback"), originalsRoot: originals),
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 150),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView!.addSubview(item.view)
        item.view.frame = NSRect(x: 0, y: 0, width: 240, height: 150)
        item.configure(identifier: "a", title: "a", toolTip: "a")
        XCTAssertFalse(item.hasThumbnail)
        let frames = [NSSize(width: 1080, height: 1920), NSSize(width: 3440, height: 1440)].map { size in
            item.setThumbnail(NSImage(size: size))
            item.view.layoutSubtreeIfNeeded()
            XCTAssertTrue(item.hasThumbnail)
            return item.thumbnailFrame
        }
        // Every aspect ratio fills the same display-shaped frame, inset for the selection ring.
        XCTAssertEqual(frames[0], frames[1])
        XCTAssertEqual(frames[0], item.view.bounds.insetBy(dx: WallpaperCollectionViewItem.ringInset, dy: WallpaperCollectionViewItem.ringInset))
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
                XCTAssertEqual(size.height, floor(size.width * 10 / 16))
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

    /// Return goes through the real event path (key equivalents → menu bar → first responder chain),
    /// not a direct keyDown call, so key-equivalent and responder interception are both exercised.
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
            // NSApplication hands a plain key to the key window's sendEvent, which dispatches it to
            // the first responder, up the responder chain, and finally to the default button.
            // A hosted test app cannot activate, so the window reports itself key.
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

    /// Wallhaven's preview image is a 3:2 crop, so an uncached remote preview is labelled approximate;
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
        let original = root.appendingPathComponent("original.png")
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

        // Uncached remote: the cropped Wallhaven preview, clearly marked.
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
        XCTAssertTrue(notice.isHidden, "A preview drawn from the downloaded original is exact")

        // Back to the uncached one, then a local file.
        controller.previousWallpaper(nil)
        XCTAssertFalse(notice.isHidden)
        controller.showLocal(nil)
        waitFor(controller.state.selectedImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } == "a.png",
                "The local folder loads (\(controller.state.selectedImagePath ?? "nothing selected"))")
        controller.toggleViewer(nil)
        waitFor(controller.stageView.image != nil, "The local file's preview loads")
        XCTAssertTrue(notice.isHidden, "A local file's preview is exact")

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
        XCTAssertEqual(sidebar.rows.map(\.title), ["Library", "Discover", "Folder", "Favorites", "Collections", "Evening Light", "Quiet Mornings"])
        XCTAssertEqual(row("Favorites")?.count, 6)
        XCTAssertEqual(row("Evening Light")?.count, 5)
        XCTAssertEqual(sidebar.selectedItem, .favorites)

        let quiet = controller.state.collections[1]
        sidebar.outlineView.selectRowIndexes([sidebar.outlineView.row(forItem: row("Quiet Mornings"))], byExtendingSelection: false)
        XCTAssertEqual(controller.state.currentSource, .collections)
        XCTAssertEqual(controller.state.selectedCollectionID, quiet.id)
        XCTAssertEqual(window.title, "Quiet Mornings")
        XCTAssertEqual(window.subtitle, "2 wallpapers")

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
        XCTAssertTrue(controller.rotationSummaryLabel.stringValue.contains("“Quiet Mornings” on Studio Display using Fill Screen"))
        interval.tag = 0
        controller.setRotationInterval(interval)
        XCTAssertEqual(controller.state.rotationInterval, .off)
        XCTAssertTrue(sidebar.rows.filter(\.isRotating).isEmpty)
    }

    @MainActor
    private func setAuditHarness() throws -> SetAuditHarness {
        let root = try historyTestFolder()
        let harness = SetAuditHarness(root: root, references: [remoteReference(id: "aaaaaa"), remoteReference(id: "bbbbbb")])
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
        XCTAssertEqual(h.desktop.calls, [.init(image: h.cached(a), display: "101", scaling: .fill)])
        XCTAssertEqual(h.controller.state.selectedRemoteIdentity, h.controller.state.favorites[1].identityKey)
        let entry = try XCTUnwrap(h.store.load().history.last)
        XCTAssertEqual(entry.replacement.imagePath, h.cached(a).path)
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
        XCTAssertEqual(h.desktop.calls.map(\.image), h.controller.state.favorites.map(h.cached))
        XCTAssertEqual(h.store.load().history.count, 2)
        XCTAssertEqual(h.store.load().history.last?.previous.imagePath, h.desktop.calls[0].image.path)
        // The previously rejected A request is accepted now, using its cached original.
        h.controller.setWallpaper(nil)
        try await finishAuditTask(h.controller.downloadTask)
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.cached(h.controller.state.favorites[0]), h.cached(h.controller.state.favorites[1]), h.cached(h.controller.state.favorites[0])])
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
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.cached(h.controller.state.favorites[0])])
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
    override var isKeyWindow: Bool { true }
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
                               windowClass: NSWindow.Type = NSWindow.self, desktop: WallpaperService? = nil,
                               configure: (inout WallpaperState) -> Void) -> (MainWindowController, NSWindow) {
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
            provider: WallhavenProvider(client: network), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: root.appendingPathComponent("Rollback"), originalsRoot: originals),
            remoteThumbnailProvider: CaptureThumbnails(), availableScreens: { [CaptureScreen()] })
        let page = RemoteSearchPage(wallpapers: references, currentPage: 1, lastPage: 54, total: 1_284,
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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        pump(5) { NSApp.isActive && NSApp.keyWindow === self.window && self.controller.undoButton.isEnabled }
    }

    var isActiveAndKey: Bool { NSApp.isActive && NSApp.keyWindow === window }

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

    func commandZ() { press(6, .maskCommand, expecting: "z") }
    func shiftCommandZ() { press(6, [.maskCommand, .maskShift]) }
    func commandDelete() { press(51, .maskCommand, expecting: "\u{7f}") }

    func type(_ text: String) {
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

    func click(_ point: NSPoint) {
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
        _ = try XCTUnwrap(app.isActiveAndKey ? app : nil, "The test app must be active with a key window")
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

    // D2: a blank click keeps the ring and the Set target together.
    @MainActor
    func testBlankGalleryClickKeepsTheVisibleSetTarget() throws {
        let app = try activeApp()
        let c = app.controller
        c.showFavorites(nil)
        app.select(1)
        c.window?.contentView?.layoutSubtreeIfNeeded()
        let scroll = c.galleryScrollForTesting
        let visible = scroll.documentVisibleRect
        let blank = NSPoint(x: visible.midX, y: visible.maxY - 6)   // flipped: just above the bottom edge
        XCTAssertNil(c.collectionView.indexPathForItem(at: blank), "The click point must be empty gallery space")
        app.click(c.collectionView.convert(blank, to: nil))
        XCTAssertTrue(c.window?.firstResponder === c.collectionView, "The click reached the gallery")
        XCTAssertEqual(c.collectionView.selectionIndexPaths, [IndexPath(item: 1, section: 0)])
        assertHonestSelection(c, "after blank click")
        XCTAssertTrue(c.setWallpaperButton.isEnabled)
        // Arrow keys still move the one selection.
        app.press(124, expecting: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        XCTAssertEqual(c.collectionView.selectionIndexPaths, [IndexPath(item: 2, section: 0)])
        XCTAssertEqual(c.state.selectedRemoteIdentity, c.state.favorites[2].identityKey)
        assertHonestSelection(c, "after arrow")
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
