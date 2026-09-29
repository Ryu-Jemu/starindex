import SwiftUI

/// Draws a `SkyFrame` into a Canvas (plan 4.3 layer order).
enum SkyRenderer {
    static func color(_ c: SIMD3<Double>, _ a: Double = 1) -> Color {
        Color(.sRGB, red: c.x, green: c.y, blue: c.z, opacity: a)
    }

    static func skyShader(_ s: SkyFrame.ShaderInputs) -> Shader {
        func f3(_ v: SIMD3<Float>) -> Shader.Argument { .float3(v.x, v.y, v.z) }
        var shader = ShaderLibrary.skyColor(
            .float4(Float(s.rect.minX), Float(s.rect.minY), Float(s.rect.width), Float(s.rect.height)),
            .float(s.focal),
            f3(s.rows.0), f3(s.rows.1), f3(s.rows.2), f3(s.sun),
            f3(s.zenith), f3(s.anti), f3(s.sunSide), f3(s.night), f3(s.ground),
            .float4(s.misc.x, s.misc.y, s.misc.z, s.misc.w))
        shader.dithersColor = true      // avoid banding in dark twilight gradients
        return shader
    }

    static func draw(_ f: SkyFrame, in ctx: inout GraphicsContext) {
        let rect = CGRect(origin: .zero, size: f.size)

        // 1. Sky (per-pixel shader; ground below the horizon is part of it).
        ctx.fill(Path(rect), with: .shader(skyShader(f.shader), bounds: rect))

        // 2. Horizon ring.
        var horizon = Path()
        for run in f.horizon where run.count > 1 { horizon.addLines(run) }
        ctx.stroke(horizon, with: .color(.white.opacity(0.35)), lineWidth: 1)

        // 3. Constellation stick figures.
        if f.lineAlpha > 0.02 {
            var lines = Path()
            for (a, b) in f.lineSegments { lines.move(to: a); lines.addLine(to: b) }
            ctx.stroke(lines, with: .color(Color(red: 0.55, green: 0.68, blue: 1.0).opacity(0.38 * f.lineAlpha)), lineWidth: 0.8)
        }

        // 4. Stars, one fill per bucket.
        for b in f.starBuckets {
            var path = Path()
            let r = b.radius
            for p in b.points { path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
            ctx.fill(path, with: .color(color(b.color, b.alpha)))
        }

        // 5. Sun, Moon (with phase), planets.
        for b in f.bodies {
            let r = b.radius
            let disk = CGRect(x: b.point.x - r, y: b.point.y - r, width: 2 * r, height: 2 * r)
            if case .body(.moon) = b.ref {
                ctx.fill(Path(ellipseIn: disk), with: .color(.white.opacity(0.12 * b.alpha)))
                // Lit part: ellipse whose width follows the illuminated fraction.
                let w = 2 * r * CGFloat(max(0.05, b.phaseFraction))
                ctx.fill(Path(ellipseIn: CGRect(x: b.point.x + r - w, y: b.point.y - r, width: w, height: 2 * r)),
                         with: .color(color(b.color, b.alpha)))
            } else {
                if case .body(.sun) = b.ref {
                    ctx.fill(Path(ellipseIn: disk.insetBy(dx: -r, dy: -r)), with: .color(color(b.color, 0.18 * b.alpha)))
                }
                ctx.fill(Path(ellipseIn: disk), with: .color(color(b.color, b.alpha)))
            }
        }

        // 6. Compass points on the horizon (kept clear of the bottom control bar).
        for (name, p) in f.cardinals where p.y < f.size.height - 130 {
            let isMain = name.count == 1
            ctx.draw(Text(name).font(.system(size: isMain ? 15 : 11, weight: isMain ? .bold : .regular))
                        .foregroundStyle(isMain ? Color(red: 1, green: 0.55, blue: 0.45) : .white.opacity(0.7)),
                     at: CGPoint(x: p.x, y: p.y + 12), anchor: .top)
        }

        // 7. Labels.
        for l in f.labels {
            ctx.draw(Text(l.text).font(.system(size: l.priority >= 90 ? 13 : 11, weight: l.priority >= 90 ? .semibold : .regular))
                        .foregroundStyle(color(l.color, l.alpha)),
                     at: CGPoint(x: l.point.x, y: l.point.y + (l.priority >= 90 ? 14 : 0)), anchor: .top)
        }
    }
}
