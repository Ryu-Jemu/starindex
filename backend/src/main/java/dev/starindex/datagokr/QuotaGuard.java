package dev.starindex.datagokr;

/** Daily call budget per API (development account: 10,000/day). Throws {@link DataGoKrException} QUOTA when exhausted. */
@FunctionalInterface
public interface QuotaGuard {
    void acquire(ApiSource source);

    QuotaGuard NONE = source -> {};
}
