#!/bin/bash

set -euo pipefail

log() {
  echo "[INFO] $(date -u +"%Y-%m-%dT%H:%M:%SZ") - $*"
}

warn() {
  echo "[WARN] $(date -u +"%Y-%m-%dT%H:%M:%SZ") - $*"
}

error() {
  echo "[ERROR] $(date -u +"%Y-%m-%dT%H:%M:%SZ") - $*"
  exit 1
}

#----------------------------------------------------------------------------
# Input
#----------------------------------------------------------------------------
SA_EMAIL="${1:-}"

#----------------------------------------------------------------------------
# Mode 1: No Service Account Provided
# Scan all service accounts and delete expired user-managed keys
#----------------------------------------------------------------------------
if [[ -z "$SA_EMAIL" ]]; then

  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

  [[ -z "$PROJECT_ID" ]] && error "No active project configured"

  log "No service account supplied"
  log "Project ID : $PROJECT_ID"
  log "Scanning all service accounts for expired keys"

  CURRENT_EPOCH=$(date -u +%s)

  SA_LIST=$(gcloud iam service-accounts list \
    --project="$PROJECT_ID" \
    --format="value(email)")

  for SA in $SA_LIST; do

    log "Checking Service Account: $SA"

    KEYS=$(gcloud iam service-accounts keys list \
      --iam-account="$SA" \
      --project="$PROJECT_ID" \
      --filter="keyType=USER_MANAGED" \
      --format="json")

    KEY_COUNT=$(echo "$KEYS" | jq length)

    [[ "$KEY_COUNT" -eq 0 ]] && continue

    echo "$KEYS" | jq -c '.[]' | while read -r KEY; do

      KEY_ID=$(echo "$KEY" | jq -r '.name | split("/") | last')
      EXPIRY=$(echo "$KEY" | jq -r '.validBeforeTime')

      [[ "$EXPIRY" == "null" || -z "$EXPIRY" ]] && continue

      EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)

      if [[ "$EXPIRY_EPOCH" -le "$CURRENT_EPOCH" ]]; then

        warn "Expired key found"
        warn "Service Account : $SA"
        warn "Key ID          : $KEY_ID"
        warn "Expired On      : $EXPIRY"

        gcloud iam service-accounts keys delete "$KEY_ID" \
          --iam-account="$SA" \
          --project="$PROJECT_ID" \
          --quiet

        log "Deleted expired key: $KEY_ID"

      fi

    done

  done

  log "Expired key cleanup completed successfully"
  exit 0

fi

#----------------------------------------------------------------------------
# Mode 2: Service Account Provided
# Rotate key if expiry is within threshold
#----------------------------------------------------------------------------

[[ -z "$SA_EMAIL" ]] && error "Service account email is required"

PROJECT_ID=$(echo "$SA_EMAIL" | cut -d'@' -f2 | cut -d'.' -f1)

[[ -z "$PROJECT_ID" ]] && error "Unable to derive project id from $SA_EMAIL"

SECRET_NAME=$(echo "$SA_EMAIL" | cut -d'@' -f1)

ROTATE_THRESHOLD_DAYS=10

log "Starting Service Account Key Rotation"
log "Service Account : $SA_EMAIL"
log "Project ID      : $PROJECT_ID"
log "Secret Name     : $SECRET_NAME"
log "Threshold Days  : $ROTATE_THRESHOLD_DAYS"

#----------------------------------------------------------------------------
# Get Keys
#----------------------------------------------------------------------------
log "Retrieving user-managed keys..."

KEY_INFO=$(gcloud iam service-accounts keys list \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --filter="keyType=USER_MANAGED" \
  --format="json")

KEY_COUNT=$(echo "$KEY_INFO" | jq length)

log "Found $KEY_COUNT user-managed key(s)"

[[ "$KEY_COUNT" -eq 0 ]] && error "No user-managed keys found"

#----------------------------------------------------------------------------
# Delete Expired Keys for Requested Service Account
#----------------------------------------------------------------------------
log "Checking for expired keys..."

