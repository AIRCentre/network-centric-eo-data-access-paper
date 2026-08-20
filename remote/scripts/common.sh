#!/usr/bin/env bash
# common.sh — Shared utilities for remote access benchmarks.
# Source from other scripts: source "$(dirname "$0")/common.sh"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Environment ---

load_env() {
    if [ ! -f "$REPO_ROOT/.env" ]; then
        echo "ERROR: .env file not found."
        echo "Copy example.env to .env and fill in your credentials:"
        echo "  cp example.env .env"
        exit 1
    fi
    set -a
    source "$REPO_ROOT/.env"
    set +a
}

# --- Output directory ---
# Sets RESULTS_DIR and EPOCH as globals. Call directly, not in $(...).

setup_output() {
    SITE="${SITE:-$(hostname -s)}"
    RESULTS_DIR="$REPO_ROOT/results/$SITE"
    mkdir -p "$RESULTS_DIR"
    EPOCH=$(date +%s)
}

# --- Portable timestamps ---

# Returns current time in nanoseconds. macOS date doesn't support %N,
# so we detect that and fall back to python3.
_ts_test=$(date +%s%N 2>/dev/null || echo "bad")
if echo "$_ts_test" | grep -qE '^[0-9]+$'; then
    timestamp_ns() { date +%s%N; }
else
    timestamp_ns() { python3 -c "import time; print(int(time.time()*1e9))"; }
fi
unset _ts_test

# --- Connectivity checks ---

check_endpoint() {
    local name="$1"
    local url="$2"
    local timeout="${3:-10}"

    printf "  %-25s " "$name"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null) || true

    if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
        echo "UNREACHABLE"
        return 1
    elif [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
        echo "OK ($http_code)"
        return 0
    elif [ "$http_code" -ge 400 ] && [ "$http_code" -lt 500 ]; then
        echo "AUTH REQUIRED ($http_code) — expected, will use API key"
        return 0
    else
        echo "ERROR ($http_code)"
        return 1
    fi
}

# --- JSON helpers ---

# Escape a string for safe JSON embedding.
json_escape() {
    python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null
}

# Escape a single value for JSON. Strips newlines, escapes quotes.
json_safe_value() {
    echo "$1" | tr -d '\n' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# --- System info ---

collect_system_info() {
    local h; h=$(json_safe_value "$(hostname -f 2>/dev/null || hostname)")
    local os; os=$(json_safe_value "$(uname -s)")
    local osv; osv=$(json_safe_value "$(uname -r)")
    local arch; arch=$(json_safe_value "$(uname -m)")
    local cv; cv=$(json_safe_value "$(curl --version 2>/dev/null | head -1)")

    cat <<SYSEOF
{
    "hostname": "$h",
    "os": "$os",
    "os_version": "$osv",
    "arch": "$arch",
    "date_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "timezone": "$(date +%Z)",
    "curl_version": "$cv",
    "site": "$(json_safe_value "${SITE:-$(hostname -s)}")",
    "location": "$(json_safe_value "${LOCATION:-not specified}")",
    "isp": "$(json_safe_value "${ISP:-not specified}")",
    "connection_type": "$(json_safe_value "${CONNECTION_TYPE:-not specified}")"
}
SYSEOF
}

# --- Progress display ---

progress() {
    echo ""
    echo "=== $1 ==="
    echo ""
}

info() {
    echo "  $1"
}

warn() {
    echo "  WARNING: $1"
}

fail() {
    echo "  FATAL: $1"
    exit 1
}
