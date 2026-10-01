package dev.starindex.security;

import com.nimbusds.jose.jwk.source.ImmutableSecret;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jose.jws.MacAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.security.oauth2.jwt.JwtIssuerValidator;
import org.springframework.security.oauth2.jwt.JwtTimestampValidator;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;

import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.UUID;

/**
 * HS256 admin tokens (PLAN D11: the app has no user login; JWT is for the operator only). Logout puts the token id
 * on a Redis deny list until the token would expire ({@code jwt:deny:{jti}}).
 */
public class AdminTokenService {
    private static final Logger log = LoggerFactory.getLogger(AdminTokenService.class);
    public static final String ISSUER = "starindex-admin";
    public static final String SCOPE = "admin";

    public record Issued(String token, Instant expiresAt) {}

    private final SecretKey key;
    private final Duration ttl;
    private final StringRedisTemplate redis;
    private final NimbusJwtEncoder encoder;

    public AdminTokenService(AdminProperties.Admin props, StringRedisTemplate redis) {
        this.key = new SecretKeySpec(secretBytes(props.jwtSecret()), "HmacSHA256");
        this.ttl = props.tokenTtl();
        this.redis = redis;
        this.encoder = new NimbusJwtEncoder(new ImmutableSecret<>(key));
    }

    static byte[] secretBytes(String base64) {
        if (base64 == null || base64.isBlank()) {
            log.warn("starindex.admin.jwt-secret is empty: using a random key for this process (local development only)");
            byte[] b = new byte[32];
            new SecureRandom().nextBytes(b);
            return b;
        }
        byte[] b = Base64.getDecoder().decode(base64.strip());
        if (b.length < 32) throw new IllegalArgumentException("starindex.admin.jwt-secret must decode to at least 32 bytes (HS256)");
        return b;
    }

    public Issued issue(String subject) {
        Instant now = Instant.now();
        Instant exp = now.plus(ttl);
        var claims = JwtClaimsSet.builder().issuer(ISSUER).subject(subject).issuedAt(now).expiresAt(exp)
                .id(UUID.randomUUID().toString()).claim("scope", SCOPE).build();
        var header = JwsHeader.with(MacAlgorithm.HS256).build();
        return new Issued(encoder.encode(JwtEncoderParameters.from(header, claims)).getTokenValue(), exp);
    }

    public void revoke(Jwt jwt) {
        if (jwt.getId() == null || jwt.getExpiresAt() == null) return;
        Duration left = Duration.between(Instant.now(), jwt.getExpiresAt());
        if (!left.isNegative() && !left.isZero()) redis.opsForValue().set("jwt:deny:" + jwt.getId(), "1", left);
    }

    public JwtDecoder decoder() {
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withSecretKey(key).macAlgorithm(MacAlgorithm.HS256).build();
        OAuth2TokenValidator<Jwt> notRevoked = jwt -> jwt.getId() != null && !Boolean.TRUE.equals(redis.hasKey("jwt:deny:" + jwt.getId()))
                ? OAuth2TokenValidatorResult.success()
                : OAuth2TokenValidatorResult.failure(new OAuth2Error("invalid_token", "token revoked", null));
        decoder.setJwtValidator(new DelegatingOAuth2TokenValidator<>(
                new JwtTimestampValidator(Duration.ofSeconds(30)), new JwtIssuerValidator(ISSUER), notRevoked));
        return decoder;
    }
}
