"""Cloud Function (gen2, Eventarc trigger): fires when a CSV lands in gs://<bucket>/billing/.
Validates rows, rejects bad ones (with a reason), and MERGEs good rows into billing_daily
so re-uploading the same file never creates duplicates."""
import csv, io, json, os, uuid
from datetime import date, datetime, timezone

import functions_framework
from google.cloud import bigquery, storage

DATASET = os.environ.get("DATASET", "costsentinel")
REQUIRED = ["usage_date", "service", "project_id", "region", "usage_amount", "usage_unit", "cost_usd"]
STAGING_SCHEMA = [
    bigquery.SchemaField("usage_date", "DATE"), bigquery.SchemaField("service", "STRING"),
    bigquery.SchemaField("project_id", "STRING"), bigquery.SchemaField("region", "STRING"),
    bigquery.SchemaField("usage_amount", "FLOAT"), bigquery.SchemaField("usage_unit", "STRING"),
    bigquery.SchemaField("cost_usd", "FLOAT"), bigquery.SchemaField("source_file", "STRING"),
]
REJECT_SCHEMA = [
    bigquery.SchemaField("source_file", "STRING"), bigquery.SchemaField("row_number", "INTEGER"),
    bigquery.SchemaField("reason", "STRING"), bigquery.SchemaField("raw_row", "STRING"),
    bigquery.SchemaField("rejected_at", "TIMESTAMP"),
]


def validate(row):
    """Return (clean_row, None) or (None, reason)."""
    missing = [k for k in REQUIRED if not (row.get(k) or "").strip()]
    if missing:
        return None, "missing field(s): " + ",".join(missing)
    try:
        d = date.fromisoformat(row["usage_date"].strip())
    except ValueError:
        return None, "invalid usage_date"
    try:
        cost, usage = float(row["cost_usd"]), float(row["usage_amount"])
    except ValueError:
        return None, "non-numeric cost_usd or usage_amount"
    if cost < 0:
        return None, "negative cost_usd"
    return {"usage_date": d.isoformat(), "service": row["service"].strip(),
            "project_id": row["project_id"].strip(), "region": row["region"].strip(),
            "usage_amount": usage, "usage_unit": row["usage_unit"].strip(), "cost_usd": cost}, None


@functions_framework.cloud_event
def load_billing(cloud_event):
    data = cloud_event.data
    bucket, name = data["bucket"], data["name"]
    if not (name.startswith("billing/") and name.endswith(".csv")):
        print(json.dumps({"event": "skipped", "file": name}))
        return

    text = storage.Client().bucket(bucket).blob(name).download_as_text()
    good, rejects, seen = [], [], set()
    now = datetime.now(timezone.utc).isoformat()
    for n, row in enumerate(csv.DictReader(io.StringIO(text)), start=2):   # row 1 is the header
        clean, reason = validate(row)
        if clean is None:
            rejects.append({"source_file": name, "row_number": n, "reason": reason,
                            "raw_row": json.dumps(row), "rejected_at": now})
            continue
        key = (clean["usage_date"], clean["service"], clean["project_id"])
        if key in seen:
            rejects.append({"source_file": name, "row_number": n, "reason": "duplicate row in file",
                            "raw_row": json.dumps(row), "rejected_at": now})
            continue
        seen.add(key)
        clean["source_file"] = name
        good.append(clean)

    client = bigquery.Client()
    p = client.project
    stg = f"{p}.{DATASET}.stg_{uuid.uuid4().hex[:12]}"
    try:
        if good:
            client.load_table_from_json(good, stg, job_config=bigquery.LoadJobConfig(
                schema=STAGING_SCHEMA, write_disposition="WRITE_TRUNCATE")).result()
            client.query(f"""
                MERGE `{p}.{DATASET}.billing_daily` T USING `{stg}` S
                ON T.usage_date = S.usage_date AND T.service = S.service AND T.project_id = S.project_id
                WHEN MATCHED THEN UPDATE SET region = S.region, usage_amount = S.usage_amount,
                  usage_unit = S.usage_unit, cost_usd = S.cost_usd, source_file = S.source_file,
                  loaded_at = CURRENT_TIMESTAMP()
                WHEN NOT MATCHED THEN INSERT (usage_date, service, project_id, region, usage_amount,
                  usage_unit, cost_usd, source_file, loaded_at)
                  VALUES (S.usage_date, S.service, S.project_id, S.region, S.usage_amount,
                  S.usage_unit, S.cost_usd, S.source_file, CURRENT_TIMESTAMP())""").result()
        if rejects:
            client.load_table_from_json(rejects, f"{p}.{DATASET}.billing_rejects",
                job_config=bigquery.LoadJobConfig(schema=REJECT_SCHEMA,
                                                  write_disposition="WRITE_APPEND")).result()
    finally:
        client.delete_table(stg, not_found_ok=True)

    print(json.dumps({"event": "billing_loaded", "file": name, "loaded": len(good), "rejected": len(rejects)}))
