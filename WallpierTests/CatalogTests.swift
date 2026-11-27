import Foundation
import XCTest
@testable import Wallpier

extension WallpierTests {
    func testCatalogMetRejectsBlankImagesAndAmbiguousCreators() throws {
        func record(publicDomain: Bool = true, original: String, creatorID: Int = 161947,
                    displayName: String = "Vincent van Gogh") throws -> MetCatalogAdapter.MetObject {
            let fields: [String: Any] = [
                "objectID": 436535, "isPublicDomain": publicDomain, "primaryImage": original,
                "primaryImageSmall": "https://images.metmuseum.org/CRDImages/ep/web-large/DP-42549-001.jpg",
                "objectURL": "https://www.metmuseum.org/art/collection/search/436535",
                "title": "Wheat Field with Cypresses", "artistDisplayName": displayName,
                "constituents": [["constituentID": creatorID, "name": "Vincent van Gogh", "role": "Artist"]]
            ]
            return try JSONDecoder().decode(MetCatalogAdapter.MetObject.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let original = "https://images.metmuseum.org/CRDImages/ep/original/DP-42549-001.jpg"
        let accepted = try XCTUnwrap(MetCatalogAdapter.reference(from: record(original: original)))
        XCTAssertEqual(accepted.catalog?.creator?.id, "161947")
        XCTAssertNil(MetCatalogAdapter.reference(from: try record(publicDomain: false, original: "")))
        XCTAssertNil(MetCatalogAdapter.reference(from: try record(original: "")))
        XCTAssertNil(MetCatalogAdapter.reference(from: try record(original: original.replacingOccurrences(of: ".org/", with: ".org.example/"))))
        let after = try XCTUnwrap(MetCatalogAdapter.reference(from: record(original: original, displayName: "After Vincent van Gogh")))
        XCTAssertNil(after.catalog?.creator)
        XCTAssertEqual(after.displayCreator, "After Vincent van Gogh")
        let other = try XCTUnwrap(MetCatalogAdapter.reference(from: record(original: original, creatorID: 100)))
        XCTAssertEqual(other.displayCreator, accepted.displayCreator)
        XCTAssertNotEqual(other.catalog?.creator?.id, accepted.catalog?.creator?.id)
    }

    func testCatalogWellcomeUsesImageRightsAndExactContributorRole() throws {
        func record(license: String, status: String, role: String) throws -> WellcomeCatalogAdapter.ImageRecord {
            let fields: [String: Any] = [
                "id": "x6f4u54f",
                "locations": [[
                    "url": "https://iiif.wellcomecollection.org/image/V0026440ER/info.json",
                    "locationType": ["id": "iiif-image"], "license": ["id": license],
                    "accessConditions": [["status": ["id": status]]], "credit": "Wellcome Collection"
                ]],
                "source": ["id": "h5e3bnr6", "title": "Tharp Mountain Girdlestone. Photograph.",
                           "contributors": [["agent": ["id": "usqyr9ur", "label": "J. Thomson"], "roles": [["label": role]]]]]
            ]
            return try JSONDecoder().decode(WellcomeCatalogAdapter.ImageRecord.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let allowed = try record(license: "pdm", status: "open", role: "Photographer")
        XCTAssertEqual(WellcomeCatalogAdapter.reference(from: allowed, width: 1251, height: 1682)?.catalog?.creator?.id, "usqyr9ur")
        let bookseller = try record(license: "pdm", status: "open", role: "Bookseller")
        XCTAssertNil(WellcomeCatalogAdapter.reference(from: bookseller, width: 1251, height: 1682)?.catalog?.creator)
        for denied in [try record(license: "cc-by-nc", status: "open", role: "Photographer"),
                       try record(license: "pdm", status: "restricted", role: "Photographer")] {
            XCTAssertNil(WellcomeCatalogAdapter.reference(from: denied, width: 1251, height: 1682))
        }
    }

    func testCatalogNASARejectsThirdPartyCredits() throws {
        func record(photographer: String? = nil, secondary: String? = nil, description: String? = nil) -> NASACatalogAdapter.DataRecord {
            NASACatalogAdapter.DataRecord(center: "JSC", nasa_id: "as10-27-3890", title: "Earth rises", media_type: "image",
                                          photographer: photographer, secondary_creator: secondary,
                                          description: description, keywords: ["APOLLO PROJECT"])
        }
        XCTAssertEqual(NASACatalogAdapter.credit(for: record()), "NASA/JSC")
        XCTAssertEqual(NASACatalogAdapter.credit(for: record(photographer: "NASA")), "NASA")
        XCTAssertNil(NASACatalogAdapter.credit(for: record(photographer: "NASA", secondary: "NASA/JPL-Caltech/Harvard-Smithsonian CfA")))
        XCTAssertNil(NASACatalogAdapter.credit(for: record(photographer: "NASA", description: "Image courtesy of another archive")))
        XCTAssertNil(NASACatalogAdapter.credit(for: record(photographer: "NASA", description: "&copy; illustrator")))
        XCTAssertNil(NASACatalogAdapter.credit(for: record(photographer: "NASA/JPL")))
    }

    func testCatalogDigitalMediaUsesReviewedFilesAndPinnedUpstream() throws {
        let pepper = PepperCatalogAdapter()
        let base = "https://www.peppercarrot.com/0_sources/0ther/wallpapers/hi-res/"
        let artwork = "2023-03-30_Concept-art-for-a-fictive-video-game-Save-Point_by-David-Revoy"
        let exact = try XCTUnwrap(URL(string: base + artwork + ".jpg"))
        XCTAssertTrue(pepper.allowsMedia(exact, id: artwork, original: true))
        XCTAssertFalse(pepper.allowsMedia(exact, id: artwork, original: false))
        let other = "2026-11-04_Cepper-and-Parrot_by-David-Revoy"
        XCTAssertFalse(pepper.allowsMedia(try XCTUnwrap(URL(string: base + other + ".jpg")), id: other, original: true))
        let plasma = PlasmaCatalogAdapter()
        let root = "https://raw.githubusercontent.com/KDE/plasma-workspace-wallpapers/"
        let suffix = "/PastelHills/contents/images/3200x2000.jpg"
        let pinned = root + "333c72796f9d9306f51bfb16088ad4e986e76e45" + suffix
        XCTAssertTrue(plasma.allowsMedia(try XCTUnwrap(URL(string: pinned)), id: "PastelHills", original: true))
        XCTAssertFalse(plasma.allowsMedia(try XCTUnwrap(URL(string: root + "master" + suffix)), id: "PastelHills", original: true))
        XCTAssertFalse(plasma.allowsMedia(try XCTUnwrap(URL(string: pinned + "?unexpected=1")), id: "PastelHills", original: true))
    }

    func testCatalogInaturalistGatesPhotoLicenseAndKeepsCredit() async throws {
        func observation(_ id: Int, license: String) -> [String: Any] {
            let photo = id + 100
            return ["id": id, "taxon": ["name": "Aves"], "photos": [[
                "id": photo, "license_code": license, "hidden": false,
                "url": "https://inaturalist-open-data.s3.amazonaws.com/photos/\(photo)/square.jpg",
                "attribution": "Photo credit", "original_dimensions": ["width": 1920, "height": 1080]
            ]]]
        }
        let result = ["page": 1, "total_results": 2,
                      "results": [observation(1, license: "cc-by"), observation(2, license: "cc0")]] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: result)
        let client = CatalogFixtureClient(body: data)
        let adapter = INaturalistCatalogAdapter()
        let transport = CatalogTransport(hosts: adapter.hosts, client: client)
        let page = try await adapter.search(CatalogSearchOptions(query: "birds"), page: 1, transport: transport)
        XCTAssertEqual(page.hiddenCount, 1)
        let reference = try XCTUnwrap(page.wallpapers.first)
        XCTAssertEqual(reference.wallpaperID, "2-102")
        XCTAssertEqual(reference.catalog?.credit, "Photo credit")
        XCTAssertNil(reference.displayCreator)
        XCTAssertTrue(adapter.allowsMedia(reference.originalURL, id: reference.wallpaperID, original: true))
        XCTAssertFalse(adapter.allowsMedia(reference.originalURL, id: "2-101", original: true))
    }

    func testCatalogTransportRetractRedirectAndBackOffOn429() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://catalog.example/search"))
        let throttled = CatalogFixtureClient(status: 429, headers: ["Retry-After": "8"])
        let transport = CatalogTransport(hosts: ["catalog.example"], client: throttled)
        do {
            _ = try await transport.bytes(from: endpoint)
            XCTFail("Expected provider throttle")
        } catch {
            XCTAssertEqual(error as? RemoteProviderError, .rateLimited(retryAfter: 8))
        }
        do {
            _ = try await transport.bytes(from: endpoint)
            XCTFail("Expected local throttle")
        } catch RemoteProviderError.rateLimited(let wait) {
            XCTAssertGreaterThan(wait ?? 0, 0)
        }
        let unsafe = try XCTUnwrap(URL(string: "https://catalog.example/other"))
        let redirect = CatalogTransport(hosts: ["catalog.example"], client: CatalogFixtureClient(finalURL: unsafe))
        do {
            _ = try await redirect.bytes(from: endpoint)
            XCTFail("Expected URL policy to reject resource change")
        } catch {
            XCTAssertEqual(error as? RemoteProviderError, .untrustedURL)
        }
    }

    func testCatalogStatePreservesIndependentQueriesAndBrowseOnlyRights() throws {
        let url = try XCTUnwrap(URL(string: "https://www.metmuseum.org/art/collection/search/436535"))
        let reference = WallpaperReference(providerIdentifier: RemoteProviderID.met.rawValue, wallpaperID: "436535",
                                           sourcePageURL: url, originalURL: url, previewURL: url, thumbnailURL: url,
                                           width: 0, height: 0, uploader: nil, tags: [], cachedLocalPath: nil,
                                           catalog: CatalogRecord(credit: "Published credit", browseOnly: true))
        XCTAssertTrue(reference.isBrowseOnly)
        XCTAssertEqual(reference.useRestriction, .catalogBrowseOnly)
        XCTAssertNil(reference.galleryThumbnailURL(large: true))
        var state = WallpaperState()
        state.catalogQueries = ["nasa": "Earth", "met": "Van Gogh"]
        let decoded = try JSONDecoder().decode(WallpaperState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.catalogQueries, state.catalogQueries)
    }
}

private struct CatalogFixtureClient: NetworkClient {
    var body = Data()
    var status = 200
    var headers: [String: String] = [:]
    var finalURL: URL?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(finalURL ?? request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
        return (body, response)
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (body, response) = try await data(for: request)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: file)
        return (file, response)
    }
}