CURRENT_EPOCH=$(date -u +%s)

echo "$KEY_INFO" | jq -c '.[]' | while read -r KEY; do

  KEY_NAME=$(echo "$KEY" | jq -r '.name')
  KEY_ID=$(basename "$KEY_NAME")
  EXPIRY=$(echo "$KEY" | jq -r '.validBeforeTime')

  [[ "$EXPIRY" == "null" || -z "$EXPIRY" ]] && continue

  EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)

  if [[ "$EXPIRY_EPOCH" -le "$CURRENT_EPOCH" ]]; then

    warn "Deleting expired key: $KEY_ID"

    gcloud iam service-accounts keys delete "$KEY_ID" \
      --iam-account="$SA_EMAIL" \
      --project="$PROJECT_ID" \
      --quiet

    log "Deleted expired key: $KEY_ID"

  fi

done

#----------------------------------------------------------------------------
# Refresh Key List
#----------------------------------------------------------------------------
KEY_INFO=$(gcloud iam service-accounts keys list \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --filter="keyType=USER_MANAGED" \
  --format="json")

KEY_COUNT=$(echo "$KEY_INFO" | jq length)

log "Active user-managed keys after cleanup : $KEY_COUNT"

[[ "$KEY_COUNT" -eq 0 ]] && error "No active user-managed keys remain"

#----------------------------------------------------------------------------
# Find Newest Key
#----------------------------------------------------------------------------
NEWEST_KEY_ID=$(echo "$KEY_INFO" | jq -r '
  sort_by(.validBeforeTime) | last | .name
')

NEWEST_EXPIRY=$(echo "$KEY_INFO" | jq -r '
  sort_by(.validBeforeTime) | last | .validBeforeTime
')

log "Newest Key Id : $(basename "$NEWEST_KEY_ID")"
log "Expiry Date   : $NEWEST_EXPIRY"

#----------------------------------------------------------------------------
# Calculate Remaining Days
#----------------------------------------------------------------------------
EXPIRY_EPOCH=$(date -d "$NEWEST_EXPIRY" +%s)
CURRENT_EPOCH=$(date -u +%s)

DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

log "Remaining Days : $DAYS_LEFT"

#----------------------------------------------------------------------------
# Skip if healthy
#----------------------------------------------------------------------------
if [[ "$DAYS_LEFT" -gt "$ROTATE_THRESHOLD_DAYS" ]]; then
  log "Key is healthy. Rotation not required."
  exit 0
fi

warn "Key expires within ${ROTATE_THRESHOLD_DAYS} days"
warn "Generating replacement key"

#----------------------------------------------------------------------------
# Create New Key
#----------------------------------------------------------------------------
TEMP_KEY="/tmp/${SECRET_NAME}.json"

gcloud iam service-accounts keys create \
  "$TEMP_KEY" \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID"

NEW_KEY_ID=$(jq -r '.private_key_id' "$TEMP_KEY")

log "Created New Key : $NEW_KEY_ID"

#----------------------------------------------------------------------------
# Ensure Secret Exists
#----------------------------------------------------------------------------
if gcloud secrets describe "$SECRET_NAME" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  log "Secret already exists"

else

  warn "Secret not found. Creating: $SECRET_NAME"

  gcloud secrets create "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --replication-policy=automatic

  log "Secret created"

fi

#----------------------------------------------------------------------------
# Upload Secret Version
#----------------------------------------------------------------------------
log "Uploading key into Secret Manager"

VERSION_NAME=$(gcloud secrets versions add \
  "$SECRET_NAME" \
  --data-file="$TEMP_KEY" \
  --project="$PROJECT_ID" \
  --format="value(name)")

log "Created secret version : $VERSION_NAME"

#----------------------------------------------------------------------------
# Cleanup
#----------------------------------------------------------------------------
rm -f "$TEMP_KEY"

log "Temporary key file removed"
log "Rotation completed successfully"
