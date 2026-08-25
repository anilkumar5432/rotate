#!/bin/bash

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
#ORG_ID="924103328234"
#ROTATE_THRESHOLD_DAYS=10

# ============================================================================
# Configuration
# ============================================================================

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

# Automatically determine Organization ID
ORG_ID=$(gcloud organizations list \
  --format="value(ID)" | head -1)

[[ -z "$ORG_ID" ]] && error "Unable to determine Organization ID. Verify Cloud Build SA has organization access."

ROTATE_THRESHOLD_DAYS=10

log "Detected Organization ID : $ORG_ID"

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

    gcloud secrets create "$SECRET_NAME" \
      --project="$PROJECT_ID" \
      --replication-policy=automatic

    log "Secret created"

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

  log "Created secret version : $VERSION_NAME"
}

# ============================================================================
# Create Initial Key
# ============================================================================
create_initial_key() {

  local PROJECT_ID="$1"
  local SA_EMAIL="$2"
  local SECRET_NAME="$3"

  TEMP_KEY="/tmp/${SECRET_NAME}.json"

  log "Creating initial key for service account"

  gcloud iam service-accounts keys create \
    "$TEMP_KEY" \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID"

  NEW_KEY_ID=$(jq -r '.private_key_id' "$TEMP_KEY")

  log "Created initial key : $NEW_KEY_ID"

  ensure_secret "$PROJECT_ID" "$SECRET_NAME"

  upload_secret "$PROJECT_ID" "$SECRET_NAME" "$TEMP_KEY"

  rm -f "$TEMP_KEY"

  log "Initial key creation completed successfully"
}

# ============================================================================
# Delete Expired Keys
# ============================================================================
delete_expired_keys() {

  local PROJECT_ID="$1"
  local SA_EMAIL="$2"

  LAST_DELETED_COUNT=0
  LAST_SA_MODIFIED="false"

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

    log "Deleted expired key : $KEY_ID"

    LAST_DELETED_COUNT=$((LAST_DELETED_COUNT + 1))
    LAST_SA_MODIFIED="true"

  fi

done < <(echo "$KEYS" | jq -c '.[]')
  # [[ "$(echo "$KEYS" | jq length)" -eq 0 ]] && return

  # echo "$KEYS" | jq -c '.[]' | while read -r KEY; do

  #   KEY_ID=$(echo "$KEY" | jq -r '.name | split("/") | last')
  #   EXPIRY=$(echo "$KEY" | jq -r '.validBeforeTime')

  #   [[ "$EXPIRY" == "null" || -z "$EXPIRY" ]] && continue

  #   EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)

  #   if [[ "$EXPIRY_EPOCH" -le "$CURRENT_EPOCH" ]]; then

  #     warn "Expired key found"
  #     warn "Project         : $PROJECT_ID"
  #     warn "Service Account : $SA_EMAIL"
  #     warn "Key ID          : $KEY_ID"
  #     warn "Expired On      : $EXPIRY"

  #     gcloud iam service-accounts keys delete \
  #       "$KEY_ID" \
  #       --iam-account="$SA_EMAIL" \
  #       --project="$PROJECT_ID" \
  #       --quiet

  #     log "Deleted expired key : $KEY_ID"

  #     LAST_DELETED_COUNT=$((LAST_DELETED_COUNT + 1))
  #     LAST_SA_MODIFIED="true"

  #   fi

  # done

  export LAST_DELETED_COUNT
  export LAST_SA_MODIFIED
}

# ============================================================================
# Input
# ============================================================================
SA_EMAIL="${1:-}"

