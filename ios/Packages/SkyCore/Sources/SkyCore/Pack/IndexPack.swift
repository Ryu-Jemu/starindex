import Foundation

// Codable mirrors of what backend `PackPublisher` writes (SERVICE-PLAN 8.3):
// - manifest `packs/manifest/latest.json` (schema 1), golden copy `contracts/golden/manifest-v1.json`
// - index pack `packs/index/<version>/index.json.gz` (schema 2), golden copy `contracts/golden/index-pack-v2.json`
//
// Decoding is deliberately tolerant: unknown keys are ignored (packs only ever gain fields, SERVICE-PLAN 8.3),
// and every field the producer can write as null is optional here. Only what the app cannot work without is
// required (version, nightDate, regions with id and name; path and sha256 in the manifest).

/// `packs/manifest/latest.json`.
public struct PackManifest: Codable, Sendable, Equatable {
    public var schema: Int
    /// When the manifest was last written (ISO-8601 with offset). Drives the "stale" warning.
    public var generatedAt: String?
    public var packs: Packs

    public struct Packs: Codable, Sendable, Equatable {
        public var index: Entry?
    }

    /// One published pack: where it is and what its compressed bytes must hash to.
    public struct Entry: Codable, Sendable, Equatable {
        public var version: String
        /// Relative to the CDN root, e.g. `packs/index/20261012-1700-b2a3bf8b/index.json.gz`.
        public var path: String
        /// Lowercase hex SHA-256 of the COMPRESSED bytes (what is downloaded).
        public var sha256: String
        public var bytes: Int?
        public var nightDate: String?
        public var issuedAt: String?

        public init(version: String, path: String, sha256: String, bytes: Int?, nightDate: String?, issuedAt: String?) {
            self.version = version
            self.path = path
            self.sha256 = sha256
            self.bytes = bytes
            self.nightDate = nightDate
            self.issuedAt = issuedAt
        }
    }

    public var generatedDate: Date? { generatedAt.flatMap(PackTime.parse) }

    public static func decode(_ data: Data) throws -> PackManifest {
        try JSONDecoder().decode(PackManifest.self, from: data)
    }
}

/// The nationwide index pack (schema 2).
public struct IndexPack: Codable, Sendable, Equatable {
    public var schema: Int
    public var kind: String?
    public var version: String
    /// "yyyy-MM-dd": the night (KST, 12:00 → 12:00) the scores are for.
    public var nightDate: String
    /// Base time of the newest KMA forecast used (null when no forecast was stored).
    public var issuedAt: String?
    public var hourlyStep: Int?
    /// Required by the data licenses; shown in the index sheet.
    public var attribution: [String]
    public var regions: [IndexRegion]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        version = try c.decode(String.self, forKey: .version)
        nightDate = try c.decode(String.self, forKey: .nightDate)
        issuedAt = try c.decodeIfPresent(String.self, forKey: .issuedAt)
        hourlyStep = try c.decodeIfPresent(Int.self, forKey: .hourlyStep)
        attribution = try c.decodeIfPresent([String].self, forKey: .attribution) ?? []
        regions = try c.decode([IndexRegion].self, forKey: .regions)
    }

    public var issuedDate: Date? { issuedAt.flatMap(PackTime.parse) }
    public var night: NightDate? { NightDate(nightDate) }

    public static func decode(json: Data) throws -> IndexPack {
        try JSONDecoder().decode(IndexPack.self, from: json)
    }
}

public struct IndexRegion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// "SIDO" or "EXTRA" today; free text so a new kind does not break decoding.
    public var kind: String?
    /// KMA grid [nx, ny].
    public var grid: [Int]?
    /// 0…100; null when no dark hour had a forecast (reasons then holds `NO_FORECAST`).
    public var score: Int?
    /// POOR / FAIR / GOOD / EXCELLENT (`StarIndexCalculator.Grade`).
    public var grade: String?
    /// Best two-hour window as ["HHmm", "HHmm"] (KST).
    public var best: [String]?
    public var reasons: [String]
    /// Share of each factor in the score's shortfall (cloud, precip, moon, light).
    public var contrib: [String: Double]?
    public var twilight: Twilight?
    public var hourly: Hourly?

    public init(id: String, name: String, kind: String? = nil, grid: [Int]? = nil, score: Int? = nil, grade: String? = nil,
                best: [String]? = nil, reasons: [String] = [], contrib: [String: Double]? = nil,
                twilight: Twilight? = nil, hourly: Hourly? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.grid = grid
        self.score = score
        self.grade = grade
        self.best = best
        self.reasons = reasons
        self.contrib = contrib
        self.twilight = twilight
        self.hourly = hourly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        grid = try c.decodeIfPresent([Int].self, forKey: .grid)
        score = try c.decodeIfPresent(Int.self, forKey: .score)
        grade = try c.decodeIfPresent(String.self, forKey: .grade)
        best = try c.decodeIfPresent([String].self, forKey: .best)
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        contrib = try c.decodeIfPresent([String: Double].self, forKey: .contrib)
        twilight = try c.decodeIfPresent(Twilight.self, forKey: .twilight)
        hourly = try c.decodeIfPresent(Hourly.self, forKey: .hourly)
    }

    /// Evening/morning times as "HHmm" (KST). Any of them is null where the event does not happen.
    public struct Twilight: Codable, Sendable, Equatable {
        /// KASI (천문연) evening times when the backend stored them; null otherwise.
        public var kasi: Times?
        /// Astronomy Engine times computed by the backend; always present.
        public var computed: Times?

        public init(kasi: Times? = nil, computed: Times? = nil) {
            self.kasi = kasi
            self.computed = computed
        }

        public struct Times: Codable, Sendable, Equatable {
            public var sunset: String?
            /// End of civil / nautical / astronomical dusk.
            public var civile: String?
            public var naute: String?
            public var aste: String?
            /// Start of astronomical dawn (computed only).
            public var astm: String?
            public var sunrise: String?

            public init(sunset: String? = nil, civile: String? = nil, naute: String? = nil, aste: String? = nil,
                        astm: String? = nil, sunrise: String? = nil) {
                self.sunset = sunset
                self.civile = civile
                self.naute = naute
                self.aste = aste
                self.astm = astm
                self.sunrise = sunrise
            }
        }
    }

    /// Hourly KMA series from `t0` (12:00 KST of the night date), one slot per `hourlyStep` hour; null = no forecast.
    public struct Hourly: Codable, Sendable, Equatable {
        public var t0: String?
        public var sky: [Double?]?
        public var pty: [Double?]?
        public var tmp: [Double?]?
        public var reh: [Double?]?
        public var wsd: [Double?]?
        public var pop: [Double?]?

        public init(t0: String?, sky: [Double?]? = nil, pty: [Double?]? = nil, tmp: [Double?]? = nil,
                    reh: [Double?]? = nil, wsd: [Double?]? = nil, pop: [Double?]? = nil) {
            self.t0 = t0
            self.sky = sky
            self.pty = pty
            self.tmp = tmp
            self.reh = reh
            self.wsd = wsd
            self.pop = pop
        }
    }

    /// (nx, ny) when the grid field is well formed.
    public var gridCell: (nx: Int, ny: Int)? {
        guard let g = grid, g.count == 2 else { return nil }
        return (g[0], g[1])
    }
}
