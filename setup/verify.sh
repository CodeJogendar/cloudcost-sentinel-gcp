#!/usr/bin/env bash
# Prints the key row counts. Run after upload_data.sh (and again after replay.sh).
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
for T in billing_daily billing_rejects anomaly_log; do
  printf "%-16s" "$T"
  bq query --nouse_legacy_sql --format=csv --quiet "SELECT COUNT(*) FROM \`$PROJECT_ID.costsentinel.$T\`" | tail -n 1
done
printf "%-16s" "anomalies(view)"
bq query --nouse_legacy_sql --format=csv --quiet "SELECT COUNTIF(is_anomaly) FROM \`$PROJECT_ID.costsentinel.v_cost_anomalies\`" | tail -n 1
