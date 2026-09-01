#!/bin/bash

set -euo pipefail

# ============================================================================
# Logging
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
# Configuration
# ============================================================================

ROTATE_THRESHOLD_DAYS=10

# ============================================================================
# Ensure Secret Exists
# ============================================================================

ensure_secret() {

  local PROJECT_ID="$1"
  local SECRET_NAME="$2"

  if gcloud secrets describe "$SECRET_NAME" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

    log "Secret already exists: $SECRET_NAME"

  else

    warn "Secret not found. Creating: $SECRET_NAME"

    gcloud secrets create \
      "$SECRET_NAME" \
      --project="$PROJECT_ID" \
      --replication-policy=automatic

    log "Secret created successfully"
  fi
}

# ============================================================================
# Upload Secret
# ============================================================================

upload_secret() {

  local PROJECT_ID="$1"
  local SECRET_NAME="$2"
  local KEY_FILE="$3"

  VERSION_NAME=$(gcloud secrets versions add \
    "$SECRET_NAME" \
    --data-file="$KEY_FILE" \
    --project="$PROJECT_ID" \
    --format="value(name)")

  log "Created secret version: $VERSION_NAME"
}

# ============================================================================
# Create New Key
# ============================================================================

create_new_key() {

  local PROJECT_ID="$1"
  local SA_EMAIL="$2"
  local SECRET_NAME="$3"

  local TEMP_KEY="/tmp/${SECRET_NAME}.json"

  log "Creating new service account key"

  gcloud iam service-accounts keys create \
    "$TEMP_KEY" \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID"

  NEW_KEY_ID=$(jq -r '.private_key_id' "$TEMP_KEY")

  log "Created new key: $NEW_KEY_ID"

  ensure_secret "$PROJECT_ID" "$SECRET_NAME"

  upload_secret \
    "$PROJECT_ID" \
    "$SECRET_NAME" \
    "$TEMP_KEY"

  rm -f "$TEMP_KEY"

  log "Temporary key file removed"
}

# ============================================================================
# Delete Expired Keys
# ============================================================================

delete_expired_keys() {

  local PROJECT_ID="$1"
  local SA_EMAIL="$2"

  local DELETED_COUNT=0
  local CURRENT_EPOCH

  CURRENT_EPOCH=$(date -u +%s)

  KEYS=$(gcloud iam service-accounts keys list \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --filter="keyType=USER_MANAGED" \
    --format=json 2>/dev/null || echo "[]")

  while read -r KEY; do

    KEY_ID=$(echo "$KEY" | jq -r '.name | split("/") | last')
    EXPIRY=$(echo "$KEY" | jq -r '.validBeforeTime')

    [[ "$EXPIRY" == "null" || -z "$EXPIRY" ]] && continue

    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)

    if [[ "$EXPIRY_EPOCH" -le "$CURRENT_EPOCH" ]]; then

      warn "Deleting expired key: $KEY_ID"

      gcloud iam service-accounts keys delete \
        "$KEY_ID" \
        --iam-account="$SA_EMAIL" \
        --project="$PROJECT_ID" \
        --quiet

      DELETED_COUNT=$((DELETED_COUNT + 1))

      log "Deleted expired key: $KEY_ID"
    fi

  done < <(echo "$KEYS" | jq -c '.[]')

  log "Expired keys deleted: $DELETED_COUNT"
}

# ============================================================================
# Conditional Cleanup
# ============================================================================

delete_keys_if_enabled() {

  local PROJECT_ID="$1"
  local SA_EMAIL="$2"

  if [[ "${DELETE_EXPIRED_KEYS,,}" == "true" ]]; then

    log "Expired key cleanup enabled"

    delete_expired_keys \
      "$PROJECT_ID" \
      "$SA_EMAIL"

  else

    warn "Expired key cleanup skipped by trigger parameter (_DELETE_EXPIRED_KEYS=false)"
  fi
}

# ============================================================================
# Validate Input
# ============================================================================

SA_EMAIL="${1:-}"
DELETE_EXPIRED_KEYS="${2:-true}"

[[ -z "$SA_EMAIL" ]] && error "Service Account email is required"

# ============================================================================
# Derive Project Details
# ============================================================================

PROJECT_ID=$(echo "$SA_EMAIL" | cut -d'@' -f2 | cut -d'.' -f1)

[[ -z "$PROJECT_ID" ]] && error "Unable to derive Project ID"

SECRET_NAME=$(echo "$SA_EMAIL" | cut -d'@' -f1)

log "=================================================="
log "Starting Service Account Key Rotation"
log "Service Account      : $SA_EMAIL"
log "Project ID           : $PROJECT_ID"
log "Secret Name          : $SECRET_NAME"
log "Threshold Days       : $ROTATE_THRESHOLD_DAYS"
log "Delete Expired Keys  : $DELETE_EXPIRED_KEYS"
log "=================================================="

# ============================================================================
# Get Existing User Managed Keys
# ============================================================================

KEY_INFO=$(gcloud iam service-accounts keys list \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --filter="keyType=USER_MANAGED" \
  --format=json)

KEY_COUNT=$(echo "$KEY_INFO" | jq length)

log "User-managed keys found: $KEY_COUNT"

# ============================================================================
# No Keys Exist
# ============================================================================

if [[ "$KEY_COUNT" -eq 0 ]]; then

  warn "No user-managed keys found"

  create_new_key \
    "$PROJECT_ID" \
    "$SA_EMAIL" \
    "$SECRET_NAME"

  delete_keys_if_enabled \
    "$PROJECT_ID" \
    "$SA_EMAIL"

  log "Initial key created successfully"
  exit 0
fi

# ============================================================================
# Find Latest Key
# ============================================================================

NEWEST_KEY_ID=$(echo "$KEY_INFO" | jq -r 'sort_by(.validAfterTime) | last | .name')
NEWEST_EXPIRY=$(echo "$KEY_INFO" | jq -r 'sort_by(.validAfterTime) | last | .validBeforeTime')

log "Newest Key ID : $(basename "$NEWEST_KEY_ID")"
log "Expiry Date   : $NEWEST_EXPIRY"

EXPIRY_EPOCH=$(date -d "$NEWEST_EXPIRY" +%s)
CURRENT_EPOCH=$(date -u +%s)

DAYS_LEFT=$(((EXPIRY_EPOCH - CURRENT_EPOCH) / 86400))

log "Remaining Days : $DAYS_LEFT"

# ============================================================================
# Key Healthy
# ============================================================================

if [[ "$DAYS_LEFT" -gt "$ROTATE_THRESHOLD_DAYS" ]]; then

  log "Key is healthy. No rotation required."

  delete_keys_if_enabled \
    "$PROJECT_ID" \
    "$SA_EMAIL"

  log "Validation completed successfully"
  exit 0
fi

# ============================================================================
# Rotate Key
# ============================================================================

warn "Key expires within ${ROTATE_THRESHOLD_DAYS} days"
warn "Creating replacement key"

create_new_key \
  "$PROJECT_ID" \
  "$SA_EMAIL" \
  "$SECRET_NAME"

delete_keys_if_enabled \
  "$PROJECT_ID" \
  "$SA_EMAIL"

log "Key rotation completed successfully"

exit 0
