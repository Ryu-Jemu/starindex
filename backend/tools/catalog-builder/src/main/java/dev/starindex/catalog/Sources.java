package dev.starindex.catalog;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;

/** Readers for the raw catalog sources in {@code data/catalog-src}. */
final class Sources {
    private Sources() {}

    /** One BSC5P row with a position. RA/Dec are J2000 degrees; proper motion in arcsec/yr (pmRA includes cos δ). */
    record BscStar(int hr, double raDeg, double decDeg, double vmag, Double bv,
                   double pmraArcsecPerYr, double pmdecArcsecPerYr, String name, String altName) {}

    record BscResult(List<BscStar> stars, int totalRows, int positionlessRows) {}

    /** Parses the HEASARC TDAT export (header {@code line[1] = ...} gives the pipe-separated field order). */
    static BscResult readBsc(Path gz) throws IOException {
        List<String> fields = null;
        boolean inData = false;
        int total = 0, positionless = 0;
        List<BscStar> stars = new ArrayList<>();
        try (var in = new BufferedReader(new InputStreamReader(
                new GZIPInputStream(Files.newInputStream(gz)), StandardCharsets.UTF_8))) {
            Map<String, Integer> idx = new HashMap<>();
            for (String line; (line = in.readLine()) != null; ) {
                if (line.startsWith("line[1] =")) {
                    fields = List.of(line.substring(line.indexOf('=') + 1).trim().split("\\s+"));
                    for (int i = 0; i < fields.size(); i++) idx.put(fields.get(i), i);
                } else if (line.startsWith("<DATA>")) {
                    inData = true;
                } else if (line.startsWith("<END>")) {
                    break;
                } else if (inData) {
                    if (fields == null) throw new IOException("TDAT has no line[1] field list");
                    total++;
                    String[] v = line.split("\\|", -1);
                    String ra = v[idx.get("ra")].trim(), dec = v[idx.get("dec")].trim(), vmag = v[idx.get("vmag")].trim();
                    if (ra.isEmpty() || dec.isEmpty() || vmag.isEmpty()) { positionless++; continue; }
                    String bv = v[idx.get("bv_color")].trim();
                    String pmra = v[idx.get("pmra")].trim(), pmdec = v[idx.get("pmdec")].trim();
                    stars.add(new BscStar(
                            Integer.parseInt(v[idx.get("hr")].trim()),
                            Double.parseDouble(ra), Double.parseDouble(dec), Double.parseDouble(vmag),
                            bv.isEmpty() ? null : Double.parseDouble(bv),
                            pmra.isEmpty() ? 0 : Double.parseDouble(pmra),
                            pmdec.isEmpty() ? 0 : Double.parseDouble(pmdec),
                            v[idx.get("name")].trim(), v[idx.get("alt_name")].trim()));
                }
            }
        }
        return new BscResult(stars, total, positionless);
    }

    private static final Pattern HR = Pattern.compile("\\bHR\\s+(\\d+)\\b");

    /** IAU-CSN: fixed-width text; the ASCII name is columns 0–17 (names may contain spaces). */
    static Map<Integer, String> readIauNames(Path txt) throws IOException {
        Map<Integer, String> names = new HashMap<>();
        for (String line : Files.readAllLines(txt, StandardCharsets.UTF_8)) {
            if (line.isBlank() || line.startsWith("#") || line.startsWith("$")) continue;
            String name = line.substring(0, Math.min(18, line.length())).trim();
            Matcher m = HR.matcher(line);
            if (!name.isEmpty() && m.find()) names.putIfAbsent(Integer.parseInt(m.group(1)), name);
        }
        return names;
    }

    /** A constellation with its stick-figure polylines as J2000 (raDeg, decDeg) vertices. */
    record Constellation(String id, String latin, String english, String korean, List<List<double[]>> polylines) {}

    /** d3-celestial lines + names. Duplicate feature ids (Serpens Caput/Cauda) are merged. */
    static Map<String, Constellation> readConstellations(Path linesJson, Path namesJson) throws IOException {
        ObjectMapper om = new ObjectMapper();
        Map<String, JsonNode> props = new HashMap<>();
        for (JsonNode f : om.readTree(namesJson.toFile()).get("features")) props.putIfAbsent(f.get("id").asText(), f.get("properties"));

        Map<String, List<List<double[]>>> lines = new LinkedHashMap<>();
        for (JsonNode f : om.readTree(linesJson.toFile()).get("features")) {
            List<List<double[]>> target = lines.computeIfAbsent(f.get("id").asText(), k -> new ArrayList<>());
            for (JsonNode poly : f.get("geometry").get("coordinates")) {
                List<double[]> pts = new ArrayList<>();
                for (JsonNode p : poly) {
                    double lon = p.get(0).asDouble(), lat = p.get(1).asDouble();
                    pts.add(new double[]{lon < 0 ? lon + 360 : lon, lat}); // d3 stores RA as −180…180°
                }
                target.add(pts);
            }
        }
        Map<String, Constellation> out = new LinkedHashMap<>();
        lines.forEach((id, polys) -> {
            JsonNode p = props.get(id);
            out.put(id, new Constellation(id,
                    p == null ? id : p.path("name").asText(id),
                    p == null ? id : p.path("en").asText(id),
                    p == null ? "" : p.path("ko").asText(""),
                    polys));
        });
        return out;
    }
}
