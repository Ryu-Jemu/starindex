package dev.starindex;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/**
 * DB-PLAN 6.1 / ADR-014: every migration applies as a NON-superuser database owner (as on RDS, where the master user
 * is not a superuser), and V5 carries the newest non-missing forecast values over from the old per-item table.
 */
class MigrationTest {

    static { IntegrationTestBase.POSTGRES.isRunning(); }   // reuse the shared container

    record Db(String name, String user, String password) {}

    /** A fresh database owned by a NOSUPERUSER NOCREATEDB role (created by the container's superuser). */
    static Db freshDatabase() {
        String id = UUID.randomUUID().toString().replace("-", "").substring(0, 10);
        Db db = new Db("mig_" + id, "owner_" + id, "pw-" + id);
        var admin = new JdbcTemplate(dataSource(IntegrationTestBase.POSTGRES.getDatabaseName(),
                IntegrationTestBase.POSTGRES.getUsername(), IntegrationTestBase.POSTGRES.getPassword()));
        admin.execute("CREATE ROLE " + db.user() + " LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '" + db.password() + "'");
        admin.execute("CREATE DATABASE " + db.name() + " OWNER " + db.user() + " TEMPLATE template0 ENCODING 'UTF8'");
        return db;
    }

    static DataSource dataSource(String dbName, String user, String password) {
        var pg = IntegrationTestBase.POSTGRES;
        return new DriverManagerDataSource(
                "jdbc:postgresql://" + pg.getHost() + ":" + pg.getMappedPort(5432) + "/" + dbName, user, password);
    }

    static Flyway flyway(DataSource ds, String target) {
        var c = Flyway.configure().dataSource(ds).locations("classpath:db/migration");
        if (target != null) c.target(MigrationVersion.fromVersion(target));
        return c.load();
    }

    @Test
    void allMigrationsApplyAsNonSuperuserOwner() {
        Db db = freshDatabase();
        DataSource ds = dataSource(db.name(), db.user(), db.password());
        var result = flyway(ds, null).migrate();
        assertTrue(result.success);
        var jdbc = new JdbcTemplate(ds);
        assertEquals(Boolean.FALSE, jdbc.queryForObject("SELECT rolsuper FROM pg_roles WHERE rolname = current_user", Boolean.class));
        assertEquals(17, jdbc.queryForObject("SELECT COUNT(*) FROM region", Integer.class));
    }

    @Test
    void v5CarriesOverTheNewestNonMissingValues() {
        Db db = freshDatabase();
        DataSource ds = dataSource(db.name(), db.user(), db.password());
        flyway(ds, "4").migrate();
        var jdbc = new JdbcTemplate(ds);
        jdbc.update("""
                INSERT INTO kma_forecast (nx, ny, base_at, fcst_at, category, value_text, value_num, value_is_code) VALUES
                (60, 127, now() - interval '5 hours', now() + interval '3 hours', 'SKY', '1', 1, false),
                (60, 127, now() - interval '2 hours', now() + interval '3 hours', 'SKY', '-999', NULL, false),
                (60, 127, now() - interval '2 hours', now() + interval '3 hours', 'TMP', '14.3', 14.3, false),
                (60, 127, now() - interval '2 hours', now() + interval '3 hours', 'WSD', '2', NULL, true),
                (60, 127, now() - interval '2 hours', now() + interval '3 hours', 'PCP', '강수없음', 0, false),
                (60, 127, now() - interval '9 days', now() - interval '8 days', 'SKY', '4', 4, false)""");
        flyway(ds, null).migrate();
        var row = jdbc.queryForMap("SELECT * FROM kma_forecast_hour");
        assertEquals((short) 1, ((Number) row.get("sky")).shortValue(), "older valid SKY replaces the newest missing one");
        assertEquals(new BigDecimal("14.3"), row.get("tmp"));
        assertNull(row.get("wsd"), "code values are not amounts");
        assertEquals(1, jdbc.queryForObject("SELECT COUNT(*) FROM kma_forecast_hour", Integer.class), "rows older than 2 days are dropped");
        assertEquals(0, jdbc.queryForObject(
                "SELECT COUNT(*) FROM information_schema.tables WHERE table_name IN ('kma_forecast', 'kma_forecast_issue')", Integer.class));
    }
}
