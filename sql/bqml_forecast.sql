-- OPTIONAL: BigQuery ML forecasting (ARIMA_PLUS). Replace PROJECT_ID. Run each statement separately.
-- Training takes about 1-3 minutes. Costs a few cents at most for this data size.

-- 1. Train one time series per service
CREATE OR REPLACE MODEL `PROJECT_ID.costsentinel.cost_forecast`
OPTIONS (model_type = 'ARIMA_PLUS', time_series_timestamp_col = 'usage_date',
         time_series_data_col = 'cost_usd', time_series_id_col = 'service',
         data_frequency = 'DAILY') AS
SELECT usage_date, service, cost_usd FROM `PROJECT_ID.costsentinel.billing_daily`;

-- 2. Forecast the next 14 days with a 90% interval
SELECT service, forecast_timestamp, ROUND(forecast_value, 2) AS forecast_cost_usd,
       ROUND(prediction_interval_lower_bound, 2) AS lower, ROUND(prediction_interval_upper_bound, 2) AS upper
FROM ML.FORECAST(MODEL `PROJECT_ID.costsentinel.cost_forecast`, STRUCT(14 AS horizon, 0.9 AS confidence_level))
ORDER BY service, forecast_timestamp;

-- 3. Model-based anomaly detection on the history (compare with the rule-based view)
SELECT service, usage_date, cost_usd, is_anomaly, ROUND(anomaly_probability, 3) AS anomaly_probability
FROM ML.DETECT_ANOMALIES(MODEL `PROJECT_ID.costsentinel.cost_forecast`, STRUCT(0.99 AS anomaly_prob_threshold))
WHERE is_anomaly ORDER BY usage_date;
