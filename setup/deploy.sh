#!/usr/bin/env bash
# One-time deploy. Usage (from the project root):  ALERT_EMAIL=you@gmail.com bash setup/deploy.sh
set -euo pipefail
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
ALERT_EMAIL=${ALERT_EMAIL:?Usage: ALERT_EMAIL=you@example.com bash setup/deploy.sh}
REGION=asia-south1
BUCKET=${PROJECT_ID}-costsentinel-landing
FN_SA=costsentinel-fn@${PROJECT_ID}.iam.gserviceaccount.com
[ -d terraform ] && [ -d function ] || { echo "ERROR: run this from the project root (folder containing terraform/ and function/)"; exit 1; }
echo "Project: $PROJECT_ID | Alert email: $ALERT_EMAIL"

# ---- 1. Terraform: install into ~/bin if Cloud Shell does not have it ----
export PATH=$HOME/bin:$PATH
if [[ "$(terraform version 2>/dev/null || true)" != Terraform\ v* ]]; then
  echo "Installing Terraform into ~/bin ..."
  ARCH=amd64; [ "$(uname -m)" = "aarch64" ] && ARCH=arm64
  TFV=1.9.8
  mkdir -p "$HOME/bin"
  curl -fsSL -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TFV}/terraform_${TFV}_linux_${ARCH}.zip"
  unzip -o /tmp/terraform.zip terraform -d "$HOME/bin" >/dev/null
  grep -q 'HOME/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH=$HOME/bin:$PATH' >> "$HOME/.bashrc"
fi
[[ "$(terraform version 2>/dev/null || true)" == Terraform\ v* ]] || { echo "ERROR: Terraform install failed"; exit 1; }

# ---- 2. APIs ----
gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com iam.googleapis.com \
  storage.googleapis.com bigquery.googleapis.com pubsub.googleapis.com logging.googleapis.com \
  monitoring.googleapis.com cloudfunctions.googleapis.com run.googleapis.com eventarc.googleapis.com \
  cloudbuild.googleapis.com artifactregistry.googleapis.com cloudscheduler.googleapis.com

# ---- 3. Platform (bucket, BigQuery, views, IAM, metric, alert) ----
# A new log-based metric can take a few minutes to become visible to Monitoring, so the alert policy
# can fail with "Cannot find metric(s)" on the first apply. Retrying is safe: Terraform only creates what is missing.
( cd terraform
  terraform init -input=false
  for attempt in 1 2 3 4 5; do
    if terraform apply -auto-approve -input=false \
         -var="project_id=$PROJECT_ID" -var="region=$REGION" -var="alert_email=$ALERT_EMAIL"; then
      break
    fi
    [ "$attempt" = "5" ] && { echo "ERROR: terraform apply failed 5 times"; exit 1; }
    echo "Apply failed (attempt $attempt of 5). Waiting 90s, then retrying ..."; sleep 90
  done )

echo "Waiting 60s for IAM changes to propagate ..."; sleep 60

# ---- 4. Service agents the Eventarc bucket trigger needs ----
gcloud beta services identity create --service=eventarc.googleapis.com --project="$PROJECT_ID" || true
# The Storage JSON API returns the agent email and creates the agent if it does not exist yet
GCS_SA=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" "https://storage.googleapis.com/storage/v1/projects/$PROJECT_ID/serviceAccount" | python3 -c "import sys,json;print(json.load(sys.stdin)['email_address'])")
[ -n "$GCS_SA" ] || { echo "ERROR: could not find the Cloud Storage service agent"; exit 1; }
echo "Cloud Storage service agent: $GCS_SA"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$GCS_SA" \
  --role="roles/pubsub.publisher" --condition=None --quiet >/dev/null

# Eventarc validates the trigger by reading the bucket: it needs storage.buckets.get on it
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
EVENTARC_SA=service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com
for M in "$FN_SA" "$EVENTARC_SA"; do
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="serviceAccount:$M" \
    --role="roles/storage.legacyBucketReader" >/dev/null
done
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$EVENTARC_SA" \
  --role="roles/eventarc.serviceAgent" --condition=None --quiet >/dev/null
echo "Waiting 90s for the new permissions to propagate ..."; sleep 90

# ---- 5. Functions ----
for attempt in 1 2 3; do
  if gcloud functions deploy cost-loader --gen2 --region=$REGION --runtime=python312 \
       --source=function/loader --entry-point=load_billing \
       --trigger-bucket="$BUCKET" --trigger-location=$REGION \
       --service-account="$FN_SA" --trigger-service-account="$FN_SA" \
       --set-env-vars=DATASET=costsentinel --memory=512Mi --timeout=300s --max-instances=3 --quiet; then break; fi
  [ "$attempt" = "3" ] && { echo "ERROR: cost-loader deploy failed 3 times"; exit 1; }
  echo "Deploy failed (attempt $attempt of 3). Permissions may still be propagating; waiting 90s ..."; sleep 90
done

gcloud functions deploy cost-anomaly-detector --gen2 --region=$REGION --runtime=python312 \
  --source=function/detector --entry-point=detect \
  --trigger-http --no-allow-unauthenticated --service-account="$FN_SA" \
  --set-env-vars=DATASET=costsentinel --memory=512Mi --timeout=120s --max-instances=2 --quiet

# ---- 6. Daily schedule (06:00 IST) ----
URL=$(gcloud functions describe cost-anomaly-detector --gen2 --region=$REGION --format="value(serviceConfig.uri)")
gcloud scheduler jobs delete costsentinel-daily --location=$REGION --quiet 2>/dev/null || true
gcloud scheduler jobs create http costsentinel-daily --location=$REGION \
  --schedule="0 6 * * *" --time-zone="Asia/Kolkata" --http-method=GET \
  --uri="${URL}?days=1" --oidc-service-account-email="$FN_SA" --oidc-token-audience="$URL"

echo "Deploy complete. Next: bash setup/upload_data.sh"
