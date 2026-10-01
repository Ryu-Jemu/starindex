package dev.starindex.api;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Liveness of the local server. It never touches the database: a periodic probe of {@code /actuator/health} (db
 * indicator) would keep Neon's compute awake (ADR-015).
 */
@RestController
public class HealthController {
    private static final Map<String, String> UP = Map.of("status", "UP");

    @GetMapping("/api/health")
    public Map<String, String> health() {
        return UP;
    }
}
