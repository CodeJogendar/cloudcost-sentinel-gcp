#!/usr/bin/env bash
# Removes everything. Usage (project root):  ALERT_EMAIL=you@gmail.com bash setup/cleanup.sh
# Add FULL=1 to also delete Cloud Functions build leftovers (artifact repo + source bucket).
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION=asia-south1
export PATH=$HOME/bin:$PATH
gcloud scheduler jobs delete costsentinel-daily --location=$REGION --quiet 2>/dev/null || true
gcloud functions delete cost-loader --gen2 --region=$REGION --quiet 2>/dev/null || true
gcloud functions delete cost-anomaly-detector --gen2 --region=$REGION --quiet 2>/dev/null || true
( cd terraform && terraform destroy -auto-approve -input=false \
    -var="project_id=$PROJECT_ID" -var="region=$REGION" -var="alert_email=${ALERT_EMAIL:-unused@example.com}" )
if [ "${FULL:-0}" = "1" ]; then   # leftovers from Cloud Functions builds (tiny storage cost)
  gcloud artifacts repositories delete gcf-artifacts --location=$REGION --quiet 2>/dev/null || true
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
  gcloud storage rm -r "gs://gcf-v2-sources-${PROJECT_NUMBER}-${REGION}" 2>/dev/null || true
fi
echo "Cleanup done."
