package dev.starindex.pack;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.*;

/** S3PackStore against an S3-compatible server (S3Mock): the metadata the app's HTTP caching relies on, listing, deletes. */
class S3PackStoreTest {
    // Adobe S3Mock (Docker Hub, amd64 + arm64). minio/minio is gone from Docker Hub and quay.io pulls timed out on CI.
    static final GenericContainer<?> S3 = new GenericContainer<>("adobe/s3mock:5.2.3").withExposedPorts(9090)
            .waitingFor(Wait.forHttp("/").forPort(9090).forStatusCodeMatching(c -> c < 500));
    static S3Client s3;
    static S3PackStore store, viaDefaultChain;

    @BeforeAll
    static void start() {
        S3.start();
        String endpoint = "http://" + S3.getHost() + ":" + S3.getMappedPort(9090);
        // The production factory (path-style, checksums WHEN_REQUIRED): an explicit key pair, as from backend/.env …
        store = S3PackStore.create("starindex-test", endpoint, "ap-southeast-1", "test", "test");
        // … and the SDK default chain, as in GitHub Actions (here through the equivalent system properties).
        System.setProperty("aws.accessKeyId", "test");
        System.setProperty("aws.secretAccessKey", "test");
        viaDefaultChain = S3PackStore.create("starindex-test", endpoint, "ap-southeast-1", "", null);
        s3 = S3Client.builder().region(Region.AP_SOUTHEAST_1).endpointOverride(URI.create(endpoint)).forcePathStyle(true)
                .credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create("test", "test")))
                .httpClient(UrlConnectionHttpClient.create()).build();
        s3.createBucket(b -> b.bucket("starindex-test"));
    }

    @AfterAll
    static void stop() {
        if (s3 != null) s3.close();
        System.clearProperty("aws.accessKeyId");
        System.clearProperty("aws.secretAccessKey");
        S3.stop();
    }

    @Test
    void putStoresContentTypeAndCacheControlAndGetReturnsTheBytes() {
        byte[] gz = {0x1f, (byte) 0x8b, 8, 0, 1, 2, 3};
        store.put("packs/index/v1/index.json.gz", gz, "application/gzip", PackStore.IMMUTABLE);
        store.put(PackPublisher.MANIFEST_PATH, "{}".getBytes(StandardCharsets.UTF_8), "application/json", PackStore.MANIFEST);
        assertArrayEquals(gz, store.get("packs/index/v1/index.json.gz").orElseThrow());
        assertArrayEquals(gz, viaDefaultChain.get("packs/index/v1/index.json.gz").orElseThrow());
        var head = s3.headObject(b -> b.bucket("starindex-test").key("packs/index/v1/index.json.gz"));
        assertEquals("application/gzip", head.contentType());
        assertEquals(PackStore.IMMUTABLE, head.cacheControl());
        assertNull(head.contentEncoding(), "no Content-Encoding: clients hash the gzip bytes themselves");
        var manifest = s3.headObject(b -> b.bucket("starindex-test").key(PackPublisher.MANIFEST_PATH));
        assertEquals("max-age=60, must-revalidate", manifest.cacheControl());
    }

    @Test
    void missingObjectIsEmptyAndListAndDeleteWorkUnderAPrefix() {
        assertTrue(store.get("packs/index/nope/index.json.gz").isEmpty());
        store.put("packs/events/v1/events.json.gz", new byte[]{1}, "application/gzip", PackStore.IMMUTABLE);
        store.put("packs/events/v2/events.json.gz", new byte[]{2}, "application/gzip", PackStore.IMMUTABLE);
        var listed = store.list("packs/events");
        assertEquals(java.util.List.of("packs/events/v1/events.json.gz", "packs/events/v2/events.json.gz"),
                listed.stream().map(PackStore.Entry::path).toList());
        assertTrue(listed.getFirst().lastModified().isAfter(Instant.now().minusSeconds(600)));
        store.delete("packs/events/v1/events.json.gz");
        store.delete("packs/events/v1/never-existed.json.gz");   // S3 DeleteObject is idempotent
        assertEquals(1, store.list("packs/events/").size());
        assertEquals("s3://starindex-test/packs/x", store.describe("packs/x"));
    }

    @Test
    void refusesPathsOutsideTheBucketLayout() {
        assertThrows(IllegalArgumentException.class, () -> store.put("/packs/x", new byte[0], "a", "b"));
        assertThrows(IllegalArgumentException.class, () -> store.get("packs/../backup/db/x"));
        assertThrows(IllegalStateException.class, () -> S3PackStore.create("b", "", "ap-southeast-1", null, null));
    }
}
