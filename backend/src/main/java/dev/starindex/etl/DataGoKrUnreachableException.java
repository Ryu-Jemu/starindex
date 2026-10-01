package dev.starindex.etl;

/**
 * data.go.kr cannot be reached from this machine at all (the fail-fast in {@link ForecastIngestService}). A batch CLI run
 * that stops on it exits with {@link EtlJobListener#EXIT_UNREACHABLE}, and the scheduled workflow retries on a fresh
 * runner (ADR-017).
 */
public class DataGoKrUnreachableException extends EtlStopException {
    public DataGoKrUnreachableException(String message, Throwable cause) {
        super(message, cause);
    }
}
