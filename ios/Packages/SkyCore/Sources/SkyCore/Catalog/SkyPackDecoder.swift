import Foundation
import simd

/// Decoded skypack (see docs/skypack-format.md). Produced by backend/tools/catalog-builder.
public struct SkyCatalog: Sendable {
    public struct Star: Sendable {
        /// J2000 unit vector at the pack epoch (proper motion applied).
        public let j2000: SIMD3<Float>
        public let magnitude: Float
        /// B−V mapped to 0…255 over [−0.4, 2.0].
        public let bvIndex: UInt8
        public let flags: UInt8
        public let hr: UInt16
        public let name: String?
        /// Vertex used only by a stick figure; never drawn as a star.
        public var isLineOnly: Bool { flags & 1 != 0 }
    }

    public struct Constellation: Sendable {
        public let abbr: String
        public let nameKo: String?
        public let nameLatin: String?
        /// Label anchor: normalized mean of the figure's vertices (J2000).
        public let anchor: SIMD3<Float>
    }

    public struct Segment: Sendable {
        public let constellation: Int
        public let a: Int
        public let b: Int
    }

    public let version: Int
    public let epoch: Float
    public let magLimit: Float
    public let stars: [Star]
    public let constellations: [Constellation]
    public let segments: [Segment]
}

public enum SkyPackDecoder {
    public enum DecodeError: Error, Equatable {
        case badMagic, unsupportedVersion(Int), truncated, trailingBytes, badString
    }

    public static func decode(_ data: Data) throws -> SkyCatalog {
        try data.withUnsafeBytes { raw -> SkyCatalog in
            var o = 0
            func need(_ n: Int) throws { if o + n > raw.count { throw DecodeError.truncated } }
            func u8() throws -> UInt8 { try need(1); defer { o += 1 }; return raw[o] }
            func u16() throws -> UInt16 { try need(2); defer { o += 2 }; return UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
            func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
            func u32() throws -> UInt32 { try need(4); defer { o += 4 }; return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
            func f32() throws -> Float { Float(bitPattern: try u32()) }

            try need(4)
            guard raw[0] == 0x53, raw[1] == 0x4B, raw[2] == 0x59, raw[3] == 0x50 else { throw DecodeError.badMagic } // "SKYP"
            o = 4
            let version = Int(try u16())
            guard version == 1 else { throw DecodeError.unsupportedVersion(version) }
            _ = try u16()
            let epoch = try f32(), magLimit = try f32()
            let nStars = Int(try u32()), nConst = Int(try u32()), nSeg = Int(try u32()), nStr = Int(try u32())

            struct RawStar { let v: SIMD3<Float>; let mag: Int16; let bv: UInt8; let flags: UInt8; let hr: UInt16; let name: Int32 }
            var rawStars: [RawStar] = []
            rawStars.reserveCapacity(nStars)
            for _ in 0..<nStars {
                let x = try f32(), y = try f32(), z = try f32()
                let mag = try i16(), bv = try u8(), flags = try u8(), hr = try u16()
                _ = try u16()
                rawStars.append(RawStar(v: SIMD3(x, y, z), mag: mag, bv: bv, flags: flags, hr: hr, name: try i32()))
            }
            struct RawConst { let abbr: String; let ko: Int32; let la: Int32; let anchor: SIMD3<Float> }
            var rawConsts: [RawConst] = []
            for _ in 0..<nConst {
                try need(4)
                let bytes = (0..<4).map { raw[o + $0] }.filter { $0 != 0 }
                o += 4
                let abbr = String(decoding: bytes, as: UTF8.self)
                let ko = try i32(), la = try i32()
                rawConsts.append(RawConst(abbr: abbr, ko: ko, la: la, anchor: SIMD3(try f32(), try f32(), try f32())))
            }
            var segments: [SkyCatalog.Segment] = []
            segments.reserveCapacity(nSeg)
            for _ in 0..<nSeg {
                let c = Int(try u16())
                _ = try u16()
                segments.append(.init(constellation: c, a: Int(try u16()), b: Int(try u16())))
            }
            var strings: [String] = []
            strings.reserveCapacity(nStr)
            for _ in 0..<nStr {
                let len = Int(try u16())
                try need(len)
                guard let s = String(bytes: UnsafeRawBufferPointer(rebasing: raw[o..<(o + len)]), encoding: .utf8) else {
                    throw DecodeError.badString
                }
                strings.append(s)
                o += len
            }
            guard o == raw.count else { throw DecodeError.trailingBytes }
            func str(_ i: Int32) -> String? { i >= 0 && Int(i) < strings.count ? strings[Int(i)] : nil }

            return SkyCatalog(
                version: version, epoch: epoch, magLimit: magLimit,
                stars: rawStars.map { .init(j2000: $0.v, magnitude: Float($0.mag) / 100, bvIndex: $0.bv,
                                             flags: $0.flags, hr: $0.hr, name: str($0.name)) },
                constellations: rawConsts.map { .init(abbr: $0.abbr, nameKo: str($0.ko), nameLatin: str($0.la), anchor: $0.anchor) },
                segments: segments)
        }
    }
}
