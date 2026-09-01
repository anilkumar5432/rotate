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

    warn "Creating secret: $SECRET_NAME"

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

  log "Secret version created: $VERSION_NAME"
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

  log "New key created: $NEW_KEY_ID"

  ensure_secret "$PROJECT_ID" "$SECRET_NAME"

  upload_secret \
    "$PROJECT_ID" \
    "$SECRET_NAME" \
    "$TEMP_KEY"

  rm -f "$TEMP_KEY"

  log "Temporary key file removed"
}

# ============================================================================
# Delete Specific Expired Key
# ============================================================================

delete_expired_key() {

  local PROJECT_ID="$1"
  local SA_EMAIL="$2"
  local TARGET_KEY_ID="$3"

  [[ -z "$TARGET_KEY_ID" ]] && \
    error "_KEY_ID is mandatory when deletion is enabled"

  log "Validating key: $TARGET_KEY_ID"

  CURRENT_EPOCH=$(date -u +%s)

  KEY_INFO=$(gcloud iam service-accounts keys list \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --filter="keyType=USER_MANAGED" \
    --format=json)

  MATCHING_KEY=$(echo "$KEY_INFO" | jq -c \
      --arg KEY_ID "$TARGET_KEY_ID" \
      '.[] | select(.name | endswith($KEY_ID))')

  [[ -z "$MATCHING_KEY" ]] && \
      error "Key not found: $TARGET_KEY_ID"

  EXPIRY=$(echo "$MATCHING_KEY" | jq -r '.validBeforeTime')

  [[ "$EXPIRY" == "null" ]] && \
      error "Unable to determine expiry date"

  EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)

  if [[ "$EXPIRY_EPOCH" -gt "$CURRENT_EPOCH" ]]; then
    warn "Key is not expired"
    warn "Key ID : $TARGET_KEY_ID"
    warn "Expiry : $EXPIRY"
    return 0
  fi

  warn "Deleting expired key: $TARGET_KEY_ID"

  gcloud iam service-accounts keys delete \
    "$TARGET_KEY_ID" \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --quiet

  log "Key deleted successfully"
}

# ============================================================================
# Conditional Cleanup
# ============================================================================

delete_keys_if_enabled() {

  local PROJECT_ID="$1"
  local SA_EMAIL="$2"
  local TARGET_KEY_ID="$3"

  if [[ "${DELETE_EXPIRED_KEYS,,}" == "true" ]]; then

    log "Deletion enabled"

    delete_expired_key \
      "$PROJECT_ID" \
      "$SA_EMAIL" \
      "$TARGET_KEY_ID"

  else

    warn "Deletion skipped"
  fi
}

# ============================================================================
# Input
# ============================================================================

SA_EMAIL="${1:-}"
DELETE_EXPIRED_KEYS="${2:-false}"
TARGET_KEY_ID="${3:-}"

[[ -z "$SA_EMAIL" ]] && \
  error "Service Account email is required"

# ============================================================================
# Project Details
# ============================================================================

PROJECT_ID=$(echo "$SA_EMAIL" | cut -d'@' -f2 | cut -d'.' -f1)

[[ -z "$PROJECT_ID" ]] && \
  error "Could not derive Project ID"

SECRET_NAME=$(echo "$SA_EMAIL" | cut -d'@' -f1)

log "=================================================="
log "Starting Service Account Key Rotation"
log "Service Account      : $SA_EMAIL"
log "Project ID           : $PROJECT_ID"
log "Secret Name          : $SECRET_NAME"
log "Threshold Days       : $ROTATE_THRESHOLD_DAYS"
log "Delete Key           : $DELETE_EXPIRED_KEYS"
log "Target Key ID        : ${TARGET_KEY_ID:-N/A}"
log "=================================================="

# ============================================================================
# Existing Keys
# ============================================================================

KEY_INFO=$(gcloud iam service-accounts keys list \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --filter="keyType=USER_MANAGED" \
  --format=json)

KEY_COUNT=$(echo "$KEY_INFO" | jq length)

log "User managed keys found: $KEY_COUNT"

# ============================================================================
# No Keys
# ============================================================================

if [[ "$KEY_COUNT" -eq 0 ]]; then

  warn "No user-managed keys found"

  create_new_key \
    "$PROJECT_ID" \
    "$SA_EMAIL" \
    "$SECRET_NAME"

  exit 0
fi

# ============================================================================
# Newest Key
# ============================================================================

NEWEST_KEY_ID=$(echo "$KEY_INFO" | jq -r \
  'sort_by(.validAfterTime) | last | .name')

NEWEST_EXPIRY=$(echo "$KEY_INFO" | jq -r \
  'sort_by(.validAfterTime) | last | .validBeforeTime')

log "Newest Key ID : $(basename "$NEWEST_KEY_ID")"
log "Expiry Date   : $NEWEST_EXPIRY"

EXPIRY_EPOCH=$(date -d "$NEWEST_EXPIRY" +%s)
CURRENT_EPOCH=$(date -u +%s)

DAYS_LEFT=$(((EXPIRY_EPOCH - CURRENT_EPOCH) / 86400))

log "Days Remaining : $DAYS_LEFT"

# ============================================================================
# Healthy
# ============================================================================

if [[ "$DAYS_LEFT" -gt "$ROTATE_THRESHOLD_DAYS" ]]; then

  log "Key is healthy"

  delete_keys_if_enabled \
      "$PROJECT_ID" \
      "$SA_EMAIL" \
      "$TARGET_KEY_ID"

  exit 0
fi

# ============================================================================
# Rotate
# ============================================================================

warn "Key nearing expiry"
warn "Creating replacement key"

create_new_key \
  "$PROJECT_ID" \
  "$SA_EMAIL" \
  "$SECRET_NAME"

delete_keys_if_enabled \
  "$PROJECT_ID" \
  "$SA_EMAIL" \
  "$TARGET_KEY_ID"

log "Key rotation completed successfully"

exit 0
