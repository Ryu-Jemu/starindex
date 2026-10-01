package dev.starindex.security;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/** {@code starindex.admin.*}: the local admin page's single login (backend/.env: ADMIN_PASSWORD_HASH, ADMIN_JWT_SECRET). */
public final class AdminProperties {
    private AdminProperties() {}

    /**
     * @param passwordHash bcrypt ($2a$/$2b$/$2y$); empty → admin login is disabled (503)
     * @param jwtSecret    base64, at least 32 bytes; empty → a random per-process key (tokens die with the process)
     */
    @ConfigurationProperties("starindex.admin")
    public record Admin(String username, String passwordHash, String jwtSecret, Duration tokenTtl,
                        int maxFailures, Duration lockout) {
        public Admin {
            if (username == null || username.isBlank()) username = "admin";
            if (tokenTtl == null || tokenTtl.isZero() || tokenTtl.isNegative()) tokenTtl = Duration.ofHours(1);
            if (maxFailures <= 0) maxFailures = 5;
            if (lockout == null || lockout.isZero() || lockout.isNegative()) lockout = Duration.ofMinutes(15);
        }

        public boolean loginEnabled() { return passwordHash != null && !passwordHash.isBlank(); }
    }
}
