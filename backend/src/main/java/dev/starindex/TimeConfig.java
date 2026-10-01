package dev.starindex;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;

/**
 * The one clock jobs read "now" from: retention cutoffs, the default night, issue and month (ADR-018).
 * Production uses the system clock. Tests that run jobs on fixed fixture dates pin it with
 * {@code starindex.clock.fixed=2026-10-01T09:00:00+09:00}, so retention inside the jobs never ages their fixtures out
 * as the calendar moves on.
 */
@Configuration
public class TimeConfig {
    @Bean
    Clock clock(@Value("${starindex.clock.fixed:}") String fixed) {
        return fixed == null || fixed.isBlank() ? Clock.systemUTC()
                : Clock.fixed(OffsetDateTime.parse(fixed).toInstant(), ZoneOffset.UTC);
    }
}
