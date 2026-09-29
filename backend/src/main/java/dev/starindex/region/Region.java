package dev.starindex.region;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** Administrative region with its KMA forecast grid (M0: 17 시·도 representatives). */
@Entity
@Table(name = "region")
public class Region {
    @Id
    private Long id;

    @Column(nullable = false, length = 20)
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

    protected Region() {}

    public Region(Long id, String sido, String sigungu, String nameKo, double lat, double lon, int kmaNx, int kmaNy) {
        this.id = id;
        this.sido = sido;
        this.sigungu = sigungu;
        this.nameKo = nameKo;
        this.lat = lat;
        this.lon = lon;
        this.kmaNx = kmaNx;
        this.kmaNy = kmaNy;
    }

    public Long getId() { return id; }
    public String getSido() { return sido; }
    public String getSigungu() { return sigungu; }
    public String getNameKo() { return nameKo; }
    public double getLat() { return lat; }
    public double getLon() { return lon; }
    public int getKmaNx() { return kmaNx; }
    public int getKmaNy() { return kmaNy; }
}
