"""Cloud Function (gen2, HTTP): reads the v_cost_anomalies view and, for every anomaly in the last
N days, writes a structured ERROR log (drives the log-based metric + alert) and a row in anomaly_log.
Called daily by Cloud Scheduler with ?days=1. Use ?days=120 to replay all history."""
import json, os
from datetime import datetime, timezone

import functions_framework
from google.cloud import bigquery
from google.cloud import logging as cloud_logging
from google.cloud.logging_v2.resource import Resource

DATASET = os.environ.get("DATASET", "costsentinel")
LOG_SCHEMA = [
    bigquery.SchemaField("detected_at", "TIMESTAMP"), bigquery.SchemaField("usage_date", "DATE"),
    bigquery.SchemaField("service", "STRING"), bigquery.SchemaField("cost_usd", "FLOAT"),
    bigquery.SchemaField("baseline_avg", "FLOAT"), bigquery.SchemaField("z_score", "FLOAT"),
    bigquery.SchemaField("ratio", "FLOAT"),
]


@functions_framework.http
def detect(request):
    days = int(request.args.get("days", "1"))
    bq = bigquery.Client()
    p = bq.project
    sql = f"""
        SELECT usage_date, service, cost_usd, baseline_avg, z_score, ratio
        FROM `{p}.{DATASET}.v_cost_anomalies`
        WHERE is_anomaly
          AND usage_date > DATE_SUB((SELECT MAX(usage_date) FROM `{p}.{DATASET}.billing_daily`),
                                    INTERVAL @days DAY)
        ORDER BY usage_date, service"""
    rows = list(bq.query(sql, job_config=bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("days", "INT64", days)])).result())

    logger = cloud_logging.Client(project=p).logger("costsentinel-anomalies")
    resource = Resource(type="global", labels={"project_id": p})
    now = datetime.now(timezone.utc).isoformat()
    log_rows = []
    for r in rows:
        payload = {"event": "cost_anomaly", "usage_date": r.usage_date.isoformat(), "service": r.service,
                   "cost_usd": float(r.cost_usd), "baseline_avg": float(r.baseline_avg),
                   "z_score": float(r.z_score), "ratio": float(r.ratio),
                   "message": f"{r.service} cost ${r.cost_usd:.2f} is {r.ratio}x its 14-day baseline on {r.usage_date}"}
        logger.log_struct(payload, severity="ERROR", resource=resource)
        log_rows.append({"detected_at": now, "usage_date": r.usage_date.isoformat(), "service": r.service,
                         "cost_usd": float(r.cost_usd), "baseline_avg": float(r.baseline_avg),
                         "z_score": float(r.z_score), "ratio": float(r.ratio)})
    if log_rows:
        bq.load_table_from_json(log_rows, f"{p}.{DATASET}.anomaly_log", job_config=bigquery.LoadJobConfig(
            schema=LOG_SCHEMA, write_disposition="WRITE_APPEND")).result()

    body = {"checked_days": days, "anomalies_found": len(rows),
            "services": sorted({r.service for r in rows})}
    return json.dumps(body), 200, {"Content-Type": "application/json"}
