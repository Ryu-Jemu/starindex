import Foundation

/// Converts WGS84 lat/lon to the KMA short-range forecast grid (nx, ny) using the Lambert
/// Conformal Conic projection published in the KMA 단기예보 활용가이드
/// (Re = 6371.00877 km, grid 5 km, standard parallels 30°/60°, origin 38°N 126°E at (43, 136)).
public enum KMAGrid {
    static let re = 6371.00877, grid = 5.0
    static let slat1 = 30.0, slat2 = 60.0, olon = 126.0, olat = 38.0
    static let xo = 43.0, yo = 136.0

    public static func toGrid(latitude: Double, longitude: Double) -> (nx: Int, ny: Int) {
        let d = Double.pi / 180
        let reG = re / grid
        let s1 = slat1 * d, s2 = slat2 * d, oL = olon * d, oA = olat * d
        var sn = tan(Double.pi * 0.25 + s2 * 0.5) / tan(Double.pi * 0.25 + s1 * 0.5)
        sn = log(cos(s1) / cos(s2)) / log(sn)
        var sf = tan(Double.pi * 0.25 + s1 * 0.5)
        sf = pow(sf, sn) * cos(s1) / sn
        var ro = tan(Double.pi * 0.25 + oA * 0.5)
        ro = reG * sf / pow(ro, sn)
        var ra = tan(Double.pi * 0.25 + latitude * d * 0.5)
        ra = reG * sf / pow(ra, sn)
        var theta = longitude * d - oL
        if theta > Double.pi { theta -= 2 * Double.pi }
        if theta < -Double.pi { theta += 2 * Double.pi }
        theta *= sn
        let x = floor(ra * sin(theta) + xo + 0.5)
        let y = floor(ro - ra * cos(theta) + yo + 0.5)
        return (Int(x), Int(y))
    }
}

/// Magnetic declination (degrees, east positive) used only by the `.cmMagnetic` fallback.
/// Values come from the NOAA WMM calculator; entries are added only when verified (gate G4).
public enum DeclinationTable {
    public struct Entry: Sendable { public let id: String; public let nameKo: String; public let declinationDeg: Double }

    /// Seoul −9.02° (NOAA WMM, verified 2026-09-29). Remaining 시·도 and overseas examples are
    /// filled from `data/declination.csv` once verified.
    public static let entries: [Entry] = [
        Entry(id: "seoul", nameKo: "서울", declinationDeg: -9.02),
    ]

    public static func declination(id: String) -> Double? {
        entries.first { $0.id == id }?.declinationDeg
    }
}
