import Compression
import Foundation

/// gzip (RFC 1952) decoder for the index pack.
///
/// The pack is served as `Content-Type: application/gzip` without `Content-Encoding`, so URLSession hands us
/// the compressed bytes (the manifest's sha256 is over exactly those) and the app has to gunzip them itself.
///
/// Only single-member files are accepted (what `java.util.zip.GZIPOutputStream` writes). The DEFLATE payload
/// is inflated with Apple's Compression (`COMPRESSION_ZLIB` is raw RFC 1951), which does not report where the
/// DEFLATE stream ended, so the trailer is taken to be the last 8 bytes. Anything else — a second member or
/// junk after the trailer — then fails the CRC32/ISIZE check: the decoder fails closed. One exception: the same
/// member repeated ends with a trailer that matches the first copy and decodes as that one copy. That cannot
/// matter here, because the app inflates only bytes whose SHA-256 already matched the manifest.
public enum Gzip {
    public enum DecodeError: Error, Equatable, Sendable {
        case truncated
        case badMagic
        case unsupportedMethod(UInt8)
        /// FLG bits 5–7 are reserved and must be zero (RFC 1952 2.3.1.2).
        case reservedFlags
        case headerCRCMismatch
        case corruptDeflate
        case crcMismatch
        case sizeMismatch
        /// Inflated output exceeded `maxOutputBytes` (decompression bomb guard).
        case tooLarge
    }

    private enum Flag {
        static let text: UInt8 = 0x01, hcrc: UInt8 = 0x02, extra: UInt8 = 0x04, name: UInt8 = 0x08, comment: UInt8 = 0x10
        static let reserved: UInt8 = 0xE0
    }

    /// - Parameter maxOutputBytes: refuse to inflate beyond this (a nationwide pack is ~35 KB today, ~250 KB at R3).
    public static func decompress(_ data: Data, maxOutputBytes: Int = 32 << 20) throws -> Data {
        let bytes = [UInt8](data)
        let payloadStart = try headerLength(bytes)
        // Smallest member: header + empty DEFLATE block (2 bytes) + 8-byte trailer.
        guard bytes.count >= payloadStart + 2 + 8 else { throw DecodeError.truncated }
        let trailerStart = bytes.count - 8
        let expectedCRC = le32(bytes, trailerStart)
        let expectedSize = le32(bytes, trailerStart + 4)

        let out = try inflateRaw(bytes[payloadStart..<trailerStart], maxOutputBytes: maxOutputBytes)
        // ISIZE is the input size modulo 2^32.
        guard UInt32(truncatingIfNeeded: out.count) == expectedSize else { throw DecodeError.sizeMismatch }
        guard CRC32.checksum(out) == expectedCRC else { throw DecodeError.crcMismatch }
        return Data(out)
    }

    /// Parses the member header (incl. optional FEXTRA/FNAME/FCOMMENT/FHCRC) and returns where DEFLATE data starts.
    static func headerLength(_ b: [UInt8]) throws -> Int {
        guard b.count >= 10 else {
            // Distinguish "not gzip at all" from "cut short" when the magic is visible.
            if b.count >= 2, b[0] != 0x1F || b[1] != 0x8B { throw DecodeError.badMagic }
            throw DecodeError.truncated
        }
        guard b[0] == 0x1F, b[1] == 0x8B else { throw DecodeError.badMagic }
        guard b[2] == 8 else { throw DecodeError.unsupportedMethod(b[2]) }
        let flags = b[3]
        guard flags & Flag.reserved == 0 else { throw DecodeError.reservedFlags }
        var o = 10                                    // MTIME(4) XFL(1) OS(1) follow ID1 ID2 CM FLG
        if flags & Flag.extra != 0 {
            guard o + 2 <= b.count else { throw DecodeError.truncated }
            let xlen = Int(b[o]) | Int(b[o + 1]) << 8
            o += 2 + xlen
            guard o <= b.count else { throw DecodeError.truncated }
        }
        for flag in [Flag.name, Flag.comment] where flags & flag != 0 {
            // Zero-terminated ISO 8859-1 string; its content is irrelevant here.
            guard let end = b[o...].firstIndex(of: 0) else { throw DecodeError.truncated }
            o = end + 1
        }
        if flags & Flag.hcrc != 0 {
            guard o + 2 <= b.count else { throw DecodeError.truncated }
            let stored = UInt16(b[o]) | UInt16(b[o + 1]) << 8
            // CRC16 = the two least significant bytes of the CRC32 of the header so far (RFC 1952 2.3.1).
            guard UInt16(truncatingIfNeeded: CRC32.checksum(b[0..<o])) == stored else { throw DecodeError.headerCRCMismatch }
            o += 2
        }
        return o
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    private static func inflateRaw(_ src: ArraySlice<UInt8>, maxOutputBytes: Int) throws -> [UInt8] {
        let chunk = 64 << 10
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        // compression_stream has no zero-initializer in Swift; init() overwrites every field.
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw DecodeError.corruptDeflate
        }
        defer { compression_stream_destroy(&stream) }

        var out: [UInt8] = []
        out.reserveCapacity(min(maxOutputBytes, max(chunk, src.count * 8)))
        return try src.withUnsafeBufferPointer { input -> [UInt8] in
            guard let base = input.baseAddress, input.count > 0 else { throw DecodeError.truncated }
            stream.src_ptr = base
            stream.src_size = input.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                // FINALIZE: all input is present, so a stream that ends early is an error, not "need more".
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 {
                    guard out.count + produced <= maxOutputBytes else { throw DecodeError.tooLarge }
                    out.append(contentsOf: UnsafeBufferPointer(start: dst, count: produced))
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return out
                case COMPRESSION_STATUS_OK:
                    // No progress with all input consumed means the DEFLATE stream never reached its final block.
                    if produced == 0 && stream.src_size == 0 { throw DecodeError.truncated }
                default:
                    throw DecodeError.corruptDeflate
                }
            }
        }
    }
}

/// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320) as used by the gzip trailer.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
