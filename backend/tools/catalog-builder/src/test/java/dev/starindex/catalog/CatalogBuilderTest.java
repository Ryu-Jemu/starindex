package dev.starindex.catalog;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.HashSet;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

/** T9: catalog QA on the real sources in data/catalog-src. */
class CatalogBuilderTest {
    static CatalogBuilder.Qa qa;
    static SkyPack.Pack pack;

    @BeforeAll
    static void build(@TempDir Path tmp) throws Exception {
        Path root = Path.of(System.getProperty("repoRoot"));
        Path out = tmp.resolve("packs");
        qa = CatalogBuilder.build(new CatalogBuilder.Options(root.resolve("data/catalog-src"), out, 5.5, 2026.5, 1));
        pack = SkyPack.read(out.resolve("skypack-v1.bin"));
    }

    @Test
    void sourceRowCountsMatchHeasarc() {
        assertEquals(9110, qa.sourceRows(), "HEASARC bsc5p TOTAL ROWS");
        assertTrue(qa.positionlessRows() > 0 && qa.positionlessRows() < 20, "BSC has a handful of non-stellar entries");
        assertEquals(0, qa.duplicateHr());
    }

    @Test
    void eightyEightConstellationsWithKoreanNames() {
        assertEquals(88, qa.constellations());
        assertEquals(0, qa.constellationsMissingKo());
        Set<String> abbrs = new HashSet<>();
        pack.constellations().forEach(c -> abbrs.add(c.abbr()));
        assertTrue(abbrs.containsAll(Set.of("Ori", "UMa", "UMi", "Cas", "Sco", "Ser", "Cru")));
    }

    @Test
    void lineVerticesMatchStarsWithinOneArcminute() {
        assertEquals(qa.lineVertices(), qa.matchedVertices() + qa.unmatchedVertices().size());
        assertTrue(qa.maxMatchArcsec() <= CatalogBuilder.MATCH_TOLERANCE_ARCSEC);
        // Report, don't hide: every unmatched vertex becomes a line-only point.
        assertEquals(qa.unmatchedVertices().size() > 0, qa.lineOnlyPoints() > 0);
    }

    @Test
    void segmentsReferenceValidStarsAndRoundTrip() {
        for (var s : pack.segments()) {
            assertTrue(s.a() < pack.stars().size() && s.b() < pack.stars().size());
            assertTrue(s.constellation() < pack.constellations().size());
        }
        assertArrayEquals(SkyPack.encode(pack), SkyPack.encode(SkyPack.decode(SkyPack.encode(pack))));
    }

    @Test
    void knownBrightStars() {
        var vega = pack.stars().stream().filter(s -> s.hr() == 7001).findFirst().orElseThrow();
        assertEquals(3, vega.mag100());                       // V = 0.03
        assertEquals("Vega", pack.strings().get(vega.nameIdx()));
        var sirius = pack.stars().getFirst();                 // brightest first
        assertEquals(2491, sirius.hr());
        assertEquals("Sirius", pack.strings().get(sirius.nameIdx()));
        // Unit vectors.
        for (var s : pack.stars()) {
            double n = Math.sqrt(s.x() * s.x() + s.y() * s.y() + s.z() * s.z());
            assertEquals(1.0, n, 1e-5);
        }
    }

    @Test
    void magnitudeSelection() {
        assertEquals(qa.starsWithinMagLimit() + qa.lineStarsBeyondLimit(), qa.starsIncluded());
        long drawable = pack.stars().stream().filter(s -> (s.flags() & SkyPack.FLAG_LINE_ONLY) == 0).count();
        assertEquals(qa.starsIncluded(), drawable);
    }
}
