#!/bin/bash

set -Eeuo pipefail
umask 077

# ==============================================================================
# Logging
# ==============================================================================

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

# ==============================================================================
# Static Configuration
# ==============================================================================

CA_PROJECT_ID="prj-ff-cert-mgr-prod-001-2147"
LOCATION="us-central1"
CA_POOL="ff37-intranet-pool-sub"

# ==============================================================================
# Input Parameters
# ==============================================================================

APP_NAME="${1:-}"
ENVIRONMENT="${2:-}"
TARGET_PROJECT_ID="${3:-}"
VALIDITY_DAYS="${4:-730}"
DNS_PREFIX_INPUT="${5:-}"

[[ -z "$APP_NAME" ]] && error "APP_NAME is required."
[[ -z "$ENVIRONMENT" ]] && error "ENVIRONMENT is required."
[[ -z "$TARGET_PROJECT_ID" ]] && error "TARGET_PROJECT_ID is required."
[[ -z "$DNS_PREFIX_INPUT" ]] && error "DNS_PREFIXES are required."

[[ "$ENVIRONMENT" =~ ^(qa|dev|prod)$ ]] || \
  error "ENVIRONMENT must be qa, dev or prod."

# ==============================================================================
# Build Values
# ==============================================================================

DNS_SUFFIX="${ENVIRONMENT}.ff37.intranet"

COMMON_NAME="*.${DNS_SUFFIX}"

CERT_NAME="${APP_NAME}-${ENVIRONMENT}-ilb-cert"

KEY_NAME="${CERT_NAME}.key"
CSR_NAME="${CERT_NAME}.csr"

TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)

OUTPUT_DIR="/workspace/output/${CERT_NAME}-${TIMESTAMP}"

mkdir -p "$OUTPUT_DIR"

KEY_FILE="${OUTPUT_DIR}/${KEY_NAME}"
CSR_FILE="${OUTPUT_DIR}/${CSR_NAME}"

CERT_FILE="${OUTPUT_DIR}/${CERT_NAME}.crt"
CHAIN_FILE="${OUTPUT_DIR}/${CERT_NAME}.chain.crt"

FINAL_CERT_FILE="${OUTPUT_DIR}/${APP_NAME}_${ENVIRONMENT}_cert.pem"

# ==============================================================================
# Build SAN List
# ==============================================================================

IFS=',' read -ra RAW_DNS_PREFIXES <<< "$DNS_PREFIX_INPUT"

SAN_VALUE=""
DNS_NAMES=()

for DNS_PREFIX in "${RAW_DNS_PREFIXES[@]}"
do
  DNS_PREFIX=$(echo "$DNS_PREFIX" | xargs)

  [[ -z "$DNS_PREFIX" ]] && \
    error "Empty DNS SAN prefix."

  DNS_NAME="${DNS_PREFIX}.${DNS_SUFFIX}"

  DNS_NAMES+=("$DNS_NAME")

  if [[ -n "$SAN_VALUE" ]]; then
    SAN_VALUE="${SAN_VALUE},"
  fi

  SAN_VALUE="${SAN_VALUE}DNS:${DNS_NAME}"
done

# ==============================================================================
# Summary
# ==============================================================================

log "======================================================="
log "Starting Certificate Automation"
log "Application      : $APP_NAME"
log "Environment      : $ENVIRONMENT"
log "Target Project   : $TARGET_PROJECT_ID"
log "Certificate Name : $CERT_NAME"
log "Validity         : $VALIDITY_DAYS days"
log "Common Name      : $COMMON_NAME"
log "CA Project       : $CA_PROJECT_ID"
log "CA Pool          : $CA_POOL"
log "Location         : $LOCATION"
log "======================================================="

# ==============================================================================
# Generate EC Private Key
# ==============================================================================

log "Generating EC private key"

openssl ecparam \
  -genkey \
  -name prime256v1 \
  -noout \
  -out "$KEY_FILE"

chmod 600 "$KEY_FILE"

