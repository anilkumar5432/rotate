#!/bin/bash

set -Eeuo pipefail
umask 077

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
# CONFIG
# ==============================================================================

CA_PROJECT_ID="project-c8d07e0f-e592-42aa-a3d"
CA_PROJECT_NUMBER="525775734928"
LOCATION="us-central1"
CA_POOL="ff37-intranet-pool-sub"

# ==============================================================================
# INPUTS
# ==============================================================================

APP_NAME="${1:-}"
ENVIRONMENT="${2:-}"
TARGET_PROJECT_ID="${3:-}"
VALIDITY_DAYS="${4:-730}"
DNS_PREFIX_INPUT="${5:-}"

[[ -z "${APP_NAME}" ]] && error "APP_NAME is required"
[[ -z "${ENVIRONMENT}" ]] && error "ENVIRONMENT is required"
[[ -z "${TARGET_PROJECT_ID}" ]] && error "TARGET_PROJECT_ID is required"
[[ -z "${DNS_PREFIX_INPUT}" ]] && error "DNS_PREFIXES is required"

# ==============================================================================
# DERIVED VALUES
# ==============================================================================

DNS_SUFFIX="${ENVIRONMENT}.ff37.intranet"
COMMON_NAME="*.${DNS_SUFFIX}"

CERT_NAME="${APP_NAME}-${ENVIRONMENT}-ilb-cert"

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"

OUTPUT_DIR="/workspace/output/${CERT_NAME}-${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

KEY_FILE="${OUTPUT_DIR}/${CERT_NAME}.key"
CSR_FILE="${OUTPUT_DIR}/${CERT_NAME}.csr"

CERT_FILE="${OUTPUT_DIR}/${CERT_NAME}.crt"
CHAIN_FILE="${OUTPUT_DIR}/${CERT_NAME}.chain.crt"

FINAL_CERT_FILE="${OUTPUT_DIR}/${APP_NAME}_${ENVIRONMENT}_cert.pem"

CERTIFICATE_ID="${CERT_NAME}-${TIMESTAMP}"

# ==============================================================================
# BUILD SAN
# ==============================================================================

IFS=',' read -ra RAW_DNS_PREFIXES <<< "$DNS_PREFIX_INPUT"

SAN_VALUE=""

for PREFIX in "${RAW_DNS_PREFIXES[@]}"
do
  PREFIX="$(echo "${PREFIX}" | xargs)"

  [[ -n "${SAN_VALUE}" ]] && SAN_VALUE="${SAN_VALUE},"

  SAN_VALUE="${SAN_VALUE}DNS:${PREFIX}.${DNS_SUFFIX}"
done

# ==============================================================================
# START
# ==============================================================================

log "======================================================="
log "Starting Certificate Automation"
log "Application      : ${APP_NAME}"
log "Environment      : ${ENVIRONMENT}"
log "Project          : ${TARGET_PROJECT_ID}"
log "Certificate Name : ${CERT_NAME}"
log "======================================================="

# ==============================================================================
# KEY
# ==============================================================================

log "Generating EC key"

openssl ecparam \
  -genkey \
  -name prime256v1 \
  -noout \
  -out "${KEY_FILE}"

chmod 600 "${KEY_FILE}"

# ==============================================================================
# CSR
# ==============================================================================

log "Generating CSR"

openssl req \
  -new \
  -sha256 \
  -key "${KEY_FILE}" \
  -out "${CSR_FILE}" \
  -subj "/CN=${COMMON_NAME}" \
  -addext "subjectAltName=${SAN_VALUE}"

openssl req \
  -in "${CSR_FILE}" \
  -noout \
  -verify

log "CSR generated"

# ==============================================================================
# CREATE CERTIFICATE
# ==============================================================================

VALIDITY_SECONDS=$((VALIDITY_DAYS * 86400))

log "Creating CAS certificate"

gcloud privateca certificates create "${CERTIFICATE_ID}" \
  --project="${CA_PROJECT_ID}" \
  --issuer-pool="${CA_POOL}" \
  --issuer-location="${LOCATION}" \
  --csr="${CSR_FILE}" \
  --validity="${VALIDITY_SECONDS}s" \
  --cert-output-file="${CERT_FILE}"

