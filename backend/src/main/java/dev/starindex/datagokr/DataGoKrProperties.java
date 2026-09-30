package dev.starindex.datagokr;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/**
 * {@code starindex.data-go-kr.*}. The service key is the data.go.kr "일반 인증키 (Decoding)": the client URL-encodes it
 * exactly once. Supplying the already-encoded "Encoding" key would double-encode it (%2B → %252B → error 30).
 */
@ConfigurationProperties("starindex.data-go-kr")
public record DataGoKrProperties(
        String serviceKey,
        String baseUrl,
        Duration connectTimeout,
        Duration readTimeout,
        Duration minInterval,
        int dailyQuota,
        double quotaWarnRatio,
        double quotaStopRatio) {

    public DataGoKrProperties {
        if (baseUrl == null || baseUrl.isBlank()) baseUrl = "https://apis.data.go.kr";
        if (connectTimeout == null) connectTimeout = Duration.ofSeconds(5);
        if (readTimeout == null) readTimeout = Duration.ofSeconds(20);
        if (minInterval == null) minInterval = Duration.ofMillis(60);
        if (dailyQuota <= 0) dailyQuota = 10_000;
        if (quotaWarnRatio <= 0) quotaWarnRatio = 0.7;
        if (quotaStopRatio <= 0) quotaStopRatio = 0.9;
        serviceKey = serviceKey == null ? "" : serviceKey.strip();
    }

    public boolean hasServiceKey() { return !serviceKey.isEmpty(); }

    /** An "Encoding" key contains '%' escapes; the Decoding key never does. */
    public boolean looksPercentEncoded() { return serviceKey.contains("%2B") || serviceKey.contains("%2F") || serviceKey.contains("%3D"); }
}
