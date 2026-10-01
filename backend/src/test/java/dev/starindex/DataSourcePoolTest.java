package dev.starindex;

import com.zaxxer.hikari.HikariDataSource;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import javax.sql.DataSource;

import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-015: on Neon Free the pool must let the compute scale to zero between batch runs, or the monthly CU-hours run
 * out (an always-open connection pinged every 2 minutes ≈ 180 CU-h/month against a 100 CU-h limit).
 */
class DataSourcePoolTest extends IntegrationTestBase {
    @Autowired DataSource dataSource;

    @Test
    void poolHoldsNoIdleConnectionsAndNeverPings() {
        var hikari = assertInstanceOf(HikariDataSource.class, dataSource);
        assertEquals(0, hikari.getMinimumIdle(), "no connection kept open between jobs");
        assertEquals(0, hikari.getKeepaliveTime(), "no keepalive ping (HikariCP 7 default is 2 min)");
        assertTrue(hikari.getIdleTimeout() >= 10_000 && hikari.getIdleTimeout() <= 120_000,
                "idle connections close well before Neon's 5-minute suspend: " + hikari.getIdleTimeout());
        assertEquals(5, hikari.getMaximumPoolSize());
    }
}
