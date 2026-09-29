package dev.starindex.catalog;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Builds {@code skypack-v<n>.bin} from {@code data/catalog-src} (no network, no DB).
 *
 * <p>Usage: {@code ./gradlew :tools:catalog-builder:run --args="--mag 5.5 --version 1"} (runs from the repo root).
 */
public final class CatalogBuilder {
    static final double MATCH_TOLERANCE_ARCSEC = 60.0;  // 1′

    public record Options(Path src, Path outDir, double magLimit, double epoch, int version) {
        static Options parse(String[] args) {
            Path src = Path.of("data/catalog-src"), out = Path.of("data/packs");
            double mag = 5.5, epoch = 2026.5;
            int version = 1;
            for (int i = 0; i < args.length; i++) {
                switch (args[i]) {
                    case "--src" -> src = Path.of(args[++i]);
                    case "--out" -> out = Path.of(args[++i]);
                    case "--mag" -> mag = Double.parseDouble(args[++i]);
                    case "--epoch" -> epoch = Double.parseDouble(args[++i]);
                    case "--version" -> version = Integer.parseInt(args[++i]);
                    default -> throw new IllegalArgumentException("unknown option " + args[i]);
                }
            }
            return new Options(src, out, mag, epoch, version);
        }
    }

    /** Catalog QA (gate T9). */
    public record Qa(String packFile, String sha256, int bytes, int sourceRows, int positionlessRows,
                     double magLimit, double epoch, int starsIncluded, int starsWithinMagLimit,
                     int lineStarsBeyondLimit, int lineOnlyPoints, int constellations, int segments,
                     int lineVertices, int matchedVertices, double maxMatchArcsec,
                     List<Map<String, Object>> unmatchedVertices, int namedStars, int duplicateHr,
                     int constellationsMissingKo) {}

    public static void main(String[] args) throws Exception {
        Qa qa = build(Options.parse(args));
        System.out.println(new ObjectMapper().enable(SerializationFeature.INDENT_OUTPUT).writeValueAsString(qa));
        if (qa.constellations() != 88 || qa.duplicateHr() != 0) System.exit(2);
    }

