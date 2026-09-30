package dev.starindex.region;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * A forecast point with its KMA grid: the 16 시·도 representatives of the official grid sheet plus EXTRA points
 * chosen for the product (V2__region.sql). The id is the 10-digit 행정구역코드.
 */
@Entity
@Table(name = "region")
public class Region {
    public enum Kind { SIDO, EXTRA }

    @Id
    private Long id;

    @Column(nullable = false, length = 8)
    @Enumerated(EnumType.STRING)
    private Kind kind;

    @Column(nullable = false, length = 30)
    private String sido;

    @Column(length = 30)
    private String sigungu;

    @Column(name = "name_ko", nullable = false, length = 40)
    private String nameKo;

    private double lat;
    private double lon;

    @Column(name = "kma_nx", nullable = false)
    private int kmaNx;

    @Column(name = "kma_ny", nullable = false)
    private int kmaNy;

    @Column(nullable = false)
    private boolean active;

    protected Region() {}

    public Region(Long id, Kind kind, String sido, String sigungu, String nameKo, double lat, double lon,
                  int kmaNx, int kmaNy, boolean active) {
        this.id = id;
        this.kind = kind;
        this.sido = sido;
        this.sigungu = sigungu;
        this.nameKo = nameKo;
        this.lat = lat;
        this.lon = lon;
        this.kmaNx = kmaNx;
        this.kmaNy = kmaNy;
        this.active = active;
    }

    public Long getId() { return id; }
    public Kind getKind() { return kind; }
    public String getSido() { return sido; }
    public String getSigungu() { return sigungu; }
    public String getNameKo() { return nameKo; }
    public double getLat() { return lat; }
    public double getLon() { return lon; }
    public int getKmaNx() { return kmaNx; }
    public int getKmaNy() { return kmaNy; }
    public boolean isActive() { return active; }
}
