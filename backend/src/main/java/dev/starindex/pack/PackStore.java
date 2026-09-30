package dev.starindex.pack;

import java.util.Optional;

/**
 * Where static packs go. Local directory now; the S3 implementation (CloudFront origin, PLAN 3.4) plugs in at W3 with
 * the same paths: {@code packs/index/{version}/index.json.gz} (immutable) and {@code packs/manifest/latest.json}.
 */
public interface PackStore {
    String IMMUTABLE = "public, max-age=31536000, immutable";
    String MANIFEST = "max-age=60, must-revalidate";

    void put(String path, byte[] bytes, String contentType, String cacheControl);

    Optional<byte[]> get(String path);

    /** Human-readable location for logs (a directory or bucket URI). */
    String describe(String path);
}
