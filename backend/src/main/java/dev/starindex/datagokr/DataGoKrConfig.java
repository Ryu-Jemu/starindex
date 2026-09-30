package dev.starindex.datagokr;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.Duration;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

@Configuration
@EnableConfigurationProperties(DataGoKrProperties.class)
public class DataGoKrConfig {
    private static final Logger log = LoggerFactory.getLogger(DataGoKrConfig.class);
    private static final ZoneId KST = ZoneId.of("Asia/Seoul");

    @Bean
    DataGoKrClient dataGoKrClient(DataGoKrProperties props, ApiCallRecorder recorder, QuotaGuard quota) {
        if (!props.hasServiceKey())
            log.warn("DATA_GO_KR_SERVICE_KEY is empty: key-dependent ETL steps will stop with KEY_MISSING (key-free steps still run)");
        else if (props.looksPercentEncoded())
            log.warn("DATA_GO_KR_SERVICE_KEY looks percent-encoded (the 'Encoding' key). Use the 'Decoding' key; it is encoded once by the client.");
        return new DataGoKrClient(props, recorder, quota);
    }

    @Bean
    ApiCallRecorder jdbcApiCallRecorder(JdbcTemplate jdbc) {
        return c -> jdbc.update("""
                INSERT INTO etl_api_call (source, operation, request_key, http_status, result_code, result_msg,
                                          item_count, duration_ms, outcome)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                c.source().name(), c.operation(), truncate(c.requestKey(), 80), c.httpStatus(), truncate(c.resultCode(), 10),
                truncate(c.resultMsg(), 160), c.itemCount(), c.durationMs(), c.outcome());
    }

    /**
     * Redis counter {@code quota:{source}:{yyyyMMdd KST}} (TTL 2 days): warn once at the warn ratio, refuse at the stop
     * ratio (PLAN 3.4: 70 % / 90 %). If Redis is down the call proceeds (the gateway still enforces its own limit).
     */
    @Bean
    QuotaGuard redisQuotaGuard(StringRedisTemplate redis, DataGoKrProperties props) {
        Set<String> warned = ConcurrentHashMap.newKeySet();
        return source -> {
            String day = LocalDate.now(KST).format(DateTimeFormatter.BASIC_ISO_DATE);
            String key = "quota:" + source.name().toLowerCase() + ":" + day;
            Long n;
            try {
                n = redis.opsForValue().increment(key);
                if (n != null && n == 1) redis.expire(key, Duration.ofDays(2));
            } catch (RuntimeException e) {
                log.warn("quota counter unavailable ({}), allowing {}", e.getClass().getSimpleName(), source);
                return;
            }
            if (n == null) return;
            if (n > props.dailyQuota() * props.quotaStopRatio()) {
                redis.opsForValue().decrement(key);
                throw new DataGoKrException(source, DataGoKrException.Kind.QUOTA, "LOCAL",
                        0, "local quota guard: " + (n - 1) + " calls today (stop at " + (int) (props.quotaStopRatio() * 100) + "%)");
            }
            if (n >= props.dailyQuota() * props.quotaWarnRatio() && warned.add(key))
                log.warn("{} used {} of {} daily calls", source, n, props.dailyQuota());
        };
    }

    private static String truncate(String s, int max) { return s == null || s.length() <= max ? s : s.substring(0, max); }
}
