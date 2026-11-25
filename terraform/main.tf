terraform {
  required_version = ">= 1.3"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  bucket_name = "${var.project_id}-costsentinel-landing"
  compute_sa  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
  fn_sa       = "serviceAccount:${google_service_account.fn.email}"
  ds          = "${var.project_id}.costsentinel"
}

# ---------------- Storage: landing bucket for billing exports ----------------
resource "google_storage_bucket" "landing" {
  name                        = local.bucket_name
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
}

# ---------------- BigQuery ----------------
resource "google_bigquery_dataset" "costsentinel" {
  dataset_id                 = "costsentinel"
  location                   = var.region
  delete_contents_on_destroy = true
}

resource "google_bigquery_table" "billing_daily" {
  dataset_id          = google_bigquery_dataset.costsentinel.dataset_id
  table_id            = "billing_daily"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "usage_date"
  }
  clustering = ["service"]

  schema = jsonencode([
    { name = "usage_date", type = "DATE", mode = "REQUIRED" },
    { name = "service", type = "STRING", mode = "REQUIRED" },
    { name = "project_id", type = "STRING", mode = "REQUIRED" },
    { name = "region", type = "STRING", mode = "NULLABLE" },
    { name = "usage_amount", type = "FLOAT", mode = "NULLABLE" },
    { name = "usage_unit", type = "STRING", mode = "NULLABLE" },
    { name = "cost_usd", type = "FLOAT", mode = "REQUIRED" },
    { name = "source_file", type = "STRING", mode = "NULLABLE" },
    { name = "loaded_at", type = "TIMESTAMP", mode = "NULLABLE" }
  ])
}

resource "google_bigquery_table" "billing_rejects" {
  dataset_id          = google_bigquery_dataset.costsentinel.dataset_id
  table_id            = "billing_rejects"
  deletion_protection = false
  schema = jsonencode([
    { name = "source_file", type = "STRING", mode = "NULLABLE" },
    { name = "row_number", type = "INTEGER", mode = "NULLABLE" },
    { name = "reason", type = "STRING", mode = "NULLABLE" },
    { name = "raw_row", type = "STRING", mode = "NULLABLE" },
    { name = "rejected_at", type = "TIMESTAMP", mode = "NULLABLE" }
  ])
}

resource "google_bigquery_table" "anomaly_log" {
  dataset_id          = google_bigquery_dataset.costsentinel.dataset_id
  table_id            = "anomaly_log"
  deletion_protection = false
  schema = jsonencode([
    { name = "detected_at", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "usage_date", type = "DATE", mode = "NULLABLE" },
    { name = "service", type = "STRING", mode = "NULLABLE" },
    { name = "cost_usd", type = "FLOAT", mode = "NULLABLE" },
    { name = "baseline_avg", type = "FLOAT", mode = "NULLABLE" },
    { name = "z_score", type = "FLOAT", mode = "NULLABLE" },
    { name = "ratio", type = "FLOAT", mode = "NULLABLE" }
  ])
}

# Anomaly rule: cost >= 3 standard deviations above, and >= 1.5x, the trailing 14-day baseline
resource "google_bigquery_table" "v_cost_anomalies" {
  dataset_id          = google_bigquery_dataset.costsentinel.dataset_id
  table_id            = "v_cost_anomalies"
  deletion_protection = false

  view {
    use_legacy_sql = false
    query          = <<-EOT
      WITH s AS (
        SELECT usage_date, service, cost_usd,
          AVG(cost_usd) OVER (PARTITION BY service ORDER BY usage_date
                              ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING) AS baseline_avg,
          STDDEV(cost_usd) OVER (PARTITION BY service ORDER BY usage_date
                                 ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING) AS baseline_std,
          COUNT(cost_usd) OVER (PARTITION BY service ORDER BY usage_date
                                ROWS BETWEEN 14 PRECEDING AND 1 PRECEDING) AS baseline_days
        FROM `${local.ds}.billing_daily`
      )
      SELECT usage_date, service, cost_usd,
        ROUND(baseline_avg, 2) AS baseline_avg,
        ROUND(SAFE_DIVIDE(cost_usd - baseline_avg, baseline_std), 2) AS z_score,
        ROUND(SAFE_DIVIDE(cost_usd, baseline_avg), 2) AS ratio,
        COALESCE(baseline_days >= 7
                 AND SAFE_DIVIDE(cost_usd - baseline_avg, baseline_std) >= 3
                 AND cost_usd >= 1.5 * baseline_avg, FALSE) AS is_anomaly
      FROM s
    EOT
  }

  depends_on = [google_bigquery_table.billing_daily]
}

resource "google_bigquery_table" "v_monthly_cost" {
  dataset_id          = google_bigquery_dataset.costsentinel.dataset_id
  table_id            = "v_monthly_cost"
  deletion_protection = false

  view {
    use_legacy_sql = false
    query          = <<-EOT
      SELECT DATE_TRUNC(usage_date, MONTH) AS month, service,
             ROUND(SUM(cost_usd), 2) AS cost_usd
      FROM `${local.ds}.billing_daily`
      GROUP BY month, service
    EOT
  }

  depends_on = [google_bigquery_table.billing_daily]
}

# ---------------- IAM: dedicated least-privilege runtime identity ----------------
resource "google_service_account" "fn" {
  account_id   = "costsentinel-fn"
  display_name = "CloudCost Sentinel functions"
}

resource "google_project_iam_member" "fn_roles" {
  for_each = toset([
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/storage.objectViewer",
    "roles/logging.logWriter",
    "roles/eventarc.eventReceiver",
    "roles/run.invoker",
  ])
  project = var.project_id
  role    = each.value
  member  = local.fn_sa
}

# Cloud Build runs as the default compute service account in new projects
resource "google_project_iam_member" "build_roles" {
  for_each = toset([
    "roles/cloudbuild.builds.builder",
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
    "roles/storage.objectViewer",
  ])
  project = var.project_id
  role    = each.value
  member  = local.compute_sa
}

# ---------------- Monitoring: log-based metric + alert ----------------
resource "google_logging_metric" "anomalies" {
  name   = "costsentinel_anomaly_count"
  filter = "logName=\"projects/${var.project_id}/logs/costsentinel-anomalies\" AND jsonPayload.event=\"cost_anomaly\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "service"
      value_type  = "STRING"
      description = "GCP service whose cost spiked"
    }
  }

  label_extractors = {
    "service" = "EXTRACT(jsonPayload.service)"
  }
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "CloudCost Sentinel email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

resource "google_monitoring_alert_policy" "cost_anomaly" {
  display_name = "CloudCost Sentinel: cost anomaly detected"
  combiner     = "OR"

  conditions {
    display_name = "At least one cost anomaly logged"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.anomalies.name}\" AND resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  documentation {
    content   = "A GCP service cost spiked above its 14-day baseline. See docs/RUNBOOK.md (cost incidents 1-4) and query 2 in sql/analytics.sql."
    mime_type = "text/markdown"
  }

  alert_strategy {
    auto_close = "1800s"
  }
}
