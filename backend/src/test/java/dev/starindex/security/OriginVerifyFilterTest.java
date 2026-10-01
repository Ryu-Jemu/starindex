package dev.starindex.security;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class OriginVerifyFilterTest {
    @Test
    void loopbackMeansTheMachineItself() {
        for (String a : new String[]{"127.0.0.1", "127.8.9.10", "::1", "0:0:0:0:0:0:0:1"}) assertTrue(OriginVerifyFilter.isLoopback(a), a);
        for (String a : new String[]{"10.0.0.5", "172.31.1.2", "13.124.199.10", "::ffff:8.8.8.8", "localhost", "", null, "127.0.0.1.evil.com"})
            assertFalse(OriginVerifyFilter.isLoopback(a), String.valueOf(a));
    }

    @Test
    void cloudFrontMayReachOnlyThePublicPaths() {
        for (String p : new String[]{"/api/health", "/api/v1/index", "/ws/v1/live"}) assertTrue(OriginVerifyFilter.isPublicPath(p), p);
        for (String p : new String[]{"/api/health/x", "/api/healthz", "/api/v1", "/api/admin/etl/runs", "/admin", "/admin/index.html",
                "/actuator/health", "/ws/admin", "/api/v1/../admin", "/api/v1/%2e%2e/admin", "/api/v1;a=b/x", "//api/v1/x", "/"})
            assertFalse(OriginVerifyFilter.isPublicPath(p), p);
    }
}
