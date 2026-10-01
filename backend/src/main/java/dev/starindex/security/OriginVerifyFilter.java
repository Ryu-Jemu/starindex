package dev.starindex.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/**
 * Allow-list in front of everything on port 8080 (PLAN 3.4 "보안 필터").
 * <ul>
 *   <li>{@code X-Origin-Verify} present and correct (CloudFront): only {@code /api/health}, {@code /api/v1/**},
 *   {@code /ws/v1/**}. Admin paths are never reachable through CloudFront.</li>
 *   <li>Header present but wrong (or no secret configured): 403.</li>
 *   <li>No header: only from a loopback socket address (the SSM port-forwarding tunnel ends on the instance itself).</li>
 * </ul>
 * The address is the TCP peer: {@code server.forward-headers-strategy=none}, so a forged {@code X-Forwarded-For}
 * cannot pose as loopback. The security group admits port 8080 from CloudFront's origin-facing prefix list only.
 */
public class OriginVerifyFilter extends OncePerRequestFilter {
    public static final String HEADER = "X-Origin-Verify";

    private final byte[] secret;

    public OriginVerifyFilter(String secret) {
        this.secret = secret == null || secret.isBlank() ? null : secret.getBytes(StandardCharsets.UTF_8);
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        String header = req.getHeader(HEADER);
        boolean allowed = header == null ? isLoopback(req.getRemoteAddr()) : verified(header) && isPublicPath(path(req));
        if (allowed) {
            chain.doFilter(req, res);
        } else {
            res.setStatus(HttpServletResponse.SC_FORBIDDEN);
            res.setContentType("text/plain;charset=UTF-8");
            res.getWriter().write("forbidden");
        }
    }

    private boolean verified(String header) {
        // Constant time: the comparison must not leak how many leading bytes matched.
        return secret != null && MessageDigest.isEqual(secret, header.getBytes(StandardCharsets.UTF_8));
    }

    /** Raw (undecoded) path inside the application, without the context path. */
    private static String path(HttpServletRequest req) {
        String uri = req.getRequestURI();
        String ctx = req.getContextPath();
        return ctx != null && !ctx.isEmpty() && uri.startsWith(ctx) ? uri.substring(ctx.length()) : uri;
    }

    /** Anything a decoder or path normalizer could read differently ("..", ";", "//", percent escapes) is refused. */
    static boolean isPublicPath(String path) {
        if (path.contains("..") || path.contains(";") || path.contains("//") || path.contains("%")) return false;
        return path.equals("/api/health") || path.startsWith("/api/v1/") || path.startsWith("/ws/v1/");
    }

    static boolean isLoopback(String address) {
        if (address == null || address.isBlank()) return false;
        // Only literal IPs: never resolve a name here.
        if (!address.matches("[0-9.]+|[0-9a-fA-F:]+(%\\w+)?")) return false;
        try {
            return InetAddress.getByName(address).isLoopbackAddress();
        } catch (UnknownHostException e) {
            return false;
        }
    }
}
