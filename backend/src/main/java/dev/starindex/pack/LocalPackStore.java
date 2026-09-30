package dev.starindex.pack;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Optional;

/** Writes packs under a local directory; each file is written to a temp file and moved atomically. */
public class LocalPackStore implements PackStore {
    private final Path root;

    public LocalPackStore(Path root) {
        this.root = root.toAbsolutePath().normalize();
    }

    private Path resolve(String path) {
        Path p = root.resolve(path).normalize();
        if (!p.startsWith(root)) throw new IllegalArgumentException("path escapes the pack root: " + path);
        return p;
    }

    @Override
    public void put(String path, byte[] bytes, String contentType, String cacheControl) {
        Path target = resolve(path);
        try {
            Files.createDirectories(target.getParent());
            Path tmp = Files.createTempFile(target.getParent(), ".pack-", ".tmp");
            Files.write(tmp, bytes);
            Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException e) {
            throw new UncheckedIOException("pack write failed: " + target, e);
        }
    }

    @Override
    public Optional<byte[]> get(String path) {
        Path p = resolve(path);
        try {
            return Files.exists(p) ? Optional.of(Files.readAllBytes(p)) : Optional.empty();
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    @Override
    public String describe(String path) { return resolve(path).toString(); }
}
