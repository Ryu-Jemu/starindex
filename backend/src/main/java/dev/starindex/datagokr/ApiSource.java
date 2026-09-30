package dev.starindex.datagokr;

/**
 * data.go.kr services used by the ETL. Each needs its own 활용신청 approval on the same account key.
 * The gateway accepts the key parameter case-insensitively; the documented spelling is kept.
 */
public enum ApiSource {
    KMA_VILAGE("1360000/VilageFcstInfoService_2.0", "serviceKey", "기상청 단기예보 조회서비스", "15084084", true),
    KASI_RISESET("B090041/openapi/service/RiseSetInfoService", "ServiceKey", "한국천문연구원 출몰시각 정보", "15012688", true),
    KASI_ASTRO_EVENT("B090041/openapi/service/AstroEventInfoService", "ServiceKey", "한국천문연구원 천문현상 정보", "15012691", true),
    KASI_SPECIAL_DAY("B090041/openapi/service/SpcdeInfoService", "ServiceKey", "한국천문연구원 특일 정보", "15012690", false),
    KASI_LUNAR("B090041/openapi/service/LrsrCldInfoService", "ServiceKey", "한국천문연구원 음양력 정보", "15012679", false);

    private final String path;
    private final String keyParam;
    private final String titleKo;
    private final String dataGoKrId;
    private final boolean requiredForM0;

    ApiSource(String path, String keyParam, String titleKo, String dataGoKrId, boolean requiredForM0) {
        this.path = path;
        this.keyParam = keyParam;
        this.titleKo = titleKo;
        this.dataGoKrId = dataGoKrId;
        this.requiredForM0 = requiredForM0;
    }

    public String path() { return path; }
    public String keyParam() { return keyParam; }
    public String titleKo() { return titleKo; }
    /** data.go.kr dataset id: https://www.data.go.kr/data/{id}/openapi.do */
    public String dataGoKrId() { return dataGoKrId; }
    /** The three services applied for in M0; 특일·음양력 are optional until applied for (SERVICE-PLAN 11.3). */
    public boolean requiredForM0() { return requiredForM0; }
}
