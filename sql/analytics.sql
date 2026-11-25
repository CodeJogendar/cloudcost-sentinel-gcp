-- Replace PROJECT_ID first (sed command is in the README). Run after upload_data.sh finishes.
-- Tables/views live in dataset costsentinel.

-- 1. Daily cost trend, last 14 days, all services
SELECT usage_date, ROUND(SUM(cost_usd), 2) AS total_cost_usd
FROM `PROJECT_ID.costsentinel.billing_daily`
GROUP BY usage_date ORDER BY usage_date DESC LIMIT 14;

-- 2. Detected cost anomalies (expect 5 rows)
SELECT usage_date, service, cost_usd, baseline_avg, ratio, z_score
FROM `PROJECT_ID.costsentinel.v_cost_anomalies`
WHERE is_anomaly ORDER BY usage_date;

-- 3. Money lost to anomalies: cost above baseline on anomaly days
SELECT service, COUNT(*) AS anomaly_days,
       ROUND(SUM(cost_usd - baseline_avg), 2) AS excess_cost_usd
FROM `PROJECT_ID.costsentinel.v_cost_anomalies`
WHERE is_anomaly GROUP BY service ORDER BY excess_cost_usd DESC;

-- 4. Spend share by service
SELECT service, ROUND(SUM(cost_usd), 2) AS cost_usd,
       ROUND(100 * SUM(cost_usd) / SUM(SUM(cost_usd)) OVER (), 1) AS pct_of_total
FROM `PROJECT_ID.costsentinel.billing_daily`
GROUP BY service ORDER BY cost_usd DESC;

-- 5. Month-over-month change per service
SELECT service, month, cost_usd,
       ROUND(100 * SAFE_DIVIDE(cost_usd - LAG(cost_usd) OVER (PARTITION BY service ORDER BY month),
                               LAG(cost_usd) OVER (PARTITION BY service ORDER BY month)), 1) AS mom_change_pct
FROM `PROJECT_ID.costsentinel.v_monthly_cost`
ORDER BY service, month;

-- 6. Data quality: why rows were rejected (expect 12 rows in total)
SELECT reason, COUNT(*) AS rows_rejected
FROM `PROJECT_ID.costsentinel.billing_rejects`
GROUP BY reason ORDER BY rows_rejected DESC;

-- 7. Weekday vs weekend cost pattern
SELECT IF(EXTRACT(DAYOFWEEK FROM usage_date) IN (1, 7), 'weekend', 'weekday') AS day_type,
       ROUND(AVG(daily_total), 2) AS avg_daily_cost_usd
FROM (SELECT usage_date, SUM(cost_usd) AS daily_total
      FROM `PROJECT_ID.costsentinel.billing_daily` GROUP BY usage_date)
GROUP BY day_type;

-- 8. Detections written by the Cloud Function (after bash setup/replay.sh; expect 5 rows)
SELECT detected_at, usage_date, service, cost_usd, ratio
FROM `PROJECT_ID.costsentinel.anomaly_log` ORDER BY usage_date;
