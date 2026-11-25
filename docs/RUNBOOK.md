# CloudCost Sentinel Runbook

Format: **Symptom, Diagnosis, Root cause, Fix, Prevention.** Replace PROJECT_ID in queries.
Incidents 1 to 4 are seeded in the dataset. Entries 5 to 16 are platform and deployment issues you may hit.
Add your own real errors at the bottom, because real incidents are the strongest interview material.

## Cost incidents (seeded in the data)

### 1. Runaway VM: Compute Engine cost 5x baseline (2026-10-05)
- **Symptom:** Compute Engine cost jumps from about 44 USD/day to about 227 USD/day; the anomaly alert fires.
- **Diagnosis:** `SELECT * FROM costsentinel.v_cost_anomalies WHERE is_anomaly AND service='Compute Engine'` confirms ratio of about 5.2 and z-score near 50. In a real project: Billing reports grouped by SKU and label, `gcloud compute instances list`, and Audit Logs for instance creation.
- **Root cause (simulated):** an autoscaler loop scaled a managed instance group to its maximum.
- **Fix:** cap the group's max size, delete the excess instances, correct the scaling metric.
- **Prevention:** budget alerts at 50/90/100 percent, a sensible max replica count, and this daily anomaly check.

### 2. Forgotten streaming job: Dataflow cost 6x baseline (2026-10-18 and 10-19)
- **Symptom:** Dataflow spend spikes two days in a row.
- **Diagnosis:** the view flags day 1 (z-score about 49) and day 2 (z-score about 3.6). Day 2 scores lower because day 1 already inflated the 14-day baseline. In a real project: `gcloud dataflow jobs list --region=REGION --status=active`.
- **Root cause (simulated):** a test streaming job was never cancelled.
- **Fix:** drain or cancel the job.
- **Prevention:** label every job with owner and expiry, run a scheduled cleanup of expired jobs, and alert on the first day. Note the limitation: a rolling baseline is best at catching the first day of a sustained problem.

### 3. Egress spike: Networking cost 4.5x baseline (2026-11-02)
- **Symptom:** Networking cost jumps to about 45 USD/day.
- **Diagnosis:** Billing SKU breakdown shows inter-region or internet egress; VPC Flow Logs show the top talkers.
- **Root cause (simulated):** a cross-region replication job started copying a large dataset.
- **Fix:** stop or reschedule the job, move producer and consumer into the same region.
- **Prevention:** keep data and compute co-located, use a CDN or caching, and set an egress budget.

### 4. BigQuery full table scan: BigQuery cost 7x baseline (2026-11-12)
- **Symptom:** one day of BigQuery cost at about 146 USD instead of about 19 USD.
- **Diagnosis:**
  ```sql
  SELECT user_email, creation_time, total_bytes_billed / POW(1024, 4) AS tib_billed, query
  FROM `region-asia-south1`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
  WHERE creation_time >= TIMESTAMP('2026-11-12') ORDER BY total_bytes_billed DESC LIMIT 10;
  ```
- **Root cause (simulated):** a query without a partition filter scanned the whole table.
- **Fix:** add a partition filter, cluster the table, rewrite the query.
- **Prevention:** `require_partition_filter = true` on large tables, a per-query `maximum_bytes_billed`, and project-level custom quotas.

## Platform and deployment issues

### 5. Terraform: command not found in Cloud Shell
- **Symptom:** "Follow the instructions at https://developer.hashicorp.com/terraform/install" and later errors such as a missing bucket.
- **Root cause:** Terraform is not preinstalled and the stub message does not stop a script.
- **Fix:** `setup/deploy.sh` now installs the binary into `~/bin` and checks `terraform version` explicitly.

### 6. Cloud Functions deploy fails during the build step
- **Symptom:** `gcloud functions deploy` ends with a build failure mentioning permissions or the default compute service account.
- **Diagnosis:** open the Cloud Build log link in the error output.
- **Root cause:** in newer projects Cloud Build runs as the default compute service account, which needs build, Artifact Registry and logging roles.
- **Fix:** Terraform grants those roles (`build_roles`); wait 1 to 2 minutes for IAM propagation and re-run `bash setup/deploy.sh`.

### 7. Uploading the CSV does not load anything
- **Symptom:** no rows in `billing_daily`, no function logs.
- **Diagnosis:** `gcloud eventarc triggers list --location=asia-south1` (the trigger should exist), then `gcloud functions logs read cost-loader --gen2 --region=asia-south1`.
- **Common causes:** the file is not under `billing/` or does not end in `.csv`; the Cloud Storage service agent lacks `roles/pubsub.publisher` (deploy.sh grants it); the bucket and function are in different regions.
- **Fix:** correct the path or role, then upload again.

### 8. Replay returns 403 or 401
- **Cause:** the detector is private. Calls need an identity token (`gcloud auth print-identity-token`), and the caller needs `roles/run.invoker`.
- **Fix:** use `bash setup/replay.sh`. Cloud Scheduler authenticates with the function's service account, which has the invoker role.

