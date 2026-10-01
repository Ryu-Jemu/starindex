package dev.starindex.pack;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

/**
 * Where static packs go: a local directory, or the Neon Object Storage public bucket (ADR-017) with the same paths: {@code packs/index/{version}/index.json.gz} (immutable) and {@code packs/manifest/latest.json}.
 * S3 gets no lifecycle expiry on {@code packs/}: while the ETL is stopped it would delete the live pack (DB-PLAN 4.3).
 */
public interface PackStore {
    String IMMUTABLE = "public, max-age=31536000, immutable";
    String MANIFEST = "max-age=60, must-revalidate";

    /** A stored object: path relative to the store root ("/" separators) and its last write (S3 LastModified). */
    record Entry(String path, Instant lastModified) {}

    void put(String path, byte[] bytes, String contentType, String cacheControl);

    Optional<byte[]> get(String path);

    /** Deletes the object if present (S3 DeleteObject). */
    void delete(String path);

    /** Every object under {@code prefix} (S3 ListObjectsV2). */
    List<Entry> list(String prefix);

    /** Human-readable location for logs (a directory or bucket URI). */
    String describe(String path);
}
