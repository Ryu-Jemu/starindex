package dev.starindex.security;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/**
 * {@code starindex.admin.*} and {@code starindex.security.*}. On EC2 the secrets come from SSM SecureString through
 * deploy/app/start.sh (ADMIN_PASSWORD_HASH, ADMIN_JWT_SECRET, ORIGIN_VERIFY_SECRET); nothing secret is in app.env.
 */
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

    /** @param originVerifySecret value CloudFront sends in X-Origin-Verify; empty → only loopback is served */
    @ConfigurationProperties("starindex.security")
    public record Security(String originVerifySecret) {}
}
