package dev.starindex.etl;

/** Stops a step with a Korean, operator-facing message (shown by {@link EtlJobListener}). */
public class EtlStopException extends RuntimeException {
    public EtlStopException(String message) {
        super(message);
    }

    public EtlStopException(String message, Throwable cause) {
        super(message, cause);
    }
}