# ==============================================================================
# CHAIN
# ==============================================================================

log "Retrieving chain"

CERT_RESOURCE="projects/${CA_PROJECT_NUMBER}/locations/${LOCATION}/caPools/${CA_POOL}/certificates/${CERTIFICATE_ID}"

gcloud privateca certificates describe "${CERT_RESOURCE}" \
  --project="${CA_PROJECT_ID}" \
  --format="get(pemCertificateChain)" \
  > "${CHAIN_FILE}"

# ==============================================================================
# BUILD FINAL PEM
# ==============================================================================

log "Building PEM bundle"

cp "${CERT_FILE}" "${FINAL_CERT_FILE}"

printf '\n' >> "${FINAL_CERT_FILE}"

cat "${CHAIN_FILE}" >> "${FINAL_CERT_FILE}"

# ==============================================================================
# DEBUG
# ==============================================================================

log "Certificate Debug"

echo "--------------------------------"
echo "LEAF CERT COUNT"
grep -c "BEGIN CERTIFICATE" "${CERT_FILE}" || true

echo "CHAIN CERT COUNT"
grep -c "BEGIN CERTIFICATE" "${CHAIN_FILE}" || true

echo "FINAL CERT COUNT"
grep -c "BEGIN CERTIFICATE" "${FINAL_CERT_FILE}" || true

echo "--------------------------------"
echo "LEAF SUBJECT / ISSUER"

openssl x509 \
  -in "${CERT_FILE}" \
  -subject \
  -issuer \
  -noout

echo "--------------------------------"
echo "SAN VALUES"

openssl x509 \
  -in "${CERT_FILE}" \
  -text \
  -noout | grep -A2 "Subject Alternative Name"

echo "--------------------------------"
echo "PEM VALIDATION"

openssl crl2pkcs7 \
  -nocrl \
  -certfile "${FINAL_CERT_FILE}" |
openssl pkcs7 \
  -print_certs \
  -noout

echo "--------------------------------"

# ==============================================================================
# KEY MATCH CHECK
# ==============================================================================

KEY_PUBLIC_SHA="$(
openssl pkey \
-in "${KEY_FILE}" \
-pubout \
-outform DER |
openssl dgst -sha256 |
awk '{print $NF}'
)"

CERT_PUBLIC_SHA="$(
openssl x509 \
-in "${CERT_FILE}" \
-pubkey \
-noout |
openssl pkey \
-pubin \
-outform DER |
openssl dgst -sha256 |
awk '{print $NF}'
)"

[[ "${KEY_PUBLIC_SHA}" == "${CERT_PUBLIC_SHA}" ]] || \
error "Key and certificate do not match"

log "Key matches certificate"

# ==============================================================================
# EXISTENCE CHECK
# ==============================================================================

if gcloud compute ssl-certificates describe "${CERT_NAME}" \
  --project="${TARGET_PROJECT_ID}" \
  --region="${LOCATION}" >/dev/null 2>&1
then
  error "Certificate already exists"
fi

# ==============================================================================
# TEST IMPORT LEAF CERT ONLY
# ==============================================================================

log "Testing import with LEAF CERTIFICATE only"

gcloud compute ssl-certificates create "${CERT_NAME}-leaf-test" \
  --project="${TARGET_PROJECT_ID}" \
  --region="${LOCATION}" \
  --certificate="${CERT_FILE}" \
  --private-key="${KEY_FILE}" \
  --quiet

log "LEAF CERTIFICATE IMPORT SUCCEEDED"

# ==============================================================================
# FULL CHAIN IMPORT
# ==============================================================================

log "Creating final SSL certificate"

gcloud compute ssl-certificates create "${CERT_NAME}" \
  --project="${TARGET_PROJECT_ID}" \
  --region="${LOCATION}" \
  --certificate="${FINAL_CERT_FILE}" \
  --private-key="${KEY_FILE}" \
  --quiet

log "SUCCESS"

log "Certificate Name : ${CERT_NAME}"
log "PEM File         : ${FINAL_CERT_FILE}"