### 9. Anomalies detected but no alert
- **Diagnosis:** Logs Explorer with `logName:"costsentinel-anomalies"`; Metrics Explorer for `costsentinel_anomaly_count`; Monitoring, Alerting, Incidents.
- **Causes:** replay not run (the daily job only checks the last day); the metric needs 2 to 3 minutes; email in Spam. The incident page shows the alert even if email is delayed.

### 10. BigQuery syntax error on the project ID
- **Symptom:** `Expected end of input but got "a6fa2"`.
- **Root cause:** project IDs containing hyphens must be quoted.
- **Fix:** wrap fully qualified names in backticks.

### 11. "No such file or directory" when running scripts
- **Root cause:** the zip was extracted into a nested folder, so the shell was one level too high.
- **Fix:** `pwd` and `ls`, then `cd` into the folder containing `terraform/` and `function/`. `deploy.sh` now checks for these.

### 12. Terraform: "Cannot find metric(s) that match type = logging.googleapis.com/user/..." (alert policy 404)
- **Symptom:** `terraform apply` creates 20 of 21 resources, then fails creating the alert policy with a 404 about a missing metric.
- **Diagnosis:** the metric `costsentinel_anomaly_count` exists in Logging, Log-based metrics, but was created only seconds earlier.
- **Root cause:** a race. Cloud Monitoring needs up to several minutes to see a new log-based metric, and the alert policy references it.
- **Fix:** wait 2 to 3 minutes and re-run `terraform apply` (it only creates the missing alert policy). `deploy.sh` now retries the apply up to 5 times, 90 seconds apart.
- **Prevention:** when one resource depends on another service's eventually consistent resource, add a retry or a delay instead of assuming instant availability.

### 13. deploy.sh: "Policy modification failed ... INVALID_ARGUMENT: Service account ..." granting pubsub.publisher
- **Symptom:** the deploy stops right after the Eventarc service identity is created, at `gcloud projects add-iam-policy-binding` for the Cloud Storage service agent.
- **Diagnosis:** print the value the script computed (`echo "$GCS_SA"`); it was empty or the account did not exist yet.
- **Root cause:** `gcloud storage service-agent` can return nothing for an agent that has not been provisioned, and an empty member makes the IAM binding invalid.
- **Fix:** look up the agent through the Storage JSON API (`projects/PROJECT/serviceAccount`), which returns the email and provisions the agent, and fail early if the value is empty.
- **Prevention:** validate variables before using them in an IAM command, and print them so failures are easy to read.

### 14. gcloud functions deploy: "Validation failed for trigger ... Permission storage.buckets.get denied on Bucket"
- **Symptom:** the `cost-loader` deploy fails with a 403 while creating the Eventarc trigger, even though the bucket exists.
- **Diagnosis:** the message names the missing permission (`storage.buckets.get`). `roles/storage.objectViewer` only covers objects, not the bucket itself.
- **Root cause:** Eventarc reads the bucket to validate the trigger, and neither the function's service account nor the Eventarc service agent could read bucket metadata.
- **Fix:** grant `roles/storage.legacyBucketReader` on the bucket to the function service account and to the Eventarc service agent, grant the agent `roles/eventarc.serviceAgent`, wait for propagation, and redeploy. `deploy.sh` now does this and retries the deploy.
- **Prevention:** grant the narrowest role that includes every permission the service checks at creation time, scoped to the one bucket instead of the whole project.

### 15. gcloud: "unrecognized arguments: --gen2 / --region" on functions list
- **Symptom:** `gcloud functions list --gen2 --region=...` fails with "unrecognized arguments".
- **Root cause:** flag names differ by subcommand. `functions list` uses `--v2` and `--regions`; `describe`, `deploy` and `logs read` use `--gen2` and `--region`.
- **Fix:** `gcloud functions list --v2 --regions=asia-south1`.
- **Prevention:** check `gcloud <command> --help` instead of assuming flags carry over.

### 16. Upload succeeded but billing_daily stayed at 0
- **Symptom:** `verify.sh` showed 0 rows after `upload_data.sh`; `replay.sh` returned a 404 for the detector.
- **Diagnosis:** `gcloud functions list --v2 --regions=asia-south1` listed 0 items.
- **Root cause:** the deploy had stopped before the functions were created, so no trigger existed. Storage events are not replayed to functions created later.
- **Fix:** finish the deploy, then upload the file again.
- **Prevention:** confirm both functions are ACTIVE before uploading.

## Design checks worth demonstrating
- **Idempotent loads:** upload the same CSV twice; `billing_daily` stays at 540 rows because the loader MERGEs on (usage_date, service, project_id).
- **Bad data is quarantined, not lost:** the 12 bad rows are in `billing_rejects` with row numbers and reasons.

## Your own incidents
Add every real error you hit while building this, in the same format.
