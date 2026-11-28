import Foundation

struct PlasmaCatalogAdapter: CatalogAdapter {
    let id: RemoteProviderID = .plasma
    let endpoint = URL(string: "https://github.com/KDE/plasma-workspace-wallpapers")!
    let hosts: Set<String> = ["api.github.com", "raw.githubusercontent.com"]

    private static let repository = "KDE/plasma-workspace-wallpapers"
    private static let treeURL = URL(string: "https://api.github.com/repos/\(repository)/git/trees/master?recursive=1")!
    private static let rawRoot = "https://raw.githubusercontent.com/\(repository)"
    private static let pageRoot = "https://github.com/\(repository)/tree"
    private static let cache = CatalogueCache()

    func search(_ options: CatalogSearchOptions, page: Int, transport: CatalogTransport) async throws -> RemoteSearchPage {
        let tree = try await Self.cache.tree(using: transport, force: false)
        let catalogue = try await Self.cache.catalogue(for: tree, using: transport)
        let query = options.trimmedQuery
        let matches = catalogue.wallpapers.filter { item in
            query.isEmpty || [item.title, item.uploader, item.wallpaperID].compactMap { $0 }.contains {
                $0.localizedStandardContains(query)
            }
        }
        let size = 20
        let currentPage = max(1, page)
        let lastPage = max(1, (matches.count + size - 1) / size)
        let rows = currentPage <= lastPage ? Array(matches.dropFirst((currentPage - 1) * size).prefix(size)) : []
        return RemoteSearchPage(wallpapers: rows, currentPage: currentPage, lastPage: lastPage, total: matches.count,
                                rateLimit: ProviderRateLimit(limit: nil, remaining: nil, resetDate: nil),
                                hiddenCount: query.isEmpty && currentPage == 1 ? catalogue.hidden : 0)
    }

    func refresh(_ reference: WallpaperReference, transport: CatalogTransport) async throws -> WallpaperReference {
        guard reference.providerIdentifier == id.rawValue, Self.validPackage(reference.wallpaperID) else {
            throw RemoteProviderError.notOpenAccess
        }
        let tree = try await Self.cache.tree(using: transport, force: true)
        guard let paths = tree.packages.first(where: { $0.id == reference.wallpaperID }),
              let current = try await Self.reference(paths, revision: tree.sha, using: transport, revalidate: true) else {
            throw RemoteProviderError.notOpenAccess
        }
        return current
    }

    func allowsMedia(_ url: URL, id: String, original: Bool) -> Bool {
        guard Self.validPackage(id), let parts = Self.pathParts(url, host: "raw.githubusercontent.com"),
              parts.count == (original ? 8 : 7), Array(parts[1...2]) == ["KDE", "plasma-workspace-wallpapers"],
              Self.validRevision(parts[3]), parts[4] == id, parts[5] == "contents" else { return false }
        if original {
            return parts[6] == "images" && Self.dimensions(for: parts[7]) != nil
        }
        return Self.previewNames.contains(parts[6])
    }

    func allowsPage(_ url: URL, id: String) -> Bool {
        guard Self.validPackage(id), let parts = Self.pathParts(url, host: "github.com"),
              parts.count == 6, Array(parts[1...3]) == ["KDE", "plasma-workspace-wallpapers", "tree"],
              Self.validRevision(parts[4]), parts[5] == id else { return false }
        return url.absoluteString == "\(Self.pageRoot)/\(parts[4])/\(id)"
    }

