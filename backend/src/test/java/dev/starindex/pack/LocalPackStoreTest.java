package dev.starindex.pack;

import dev.starindex.etl.EtlProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.*;

/** DB-PLAN 6.1: path confinement, empty version directories, listing; and the retention floors. */
class LocalPackStoreTest {
    @TempDir Path root;

    @Test
    void pathsCannotEscapeTheRoot() {
        var s = new LocalPackStore(root);
        assertThrows(IllegalArgumentException.class, () -> s.delete("../outside.json"));
        assertThrows(IllegalArgumentException.class, () -> s.delete("packs/../../outside.json"));
        assertThrows(IllegalArgumentException.class, () -> s.delete("."));
        assertThrows(IllegalArgumentException.class, () -> s.list("../"));
    }

    @Test
    void deleteRemovesTheEmptyVersionDirectoryButNotTheKindDirectory() {
        var s = new LocalPackStore(root);
        s.put("packs/index/v1/index.json.gz", new byte[]{1}, "application/gzip", PackStore.IMMUTABLE);
        s.put("packs/index/v2/index.json.gz", new byte[]{2}, "application/gzip", PackStore.IMMUTABLE);
        s.put("packs/index/v2/extra.json", new byte[]{3}, "application/json", PackStore.IMMUTABLE);
        s.delete("packs/index/v1/index.json.gz");
        s.delete("packs/index/v2/index.json.gz");
        s.delete("packs/index/v9/missing.json.gz");                      // absent: no error
        assertFalse(Files.exists(root.resolve("packs/index/v1")));
        assertTrue(Files.exists(root.resolve("packs/index/v2/extra.json")), "a non-empty version directory stays");
        assertTrue(Files.isDirectory(root.resolve("packs/index")));
    }

    @Test
    void listReturnsRelativePathsAndModificationTimes() throws Exception {
        var s = new LocalPackStore(root);
        s.put("packs/index/v1/index.json.gz", new byte[]{1}, "application/gzip", PackStore.IMMUTABLE);
        s.put("packs/manifest/latest.json", new byte[]{2}, "application/json", PackStore.MANIFEST);
        Instant t = Instant.parse("2026-01-02T03:04:05Z");
        Files.setLastModifiedTime(root.resolve("packs/index/v1/index.json.gz"), FileTime.from(t));
        var all = s.list("packs/");
        assertEquals(2, all.size());
        assertEquals(new PackStore.Entry("packs/index/v1/index.json.gz", t), all.getFirst());
        assertEquals("packs/manifest/latest.json", all.get(1).path());
        assertEquals(1, s.list("packs/index/").size());
        assertEquals(0, s.list("packs/events/").size(), "missing prefix → empty");
    }

    @Test
    void lifecycleFloorsAreEnforcedAndDefaultsApplied() {
        var d = new EtlProperties.Etl(null, 0, 0, null, null, 0, null);
        assertEquals(java.time.Duration.ofHours(12), d.dataRetention());
        assertEquals(java.time.Duration.ofDays(2), d.historyRetention());
        assertEquals(3, d.packKeepMin());
        assertThrows(IllegalArgumentException.class, () -> new EtlProperties.Etl(null, 0, 0, java.time.Duration.ofHours(11), null, 3, null),
                "the 05:20 run needs yesterday's evening forecast");
        assertThrows(IllegalArgumentException.class, () -> new EtlProperties.Etl(null, 0, 0, null, java.time.Duration.ofHours(23), 3, null));
        assertEquals(java.time.Duration.ofDays(30),
                new EtlProperties.Etl(null, 0, 0, null, java.time.Duration.ofDays(30), 3, null).historyRetention(), "longer is allowed");
    }
}
