package dev.starindex;

import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.postgresql.PostgreSQLContainer;

/**
 * Singleton containers shared by every integration test class (started once per JVM), so the Spring context
 * cache is reused across classes. PostgreSQL 18 = the production major (Neon, ADR-015), locale C like the database
 * bootstrap creates; Valkey 8 = Redis-compatible store.
 */
@SpringBootTest(properties = {
        "spring.data.redis.repositories.enabled=false",
        // Never the developer's build/packs: retention (astroDailyJob) deletes pack files it has no row for.
        "starindex.pack.local-dir=build/test-packs",
        // Never a real bucket either, whatever PACK_BUCKET the shell or backend/.env holds (ADR-017).
        "starindex.pack.s3-bucket="})
public abstract class IntegrationTestBase {

    @ServiceConnection
    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:18")
            .withEnv("POSTGRES_INITDB_ARGS", "--locale=C --encoding=UTF8");

    @ServiceConnection(name = "redis")
    static final GenericContainer<?> VALKEY = new GenericContainer<>("valkey/valkey:8").withExposedPorts(6379);

    static {
        POSTGRES.start();
        VALKEY.start();
    }
}
