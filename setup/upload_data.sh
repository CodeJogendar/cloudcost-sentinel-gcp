#!/usr/bin/env bash
# Drops the billing CSV into the landing bucket. This upload is what triggers the loader function.
set -euo pipefail
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
BUCKET=${PROJECT_ID}-costsentinel-landing
gcloud storage cp data/billing_2026_q3q4.csv gs://$BUCKET/billing/billing_2026_q3q4.csv
echo "Uploaded. The cost-loader function should finish within about a minute."
echo "Watch it:  gcloud functions logs read cost-loader --gen2 --region=asia-south1 --limit=20"
