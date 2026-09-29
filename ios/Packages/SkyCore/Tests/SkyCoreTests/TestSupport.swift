import Foundation
import simd
@testable import SkyCore

func utc(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
}

/// J2000 unit vector from RA (hours) / Dec (degrees).
func j2000(raHours: Double, decDeg: Double) -> SIMD3<Double> {
    let a = raHours * 15 * Double.pi / 180, d = decDeg * Double.pi / 180
    return SIMD3(cos(d) * cos(a), cos(d) * sin(a), sin(d))
}

func angleDeg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let c = simd_dot(simd_normalize(a), simd_normalize(b))
    return acos(max(-1, min(1, c))) * 180 / Double.pi
}

/// Device→reference matrix from device axes expressed in the horizontal frame;
/// A (reference→device) is its transpose.
func attitude(x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>) -> simd_double3x3 {
    simd_double3x3(columns: (x, y, z)).transpose
}

let N = SIMD3<Double>(1, 0, 0), W = SIMD3<Double>(0, 1, 0), U = SIMD3<Double>(0, 0, 1)
let S = -N, E = -W

let observers: [ObserverLocation] = [
    .seoul,
    ObserverLocation(latitude: 33.4996, longitude: 126.5312),   // Jeju
    ObserverLocation(latitude: 60.1699, longitude: 24.9384),    // Helsinki (60°N)
    ObserverLocation(latitude: 0.0, longitude: 0.0),            // equator
    ObserverLocation(latitude: -33.8688, longitude: 151.2093),  // Sydney
]

let sampleDates: [Date] = [
    utc("2026-10-01T12:00:00Z"), utc("2026-12-21T09:30:00Z"),
    utc("2027-03-20T15:00:00Z"), utc("2027-06-21T21:00:00Z"),
]
