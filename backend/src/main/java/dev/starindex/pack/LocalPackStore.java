package dev.starindex.pack;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.DirectoryNotEmptyException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;

/** Writes packs under a local directory; each file is written to a temp file and moved atomically. */
public class LocalPackStore implements PackStore {
    private final Path root;

    public LocalPackStore(Path root) {
        this.root = root.toAbsolutePath().normalize();
    }

    private Path resolve(String path) {
        Path p = root.resolve(path).normalize();
        if (!p.startsWith(root) || p.equals(root)) throw new IllegalArgumentException("path escapes the pack root: " + path);
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

    /** Also removes the version directory once it is empty (never the root or a kind directory like packs/index). */
    @Override
    public void delete(String path) {
        Path p = resolve(path);
        try {
            Files.deleteIfExists(p);
            Path dir = p.getParent();
            if (dir != null && root.relativize(dir).getNameCount() >= 3) {
                try {
                    Files.deleteIfExists(dir);
                } catch (DirectoryNotEmptyException ignored) {
                    // other files of the same version remain
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException("pack delete failed: " + p, e);
        }
    }

    /**
     * A file that disappears during the walk (a publish moving its temp file into place) is skipped, not an error:
     * the modification time comes from the attributes read with the directory entry, never from a second stat.
     */
    @Override
    public List<Entry> list(String prefix) {
        Path start = resolve(prefix);
        if (!Files.isDirectory(start)) return List.of();
        List<Entry> out = new ArrayList<>();
        try {
            Files.walkFileTree(start, new SimpleFileVisitor<>() {
                @Override
                public FileVisitResult visitFile(Path f, BasicFileAttributes attrs) {
                    if (attrs.isRegularFile())
                        out.add(new Entry(root.relativize(f).toString().replace(f.getFileSystem().getSeparator(), "/"),
                                attrs.lastModifiedTime().toInstant()));
                    return FileVisitResult.CONTINUE;
                }

                @Override
                public FileVisitResult visitFileFailed(Path f, IOException e) throws IOException {
                    if (e instanceof NoSuchFileException) return FileVisitResult.CONTINUE;
                    throw e;
                }
            });
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        out.sort(Comparator.comparing(Entry::path));
        return out;
    }

    @Override
    public String describe(String path) { return resolve(path).toString(); }
}
