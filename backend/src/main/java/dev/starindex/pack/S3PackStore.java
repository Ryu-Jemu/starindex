package dev.starindex.pack;

import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.DeleteObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.model.S3Object;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;

/**
 * Packs in the S3 bucket behind CloudFront (PLAN 3.4): {@code packs/manifest/latest.json} (max-age=60) and immutable
 * {@code packs/{kind}/{version}/…}. Same paths as {@link LocalPackStore}. Every PUT replaces the object atomically, so a
 * client never reads half a pack; objects are not public (the bucket policy allows CloudFront's OAC only).
 */
public class S3PackStore implements PackStore {
    private final S3Client s3;
    private final String bucket;

    public S3PackStore(S3Client s3, String bucket) {
        this.s3 = s3;
        this.bucket = bucket;
    }

    private static String key(String path) {
        if (path.startsWith("/") || path.contains("..") || path.contains("\\"))
            throw new IllegalArgumentException("bad pack path: " + path);
        return path;
    }

    @Override
    public void put(String path, byte[] bytes, String contentType, String cacheControl) {
        // No Content-Encoding on .json.gz: clients download the gzip bytes whose sha256 the manifest carries.
        s3.putObject(PutObjectRequest.builder().bucket(bucket).key(key(path)).contentType(contentType)
                .cacheControl(cacheControl).build(), RequestBody.fromBytes(bytes));
    }

    @Override
    public Optional<byte[]> get(String path) {
        try {
            return Optional.of(s3.getObjectAsBytes(GetObjectRequest.builder().bucket(bucket).key(key(path)).build()).asByteArray());
        } catch (NoSuchKeyException e) {
            return Optional.empty();
        }
    }

    @Override
    public void delete(String path) {
        s3.deleteObject(DeleteObjectRequest.builder().bucket(bucket).key(key(path)).build());
    }

    @Override
    public List<Entry> list(String prefix) {
        String p = key(prefix.endsWith("/") ? prefix : prefix + "/");
        List<Entry> out = new ArrayList<>();
        for (S3Object o : s3.listObjectsV2Paginator(ListObjectsV2Request.builder().bucket(bucket).prefix(p).build()).contents())
            out.add(new Entry(o.key(), o.lastModified()));
        out.sort(Comparator.comparing(Entry::path));
        return out;
    }

    @Override
    public String describe(String path) { return "s3://" + bucket + "/" + path; }
}
