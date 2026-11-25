#!/usr/bin/env bash
# Runs the anomaly detector over history (default 120 days) so you can see alerts fire.
# Usage: bash setup/replay.sh [days]
set -euo pipefail
REGION=asia-south1
URL=$(gcloud functions describe cost-anomaly-detector --gen2 --region=$REGION --format="value(serviceConfig.uri)")
curl -s -H "Authorization: Bearer $(gcloud auth print-identity-token)" "${URL}?days=${1:-120}"
echo
