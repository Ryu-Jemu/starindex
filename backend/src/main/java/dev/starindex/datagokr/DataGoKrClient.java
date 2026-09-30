package dev.starindex.datagokr;

import dev.starindex.datagokr.DataGoKrException.Kind;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.web.client.RestClient;
import org.springframework.web.util.UriComponentsBuilder;

import java.net.URI;
import java.net.http.HttpClient;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Calls one data.go.kr operation and returns its parsed body, or throws a classified {@link DataGoKrException}.
 * <ul>
 *   <li>The key and every query value are URI template variables → strictly encoded once (+ → %2B, / → %2F, = → %3D).</li>
 *   <li>Gateway errors arrive as HTTP 4xx with an {@code OpenAPI_ServiceResponse} body; the body is read on any status.</li>
 *   <li>resultCode "00"/"0" = OK, "03" = NO_DATA (empty result, not an error).</li>
 *   <li>IO and provider errors are retried twice (1 s, 3 s); key and quota errors are not.</li>
 *   <li>Every attempt is recorded ({@link ApiCallRecorder}); the key and the full URL are never logged.</li>
 * </ul>
 */
public class DataGoKrClient {
    private static final Logger log = LoggerFactory.getLogger(DataGoKrClient.class);
    private static final Set<String> KEY_CODES = Set.of("20", "21", "30", "31", "32", "33");
    private static final Set<String> QUOTA_CODES = Set.of("22", "23");
    private static final long[] BACKOFF_MS = {1000, 3000};

    private final DataGoKrProperties props;
    private final RestClient http;
    private final ApiCallRecorder recorder;
    private final QuotaGuard quota;
    private final Object throttleLock = new Object();
    private long lastCallNanos;

    public DataGoKrClient(DataGoKrProperties props, ApiCallRecorder recorder, QuotaGuard quota) {
        this.props = props;
        this.recorder = recorder;
        this.quota = quota;
        var factory = new JdkClientHttpRequestFactory(HttpClient.newBuilder()
                .connectTimeout(props.connectTimeout())
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build());
        factory.setReadTimeout(props.readTimeout());
        this.http = RestClient.builder().requestFactory(factory).build();
    }

    public DataGoKrProperties properties() { return props; }

    /**
     * @param params     query parameters other than the key, in order
     * @param requestKey short, key-free description for the audit log, e.g. "60,127@20260930 0500 p1"
     */
    public DataGoKrXml.Body get(ApiSource source, String operation, Map<String, String> params, String requestKey) {
        if (!props.hasServiceKey())
            throw new DataGoKrException(source, Kind.KEY_MISSING, null, 0, "DATA_GO_KR_SERVICE_KEY is empty");
        DataGoKrException last = null;
        for (int attempt = 0; attempt <= BACKOFF_MS.length; attempt++) {
            if (attempt > 0) sleep(BACKOFF_MS[attempt - 1]);
            try {
                return once(source, operation, params, requestKey);
            } catch (DataGoKrException e) {
                last = e;
                if (!e.kind().retryable()) throw e;
                log.warn("{} {} {} failed ({} {}), attempt {}", source, operation, requestKey, e.kind(), e.code(), attempt + 1);
            }
        }
        throw last;
    }

    private DataGoKrXml.Body once(ApiSource source, String operation, Map<String, String> params, String requestKey) {
        quota.acquire(source);
        throttle();
        URI uri = buildUri(source, operation, params);
        long t0 = System.nanoTime();
        Integer status = null;
        try {
            Raw raw = http.get().uri(uri).exchangeForRequiredValue(
                    (req, res) -> new Raw(res.getStatusCode().value(), res.getBody().readAllBytes()), true);
            status = raw.status();
            DataGoKrXml.Parsed parsed;
            try {
                parsed = DataGoKrXml.parse(raw.body());
            } catch (IllegalArgumentException e) {
                Kind kind = raw.status() >= 400 ? Kind.IO : Kind.PARSE;
                throw fail(source, operation, requestKey, t0, status, null, e.getMessage(), kind, "HTTP " + raw.status(), e);
            }
            if (parsed instanceof DataGoKrXml.GatewayError g) {
                Kind kind = KEY_CODES.contains(g.code()) ? Kind.KEY_REJECTED
                        : QUOTA_CODES.contains(g.code()) ? Kind.QUOTA : Kind.GATEWAY;
                throw fail(source, operation, requestKey, t0, status, g.code(), g.errMsg(), kind, g.errMsg(), null);
            }
            DataGoKrXml.Body body = (DataGoKrXml.Body) parsed;
            if (!body.ok() && !body.noData()) {
                Kind kind = "22".equals(body.resultCode()) ? Kind.QUOTA
                        : KEY_CODES.contains(body.resultCode()) ? Kind.KEY_REJECTED : Kind.PROVIDER;
                throw fail(source, operation, requestKey, t0, status, body.resultCode(), body.resultMsg(), kind, body.resultMsg(), null);
            }
            record(source, operation, requestKey, t0, status, body.resultCode(), body.resultMsg(), body.items().size(),
                    body.noData() ? "NO_DATA" : "OK");
            return body;
        } catch (DataGoKrException e) {
            throw e;
        } catch (Exception e) {
            throw fail(source, operation, requestKey, t0, status, null, e.getClass().getSimpleName(), Kind.IO,
                    e.getClass().getSimpleName() + ": " + e.getMessage(), e);
        }
    }

    /** Package-visible for the encoding test. */
    URI buildUri(ApiSource source, String operation, Map<String, String> params) {
        UriComponentsBuilder b = UriComponentsBuilder.fromUriString(props.baseUrl())
                .path("/" + source.path() + "/" + operation);
        List<Object> values = new ArrayList<>();
        b.queryParam(source.keyParam(), "{v0}");
        values.add(props.serviceKey());
        int i = 1;
        for (var e : new LinkedHashMap<>(params).entrySet()) {
            b.queryParam(e.getKey(), "{v" + i++ + "}");
            values.add(e.getValue());
        }
        // encode() first: the template is encoded and the variables are STRICTLY encoded when expanded.
        return b.encode().buildAndExpand(values.toArray()).toUri();
    }

    private DataGoKrException fail(ApiSource source, String op, String requestKey, long t0, Integer status, String code,
                                   String msg, Kind kind, String message, Throwable cause) {
        record(source, op, requestKey, t0, status, code, msg, null, kind.name());
        return new DataGoKrException(source, kind, code, status == null ? 0 : status, message, cause);
    }

    private void record(ApiSource source, String op, String requestKey, long t0, Integer status, String code,
                        String msg, Integer items, String outcome) {
        int ms = (int) ((System.nanoTime() - t0) / 1_000_000);
        try {
            recorder.record(new ApiCallRecorder.Call(source, op, requestKey, status, code, msg, items, ms, outcome));
        } catch (RuntimeException e) {
            log.warn("could not record api call: {}", e.toString());
        }
    }

    private void throttle() {
        long gap = props.minInterval().toNanos();
        synchronized (throttleLock) {
            long wait = lastCallNanos + gap - System.nanoTime();
            if (wait > 0) sleep(wait / 1_000_000 + 1);
            lastCallNanos = System.nanoTime();
        }
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new DataGoKrException(null, Kind.IO, null, 0, "interrupted");
        }
    }

    private record Raw(int status, byte[] body) {}
}
