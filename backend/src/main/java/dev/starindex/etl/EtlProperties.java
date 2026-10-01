package dev.starindex.etl;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/** {@code starindex.etl.*} and {@code starindex.pack.*}. */
public final class EtlProperties {
    private EtlProperties() {}

    /** Retention floors (DB-PLAN 4.3): 2 days to republish last night, 8 days for the 7-day G6 window + 1. */
    public static final int MIN_FORECAST_RETENTION_DAYS = 2, MIN_AUDIT_RETENTION_DAYS = 8;

    @ConfigurationProperties("starindex.etl")
    public record Etl(Duration kmaAvailabilityDelay, double forecastMinCompleteness, int astroDaysAhead,
                      int forecastRetentionDays, int auditRetentionDays, int packKeepMin, Schedule schedule) {
        public Etl {
            if (forecastRetentionDays <= 0) forecastRetentionDays = MIN_FORECAST_RETENTION_DAYS;
            if (auditRetentionDays <= 0) auditRetentionDays = MIN_AUDIT_RETENTION_DAYS;
            if (forecastRetentionDays < MIN_FORECAST_RETENTION_DAYS)
                throw new IllegalArgumentException("starindex.etl.forecast-retention-days must be >= " + MIN_FORECAST_RETENTION_DAYS
                        + " (last night must stay republishable): " + forecastRetentionDays);
            if (auditRetentionDays < MIN_AUDIT_RETENTION_DAYS)
                throw new IllegalArgumentException("starindex.etl.audit-retention-days must be >= " + MIN_AUDIT_RETENTION_DAYS
                        + " (G6 judges 7 consecutive days): " + auditRetentionDays);
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
     */
    @ConfigurationProperties("starindex.pack")
    public record Pack(String localDir, int hourlySlots, String s3Bucket, String s3Region, String s3Endpoint) {
        public Pack {
            if (localDir == null || localDir.isBlank()) localDir = "build/packs";
            if (hourlySlots <= 0) hourlySlots = 72;
            if (s3Region == null || s3Region.isBlank()) s3Region = "ap-southeast-1";
        }

        public boolean usesS3() { return s3Bucket != null && !s3Bucket.isBlank(); }
    }
}
