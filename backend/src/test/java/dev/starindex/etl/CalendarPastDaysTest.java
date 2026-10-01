package dev.starindex.etl;

import dev.starindex.etl.kasi.KasiClient;
import dev.starindex.region.RegionQueryRepository;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.Clock;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.YearMonth;
import java.time.ZoneOffset;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

/** ADR-018: calendar days that have already passed are never stored; a monthly feature stays while its month lasts. */
class CalendarPastDaysTest {
    static Clock at(String iso) { return Clock.fixed(OffsetDateTime.parse(iso).toInstant(), ZoneOffset.UTC); }

    @Test
    @SuppressWarnings("unchecked")
    void pastDaysAreFilteredBeforeTheUpsert() {
        var kasi = mock(KasiClient.class);
        var repo = mock(EtlRepository.class);
        var ym = YearMonth.of(2026, 10);
        when(kasi.astroEvents(ym)).thenReturn(List.of(
                new KasiClient.AstroEvent(LocalDate.of(2026, 10, 1), true, 1, null, "가을 별자리", "이달의 천문 이야기", null),
                new KasiClient.AstroEvent(LocalDate.of(2026, 10, 2), false, 1, null, "", "지난 현상", null),
                new KasiClient.AstroEvent(LocalDate.of(2026, 10, 3), false, 1, null, "", "오늘 밤 현상", null)));
        when(kasi.lunarMonth(ym)).thenReturn(List.of(
                new KasiClient.LunarDay(LocalDate.of(2026, 10, 2), 2026, 8, 22, false, "을축"),
                new KasiClient.LunarDay(LocalDate.of(2026, 10, 3), 2026, 8, 23, false, "병인")));
        when(kasi.specialDays(any(), eq(ym))).thenReturn(List.of());
        // 2026-10-04 05:00 KST: the night in progress is 10-03.
        var svc = new AstroService(mock(RegionQueryRepository.class), kasi, repo, at("2026-10-04T05:00:00+09:00"));

        assertEquals(2, svc.fetchAstroEvents(ym));
        var events = ArgumentCaptor.forClass(List.class);
        verify(repo).upsertAstroEvents(events.capture());
        assertEquals(List.of("이달의 천문 이야기", "오늘 밤 현상"),
                ((List<KasiClient.AstroEvent>) events.getValue()).stream().map(KasiClient.AstroEvent::event).toList());

        assertEquals(1, svc.fetchLunar(ym));
        var lunar = ArgumentCaptor.forClass(List.class);
        verify(repo).upsertLunar(lunar.capture());
        assertEquals(LocalDate.of(2026, 10, 3), ((List<KasiClient.LunarDay>) lunar.getValue()).getFirst().solDate());
    }
}
