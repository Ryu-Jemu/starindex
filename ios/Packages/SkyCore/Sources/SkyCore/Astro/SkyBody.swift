import CAstronomy

/// Solar-system bodies the sky view renders.
public enum SkyBody: String, CaseIterable, Sendable {
    case sun, moon, mercury, venus, mars, jupiter, saturn, uranus, neptune

    var cBody: astro_body_t {
        switch self {
        case .sun: return BODY_SUN
        case .moon: return BODY_MOON
        case .mercury: return BODY_MERCURY
        case .venus: return BODY_VENUS
        case .mars: return BODY_MARS
        case .jupiter: return BODY_JUPITER
        case .saturn: return BODY_SATURN
        case .uranus: return BODY_URANUS
        case .neptune: return BODY_NEPTUNE
        }
    }

    /// Korean display name.
    public var nameKo: String {
        switch self {
        case .sun: return "태양"
        case .moon: return "달"
        case .mercury: return "수성"
        case .venus: return "금성"
        case .mars: return "화성"
        case .jupiter: return "목성"
        case .saturn: return "토성"
        case .uranus: return "천왕성"
        case .neptune: return "해왕성"
        }
    }
}

/// Observer on the Earth's surface. Latitude/longitude in degrees, height in meters.
public struct ObserverLocation: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var heightMeters: Double

    public init(latitude: Double, longitude: Double, heightMeters: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.heightMeters = heightMeters
    }

    var cObserver: astro_observer_t {
        Astronomy_MakeObserver(latitude, longitude, heightMeters)
    }

    public static let seoul = ObserverLocation(latitude: 37.5665, longitude: 126.9780, heightMeters: 38)
}
