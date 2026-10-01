package dev.starindex.admin;

import org.springframework.boot.autoconfigure.condition.ConditionalOnWebApplication;
import dev.starindex.security.AdminProperties;
import dev.starindex.security.AdminTokenService;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/**
 * Operator login (PLAN 3.4 {@code /api/admin/auth/login}). One account from configuration (bcrypt hash in SSM).
 * Five failures from one address lock it for 15 minutes ({@code auth:fail:{ip}} in Redis). Through the SSM tunnel
 * every request comes from loopback, so in practice the lock is global, which is what a single-operator page wants.
 */
@ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.SERVLET)
@RestController
@RequestMapping("/api/admin/auth")
public class AuthController {
    private static final Logger log = LoggerFactory.getLogger(AuthController.class);
    /** Compared against when the username is wrong, so both failures cost one bcrypt check. */
    private static final String DUMMY_HASH = "$2y$12$4zXFuVfCSn6IthR6TPtOm.zxlzZfQ5zKH8aUmjSke0e9zH.fTPcqS";

    public record Login(String username, String password) {}

    private final AdminProperties.Admin props;
    private final AdminTokenService tokens;
    private final BCryptPasswordEncoder bcrypt;
    private final StringRedisTemplate redis;

    public AuthController(AdminProperties.Admin props, AdminTokenService tokens, BCryptPasswordEncoder bcrypt, StringRedisTemplate redis) {
        this.props = props;
        this.tokens = tokens;
        this.bcrypt = bcrypt;
        this.redis = redis;
    }

    @PostMapping("/login")
    public ResponseEntity<?> login(@RequestBody(required = false) Login body, HttpServletRequest req) {
        if (!props.loginEnabled())
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(Map.of("error", "관리자 비밀번호가 설정되지 않았습니다(ADMIN_PASSWORD_HASH)"));
        String failKey = "auth:fail:" + req.getRemoteAddr();
        String count = redis.opsForValue().get(failKey);
        if (count != null && Long.parseLong(count) >= props.maxFailures()) {
            return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS)
                    .header("Retry-After", Long.toString(props.lockout().toSeconds()))
                    .body(Map.of("error", "로그인 실패가 많아 " + props.lockout().toMinutes() + "분 동안 잠겼습니다"));
        }
        String user = body == null || body.username() == null ? "" : body.username();
        String password = body == null || body.password() == null ? "" : body.password();
        boolean userOk = MessageDigest.isEqual(user.getBytes(StandardCharsets.UTF_8), props.username().getBytes(StandardCharsets.UTF_8));
        boolean passwordOk = bcrypt.matches(password, userOk ? props.passwordHash() : DUMMY_HASH);
        if (!userOk || !passwordOk) {
            Long n = redis.opsForValue().increment(failKey);
            if (n != null && n == 1) redis.expire(failKey, props.lockout());
            log.warn("admin login failed from {} ({} in the current window)", req.getRemoteAddr(), n);
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "아이디 또는 비밀번호가 틀렸습니다"));
        }
        redis.delete(failKey);
        var issued = tokens.issue(props.username());
        log.info("admin login from {}", req.getRemoteAddr());
        return ResponseEntity.ok(Map.of("token", issued.token(), "expiresAt", issued.expiresAt().toString()));
    }

    @PostMapping("/logout")
    public ResponseEntity<Void> logout(@AuthenticationPrincipal Jwt jwt) {
        tokens.revoke(jwt);
        return ResponseEntity.noContent().build();
    }
}
