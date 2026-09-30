-- Retention deletes kma_forecast by issue time every day (astroDailyJob.retention).
CREATE INDEX idx_kma_forecast_base ON kma_forecast (base_at);
