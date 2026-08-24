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
SA_EMAIL="$1"

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
``
