package dev.starindex.datagokr;

/** Audit sink for every data.go.kr attempt (etl_api_call). Must never receive the key or user coordinates. */
@FunctionalInterface
public interface ApiCallRecorder {
    record Call(ApiSource source, String operation, String requestKey, Integer httpStatus, String resultCode,
                String resultMsg, Integer itemCount, int durationMs, String outcome) {}

    void record(Call call);

    ApiCallRecorder NONE = call -> {};
}
