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
        // The fixture never chooses a scaling mode, so it has the default: Fit (formerly Fill).
        XCTAssertTrue(controller.rotationSummaryLabel.stringValue.contains("“Quiet Mornings” on Studio Display using Fit to Screen"))
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
                               windowClass: NSWindow.Type = NSWindow.self, desktop: WallpaperService? = nil,
                               thumbnails: RemoteThumbnailProvider? = nil, page: RemoteSearchPage? = nil, screens: [NSScreen]? = nil,
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
            remoteThumbnailProvider: thumbnails ?? CaptureThumbnails(), availableScreens: { screens ?? [CaptureScreen()] })
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
                XCTAssertGreaterThanOrEqual(columns, 2, context)
                view.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .top)
                select(1)
                func expectSelection(_ index: Int, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
                    XCTAssertEqual(view.selectionIndexPaths, [IndexPath(item: index, section: 0)], "\(context): \(step)", file: file, line: line)
                    XCTAssertEqual(c.state.selectedRemoteIdentity, identities[index], "\(context): \(step)", file: file, line: line)
                    assertHonestSelection(c, "\(context): \(step)", file: file, line: line)
                }

                // The gutter between the first two pictures is empty space at every column count.
                let first = view.frameForItem(at: 0), second = view.frameForItem(at: 1)
                let blank = NSPoint(x: (first.maxX + second.minX) / 2, y: first.midY)
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
         extraCollections: [WallpaperCollection] = []) throws {
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
            provider: WallhavenProvider(client: network), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: root.appendingPathComponent("Rollback"), originalsRoot: originals),
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

    /// A new controller over the same persisted state and isolated dependencies, through the real startup path.
    func relaunch() -> MainWindowController {
        let relaunched = MainWindowController(window: nil, wallpaperService: desktop, stateStore: store,
            provider: WallhavenProvider(client: network), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: rollbackRoot, originalsRoot: originals),
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
                                 extraCollections: [WallpaperCollection] = []) throws -> RotationHarness {
        let root = try historyTestFolder()
        let harness = try RotationHarness(root: root, references: references, interval: interval,
                                          shuffle: shuffle, localImages: localImages, favorites: favorites,
                                          extraCollections: extraCollections)
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
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.cached(refs[1])])
        // The following tick downloads exactly the next selected original and nothing else.
        h.network.downloadGate = SetAuditGate<URL>()
        try writeTestImage(to: h.incoming, width: 5)
        h.scheduledTimers[0].fire()
        await fulfillment(of: [h.network.downloadGate.started], timeout: 5)
        XCTAssertEqual(h.network.downloads, [refs[1].originalURL, refs[2].originalURL])
        h.network.downloadGate.release(.success(h.incoming))
        try await finishAuditTask(h.controller.rotationTask)
        XCTAssertEqual(h.network.downloads.count, 2)
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.cached(refs[1]), h.cached(refs[2])])
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
        XCTAssertEqual(h.desktop.calls, [SetAuditWallpaperService.Call(image: h.cached(next), display: "101", scaling: .fit)])
        let entry = try XCTUnwrap(h.store.load().history.last)
        XCTAssertEqual(entry.replacement.imagePath, h.cached(next).path)
        XCTAssertEqual(entry.replacement.displayID, "101")
        XCTAssertEqual(entry.replacement.scaling, .fit)
        XCTAssertEqual(entry.previous.imagePath, h.prior.path, "The prior image is captured through the shared path")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(entry.rollbackPath))), try Data(contentsOf: h.prior))
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, h.cached(next).path)
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
        XCTAssertEqual(applied, [h.cached(refs[1]), h.cached(refs[0]), h.cached(refs[1]), h.cached(refs[0])])
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
            let member = refs.first { h.cached($0).path == appliedPath }
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
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.cached(refs[1])])
        XCTAssertEqual(visibleSelection(h.controller), [2], "Rotation must not move the visible selection")
        XCTAssertEqual(h.controller.state.selectedRemoteIdentity, refs[2].identityKey, "…nor the remembered one")
        // Browse an unrelated favorite: the next tick continues after the last rotated member.
        h.controller.showFavorites(nil)
        XCTAssertEqual(h.controller.state.selectedRemoteIdentity, favorite.identityKey)
        try await tick(h, .success(h.incoming))
        XCTAssertEqual(h.network.downloads, [refs[1].originalURL, refs[2].originalURL])
        XCTAssertEqual(h.desktop.calls.map(\.image), [h.cached(refs[1]), h.cached(refs[2])])
        XCTAssertEqual(h.controller.state.selectedRemoteIdentity, favorite.identityKey)
        XCTAssertEqual(visibleSelection(h.controller), [0])
        try await tick(h, .success(h.incoming))
        XCTAssertEqual(h.desktop.calls.last?.image, h.cached(refs[0]), "The sequence wraps around")
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
        XCTAssertEqual(applied, [1, 0, 1, 0, 1, 0].map { h.cached(refs[$0]) })
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
                       [refs[1], other.wallpapers[0], other.wallpapers[1], refs[0], refs[1]].map(h.cached))
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
        XCTAssertEqual(h.desktop.calls.map(\.image), [refs[1], refs[2], refs[0]].map(h.cached))
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
        XCTAssertEqual(h.desktop.calls.map(\.image), [refs[2], refs[0], refs[1]].map(h.cached))
        XCTAssertEqual(h.store.load().history.map(\.replacement.imagePath), [refs[2], refs[1]].map { h.cached($0).path })
        XCTAssertEqual(h.store.load().assignment(for: "101")?.imagePath, h.cached(refs[1]).path)
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
        XCTAssertEqual(h.desktop.calls.map(\.image), [refs[1], refs[2]].map(h.cached))
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
        XCTAssertEqual(h.desktop.calls.map(\.image), [refs[1], refs[2], refs[0]].map(h.cached))
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
        XCTAssertEqual(h.desktop.calls, [.init(image: h.cached(a), display: "101", scaling: .fill)])
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
        XCTAssertEqual(h.desktop.calls.last, .init(image: h.cached(a), display: "202", scaling: .fit))
        // A relaunch restores them.
        let screens: [NSScreen] = [h.x, h.y]
        let originals = h.root.appendingPathComponent("Originals")
        let relaunched = MainWindowController(window: nil, wallpaperService: h.desktop, stateStore: h.store,
            provider: WallhavenProvider(client: h.network), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: h.root.appendingPathComponent("Rollback"), originalsRoot: originals),
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
        XCTAssertEqual(h.desktop.calls, [.init(image: h.cached(refs[1]), display: "101", scaling: .fill)])
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
        XCTAssertEqual(h.desktop.calls.last, .init(image: h.cached(refs[2]), display: "202", scaling: .fit))
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
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // Bars (apply bar, status, folder bar) sit on the window background; empty states and captions on the content background.
            XCTAssertGreaterThanOrEqual(contrast(.secondaryText, on: .windowBackgroundColor, in: appearance), 5, "\(appearance.rawValue) bars")
            XCTAssertGreaterThanOrEqual(contrast(.secondaryText, on: .controlBackgroundColor, in: appearance), 5, "\(appearance.rawValue) content")
            // Hierarchy: still clearly secondary to the primary label.
            XCTAssertGreaterThan(contrast(.labelColor, on: .controlBackgroundColor, in: appearance),
                                 contrast(.secondaryText, on: .controlBackgroundColor, in: appearance) * 1.8, appearance.rawValue)
        }
        // Dark keeps the native secondary label.
        var dark: (NSColor, NSColor)!
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            dark = (NSColor.secondaryText.usingColorSpace(.sRGB)!, NSColor.secondaryLabelColor.usingColorSpace(.sRGB)!)
        }
        XCTAssertEqual(dark.0, dark.1)
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
        XCTAssertEqual(c.statusLabel.textColor, .systemRed)
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
        for (name, expected) in [(NSAppearance.Name.darkAqua, NSColor.secondaryLabelColor), (.aqua, NSColor(white: 0, alpha: 0.62))] {
            window.appearance = NSAppearance(named: name)
            var resolved: (NSColor, NSColor)!
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = (c.statusLabel.textColor!.usingColorSpace(.sRGB)!, expected.usingColorSpace(.sRGB)!)
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
                       [root.appendingPathComponent("Originals").appendingPathComponent(RemoteWallpaperCache.filename(for: captured)).path],
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
            provider: WallhavenProvider(client: OfflineNetwork()), originalCache: RemoteWallpaperCache(rootURL: originals),
            historyStore: WallpaperHistoryStore(root: root.appendingPathComponent("Rollback"), originalsRoot: originals),
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
        guard await eventually(2, { network.searchState(page: 2) == .held }) else {
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