# ==============================================================================
# Generate CSR
# ==============================================================================

log "Generating CSR"

openssl req \
  -new \
  -sha256 \
  -key "$KEY_FILE" \
  -out "$CSR_FILE" \
  -subj "/CN=${COMMON_NAME}" \
  -addext "subjectAltName=${SAN_VALUE}"

openssl req \
  -in "$CSR_FILE" \
  -noout \
  -verify

log "CSR generated successfully"

# ==============================================================================
# Convert Days To Seconds
# ==============================================================================

VALIDITY_SECONDS=$((VALIDITY_DAYS * 86400))

log "Validity Seconds: ${VALIDITY_SECONDS}"

# ==============================================================================
# Issue Certificate Using CAS
# ==============================================================================

CERTIFICATE_ID="${CERT_NAME}-${TIMESTAMP}"

log "Requesting certificate from CAS"

gcloud privateca certificates create "$CERTIFICATE_ID" \
  --project="$CA_PROJECT_ID" \
  --location="$LOCATION" \
  --issuer-pool="$CA_POOL" \
  --csr="$CSR_FILE" \
  --validity="${VALIDITY_SECONDS}s"

# ==============================================================================
# Export Certificate
# ==============================================================================

log "Exporting leaf certificate"

gcloud privateca certificates describe \
  "$CERTIFICATE_ID" \
  --project="$CA_PROJECT_ID" \
  --location="$LOCATION" \
  --issuer-pool="$CA_POOL" \
  --format="value(pemCertificate)" \
  > "$CERT_FILE"

log "Exporting certificate chain"

gcloud privateca certificates describe \
  "$CERTIFICATE_ID" \
  --project="$CA_PROJECT_ID" \
  --location="$LOCATION" \
  --issuer-pool="$CA_POOL" \
  --format="value(pemCertificateChain)" \
  > "$CHAIN_FILE"

# ==============================================================================
# Assemble Final PEM
# ==============================================================================

cat "$CERT_FILE" > "$FINAL_CERT_FILE"
cat "$CHAIN_FILE" >> "$FINAL_CERT_FILE"

# ==============================================================================
# Key/Cert Validation
# ==============================================================================

KEY_PUBLIC_SHA=$(
openssl pkey \
  -in "$KEY_FILE" \
  -pubout \
  -outform DER |
openssl dgst -sha256 |
awk '{print $NF}'
)

CERT_PUBLIC_SHA=$(
openssl x509 \
  -in "$FINAL_CERT_FILE" \
  -pubkey \
  -noout |
openssl pkey \
  -pubin \
  -outform DER |
openssl dgst -sha256 |
awk '{print $NF}'
)

[[ "$KEY_PUBLIC_SHA" == "$CERT_PUBLIC_SHA" ]] || \
  error "Certificate does not match generated private key."

log "Certificate validation successful"

# ==============================================================================
# Check Existing SSL Certificate
# ==============================================================================

if gcloud compute ssl-certificates describe "$CERT_NAME" \
  --project="$TARGET_PROJECT_ID" \
  --region="$LOCATION" \
  >/dev/null 2>&1; then

  error "SSL certificate already exists: $CERT_NAME"
fi

# ==============================================================================
# Create Regional SSL Certificate
# ==============================================================================

log "Creating regional SSL certificate"

gcloud compute ssl-certificates create "$CERT_NAME" \
  --project="$TARGET_PROJECT_ID" \
  --region="$LOCATION" \
  --certificate="$FINAL_CERT_FILE" \
  --private-key="$KEY_FILE" \
  --quiet

# ==============================================================================
# Complete
# ==============================================================================

log "======================================================="
log "Certificate Created Successfully"
log "Certificate Name : $CERT_NAME"
log "Project          : $TARGET_PROJECT_ID"
log "Region           : $LOCATION"
log "Private Key      : $KEY_FILE"
log "CSR              : $CSR_FILE"
log "Certificate PEM  : $FINAL_CERT_FILE"
log "======================================================="
