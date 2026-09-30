package dev.starindex.datagokr;

/** A data.go.kr call that did not produce data, classified so jobs can decide: stop, skip or retry. */
public class DataGoKrException extends RuntimeException {

    public enum Kind {
        /** No key configured: nothing to call. */
        KEY_MISSING,
        /** Gateway refused the key: not registered/approved for this API yet, expired, IP or signature (20, 21, 30–33). */
        KEY_REJECTED,
        /** Daily or per-second quota (22, 23), or our own quota guard. */
        QUOTA,
        /** Provider-level error inside response.header (01, 02, 04, 05, 10, 11, 99 …). */
        PROVIDER,
        /** Other gateway refusals (12 no such service, 29 blacklisted IP …). */
        GATEWAY,
        /** Network, timeout or HTTP without a recognisable body. */
        IO,
        /** Body is neither a data.go.kr response nor a gateway error. */
        PARSE;

        public boolean retryable() { return this == IO || this == PROVIDER; }
    }

    private final ApiSource source;
    private final Kind kind;
    private final String code;
    private final int httpStatus;

    public DataGoKrException(ApiSource source, Kind kind, String code, int httpStatus, String message, Throwable cause) {
        super(message, cause);
        this.source = source;
        this.kind = kind;
        this.code = code;
        this.httpStatus = httpStatus;
    }

    public DataGoKrException(ApiSource source, Kind kind, String code, int httpStatus, String message) {
        this(source, kind, code, httpStatus, message, null);
    }

    public ApiSource source() { return source; }
    public Kind kind() { return kind; }
    public String code() { return code; }
    public int httpStatus() { return httpStatus; }

    /** One Korean line an operator can act on (job exit description, keycheck report). */
    public String guidance() {
        String api = source == null ? "data.go.kr" : source.titleKo();
        return switch (kind) {
            case KEY_MISSING -> "인증키가 없습니다. backend/.env에 DATA_GO_KR_SERVICE_KEY=<일반 인증키(Decoding)>를 넣으세요.";
            case KEY_REJECTED -> api + ": 키가 거부됐습니다(" + code + " " + getMessage() + "). 이 API의 활용신청 승인 여부를 확인하세요. "
                    + "승인 직후에는 키 활성화까지 1~2시간 걸릴 수 있고, Encoding 키를 넣었다면 Decoding 키로 바꾸세요.";
            case QUOTA -> api + ": 호출 한도에 걸렸습니다(" + code + "). 내일 다시 실행하거나 운영계정 트래픽 증가를 신청하세요.";
            case PROVIDER -> api + ": 제공기관 오류(" + code + " " + getMessage() + ").";
            case GATEWAY -> api + ": 게이트웨이 오류(" + code + " " + getMessage() + ").";
            case IO -> api + ": 통신 오류(" + getMessage() + ").";
            case PARSE -> api + ": 응답 형식을 해석하지 못했습니다(" + getMessage() + ").";
        };
    }
}
