package dev.starindex.etl;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/** {@code starindex.etl.*} and {@code starindex.pack.*}. */
public final class EtlProperties {
    private EtlProperties() {}

    /**
     * Lifecycle floors (ADR-018). Collected data: 12 hours, the least that still lets the last run of a night (05:20)
     * compute it from its first dark hour (yesterday ~19:00). History: one full day of runs (8 forecast runs, the
     * 24-hour unattended check and the admin page's history).
     */
    public static final Duration MIN_DATA_RETENTION = Duration.ofHours(12), MIN_HISTORY_RETENTION = Duration.ofDays(1);

    /**
     * @param dataRetention    forecast hours are deleted this long after their forecast time (night-keyed data and
     *                         calendars go once their night or day has passed)
     * @param historyRetention API call log, cross-check, pack history and files, Spring Batch metadata
     */
    @ConfigurationProperties("starindex.etl")
    public record Etl(Duration kmaAvailabilityDelay, double forecastMinCompleteness, int astroDaysAhead,
                      Duration dataRetention, Duration historyRetention, int packKeepMin, Schedule schedule) {
        public Etl {
            if (dataRetention == null || dataRetention.isZero() || dataRetention.isNegative()) dataRetention = Duration.ofHours(12);
            if (historyRetention == null || historyRetention.isZero() || historyRetention.isNegative()) historyRetention = Duration.ofDays(2);
            if (dataRetention.compareTo(MIN_DATA_RETENTION) < 0)
                throw new IllegalArgumentException("starindex.etl.data-retention must be >= " + MIN_DATA_RETENTION
                        + " (the 05:20 run still reads yesterday's evening forecast): " + dataRetention);
            if (historyRetention.compareTo(MIN_HISTORY_RETENTION) < 0)
                throw new IllegalArgumentException("starindex.etl.history-retention must be >= " + MIN_HISTORY_RETENTION
                        + " (one full day of runs): " + historyRetention);
            if (packKeepMin <= 0) packKeepMin = 3;
            if (kmaAvailabilityDelay == null) kmaAvailabilityDelay = Duration.ofMinutes(15);
            if (forecastMinCompleteness <= 0) forecastMinCompleteness = 0.9;
            if (astroDaysAhead < 0) astroDaysAhead = 3;
            if (schedule == null) schedule = new Schedule(false);
        }
    }

    public record Schedule(boolean enabled) {}

    /**
     * @param s3Bucket   non-empty → packs go to this bucket (PACK_BUCKET; the Neon public bucket, ADR-017); empty → {@code localDir}
     * @param s3Endpoint the S3-compatible endpoint (Neon Object Storage, or S3Mock locally); path-style addressing
     * @param s3AccessKeyId     a Neon storage credential (token_id); with the secret it overrides the SDK's default
     *                          chain, which reads only real environment variables (backend/.env is a Spring source)
     */
    @ConfigurationProperties("starindex.pack")
    public record Pack(String localDir, int hourlySlots, String s3Bucket, String s3Region, String s3Endpoint,
                       String s3AccessKeyId, String s3SecretAccessKey) {
        public Pack {
            if (localDir == null || localDir.isBlank()) localDir = "build/packs";
            if (hourlySlots <= 0) hourlySlots = 72;
            if (s3Region == null || s3Region.isBlank()) s3Region = "ap-southeast-1";
        }

        public boolean usesS3() { return s3Bucket != null && !s3Bucket.isBlank(); }
    }
}
