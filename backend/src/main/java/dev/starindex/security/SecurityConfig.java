package dev.starindex.security;

import org.springframework.boot.autoconfigure.condition.ConditionalOnWebApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;

/**
 * Port 8080 has two audiences (PLAN 3.4/3.5): the public app traffic through CloudFront (health, /api/v1, /ws/v1)
 * and the operator through the SSM tunnel (admin page and /api/admin with a bearer JWT). {@link OriginVerifyFilter}
 * runs first and decides who may reach what; this chain then requires a token for /api/admin.
 * No cookies or sessions anywhere, so CSRF protection has nothing to protect.
 */
// Not in CLI runs (scripts/etl.sh: web-application-type=none): there is no HTTP surface to protect.
@ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.SERVLET)
@Configuration
@EnableConfigurationProperties({AdminProperties.Admin.class, AdminProperties.Security.class})
public class SecurityConfig {

    @Bean
    FilterRegistrationBean<OriginVerifyFilter> originVerifyFilter(AdminProperties.Security props) {
        var reg = new FilterRegistrationBean<>(new OriginVerifyFilter(props.originVerifySecret()));
        reg.setOrder(Ordered.HIGHEST_PRECEDENCE);   // before Spring Security's chain (order -100)
        reg.addUrlPatterns("/*");
        return reg;
    }

    @Bean
    AdminTokenService adminTokenService(AdminProperties.Admin props, StringRedisTemplate redis) {
        return new AdminTokenService(props, redis);
    }

    @Bean
    BCryptPasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http, AdminTokenService tokens) throws Exception {
        http.csrf(c -> c.disable())
                .httpBasic(b -> b.disable())
                .formLogin(f -> f.disable())
                .logout(l -> l.disable())
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .headers(h -> h.contentSecurityPolicy(csp -> csp.policyDirectives(
                        "default-src 'self'; script-src 'self' https://cdn.jsdelivr.net; style-src 'self' https://cdn.jsdelivr.net; "
                                + "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")))
                .authorizeHttpRequests(a -> a
                        .requestMatchers("/api/health", "/api/v1/**", "/ws/v1/**", "/error").permitAll()
                        .requestMatchers("/actuator/health", "/actuator/health/**").permitAll()   // loopback:8081 only
                        .requestMatchers("/admin", "/admin/**").permitAll()                       // static page, no data
                        .requestMatchers(HttpMethod.POST, "/api/admin/auth/login").permitAll()
                        .requestMatchers("/api/admin/**").hasAuthority("SCOPE_" + AdminTokenService.SCOPE)
                        .anyRequest().denyAll())
                .oauth2ResourceServer(o -> o.jwt(j -> j.decoder(tokens.decoder())));
        return http.build();
    }
}