    private static func pathParts(_ url: URL, host: String) -> [String]? {
        guard CatalogURL.isHTTPS(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == host, components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == components.path else { return nil }
        return components.path.components(separatedBy: "/")
    }

    private static func validRevision(_ value: String) -> Bool {
        value.range(of: #"^[a-f0-9]{40}\z"#, options: .regularExpression) != nil
    }

    private static func validPackage(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{1,64}\z"#, options: .regularExpression) != nil
    }

    private static let previewNames: Set<String> = ["screenshot.jpg", "screenshot.jpeg", "screenshot.png"]

    private static func dimensions(for name: String) -> (width: Int, height: Int)? {
        guard name.range(of: #"^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}\.(jpg|jpeg|png)\z"#, options: .regularExpression) != nil
        else { return nil }
        let parts = name.split(whereSeparator: { $0 == "x" || $0 == "." })
        guard let width = Int(parts[0]), let height = Int(parts[1]),
              width >= 1280, height >= 720, width >= height, width <= 8192, height <= 8192,
              width * height <= 40_000_000 else { return nil }
        return (width, height)
    }

    private struct Tree: Decodable {
        struct Entry: Decodable {
            let path: String
            let type: String
            let mode: String
            let size: Int?
        }

        let sha: String
        let truncated: Bool
        let tree: [Entry]

        var packages: [PackagePaths] {
            let files = tree.filter { $0.type == "blob" && $0.mode == "100644" }
            let grouped = Dictionary(grouping: files) { $0.path.split(separator: "/").first.map(String.init) ?? "" }
            return grouped.keys.sorted().compactMap { id in
                guard PlasmaCatalogAdapter.validPackage(id), let files = grouped[id],
                      files.contains(where: { $0.path == "\(id)/metadata.json" }) else { return nil }
                return PackagePaths(id: id, files: files)
            }
        }
    }

    private struct PackagePaths {
        let id: String
        let files: [Tree.Entry]

        var preview: String? {
            files.first {
                let relativePath = $0.path.components(separatedBy: "/")
                return relativePath.count == 3 && relativePath[1] == "contents" &&
                    PlasmaCatalogAdapter.previewNames.contains(relativePath[2]) &&
                    (1_024...1_500_000).contains($0.size ?? 0)
            }?.path
        }

        var original: (path: String, width: Int, height: Int)? {
            files.compactMap { file -> (path: String, width: Int, height: Int)? in
                let parts = file.path.components(separatedBy: "/")
                guard parts.count == 4, parts[1] == "contents", parts[2] == "images",
                      // A Git symlink or LFS stub is not an image rendition.
                      (1_024...40_000_000).contains(file.size ?? 0),
                      let dimensions = PlasmaCatalogAdapter.dimensions(for: parts[3]) else { return nil }
                return (file.path, dimensions.width, dimensions.height)
            }.max {
                ($0.width * $0.height, $0.path) < ($1.width * $1.height, $1.path)
            }
        }
    }

    private struct PackageMetadata: Decodable {
        struct Plugin: Decodable {
            struct Author: Decodable {
                let name: String?
                enum CodingKeys: String, CodingKey { case name = "Name" }
            }

            let name: String
            let license: String
            let authors: [Author]

            enum CodingKeys: String, CodingKey {
                case name = "Name"
                case license = "License"
                case authors = "Authors"
            }
        }

        let plugin: Plugin
        enum CodingKeys: String, CodingKey { case plugin = "KPlugin" }
    }

    private struct License {
        let name: String
        let version: String
        let url: URL

        init?(_ source: String) {
            switch source.lowercased() {
            case "cc-by-4.0":
                name = "CC BY"; version = "4.0"; url = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
            case "cc-by-sa-4.0":
                name = "CC BY-SA"; version = "4.0"; url = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
            case "cc0-1.0":
                name = "CC0"; version = "1.0"; url = URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!
            case "lgplv3", "lgpl-3.0-only":
                name = "LGPL"; version = "3.0"; url = URL(string: "https://www.gnu.org/licenses/lgpl-3.0.html")!
            case "gplv3", "gpl-3.0-only":
                name = "GPL"; version = "3.0"; url = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
            default:
                return nil
            }
        }
    }

    private static func reference(
        _ paths: PackagePaths, revision: String, using transport: CatalogTransport, revalidate: Bool
    ) async throws -> WallpaperReference? {
        guard let preview = paths.preview, let original = paths.original else { return nil }
        let base = "\(rawRoot)/\(revision)"
        let address = URL(string: "\(base)/\(paths.id)/metadata.json")!
        let metadata: PackageMetadata.Plugin
        do {
            metadata = try await transport.json(PackageMetadata.self, from: address, maximumBytes: 32_768,
                                                revalidate: revalidate).plugin
        } catch RemoteProviderError.httpStatus(404) {
            return nil
        } catch RemoteProviderError.invalidData {
            return nil
        } catch is DecodingError {
            return nil
        }
        let title = DisplayText.clean(metadata.name)
        let names = metadata.authors.map { DisplayText.clean($0.name) }.filter { !$0.isEmpty }
        guard !title.isEmpty, !names.isEmpty, let license = License(metadata.license) else { return nil }
        let credit = names.joined(separator: ", ")
        let previewURL = URL(string: "\(base)/\(preview)")!
        return WallpaperReference(
            providerIdentifier: RemoteProviderID.plasma.rawValue, wallpaperID: paths.id,
            sourcePageURL: URL(string: "\(pageRoot)/\(revision)/\(paths.id)")!,
            originalURL: URL(string: "\(base)/\(original.path)")!,
            previewURL: previewURL, thumbnailURL: previewURL, width: original.width, height: original.height,
            uploader: credit, tags: [], cachedLocalPath: nil, title: title,
            license: license.name, licenseVersion: license.version, licenseURL: license.url,
            catalog: CatalogRecord(credit: credit)
        )
    }

    private struct Catalogue {
        let wallpapers: [WallpaperReference]
        let hidden: Int

        static func load(_ tree: Tree, using transport: CatalogTransport) async throws -> Catalogue {
            let packages = tree.packages
            var wallpapers: [WallpaperReference] = []
            for index in stride(from: 0, to: packages.count, by: 4) {
                let batch = try await withThrowingTaskGroup(of: WallpaperReference?.self) { group in
                    for paths in packages[index..<min(index + 4, packages.count)] {
                        group.addTask { try await PlasmaCatalogAdapter.reference(paths, revision: tree.sha, using: transport, revalidate: false) }
                    }
                    return try await group.reduce(into: [WallpaperReference]()) { items, item in
                        if let item { items.append(item) }
                    }
                }
                wallpapers.append(contentsOf: batch)
            }
            wallpapers.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
            return Catalogue(wallpapers: wallpapers, hidden: packages.count - wallpapers.count)
        }
    }

    private actor CatalogueCache {
        private var currentTree: Tree?
        private var etag: String?
        private var checkedAt = Date.distantPast
        private var loadingTree: Task<(Tree, String?), Error>?
        private var lastCatalogue: (revision: String, catalogue: Catalogue)?
        private var loadingCatalogues: [String: Task<Catalogue, Error>] = [:]

        func tree(using transport: CatalogTransport, force: Bool) async throws -> Tree {
            if !force, let currentTree, Date().timeIntervalSince(checkedAt) < 300 { return currentTree }
            if let loadingTree { return try await loadingTree.value.0 }

            let previous = currentTree
            let previousETag = etag
            let task = Task {
                let response = try await transport.conditionalBytes(from: PlasmaCatalogAdapter.treeURL, etag: previousETag)
                guard let data = response.data else {
                    guard let previous else { throw RemoteProviderError.invalidResponse }
                    return (previous, response.etag ?? previousETag)
                }
                let tree = try JSONDecoder().decode(Tree.self, from: data)
                guard PlasmaCatalogAdapter.validRevision(tree.sha), !tree.truncated else {
                    throw RemoteProviderError.invalidData
                }
                return (tree, response.etag)
            }
            loadingTree = task
            defer { loadingTree = nil }
            let (tree, tag) = try await task.value
            currentTree = tree
            etag = tag
            checkedAt = Date()
            return tree
        }

        func catalogue(for tree: Tree, using transport: CatalogTransport) async throws -> Catalogue {
            if let lastCatalogue, lastCatalogue.revision == tree.sha { return lastCatalogue.catalogue }
            if let task = loadingCatalogues[tree.sha] { return try await task.value }
            let task = Task { try await Catalogue.load(tree, using: transport) }
            loadingCatalogues[tree.sha] = task
            defer { loadingCatalogues[tree.sha] = nil }
            let catalogue = try await task.value
            if currentTree?.sha == tree.sha { lastCatalogue = (tree.sha, catalogue) }
            return catalogue
        }
    }
}
