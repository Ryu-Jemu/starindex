package dev.starindex;

import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.postgresql.PostgreSQLContainer;

/**
 * Singleton containers shared by every integration test class (started once per JVM), so the Spring context
 * cache is reused across classes. PostgreSQL 18 = the planned RDS major; Valkey 8 = Redis-compatible store.
 */
@SpringBootTest(properties = "spring.data.redis.repositories.enabled=false")
public abstract class IntegrationTestBase {

    @ServiceConnection
    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:18");

    @ServiceConnection(name = "redis")
    static final GenericContainer<?> VALKEY = new GenericContainer<>("valkey/valkey:8").withExposedPorts(6379);

    static {
        POSTGRES.start();
        VALKEY.start();
    }
}
