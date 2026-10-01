package dev.starindex.pack;

import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.checksums.RequestChecksumCalculation;
import software.amazon.awssdk.core.checksums.ResponseChecksumValidation;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.DeleteObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;
import software.amazon.awssdk.services.s3.model.NoSuchKeyException;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.model.S3Object;

import java.net.URI;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;

/**
 * Packs in an S3-compatible bucket, the Neon Object Storage public_read bucket in production (ADR-017):
 * {@code packs/manifest/latest.json} (max-age=60) and immutable {@code packs/{kind}/{version}/…}. Same paths as
 * {@link LocalPackStore}. Every PUT replaces the object atomically, so a client never reads half a pack. Neon stores
 * Content-Type and Cache-Control and returns them on GET (its S3 compatibility page), which the app's caching uses.
 */
public class S3PackStore implements PackStore {
    private final S3Client s3;
    private final String bucket;

    public S3PackStore(S3Client s3, String bucket) {
        this.s3 = s3;
        this.bucket = bucket;
    }

    /**
     * Client for an S3-compatible endpoint (Neon Object Storage; S3Mock in tests): path-style addressing (Neon supports
     * nothing else), and checksums only where the S3 API requires them (recent SDKs add CRC trailers to every upload
     * by default, which compatible servers do not all accept). Credentials: the given key pair (Spring properties,
     * e.g. backend/.env), else the SDK's default chain (environment variables in GitHub Actions). Either way the pair
     * is a Neon storage credential (token_id / s3_secret_access_key), not an AWS key.
     */
    public static S3PackStore create(String bucket, String endpoint, String region, String keyId, String secret) {
        if (endpoint == null || endpoint.isBlank())
            throw new IllegalStateException("PACK_BUCKET is set but AWS_ENDPOINT_URL_S3 (the storage endpoint) is empty");
        var builder = S3Client.builder();
        if (keyId != null && !keyId.isBlank() && secret != null && !secret.isBlank())
            builder.credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create(keyId, secret)));
        S3Client client = builder.region(Region.of(region)).endpointOverride(URI.create(endpoint))
                .forcePathStyle(true).httpClient(UrlConnectionHttpClient.create())
                .requestChecksumCalculation(RequestChecksumCalculation.WHEN_REQUIRED)
                .responseChecksumValidation(ResponseChecksumValidation.WHEN_REQUIRED)
                .build();
        return new S3PackStore(client, bucket);
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
