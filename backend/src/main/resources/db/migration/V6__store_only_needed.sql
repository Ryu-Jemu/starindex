-- DB-PLAN 3.2 (ADR-014): drop what nothing reads. Every dropped value can be recomputed (Astronomy Engine, index)
-- or fetched again from KASI; this migration is not reversible.
DROP TABLE star_index_hourly;   -- the pack is built from memory; nightly score stays for the R3 public ranking
DROP TABLE astro_night;         -- a cache of Astronomy Engine results, computed on demand now

ALTER TABLE star_index_nightly
  DROP COLUMN best_from, DROP COLUMN best_to, DROP COLUMN contrib, DROP COLUMN reasons, DROP COLUMN computed_at;
ALTER TABLE kasi_riseset
  DROP COLUMN kasi_location, DROP COLUMN sunrise, DROP COLUMN suntransit, DROP COLUMN moonrise,
  DROP COLUMN moontransit, DROP COLUMN moonset, DROP COLUMN civilm, DROP COLUMN nautm, DROP COLUMN astm,
  DROP COLUMN fetched_at;
ALTER TABLE astro_crosscheck DROP COLUMN kasi_at, DROP COLUMN computed_at, DROP COLUMN checked_at;
ALTER TABLE kasi_astro_event DROP COLUMN fetched_at;
ALTER TABLE kasi_special_day DROP COLUMN kst, DROP COLUMN sun_longitude, DROP COLUMN fetched_at;
ALTER TABLE kasi_lunar_day   DROP COLUMN lun_iljin, DROP COLUMN fetched_at;

-- The error text is the only way to tell why a call failed; successful calls keep none.
ALTER TABLE etl_api_call     DROP COLUMN item_count;
UPDATE etl_api_call SET result_msg = NULL WHERE outcome IN ('OK', 'NO_DATA');
ALTER TABLE etl_api_call     ALTER COLUMN result_msg TYPE VARCHAR(80) USING left(result_msg, 80);

-- pinned: never deleted by retention (demo packs, rollback targets). DB-PLAN 4.3.
ALTER TABLE data_pack        DROP COLUMN raw_bytes, DROP COLUMN region_count,
                             ADD COLUMN pinned BOOLEAN NOT NULL DEFAULT false;