    public static Qa build(Options o) throws IOException {
        Sources.BscResult bsc = Sources.readBsc(o.src().resolve("heasarc_bsc5p.tdat.gz"));
        Map<Integer, String> iau = Sources.readIauNames(o.src().resolve("IAU-CSN.txt"));
        Map<String, Sources.Constellation> consts = Sources.readConstellations(
                o.src().resolve("d3-constellations.lines.json"), o.src().resolve("d3-constellations.json"));

        List<Sources.BscStar> all = bsc.stars();
        Set<Integer> seenHr = new HashSet<>();
        int dupHr = 0;
        for (var s : all) if (!seenHr.add(s.hr())) dupHr++;

        // J2000 (catalog epoch) unit vectors for matching against d3 J2000 vertices.
        double[][] j2000 = new double[all.size()][];
        for (int i = 0; i < all.size(); i++) j2000[i] = unit(all.get(i).raDeg(), all.get(i).decDeg());

        // Match every stick-figure vertex to the nearest BSC star (≤ 1′).
        Map<String, Integer> vertexToStar = new HashMap<>();
        List<Map<String, Object>> unmatched = new ArrayList<>();
        int vertices = 0, matched = 0;
        double maxMatch = 0;
        for (var c : consts.values()) {
            for (var poly : c.polylines()) {
                for (double[] v : poly) {
                    vertices++;
                    double[] u = unit(v[0], v[1]);
                    int best = -1;
                    double bestDot = -2;
                    for (int i = 0; i < j2000.length; i++) {
                        double d = dot(u, j2000[i]);
                        if (d > bestDot) { bestDot = d; best = i; }
                    }
                    double sep = Math.toDegrees(Math.acos(Math.min(1, bestDot))) * 3600;
                    if (sep <= MATCH_TOLERANCE_ARCSEC) {
                        matched++;
                        maxMatch = Math.max(maxMatch, sep);
                        vertexToStar.put(key(v), best);
                    } else {
                        Map<String, Object> m = new LinkedHashMap<>();
                        m.put("constellation", c.id());
                        m.put("raDeg", v[0]);
                        m.put("decDeg", v[1]);
                        m.put("nearestArcsec", Math.round(sep * 10) / 10.0);
                        unmatched.add(m);
                    }
                }
            }
        }

        // Included stars: within the magnitude limit, plus every matched line star.
        Set<Integer> include = new HashSet<>();
        int withinLimit = 0;
        for (int i = 0; i < all.size(); i++) if (all.get(i).vmag() <= o.magLimit()) { include.add(i); withinLimit++; }
        int beyond = 0;
        for (int i : new HashSet<>(vertexToStar.values())) if (include.add(i)) beyond++;

        List<Integer> order = new ArrayList<>(include);
        order.sort(Comparator.comparingDouble((Integer i) -> all.get(i).vmag()).thenComparingInt(i -> all.get(i).hr()));

        List<String> strings = new ArrayList<>();
        Map<String, Integer> stringIdx = new HashMap<>();
        java.util.function.Function<String, Integer> intern = s -> {
            if (s == null || s.isEmpty()) return -1;
            return stringIdx.computeIfAbsent(s, k -> { strings.add(k); return strings.size() - 1; });
        };

        List<SkyPack.Star> stars = new ArrayList<>();
        Map<Integer, Integer> bscToPack = new HashMap<>();
        int named = 0;
        double years = o.epoch() - 2000.0;
        for (int i : order) {
            var s = all.get(i);
            double dec = s.decDeg() + s.pmdecArcsecPerYr() * years / 3600.0;
            double cosDec = Math.cos(Math.toRadians(s.decDeg()));
            double ra = s.raDeg() + (cosDec > 1e-6 ? s.pmraArcsecPerYr() / cosDec * years / 3600.0 : 0);
            double[] u = unit(ra, dec);
            String name = iau.get(s.hr());
            int nameIdx = intern.apply(name);
            if (nameIdx >= 0) named++;
            bscToPack.put(i, stars.size());
            stars.add(new SkyPack.Star((float) u[0], (float) u[1], (float) u[2],
                    (short) Math.round(s.vmag() * 100), bvIndex(s.bv()),
                    nameIdx >= 0 ? SkyPack.FLAG_HAS_NAME : 0, s.hr(), nameIdx));
        }

        // Unmatched vertices become line-only points so every stick figure stays drawable.
        Map<String, Integer> lineOnlyIdx = new HashMap<>();
        for (var c : consts.values()) for (var poly : c.polylines()) for (double[] v : poly) {
            if (vertexToStar.containsKey(key(v)) || lineOnlyIdx.containsKey(key(v))) continue;
            double[] u = unit(v[0], v[1]);
            lineOnlyIdx.put(key(v), stars.size());
            stars.add(new SkyPack.Star((float) u[0], (float) u[1], (float) u[2], (short) 9999, 128,
                    SkyPack.FLAG_LINE_ONLY, 0, -1));
        }
        if (stars.size() > 0xFFFF) throw new IllegalStateException("too many stars for u16 indices");

        List<SkyPack.Constellation> packConsts = new ArrayList<>();
        List<SkyPack.Segment> segments = new ArrayList<>();
        int missingKo = 0;
        List<String> ids = new ArrayList<>(consts.keySet());
        ids.sort(null);
        for (String id : ids) {
            var c = consts.get(id);
            if (c.korean().isEmpty()) missingKo++;
            double[] sum = new double[3];
            Set<Long> seen = new HashSet<>();
            int ci = packConsts.size();
            for (var poly : c.polylines()) {
                for (int k = 0; k < poly.size(); k++) {
                    double[] u = unit(poly.get(k)[0], poly.get(k)[1]);
                    sum[0] += u[0]; sum[1] += u[1]; sum[2] += u[2];
                    if (k == 0) continue;
                    int a = packIndex(poly.get(k - 1), vertexToStar, bscToPack, lineOnlyIdx);
                    int b = packIndex(poly.get(k), vertexToStar, bscToPack, lineOnlyIdx);
                    if (a == b) continue;
                    long pair = ((long) Math.min(a, b) << 32) | Math.max(a, b);
                    if (seen.add(pair)) segments.add(new SkyPack.Segment(ci, a, b));
                }
            }
            double n = Math.sqrt(sum[0] * sum[0] + sum[1] * sum[1] + sum[2] * sum[2]);
            packConsts.add(new SkyPack.Constellation(id, intern.apply(c.korean()), intern.apply(c.latin()),
                    (float) (sum[0] / n), (float) (sum[1] / n), (float) (sum[2] / n)));
        }

        SkyPack.Pack pack = new SkyPack.Pack((float) o.epoch(), (float) o.magLimit(), stars, packConsts, segments, strings);
        byte[] bytes = SkyPack.encode(pack);
        Files.createDirectories(o.outDir());
        String fileName = "skypack-v" + o.version() + ".bin";
        Files.write(o.outDir().resolve(fileName), bytes);
        writeNamesKo(o.outDir().getParent() == null ? Path.of(".") : o.outDir().getParent(), consts, ids);

        Qa qa = new Qa(fileName, sha256(bytes), bytes.length, bsc.totalRows(), bsc.positionlessRows(),
                o.magLimit(), o.epoch(), stars.size() - lineOnlyIdx.size(), withinLimit, beyond,
                lineOnlyIdx.size(), packConsts.size(), segments.size(), vertices, matched,
                Math.round(maxMatch * 10) / 10.0, unmatched, named, dupHr, missingKo);
        Files.writeString(o.outDir().resolve("skypack-v" + o.version() + ".qa.json"),
                new ObjectMapper().enable(SerializationFeature.INDENT_OUTPUT).writeValueAsString(qa) + "\n");
        return qa;
    }

