#!/bin/bash
# entrypoint.sh — Nextflow head job for nf-core/demo on AWS Batch
#
# Environment variables:
#   NF_PROFILE       Nextflow profile(s), comma-separated  (default: docker)
#   NXF_CONFIG_S3    S3 URI of nextflow.config to download (optional)
#   NF_INPUT         S3 URI of the input samplesheet        (optional; not needed for test profile)
#   NF_OUTDIR        S3 URI for pipeline outputs            (required)
#   NF_WORKDIR       S3 URI for Nextflow work directory     (required)

set -euo pipefail

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] === Nextflow Head Job Starting ==="
echo "Nextflow: $(nextflow -version 2>&1 | head -1)"
echo "AWS CLI:  $(aws --version 2>&1)"
echo "Region:   ${AWS_DEFAULT_REGION:-us-east-1}"

# Validate required variables
: "${NF_OUTDIR:?NF_OUTDIR must be set}"
: "${NF_WORKDIR:?NF_WORKDIR must be set}"

# ── Download nextflow.config from S3 ─────────────────────────────────────────
CONFIG_FLAG=""
if [ -n "${NXF_CONFIG_S3:-}" ]; then
    echo "Downloading nextflow.config from ${NXF_CONFIG_S3}"
    aws s3 cp "${NXF_CONFIG_S3}" /opt/nextflow.config
    CONFIG_FLAG="-c /opt/nextflow.config"
fi

# ── Assemble the nextflow run command ────────────────────────────────────────
PROFILE="${NF_PROFILE:-docker}"

NF_CMD=(
    nextflow run nf-core/demo
    -r 1.1.0
    -profile "${PROFILE}"
    -work-dir "${NF_WORKDIR}"
    --outdir  "${NF_OUTDIR}"
)

[ -n "$CONFIG_FLAG" ]       && NF_CMD+=($CONFIG_FLAG)
[ -n "${NF_INPUT:-}" ]      && NF_CMD+=(--input "${NF_INPUT}")

echo "Command: ${NF_CMD[*]}"
echo "──────────────────────────────────────────────────────────────"

# ── Run pipeline ─────────────────────────────────────────────────────────────
"${NF_CMD[@]}"
EXIT_CODE=$?

# ── Upload Nextflow log to S3 (best-effort) ───────────────────────────────────
if [ -f .nextflow.log ]; then
    LOG_DEST="${NF_OUTDIR%/}/pipeline_info/nextflow.log"
    echo "Uploading .nextflow.log to ${LOG_DEST}"
    aws s3 cp .nextflow.log "${LOG_DEST}" 2>/dev/null || echo "Warning: log upload failed"
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] === Head job finished with exit code ${EXIT_CODE} ==="
exit "${EXIT_CODE}"
