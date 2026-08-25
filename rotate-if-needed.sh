#!/bin/bash

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
ORG_ID="123456789012"
ROTATE_THRESHOLD_DAYS=10

# ============================================================================
# Logging Functions
# ============================================================================
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

# ============================================================================
# Function: Delete Expired Keys
# ============================================================================
delete_expired_keys() {

  local PROJECT_ID="$1"
  local SA_EMAIL="$2"

  CURRENT_EPOCH=$(date -u +%s)

  KEYS=$(gcloud iam service-accounts keys list \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --filter="keyType=USER_MANAGED" \
    --format=json 2>/dev/null || echo "[]")

  KEY_COUNT=$(echo "$KEYS" | jq length)

  [[ "$KEY_COUNT" -eq 0 ]] && return 0

  echo "$KEYS" | jq -c '.[]' | while read -r KEY; do

    KEY_ID=$(echo "$KEY" | jq -r '.name | split("/") | last')
    EXPIRY=$(echo "$KEY" | jq -r '.validBeforeTime')

    [[ "$EXPIRY" == "null" || -z "$EXPIRY" ]] && continue

    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)

    if [[ "$EXPIRY_EPOCH" -le "$CURRENT_EPOCH" ]]; then

      warn "Expired key found"
      warn "Project         : $PROJECT_ID"
      warn "Service Account : $SA_EMAIL"
      warn "Key ID          : $KEY_ID"
      warn "Expired On      : $EXPIRY"

      gcloud iam service-accounts keys delete \
        "$KEY_ID" \
        --iam-account="$SA_EMAIL" \
        --project="$PROJECT_ID" \
        --quiet

      log "Deleted expired key: $KEY_ID"

    fi

  done
}

# ============================================================================
# Input
# ============================================================================
SA_EMAIL="${1:-}"

# ============================================================================
# MODE 1
# No Service Account Supplied
# Scan Entire Organization and Delete Expired Keys
# ============================================================================
if [[ -z "$SA_EMAIL" ]]; then

  log "No service account specified"
  log "Organization ID : $ORG_ID"
  log "Scanning all organization projects for expired keys"

  PROJECTS=$(gcloud projects list \
    --filter="parent.type=organization AND parent.id=${ORG_ID}" \
    --format="value(projectId)")

  PROJECT_COUNT=0
  KEY_DELETE_COUNT=0

  for PROJECT_ID in $PROJECTS; do

    PROJECT_COUNT=$((PROJECT_COUNT + 1))

    log "================================================="
    log "Project : $PROJECT_ID"
    log "================================================="

    SA_LIST=$(gcloud iam service-accounts list \
      --project="$PROJECT_ID" \
      --format="value(email)" \
      2>/dev/null || true)

    [[ -z "$SA_LIST" ]] && continue

    for SA in $SA_LIST; do

      log "Checking : $SA"

      BEFORE=$(gcloud iam service-accounts keys list \
        --iam-account="$SA" \
        --project="$PROJECT_ID" \
        --filter="keyType=USER_MANAGED" \
        --format="value(name)" 2>/dev/null | wc -l)

      delete_expired_keys "$PROJECT_ID" "$SA"

      AFTER=$(gcloud iam service-accounts keys list \
        --iam-account="$SA" \
        --project="$PROJECT_ID" \
        --filter="keyType=USER_MANAGED" \
        --format="value(name)" 2>/dev/null | wc -l)

      if [[ "$BEFORE" -gt "$AFTER" ]]; then
        KEY_DELETE_COUNT=$((KEY_DELETE_COUNT + (BEFORE - AFTER)))
      fi

    done

  done

  log "================================================="
  log "Organization scan completed"
  log "Projects Scanned : $PROJECT_COUNT"
  log "Keys Deleted     : $KEY_DELETE_COUNT"
  log "================================================="

  exit 0

fi

# ============================================================================
# MODE 2
# Rotate Particular Service Account
# ============================================================================

[[ -z "$SA_EMAIL" ]] && error "Service account email is required"

PROJECT_ID=$(echo "$SA_EMAIL" | cut -d'@' -f2 | cut -d'.' -f1)

[[ -z "$PROJECT_ID" ]] && error "Unable to derive project id from $SA_EMAIL"

SECRET_NAME=$(echo "$SA_EMAIL" | cut -d'@' -f1)

log "Starting Service Account Key Rotation"
log "Service Account : $SA_EMAIL"
log "Project ID      : $PROJECT_ID"
log "Secret Name     : $SECRET_NAME"
log "Threshold Days  : $ROTATE_THRESHOLD_DAYS"

# ============================================================================
# Cleanup Expired Keys for Target Service Account
# ============================================================================
delete_expired_keys "$PROJECT_ID" "$SA_EMAIL"

# ============================================================================
# Retrieve Active Keys
# ============================================================================
KEY_INFO=$(gcloud iam service-accounts keys list \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --filter="keyType=USER_MANAGED" \
  --format=json)

KEY_COUNT=$(echo "$KEY_INFO" | jq length)

log "Active user-managed keys : $KEY_COUNT"

[[ "$KEY_COUNT" -eq 0 ]] && error "No active user-managed keys found"

# ============================================================================
# Find Newest Key
# ============================================================================
NEWEST_KEY_ID=$(echo "$KEY_INFO" | jq -r '
  sort_by(.validBeforeTime) | last | .name
')

NEWEST_EXPIRY=$(echo "$KEY_INFO" | jq -r '
  sort_by(.validBeforeTime) | last | .validBeforeTime
')

log "Newest Key ID : $(basename "$NEWEST_KEY_ID")"
log "Expiry Date   : $NEWEST_EXPIRY"

# ============================================================================
# Calculate Days Remaining
# ============================================================================
EXPIRY_EPOCH=$(date -d "$NEWEST_EXPIRY" +%s)
CURRENT_EPOCH=$(date -u +%s)

DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

log "Remaining Days : $DAYS_LEFT"

# ============================================================================
# Skip Rotation if Healthy
# ============================================================================
if [[ "$DAYS_LEFT" -gt "$ROTATE_THRESHOLD_DAYS" ]]; then
  log "Key is healthy. Rotation not required."
  exit 0
fi

warn "Key expires within ${ROTATE_THRESHOLD_DAYS} days"
warn "Generating replacement key"

# ============================================================================
# Create New Key
# ============================================================================
TEMP_KEY="/tmp/${SECRET_NAME}.json"

gcloud iam service-accounts keys create \
  "$TEMP_KEY" \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID"

NEW_KEY_ID=$(jq -r '.private_key_id' "$TEMP_KEY")

log "Created new key : $NEW_KEY_ID"

# ============================================================================
# Ensure Secret Exists
# ============================================================================
if gcloud secrets describe "$SECRET_NAME" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  log "Secret already exists"

else

  warn "Secret not found. Creating: $SECRET_NAME"

  gcloud secrets create \
    "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --replication-policy=automatic

  log "Secret created"

fi

# ============================================================================
# Upload Secret Version
# ============================================================================
log "Uploading key to Secret Manager"

VERSION_NAME=$(gcloud secrets versions add \
  "$SECRET_NAME" \
  --data-file="$TEMP_KEY" \
  --project="$PROJECT_ID" \
  --format="value(name)")

log "Created secret version : $VERSION_NAME"

# ============================================================================
# Cleanup
# ============================================================================
rm -f "$TEMP_KEY"

log "Temporary key file removed"
log "Rotation completed successfully"
