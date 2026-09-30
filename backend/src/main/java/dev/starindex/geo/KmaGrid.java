package dev.starindex.geo;

import java.util.Optional;

/**
 * WGS84 lat/lon → KMA 단기예보 grid (nx, ny), Lambert Conformal Conic as published in the
 * 단기예보 활용가이드 (Re 6371.00877 km, grid 5 km, standard parallels 30°/60°, origin 38°N 126°E at (43, 136)).
 * Same formula as the app's {@code KMAGrid.swift}; Seoul (37.5665, 126.9780) → (60, 127).
 */
public final class KmaGrid {
    public record Cell(int nx, int ny) {}

    private static final double RE = 6371.00877, GRID = 5.0;
    private static final double SLAT1 = 30.0, SLAT2 = 60.0, OLON = 126.0, OLAT = 38.0;
    private static final double XO = 43.0, YO = 136.0;
    public static final int NX_MAX = 149, NY_MAX = 253;

    private KmaGrid() {}

    /** Empty for non-finite input, the poles, or points outside the KMA grid. */
    public static Optional<Cell> toGrid(double lat, double lon) {
        if (!Double.isFinite(lat) || !Double.isFinite(lon) || lat <= -90 || lat >= 90) return Optional.empty();
        double d = Math.PI / 180;
        double reG = RE / GRID;
        double s1 = SLAT1 * d, s2 = SLAT2 * d, oL = OLON * d, oA = OLAT * d;
        double sn = Math.tan(Math.PI * 0.25 + s2 * 0.5) / Math.tan(Math.PI * 0.25 + s1 * 0.5);
        sn = Math.log(Math.cos(s1) / Math.cos(s2)) / Math.log(sn);
        double sf = Math.tan(Math.PI * 0.25 + s1 * 0.5);
        sf = Math.pow(sf, sn) * Math.cos(s1) / sn;
        double ro = Math.tan(Math.PI * 0.25 + oA * 0.5);
        ro = reG * sf / Math.pow(ro, sn);
        double ra = Math.tan(Math.PI * 0.25 + lat * d * 0.5);
        ra = reG * sf / Math.pow(ra, sn);
        double theta = lon * d - oL;
        if (theta > Math.PI) theta -= 2 * Math.PI;
        if (theta < -Math.PI) theta += 2 * Math.PI;
        theta *= sn;
        double x = Math.floor(ra * Math.sin(theta) + XO + 0.5);
        double y = Math.floor(ro - ra * Math.cos(theta) + YO + 0.5);
        if (!Double.isFinite(x) || !Double.isFinite(y)) return Optional.empty();
        int nx = (int) x, ny = (int) y;
        if (nx < 1 || nx > NX_MAX || ny < 1 || ny > NY_MAX) return Optional.empty();
        return Optional.of(new Cell(nx, ny));
    }
}
