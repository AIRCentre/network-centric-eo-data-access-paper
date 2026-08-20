#!/bin/bash
set -euo pipefail

# --- Tooling smoke check ---
#
# Guards against base-image regressions like #9/#23, where the previous
# minio/mc image lacked grep/awk and broke the scripts silently.
_missing=""
for _c in grep awk sed mc dd md5sum bash; do
    command -v "$_c" > /dev/null 2>&1 || _missing="${_missing} ${_c}"
done
if [ -n "$_missing" ]; then
    echo "==> ERROR: devshell image is missing required tools:${_missing}" >&2
    echo "    Rebuild with: docker compose build devshell" >&2
    exit 1
fi
unset _c _missing

# --- Configure mc aliases ---

echo "==> Configuring mc alias 'local' -> ${MINIO_ENDPOINT:-http://minio:9000}"
mc alias set local \
    "${MINIO_ENDPOINT:-http://minio:9000}" \
    "${MINIO_ROOT_USER:-minioadmin}" \
    "${MINIO_ROOT_PASSWORD:-minioadmin}" \
    --api S3v4

if [ -n "${AIRDC_ACCESS_KEY:-}" ] && [ -n "${AIRDC_SECRET_KEY:-}" ]; then
    echo "==> Configuring mc alias 'airdc' -> ${AIRDC_ENDPOINT}"
    mc alias set airdc \
        "${AIRDC_ENDPOINT}" \
        "${AIRDC_ACCESS_KEY}" \
        "${AIRDC_SECRET_KEY}" \
        --api S3v4
else
    echo "==> WARNING: AIRDC_ACCESS_KEY / AIRDC_SECRET_KEY not set."
    echo "    Replication benchmark will not work without remote credentials."
fi

# --- Create bucket and enable versioning (idempotent) ---

BUCKET="${REPL_BUCKET:-atlantic-cloud-replication-test}"

echo "==> Ensuring bucket 'local/${BUCKET}' exists"
mc mb --ignore-existing "local/${BUCKET}"

echo "==> Enabling versioning on 'local/${BUCKET}'"
mc version enable "local/${BUCKET}"

# --- Configure replication (if remote credentials provided) ---

if [ -n "${AIRDC_ACCESS_KEY:-}" ] && [ -n "${AIRDC_SECRET_KEY:-}" ]; then
    AIRDC_HOST="${AIRDC_ENDPOINT:-https://s3.ac-az1.aircentre.org}"
    REMOTE_URL="${AIRDC_HOST%%/}/${BUCKET}"
    # Inject credentials into URL: https://KEY:SECRET@host/bucket
    REMOTE_URL="${REMOTE_URL/\/\////${AIRDC_ACCESS_KEY}:${AIRDC_SECRET_KEY}@}"

    # Add replication rule (mc replicate add is idempotent if remote-bucket matches).
    echo "==> Adding replication to ${AIRDC_HOST}/${BUCKET}"
    mc replicate add "local/${BUCKET}" \
        --remote-bucket "${REMOTE_URL}" \
        --replicate "delete,delete-marker,existing-objects" \
        || echo "==> WARNING: mc replicate add failed (rule may already exist)"
    mc replicate status "local/${BUCKET}" 2>/dev/null || true
else
    echo "==> AIRDC credentials not set — skipping replication setup."
fi

echo "==> Ready."
echo ""

exec "$@"
