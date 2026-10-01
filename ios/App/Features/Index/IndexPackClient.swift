import Foundation
import SkyCore

/// A verified, decoded pack plus what the manifest said about it.
struct LoadedIndexPack: Sendable, Equatable {
    var pack: IndexPack
    var entry: PackManifest.Entry
    /// Manifest `generatedAt` (drives the 6 h "stale" badge).
    var generatedAt: Date?
}

/// Last good pack on disk (`Caches/IndexPack/`), so the chip works offline and right at a cold start.
///
/// Layout: `index-<version>.json.gz` (the exact downloaded bytes) and `meta.json` (manifest entry, validators).
/// The pack file is written first under its own name and `meta.json` is replaced atomically afterwards, so a
/// crash in between leaves the previous pair intact. Loading re-verifies the SHA-256, so a damaged file is
/// dropped instead of shown. Caches may be purged by iOS; the next refresh simply downloads again.
struct IndexPackCache: Sendable {
    struct Meta: Codable, Sendable, Equatable {
        var entry: PackManifest.Entry
        var generatedAt: String?
        /// Server the validators belong to (Debug and Release talk to different hosts).
        var baseURL: String
        var etag: String?
        var lastModified: String?
        var savedAt: Date
    }

    let directory: URL

    static var standard: IndexPackCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return IndexPackCache(directory: caches.appending(path: "IndexPack", directoryHint: .isDirectory))
    }

    private var metaURL: URL { directory.appending(path: "meta.json") }
    private func packURL(_ version: String) -> URL { directory.appending(path: "index-\(version).json.gz") }

    func load() -> (meta: Meta, loaded: LoadedIndexPack)? {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              IndexPackDecoder.isSafeRelativePath("index-\(meta.entry.version).json.gz"),
              let gz = try? Data(contentsOf: packURL(meta.entry.version)),
              let pack = try? IndexPackDecoder.decode(gzipped: gz, entry: meta.entry) else { return nil }
        return (meta, LoadedIndexPack(pack: pack, entry: meta.entry, generatedAt: meta.generatedAt.flatMap(PackTime.parse)))
    }

    func save(gzipped: Data, meta: Meta) throws {
        // Same rule as load(): the version names a file in our directory, never a path.
        guard IndexPackDecoder.isSafeRelativePath("index-\(meta.entry.version).json.gz") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try gzipped.write(to: packURL(meta.entry.version), options: .atomic)
        try saveMeta(meta)
        // Older packs are no longer referenced.
        let keep = packURL(meta.entry.version).lastPathComponent
        for f in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where f.hasPrefix("index-") && f != keep {
            try? FileManager.default.removeItem(at: directory.appending(path: f))
        }
    }

    func saveMeta(_ meta: Meta) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }
}