    /** data/names_ko.csv — the source of truth for Korean constellation names (reviewed=false until R1). */
    static void writeNamesKo(Path dataDir, Map<String, Sources.Constellation> consts, List<String> ids) throws IOException {
        StringBuilder sb = new StringBuilder("iau_abbr,latin,english,korean,korean_source,reviewed\n");
        for (String id : ids) {
            var c = consts.get(id);
            sb.append(csv(id)).append(',').append(csv(c.latin())).append(',').append(csv(c.english())).append(',')
              .append(csv(c.korean())).append(",d3-celestial(Wikipedia),false\n");
        }
        Files.writeString(dataDir.resolve("names_ko.csv"), sb.toString(), StandardCharsets.UTF_8);
    }

    static int packIndex(double[] v, Map<String, Integer> vertexToStar, Map<Integer, Integer> bscToPack,
                         Map<String, Integer> lineOnly) {
        Integer bscIdx = vertexToStar.get(key(v));
        return bscIdx != null ? bscToPack.get(bscIdx) : lineOnly.get(key(v));
    }

    /** B−V → 0…255 over [−0.4, 2.0]; missing → B−V 0.6 (solar-like). */
    static int bvIndex(Double bv) {
        double v = bv == null ? 0.6 : bv;
        return (int) Math.max(0, Math.min(255, Math.round((v + 0.4) / 2.4 * 255)));
    }

    static double[] unit(double raDeg, double decDeg) {
        double a = Math.toRadians(raDeg), d = Math.toRadians(decDeg);
        return new double[]{Math.cos(d) * Math.cos(a), Math.cos(d) * Math.sin(a), Math.sin(d)};
    }

    static double dot(double[] a, double[] b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }

    static String key(double[] v) { return v[0] + "," + v[1]; }

    static String csv(String s) {
        return s.contains(",") || s.contains("\"") ? "\"" + s.replace("\"", "\"\"") + "\"" : s;
    }

    static String sha256(byte[] b) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(b));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
