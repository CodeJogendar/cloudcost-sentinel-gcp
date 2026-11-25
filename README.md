# CloudCost Sentinel: Event-Driven GCP Cost Anomaly Detection

**Services:** Cloud Storage, Eventarc, Cloud Functions (gen2), BigQuery (+ optional BigQuery ML), Cloud Scheduler, Cloud Logging, Cloud Monitoring, Terraform, Looker Studio

## Architecture
```
 billing CSV ──► Cloud Storage (billing/) ──Eventarc──► cost-loader (Cloud Function)
                                                          │ validate, reject bad rows, MERGE (idempotent)
                                                          ▼
                       BigQuery: billing_daily (partitioned by day) + billing_rejects
                                                          │
                          view v_cost_anomalies (14-day rolling baseline, z-score and ratio rule)
                                                          │
 Cloud Scheduler (06:00 IST) ──► cost-anomaly-detector (Cloud Function) ──► anomaly_log (BigQuery)
                                                          │ structured ERROR log per anomaly
                                                          ▼
                    log-based metric ──► Monitoring alert policy ──► email
 Looker Studio dashboard reads v_cost_anomalies and v_monthly_cost
 Terraform provisions the platform; two gcloud commands deploy the functions and the schedule.
```

## Dataset: 552 rows
| Item | Rows | Notes |
|---|---|---|
| Clean billing rows | 540 | 90 days (2026-08-25 to 2026-11-22) x 6 services, about 11,911.74 USD in total |
| Bad rows | 12 | 5 exact duplicates, 4 invalid costs ("N/A"), 3 missing service names |

Seeded incidents: Compute Engine runaway VM (Oct 5), Dataflow forgotten job (Oct 18 and 19), Networking egress spike (Nov 2), BigQuery full table scan (Nov 12).
Columns: usage_date, service, project_id, region, usage_amount, usage_unit, cost_usd

## Run it (Cloud Shell, from the project root)
1. `ALERT_EMAIL=you@gmail.com bash setup/deploy.sh` (about 10 to 15 minutes; installs Terraform if missing)
2. `bash setup/upload_data.sh` (this upload triggers the loader)
3. `bash setup/verify.sh` (row counts)
4. `bash setup/replay.sh` (runs the detector over all history; alert fires within 2 to 3 minutes)
5. Run sql/analytics.sql (replace PROJECT_ID); optionally sql/bqml_forecast.sql
6. Build the Looker Studio dashboard (steps below)
7. `ALERT_EMAIL=you@gmail.com FULL=1 bash setup/cleanup.sh`

## Expected results
| Check | Expected |
|---|---|
| billing_daily | 540 rows |
| billing_rejects | 12 rows (5 duplicate, 4 non-numeric cost, 3 missing service) |
| v_cost_anomalies, is_anomaly = TRUE | 5 rows: Compute Engine 10-05, Dataflow 10-18 and 10-19, Networking 11-02, BigQuery 11-12 |
| anomaly_log after replay | 5 rows |
| Alert | one incident per affected service (4 services) |
| Re-uploading the CSV | billing_daily stays at 540 |

## Looker Studio dashboard (free)
1. Open lookerstudio.google.com, then Create, then Report.
2. Add data: BigQuery connector, select your project, dataset costsentinel, table v_cost_anomalies.
3. Add a time series chart (dimension usage_date, metric cost_usd, breakdown service), a scorecard (sum of cost_usd), and a table filtered to is_anomaly = true.
4. Screenshot the report for your portfolio.

## Design choices
- **Event-driven ingestion:** files trigger processing the moment they land, with no polling or orchestrator.
- **Idempotent MERGE load:** safe against duplicate events and re-uploads; bad rows are quarantined with reasons.
- **Transparent anomaly rule in SQL:** easy to explain and audit; BigQuery ML ARIMA_PLUS is included as an optional comparison.
- **Dedicated service account:** the functions run with only the roles they need.
- **No Composer, Dataproc or Dataflow:** nothing here needs them, so there are no clusters or workers to manage.

## Cost
Mostly free-tier: Cloud Run functions, Scheduler (3 free jobs), tiny BigQuery usage. The only residual cost is function build artifacts, which `FULL=1` cleanup removes.

## Resume bullets
- Built an event-driven cost anomaly detection platform on GCP (Eventarc, Cloud Functions, BigQuery, Cloud Scheduler, Cloud Monitoring) provisioned with Terraform.
- Implemented an idempotent MERGE-based loader with row-level validation and a rejects table; detected cost spikes with a 14-day rolling z-score rule and alerted via a log-based metric.
- Authored a runbook covering 4 cost incidents (runaway VM, forgotten Dataflow job, egress spike, BigQuery full scan) and 12 deployment failure modes with diagnosis queries and preventive controls.