/// Downloads the manifest and, when its index entry changed, the pack (PLAN 3.2 `ManifestClient`/`PackStore`).
///
/// Privacy (D4, SERVICE-PLAN 8.5): only two static GETs with fixed paths — no query, no coordinates, no grid cell,
/// no region id, no device identifier. The region is chosen on the device from the nationwide pack.
actor IndexPackClient {
    enum FetchError: Error, Equatable, Sendable {
        /// No connection, DNS failure, timeout… (a cached pack is shown as "offline").
        case offline
        /// Other URLError (code), e.g. ATS refusing plain HTTP to a non-local host.
        case network(Int)
        case http(Int)
        case badManifest
        case unsafePath
        case integrity(String)
    }

    enum Update: Sendable {
        /// The manifest still points at the pack we have (304, or same version); generatedAt may have moved.
        case unchanged(generatedAt: Date?)
        case newPack(LoadedIndexPack)
    }

    static let manifestPath = "packs/manifest/latest.json"

    let base: URL
    private let cache: IndexPackCache
    private let session: URLSession
    /// What is on disk (and in the store): source of the conditional-request validators.
    private var meta: IndexPackCache.Meta?
    /// `Cache-Control: max-age` of the last manifest response (CloudFront sends 60).
    private(set) var manifestMaxAge: TimeInterval = 60

    init(base: URL, cache: IndexPackCache, meta: IndexPackCache.Meta?) {
        self.base = base
        self.cache = cache
        self.meta = meta
        let config = URLSessionConfiguration.ephemeral
        // HTTP caching is done explicitly with validators below; URLCache would answer 304s with stale bodies.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10          // SERVICE-PLAN 4.6: "받는 중" turns into "없음" after ~10 s
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    private func url(_ path: String) -> URL {
        URL(string: base.absoluteString.trimmingSuffix("/") + "/" + path)!
    }

    func refresh() async -> Result<Update, FetchError> {
        do {
            return .success(try await fetch())
        } catch let e as FetchError {
            return .failure(e)
        } catch let e as URLError {
            return .failure(Self.isConnectivity(e) ? .offline : .network(e.code.rawValue))
        } catch {
            return .failure(.offline)
        }
    }

    private func fetch() async throws -> Update {
        var req = URLRequest(url: url(Self.manifestPath))
        if let m = meta, m.baseURL == base.absoluteString {
            // If-None-Match wins when both are sent (RFC 9110 13.2.2): CloudFront/S3 use the ETag,
            // python http.server (scripts/serve-packs.sh) only Last-Modified.
            if let etag = m.etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lm = m.lastModified { req.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
        }
        let (body, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badManifest }
        manifestMaxAge = Self.maxAge(http.value(forHTTPHeaderField: "Cache-Control")) ?? 60

        if http.statusCode == 304, let m = meta {
            return .unchanged(generatedAt: m.generatedAt.flatMap(PackTime.parse))
        }
        guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
        guard let manifest = try? PackManifest.decode(body), let entry = manifest.packs.index else {
            throw FetchError.badManifest
        }
        var next = IndexPackCache.Meta(entry: entry, generatedAt: manifest.generatedAt, baseURL: base.absoluteString,
                                       etag: http.value(forHTTPHeaderField: "ETag"),
                                       lastModified: http.value(forHTTPHeaderField: "Last-Modified"), savedAt: Date())

        if let m = meta, m.entry.version == entry.version, m.entry.sha256 == entry.sha256 {
            try? cache.saveMeta(next)
            meta = next
            return .unchanged(generatedAt: manifest.generatedDate)
        }

        guard IndexPackDecoder.isSafeRelativePath(entry.path) else { throw FetchError.unsafePath }
        // Pack paths are immutable (version in the path): the default policy is fine, but keep it explicit.
        let (gz, packResponse) = try await session.data(from: url(entry.path))
        guard let ph = packResponse as? HTTPURLResponse else { throw FetchError.badManifest }
        guard ph.statusCode == 200 else { throw FetchError.http(ph.statusCode) }
        let pack: IndexPack
        do {
            pack = try IndexPackDecoder.decode(gzipped: gz, entry: entry)
        } catch {
            throw FetchError.integrity(String(describing: error))
        }
        next.savedAt = Date()
        try? cache.save(gzipped: gz, meta: next)       // a full disk must not hide a good pack from the screen
        meta = next
        return .newPack(LoadedIndexPack(pack: pack, entry: entry, generatedAt: manifest.generatedDate))
    }

    static func maxAge(_ cacheControl: String?) -> TimeInterval? {
        guard let cc = cacheControl else { return nil }
        for part in cc.split(separator: ",") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "max-age", let v = Double(kv[1]) { return max(0, v) }
        }
        return nil
    }

    static func isConnectivity(_ e: URLError) -> Bool {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed:
            true
        default:
            false
        }
    }
}

private extension String {
    func trimmingSuffix(_ s: String) -> String {
        var r = self
        while r.hasSuffix(s) { r.removeLast(s.count) }
        return r
    }
}
