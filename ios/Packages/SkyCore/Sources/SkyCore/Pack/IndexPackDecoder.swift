import CryptoKit
import Foundation

/// Downloaded bytes → verified, decoded `IndexPack` (PLAN 3.2 `PackStore`: sha256 over the COMPRESSED bytes).
/// The order matters: nothing from the network is inflated or parsed before its hash matches the manifest.
public enum IndexPackDecoder {
    public enum Failure: Error, Equatable, Sendable {
        case sizeMismatch(expected: Int, actual: Int)
        case shaMismatch
        case gzip(Gzip.DecodeError)
        case json(String)
        /// The pack's own version/kind disagree with the manifest entry that pointed at it.
        case inconsistent(String)
    }

    /// Lowercase hex SHA-256.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Checks size (when the manifest gives one) and SHA-256 of the compressed bytes against the manifest entry.
    public static func verify(_ gzipped: Data, against entry: PackManifest.Entry) throws(Failure) {
        if let expected = entry.bytes, expected != gzipped.count {
            throw .sizeMismatch(expected: expected, actual: gzipped.count)
        }
        guard sha256Hex(gzipped) == entry.sha256.lowercased() else { throw .shaMismatch }
    }

    /// verify → gunzip → decode → cross-check with the entry.
    public static func decode(gzipped: Data, entry: PackManifest.Entry) throws(Failure) -> IndexPack {
        try verify(gzipped, against: entry)
        let json: Data
        do {
            json = try Gzip.decompress(gzipped)
        } catch let e as Gzip.DecodeError {
            throw .gzip(e)
        } catch {
            throw .gzip(.corruptDeflate)
        }
        let pack: IndexPack
        do {
            pack = try IndexPack.decode(json: json)
        } catch {
            throw .json(String(describing: error))
        }
        guard pack.version == entry.version else { throw .inconsistent("version \(pack.version) ≠ manifest \(entry.version)") }
        if let kind = pack.kind, kind != "index" { throw .inconsistent("kind \(kind)") }
        guard pack.night != nil else { throw .inconsistent("nightDate \(pack.nightDate)") }
        return pack
    }

    /// A manifest path is joined onto the CDN base URL, so only plain relative paths are accepted
    /// (no scheme, no leading slash, no `..`, no query): a bad manifest cannot redirect the download elsewhere.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 256, !path.hasPrefix("/") else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        guard path.allSatisfy({ allowed.contains($0) }) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
