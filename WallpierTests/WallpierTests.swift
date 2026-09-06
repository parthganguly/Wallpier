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
        XCTAssertFalse(h.controller.previewImageView.image === obsoleteImage)
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
