package dev.starindex.pack;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.zip.GZIPOutputStream;

/**
 * Static data packs (PLAN D8, 3.4): JSON gzipped as {@code .json.gz}; the sha256 in the manifest is over the
 * COMPRESSED bytes (what the app downloads and verifies before swapping atomically).
 */
public final class PackWriter {
    public record Packed(byte[] gzipBytes, String sha256, int rawBytes) {}

    private PackWriter() {}

    public static Packed gzip(byte[] json) {
        try (var bos = new ByteArrayOutputStream(); var gz = new GZIPOutputStream(bos)) {
            gz.write(json);
            gz.finish();
            byte[] out = bos.toByteArray();
            return new Packed(out, sha256(out), json.length);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    public static String sha256(byte[] bytes) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
