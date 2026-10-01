package dev.starindex.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.net.InetAddress;
import java.net.UnknownHostException;

/**
 * The web server is a local operator tool (ADR-017: no public server; the app reads static packs from the Neon
 * Object Storage bucket). Every request must come from a loopback socket address; anything else gets 403, even if
 * the port is published by mistake. The address is the TCP peer: {@code server.forward-headers-strategy=none}, so a
 * forged {@code X-Forwarded-For} cannot pose as loopback.
 */
public class LocalOnlyFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        if (isLoopback(req.getRemoteAddr())) {
            chain.doFilter(req, res);
        } else {
            res.setStatus(HttpServletResponse.SC_FORBIDDEN);
            res.setContentType("text/plain;charset=UTF-8");
            res.getWriter().write("forbidden");
        }
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
