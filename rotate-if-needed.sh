#!/bin/bash

set -euo pipefail

SA_EMAIL="$1"
PROJECT_ID="$2"

ROTATE_THRESHOLD_DAYS=10
SECRET_NAME=$(echo "$SA_EMAIL" | cut -d'@' -f1)

echo "Checking Service Account: $SA_EMAIL"

KEY_INFO=$(gcloud iam service-accounts keys list \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --filter="keyType=USER_MANAGED" \
  --format="json")

KEY_COUNT=$(echo "$KEY_INFO" | jq length)

if [[ "$KEY_COUNT" -eq 0 ]]; then
  echo "No user-managed keys found."
  exit 1
fi

NEWEST_EXPIRY=$(echo "$KEY_INFO" | jq -r 'sort_by(.validBeforeTime) | last | .validBeforeTime')

echo "Newest key expires at: $NEWEST_EXPIRY"

EXPIRY_EPOCH=$(date -d "$NEWEST_EXPIRY" +%s)
CURRENT_EPOCH=$(date -u +%s)

DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

echo "Days remaining: $DAYS_LEFT"

if [[ "$DAYS_LEFT" -gt "$ROTATE_THRESHOLD_DAYS" ]]; then
  echo "Rotation not required."
  exit 0
fi

echo "Key is expiring within $ROTATE_THRESHOLD_DAYS days."
echo "Generating replacement key..."

TEMP_KEY="/tmp/$(basename "$SECRET_NAME").json"

gcloud iam service-accounts keys create "$TEMP_KEY" \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID"

if ! gcloud secrets describe "$SECRET_NAME" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "Creating secret: $SECRET_NAME"

  gcloud secrets create "$SECRET_NAME" \
    --replication-policy=automatic \
    --project="$PROJECT_ID"
fi

gcloud secrets versions add "$SECRET_NAME" \
  --data-file="$TEMP_KEY" \
  --project="$PROJECT_ID"

echo "Successfully uploaded new key to Secret Manager."

rm -f "$TEMP_KEY"

echo "Rotation completed."
