import CoreGraphics
import Foundation
import simd
import SkyCore

/// What the user tapped / can select.
enum SkyObjectRef: Hashable, Sendable {
    case body(SkyBody)
    case star(Int)
    case constellation(Int)
}

/// Pure draw data for one rendered frame (built on the main actor, consumed by the Canvas).
struct SkyFrame: Sendable {
    struct StarBucket: Sendable {
        var radius: CGFloat
        var color: SIMD3<Double>          // sRGB-encoded 0…1
        var alpha: Double
        var points: [CGPoint]
    }
    struct BodyMark: Sendable {
        var ref: SkyObjectRef
        var point: CGPoint
        var radius: CGFloat
        var color: SIMD3<Double>
        var alpha: Double
        var phaseFraction: Double
        var belowHorizon: Bool
    }
    struct Label: Sendable {
        var text: String
        var point: CGPoint
        var priority: Int
        var color: SIMD3<Double>
        var alpha: Double
    }
    struct HitTarget: Sendable {
        var ref: SkyObjectRef
        var point: CGPoint
        var weight: Double
    }
    struct ShaderInputs: Sendable {
        var rect: CGRect
        var focal: Float
        var rows: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
        var sun: SIMD3<Float>
        var zenith, anti, sunSide, night, ground: SIMD3<Float>
        var misc: SIMD4<Float>            // glowStrength, glowWidth, cloud, nightGlow
    }

    var size: CGSize
    var shader: ShaderInputs
    var starBuckets: [StarBucket]
    var lineSegments: [(CGPoint, CGPoint)]
    var lineAlpha: Double
    var horizon: [[CGPoint]]
    var cardinals: [(String, CGPoint)]
    var bodies: [BodyMark]
    var labels: [Label]
    var hitTargets: [HitTarget]
    var reticleAzimuth: Double
    var reticleAltitude: Double
    var reticleConstellation: String?
}

enum SkyFrameBuilder {
    static let cardinalNames = ["북", "북동", "동", "남동", "남", "남서", "서", "북서"]