# ============================================================================
# MODE 1 - Organization Wide Cleanup
# ============================================================================
if [[ -z "$SA_EMAIL" ]]; then

  log "No Service Account supplied"
  log "Organization ID : $ORG_ID"
  log "Scanning all projects for expired keys"

  PROJECT_COUNT=0
  TOTAL_SA_COUNT=0
  TOTAL_EXPIRED_KEYS_DELETED=0

  ORG_AFFECTED_SAS=""

  PROJECTS=$(gcloud projects list \
    --filter="parent.type=organization AND parent.id=${ORG_ID}" \
    --format="value(projectId)")

  for PROJECT_ID in $PROJECTS; do

    PROJECT_COUNT=$((PROJECT_COUNT + 1))
    PROJECT_SA_COUNT=0
    PROJECT_KEYS_DELETED=0
    PROJECT_AFFECTED_SAS=""

    log "=================================================="
    log "Project : $PROJECT_ID"
    log "=================================================="

    SA_LIST=$(gcloud iam service-accounts list \
      --project="$PROJECT_ID" \
      --format="value(email)" \
      2>/dev/null || true)

    [[ -z "$SA_LIST" ]] && continue

    for SA in $SA_LIST; do

      PROJECT_SA_COUNT=$((PROJECT_SA_COUNT + 1))
      TOTAL_SA_COUNT=$((TOTAL_SA_COUNT + 1))

      delete_expired_keys "$PROJECT_ID" "$SA"

      PROJECT_KEYS_DELETED=$((PROJECT_KEYS_DELETED + LAST_DELETED_COUNT))
      TOTAL_EXPIRED_KEYS_DELETED=$((TOTAL_EXPIRED_KEYS_DELETED + LAST_DELETED_COUNT))

      if [[ "$LAST_SA_MODIFIED" == "true" ]]; then
        PROJECT_AFFECTED_SAS="${PROJECT_AFFECTED_SAS}${SA}"$'\n'
        ORG_AFFECTED_SAS="${ORG_AFFECTED_SAS}${PROJECT_ID} | ${SA}"$'\n'
      fi

    done

    log "--------------------------------------------------"
    log "Project Summary : $PROJECT_ID"
    log "Service Accounts Scanned : $PROJECT_SA_COUNT"
    log "Expired Keys Deleted     : $PROJECT_KEYS_DELETED"

    if [[ -n "$PROJECT_AFFECTED_SAS" ]]; then

      log "Service Accounts With Deleted Keys:"

      while IFS= read -r SA; do
        [[ -n "$SA" ]] && log "  - $SA"
      done <<< "$PROJECT_AFFECTED_SAS"

    fi

    log "--------------------------------------------------"

  done

  log "=================================================="
  log "Organization-wide expired key cleanup completed"
  log "Projects Scanned         : $PROJECT_COUNT"
  log "Service Accounts Scanned : $TOTAL_SA_COUNT"
  log "Expired Keys Deleted     : $TOTAL_EXPIRED_KEYS_DELETED"

  if [[ -n "$ORG_AFFECTED_SAS" ]]; then

    log "=================================================="
    log "Service Accounts Where Keys Were Deleted"
    log "=================================================="

    while IFS= read -r ENTRY; do
      [[ -n "$ENTRY" ]] && log "$ENTRY"
    done <<< "$ORG_AFFECTED_SAS"

  fi

  log "=================================================="

  exit 0

fi

# ============================================================================
# MODE 2 - Rotate Specific Service Account
# ============================================================================
PROJECT_ID=$(echo "$SA_EMAIL" | cut -d'@' -f2 | cut -d'.' -f1)

[[ -z "$PROJECT_ID" ]] && error "Unable to derive project id"

SECRET_NAME=$(echo "$SA_EMAIL" | cut -d'@' -f1)

log "Starting Service Account Key Rotation"
log "Service Account : $SA_EMAIL"
log "Project ID      : $PROJECT_ID"
log "Secret Name     : $SECRET_NAME"
log "Threshold Days  : $ROTATE_THRESHOLD_DAYS"

delete_expired_keys "$PROJECT_ID" "$SA_EMAIL"

KEY_INFO=$(gcloud iam service-accounts keys list \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --filter="keyType=USER_MANAGED" \
  --format=json)

KEY_COUNT=$(echo "$KEY_INFO" | jq length)

log "Active user-managed keys : $KEY_COUNT"

if [[ "$KEY_COUNT" -eq 0 ]]; then

  warn "No user-managed keys found"

  create_initial_key \
    "$PROJECT_ID" \
    "$SA_EMAIL" \
    "$SECRET_NAME"

  exit 0

fi

NEWEST_KEY_ID=$(echo "$KEY_INFO" | jq -r 'sort_by(.validBeforeTime) | last | .name')
NEWEST_EXPIRY=$(echo "$KEY_INFO" | jq -r 'sort_by(.validBeforeTime) | last | .validBeforeTime')

log "Newest Key ID : $(basename "$NEWEST_KEY_ID")"
log "Expiry Date   : $NEWEST_EXPIRY"

EXPIRY_EPOCH=$(date -d "$NEWEST_EXPIRY" +%s)
CURRENT_EPOCH=$(date -u +%s)

DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

log "Remaining Days : $DAYS_LEFT"

if [[ "$DAYS_LEFT" -gt "$ROTATE_THRESHOLD_DAYS" ]]; then
  log "Key is healthy. Rotation not required."
  exit 0
fi

warn "Key expires within ${ROTATE_THRESHOLD_DAYS} days"
warn "Generating replacement key"

TEMP_KEY="/tmp/${SECRET_NAME}.json"

gcloud iam service-accounts keys create \
  "$TEMP_KEY" \
  --iam-account="$SA_EMAIL" \
  --project="$PROJECT_ID"

NEW_KEY_ID=$(jq -r '.private_key_id' "$TEMP_KEY")

log "Created new key : $NEW_KEY_ID"

ensure_secret "$PROJECT_ID" "$SECRET_NAME"

upload_secret "$PROJECT_ID" "$SECRET_NAME" "$TEMP_KEY"

rm -f "$TEMP_KEY"

log "Temporary key file removed"
log "Rotation completed successfully"
