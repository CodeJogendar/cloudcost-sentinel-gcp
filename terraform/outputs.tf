output "bucket" {
  value = google_storage_bucket.landing.name
}

output "dataset" {
  value = "${var.project_id}.${google_bigquery_dataset.costsentinel.dataset_id}"
}

output "function_service_account" {
  value = google_service_account.fn.email
}
