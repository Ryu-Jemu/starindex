import Foundation

/// Picks the pack region for the observer ON THE DEVICE (plan D4, SERVICE-PLAN 8.5): the pack is nationwide,
/// so neither coordinates nor a grid cell nor a region id ever leave the phone.
public enum RegionLocator {
    /// Largest grid distance (5 km cells) still served by the nearest region: 60 cells = 300 km.
    ///
    /// Why 60: the farthest South Korean territory from any of the 17 pack points is Dokdo, 57.3 cells from
    /// 울산 (Ulleungdo 45.2, Baengnyeongdo 36.7, Gageodo 28.2), so every location in South Korea gets an index.
    /// A distance bound cannot separate Korea from Tsushima (21.6), Pyongyang (37.4) or Fukuoka (42.2) anyway;
    /// those get the nearest region, whose name the UI always shows. Farther points inside the KMA grid
    /// (Chongjin 90.5, Sinuiju 69.3) and everything outside it (China, most of Japan, the US) → nil.
    public static let maxGridDistance = 60.0

    /// Nearest region by Euclidean distance on the KMA grid (LCC is conformal, cells are ~square).
    /// Ties go to the lower id. Nil outside the KMA grid, beyond `maxDistance`, or when no region has a grid.
    public static func nearest(_ regions: [IndexRegion], latitude: Double, longitude: Double,
                               maxDistance: Double = maxGridDistance) -> IndexRegion? {
        guard let g = KMAGrid.toGrid(latitude: latitude, longitude: longitude) else { return nil }
        return nearest(regions, nx: g.nx, ny: g.ny, maxDistance: maxDistance)
    }

    public static func nearest(_ regions: [IndexRegion], nx: Int, ny: Int,
                               maxDistance: Double = maxGridDistance) -> IndexRegion? {
        var best: (region: IndexRegion, d2: Int)?
        for r in regions {
            guard let c = r.gridCell else { continue }
            let dx = c.nx - nx, dy = c.ny - ny
            let d2 = dx * dx + dy * dy
            if let b = best, d2 > b.d2 || (d2 == b.d2 && !idLess(r.id, b.region.id)) { continue }
            best = (r, d2)
        }
        guard let best, Double(best.d2).squareRoot() <= maxDistance else { return nil }
        return best.region
    }

    /// Region ids are 10-digit administrative codes: compare numerically when both parse, else as text.
    static func idLess(_ a: String, _ b: String) -> Bool {
        if let x = Int64(a), let y = Int64(b) { return x < y }
        return a < b
    }

    /// Seoul (default when the observer is unknown or outside Korea): id 1100000000, else by name.
    public static func seoul(_ regions: [IndexRegion]) -> IndexRegion? {
        regions.first { $0.id == "1100000000" } ?? regions.first { $0.name == "서울" }
    }
}
