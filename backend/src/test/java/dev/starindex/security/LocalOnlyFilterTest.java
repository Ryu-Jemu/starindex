package dev.starindex.security;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LocalOnlyFilterTest {
    @Test
    void loopbackMeansTheMachineItself() {
        for (String a : new String[]{"127.0.0.1", "127.8.9.10", "::1", "0:0:0:0:0:0:0:1"}) assertTrue(LocalOnlyFilter.isLoopback(a), a);
        for (String a : new String[]{"10.0.0.5", "172.31.1.2", "192.168.0.7", "13.124.199.10", "::ffff:8.8.8.8", "localhost", "", null,
                "127.0.0.1.evil.com"})
            assertFalse(LocalOnlyFilter.isLoopback(a), String.valueOf(a));
    }

    @Test
    void serverNameMustBeThisMachine() {
        for (String h : new String[]{"localhost", "127.0.0.1", "::1", "[::1]", "LOCALHOST"})
            assertTrue(LocalOnlyFilter.isLocalServerName(h), h);
        for (String h : new String[]{"evil.example", "localhost.evil.example", "127.0.0.1.nip.io", "[::2]", "10.0.0.1", "", null})
            assertFalse(LocalOnlyFilter.isLocalServerName(h), String.valueOf(h));
    }
}