    static func build(catalog: SkyCatalog, snapshot s: SkySnapshot, transform ft: FrameTransform,
                      camera: CameraModel, cloud: Double = 0) -> SkyFrame {
        let m = ft.forward
        let mf = simd_float3x3(columns: (SIMD3<Float>(m.columns.0), SIMD3<Float>(m.columns.1), SIMD3<Float>(m.columns.2)))
        func project(_ h: SIMD3<Float>, margin: Double = 5) -> CGPoint? {
            Projector.project(SIMD3<Double>(mf * h), camera: camera, marginDeg: margin).map { CGPoint(x: $0.x, y: $0.y) }
        }

        // Stars → (radius, color, alpha) buckets so the Canvas fills ≤ ~48 paths.
        var buckets: [Int: SkyFrame.StarBucket] = [:]
        var hits: [SkyFrame.HitTarget] = []
        for (i, star) in catalog.stars.enumerated() {
            var a = Double(s.starAlpha[i])
            guard a > 0.02 else { continue }
            let h = s.starsHOR[i]
            guard let p = project(h) else { continue }
            if h.z < 0 { a *= 0.3 }                                   // seen "through" the ground
            let r = max(0.8, 4.2 - 0.6 * Double(star.magnitude))
            let rClass = Int((r * 2).rounded())
            let cClass = colorClass(star.bvIndex)
            let aClass = a > 0.75 ? 2 : (a > 0.4 ? 1 : 0)
            let key = rClass * 100 + cClass * 10 + aClass
            buckets[key, default: .init(radius: CGFloat(rClass) / 2, color: starColors[cClass],
                                        alpha: [0.3, 0.6, 1.0][aClass], points: [])].points.append(p)
            if star.magnitude < 3.0 || star.name != nil {
                hits.append(.init(ref: .star(i), point: p, weight: Double(3.5 - star.magnitude)))
            }
        }

        // Constellation stick figures.
        var segments: [(CGPoint, CGPoint)] = []
        if s.lineAlpha > 0.02 {
            for seg in catalog.segments {
                if let a = project(s.starsHOR[seg.a], margin: 25), let b = project(s.starsHOR[seg.b], margin: 25) {
                    segments.append((a, b))
                }
            }
        }

        // Horizon ring and compass points.
        var horizon: [[CGPoint]] = []
        var current: [CGPoint] = []
        for step in 0...120 {
            let v = SIMD3<Float>(Horizontal.vector(altitudeDeg: 0, azimuthDeg: Double(step) * 3))
            if let p = project(v, margin: 20) { current.append(p) } else if !current.isEmpty { horizon.append(current); current = [] }
        }
        if !current.isEmpty { horizon.append(current) }
        var cardinals: [(String, CGPoint)] = []
        for (k, name) in cardinalNames.enumerated() {
            if let p = project(SIMD3<Float>(Horizontal.vector(altitudeDeg: 0, azimuthDeg: Double(k) * 45))) {
                cardinals.append((name, p))
            }
        }

        // Sun, Moon, planets.
        var bodies: [SkyFrame.BodyMark] = []
        var labels: [SkyFrame.Label] = []
        for b in s.bodies where b.alpha > 0.02 {
            guard let p = project(SIMD3<Float>(b.horizontal)) else { continue }
            let below = b.horizontal.z < 0
            let radius: CGFloat
            let color: SIMD3<Double>
            switch b.body {
            case .sun: radius = 11; color = SIMD3(1.0, 0.93, 0.70)
            case .moon: radius = 10; color = SIMD3(0.94, 0.94, 0.90)
            default: radius = CGFloat(max(2.5, 5.2 - 0.6 * b.magnitude)); color = SIMD3(1.0, 0.95, 0.80)
            }
            bodies.append(.init(ref: .body(b.body), point: p, radius: radius, color: color,
                                alpha: b.alpha * (below ? 0.4 : 1), phaseFraction: b.phaseFraction, belowHorizon: below))
            labels.append(.init(text: b.body.nameKo, point: p, priority: b.body == .sun || b.body == .moon ? 100 : 90,
                                color: SIMD3(1, 0.9, 0.6), alpha: b.alpha * (below ? 0.5 : 1)))
            hits.append(.init(ref: .body(b.body), point: p, weight: 10))
        }

        // Constellation and bright-star names.
        if s.lineAlpha > 0.3 && camera.fovVerticalDeg <= 90 {
            for (i, c) in catalog.constellations.enumerated() {
                guard let p = project(s.anchorsHOR[i]) else { continue }
                labels.append(.init(text: c.nameKo ?? c.abbr, point: p, priority: 70,
                                    color: SIMD3(0.62, 0.74, 1.0), alpha: s.lineAlpha * 0.9))
                hits.append(.init(ref: .constellation(i), point: p, weight: 1))
            }
        }
        for (i, star) in catalog.stars.enumerated() where star.magnitude < 1.5 && star.name != nil && s.starAlpha[i] > 0.3 {
            guard let p = project(s.starsHOR[i]) else { continue }
            labels.append(.init(text: star.name!, point: CGPoint(x: p.x + 6, y: p.y - 6), priority: 60,
                                color: SIMD3(0.9, 0.9, 0.95), alpha: Double(s.starAlpha[i])))
        }

        // Reticle: device −z → HOR (true north) → constellation of the J2000 direction.
        let dDev = Projector.unproject(camera.center, camera: camera)
        let dHOR = ft.toHorizontal(dDev)
        let (ralt, raz) = Horizontal.altAz(dHOR)
        let dEQJ = s.rotation.transpose * Refraction.unrefract(dHOR)
        let abbr = ConstellationLocator.locate(j2000: dEQJ)
        let constellationName = abbr.flatMap { a in catalog.constellations.first { $0.abbr == a }?.nameKo }

        let rows = ft.deviceToHorizontalRows
        let rect = CGRect(origin: .zero, size: CGSize(width: camera.viewportWidth, height: camera.viewportHeight))
        let p = s.palette
        let shader = SkyFrame.ShaderInputs(
            rect: rect, focal: Float(camera.focal),
            rows: (SIMD3<Float>(rows.0), SIMD3<Float>(rows.1), SIMD3<Float>(rows.2)),
            sun: SIMD3<Float>(s.sun.apparentHorizontal),
            zenith: SIMD3<Float>(p.zenith), anti: SIMD3<Float>(p.horizonAnti), sunSide: SIMD3<Float>(p.horizonSun),
            night: SIMD3<Float>(s.night), ground: SIMD3<Float>(s.ground),
            misc: SIMD4<Float>(Float(p.glowStrength), Float(p.glowWidth), Float(cloud), Float(p.nightGlow)))

        return SkyFrame(
            size: rect.size, shader: shader,
            starBuckets: Array(buckets.values), lineSegments: segments, lineAlpha: s.lineAlpha,
            horizon: horizon, cardinals: cardinals, bodies: bodies,
            labels: placeLabels(labels, in: rect, max: 40),
            hitTargets: hits, reticleAzimuth: raz, reticleAltitude: ralt, reticleConstellation: constellationName)
    }

    /// Greedy label placement on a 32 pt grid (plan 4.3): highest priority wins a cell.
    static func placeLabels(_ labels: [SkyFrame.Label], in rect: CGRect, max: Int) -> [SkyFrame.Label] {
        var taken = Set<Int>()
        var out: [SkyFrame.Label] = []
        for l in labels.sorted(by: { $0.priority > $1.priority }) {
            guard rect.insetBy(dx: -8, dy: -8).contains(l.point) else { continue }
            let key = Int(l.point.x / 32) * 10_000 + Int(l.point.y / 32)
            if taken.contains(key) { continue }
            taken.insert(key)
            out.append(l)
            if out.count >= max { break }
        }
        return out
    }

    static let starColors: [SIMD3<Double>] = [
        SIMD3(0.70, 0.78, 1.00),   // B−V < 0.0: blue-white
        SIMD3(0.95, 0.96, 1.00),   // < 0.5: white
        SIMD3(1.00, 0.94, 0.85),   // < 1.0: yellow-white
        SIMD3(1.00, 0.80, 0.62),   // ≥ 1.0: orange
    ]

    static func colorClass(_ bvIndex: UInt8) -> Int {
        let bv = Double(bvIndex) / 255 * 2.4 - 0.4
        return bv < 0 ? 0 : (bv < 0.5 ? 1 : (bv < 1.0 ? 2 : 3))
    }
}
