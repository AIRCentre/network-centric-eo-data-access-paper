#!/usr/bin/env bash
# run_replication.sh — Option B: Cross-site MinIO replication benchmark.
# Linux and macOS only.
#
# Measures replication throughput, latency, and integrity between
# your local MinIO instance and the AIR Data Centre. Requires mc
# (MinIO Client) with aliases configured for both endpoints.
#
# Before running:
#   1. Follow REPLICATION_SETUP.md to install MinIO and mc.
#   2. Configure mc aliases: "local" (your MinIO) and "airdc" (Azores).
#   3. Set up bucket replication with João's help.
#   4. Copy example.env to .env and set SITE and replication variables.
#
# Usage:
#   ./scripts/run_replication.sh

source "$(dirname "$0")/common.sh"

# --- Platform check ---

_os=$(uname -s)
case "$_os" in
    Linux|Darwin)
        ;;
    MINGW*|MSYS*|CYGWIN*)
        fail "Native Windows is not supported. Use WSL (Windows Subsystem for Linux)."
        ;;
    *)
        warn "Unrecognised platform: $_os. Scripts are tested on Linux and macOS only."
        ;;
esac
unset _os

load_env

echo "======================================"
echo "  Atlantic Cloud — Remote Benchmarks"
echo "  Option B: Cross-Site Replication"
echo "======================================"

# --- Configuration ---

LOCAL_ALIAS="${REPL_LOCAL_ALIAS:-local}"
REMOTE_ALIAS="${REPL_REMOTE_ALIAS:-airdc}"
BUCKET="${REPL_BUCKET:-atlantic-cloud-replication-test}"
REPS="${REPL_REPS:-3}"
POLL_INTERVAL="${REPL_POLL_INTERVAL:-2}"
# Per-size poll timeouts in seconds. REPL_POLL_TIMEOUT (if set) overrides all.
POLL_TIMEOUT_4MIB="${REPL_POLL_TIMEOUT:-${REPL_POLL_TIMEOUT_4MIB:-300}}"
POLL_TIMEOUT_64MIB="${REPL_POLL_TIMEOUT:-${REPL_POLL_TIMEOUT_64MIB:-900}}"
POLL_TIMEOUT_512MIB="${REPL_POLL_TIMEOUT:-${REPL_POLL_TIMEOUT_512MIB:-1800}}"

# Sizes matching the internal benchmarks (no 2 GiB — too slow over WAN).
declare -a SIZES=("4MiB" "64MiB" "512MiB")
declare -a SIZE_BYTES=(4194304 67108864 536870912)
declare -a SIZE_EO=("Zarr chunk" "COG tile" "Sentinel-2 granule")
declare -a SIZE_TIMEOUTS=("$POLL_TIMEOUT_4MIB" "$POLL_TIMEOUT_64MIB" "$POLL_TIMEOUT_512MIB")

# --- Prerequisites ---

progress "Checking prerequisites"

for cmd in mc dd; do
    if command -v "$cmd" > /dev/null 2>&1; then
        info "$cmd: OK"
    else
        fail "$cmd is required but not found. See REPLICATION_SETUP.md."
    fi
done

# md5sum on Linux, md5 on macOS.
if command -v md5sum > /dev/null 2>&1; then
    compute_md5() { md5sum "$1" | awk '{print $1}'; }
    info "md5sum: OK"
elif command -v md5 > /dev/null 2>&1; then
    compute_md5() { md5 -q "$1"; }
    info "md5: OK (macOS)"
else
    fail "Neither md5sum nor md5 found."
fi

# Verify mc aliases.
info "Checking mc alias '$LOCAL_ALIAS'..."
mc ls "$LOCAL_ALIAS" > /dev/null 2>&1 \
    || fail "mc alias '$LOCAL_ALIAS' not configured. Run: mc alias set $LOCAL_ALIAS ..."

info "Checking mc alias '$REMOTE_ALIAS'..."
mc ls "$REMOTE_ALIAS" > /dev/null 2>&1 \
    || fail "mc alias '$REMOTE_ALIAS' not configured. Run: mc alias set $REMOTE_ALIAS ..."

# Verify bucket exists.
info "Checking bucket '$BUCKET' on $LOCAL_ALIAS..."
mc ls "$LOCAL_ALIAS/$BUCKET" > /dev/null 2>&1 \
    || fail "Bucket '$BUCKET' not found on $LOCAL_ALIAS. See REPLICATION_SETUP.md."

# --- Clear buckets ---
#
# Clear remote only (purges all versions + delete markers at the
# destination). Local bucket is expected to already be clean — per-rep
# cleanup removes objects at the end of each iteration.

progress "Clearing remote bucket (all versions)"
mc rm --recursive --force --versions "$REMOTE_ALIAS/$BUCKET" > /dev/null 2>&1 || true

wait_bucket_empty() {
    local target="$1"
    local timeout="$2"
    local waited=0
    local output rc count
    while [ "$waited" -lt "$timeout" ]; do
        output=$(mc ls --recursive --versions "$target" 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            warn "  mc ls failed (rc=$rc): $output — retrying"
        else
            # Count non-empty lines robustly.
            if [ -z "$output" ]; then
                count=0
            else
                count=$(printf '%s\n' "$output" | grep -c '[^[:space:]]')
            fi
            if [ "$count" -eq 0 ]; then
                info "  $target: empty (after ${waited}s)"
                return 0
            fi
            info "  $target: $count entries remaining (waited ${waited}s)"
        fi
        sleep 5
        waited=$((waited + 5))
    done
    fail "$target still has objects after ${timeout}s — clear failed."
}

info "Waiting for remote bucket to report empty..."
wait_bucket_empty "$REMOTE_ALIAS/$BUCKET" "$POLL_TIMEOUT_512MIB"

# --- Replication status ---

info "Checking replication status..."
repl_status=$(mc replicate status "$LOCAL_ALIAS/$BUCKET" 2>&1) || true
echo "$repl_status" | head -5 | while read -r line; do info "  $line"; done

# --- Setup ---

setup_output
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info "Site:    $SITE"
info "Output:  $RESULTS_DIR"
info "Run ID:  $EPOCH"

# --- Replication benchmark ---

progress "Replication benchmark"

all_results=""
for si in 0 1 2; do
    size_label="${SIZES[$si]}"
    size_bytes="${SIZE_BYTES[$si]}"
    size_eo="${SIZE_EO[$si]}"
    size_mib=$((size_bytes / 1048576))
    size_timeout="${SIZE_TIMEOUTS[$si]}"

    info "$size_label ($size_eo) x $REPS reps (timeout ${size_timeout}s)"

    timings=""
    for rep in $(seq 1 "$REPS"); do
        obj_name="bench_${size_label}_rep${rep}_${EPOCH}"
        local_file="$TMPDIR/${obj_name}"

        # Generate random test object.
        dd if=/dev/urandom of="$local_file" bs=1048576 count="$size_mib" 2>/dev/null
        src_md5=$(compute_md5 "$local_file")

        # Upload to local MinIO.
        upload_start=$(timestamp_ns)
        if ! mc cp "$local_file" "$LOCAL_ALIAS/$BUCKET/$obj_name" > /dev/null 2>&1; then
            warn "  rep $rep: upload failed — skipping."
            rm -f "$local_file"
            continue
        fi
        upload_end=$(timestamp_ns)
        upload_ms=$(( (upload_end - upload_start) / 1000000 ))

        # Poll remote until the object appears or timeout.
        repl_start=$upload_end
        repl_ok=false
        elapsed_s=0
        while [ "$elapsed_s" -lt "$size_timeout" ]; do
            if mc stat "$REMOTE_ALIAS/$BUCKET/$obj_name" > /dev/null 2>&1; then
                repl_ok=true
                break
            fi
            sleep "$POLL_INTERVAL"
            now=$(timestamp_ns)
            elapsed_s=$(( (now - repl_start) / 1000000000 ))
        done
        repl_end=$(timestamp_ns)
        repl_ms=$(( (repl_end - repl_start) / 1000000 ))

        # Verify integrity.
        dst_file="$TMPDIR/${obj_name}_remote"
        integrity="unknown"
        if [ "$repl_ok" = true ]; then
            if mc cp "$REMOTE_ALIAS/$BUCKET/$obj_name" "$dst_file" > /dev/null 2>&1; then
                dst_md5=$(compute_md5 "$dst_file")
                if [ "$src_md5" = "$dst_md5" ]; then
                    integrity="verified"
                else
                    integrity="mismatch"
                    warn "  rep $rep: MD5 mismatch — src=$src_md5 dst=$dst_md5"
                fi
            else
                integrity="download_failed"
                warn "  rep $rep: could not download replicated object for verification."
            fi
            rm -f "$dst_file"
        else
            integrity="timeout"
            warn "  rep $rep: replication timed out after ${size_timeout}s."
        fi

        info "  rep $rep: upload=${upload_ms}ms repl=${repl_ms}ms integrity=$integrity"

        if [ -n "$timings" ]; then timings="${timings},"; fi
        timings="${timings}{\"rep\":$rep,\"upload_ms\":$upload_ms,\"replication_ms\":$repl_ms,\"replicated\":$repl_ok,\"integrity\":\"$integrity\",\"src_md5\":\"$src_md5\"}"

        # Clean up.
        mc rm "$LOCAL_ALIAS/$BUCKET/$obj_name" > /dev/null 2>&1 || true
        mc rm "$REMOTE_ALIAS/$BUCKET/$obj_name" > /dev/null 2>&1 || true
        rm -f "$local_file"
    done

    if [ -n "$all_results" ]; then all_results="${all_results},"; fi
    all_results="${all_results}{\"size\":\"$size_label\",\"size_bytes\":$size_bytes,\"eo_type\":\"$size_eo\",\"poll_timeout_s\":$size_timeout,\"reps\":[$timings]}"
done

info "Done."

# --- Write output ---

OUTFILE="$RESULTS_DIR/${EPOCH}_replication.json"

cat > "$OUTFILE" <<JSONEOF
{
    "test": "cross_site_replication",
    "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "epoch": $EPOCH,
    "local_alias": "$LOCAL_ALIAS",
    "remote_alias": "$REMOTE_ALIAS",
    "bucket": "$BUCKET",
    "repetitions": $REPS,
    "poll_interval_s": $POLL_INTERVAL,
    "objects": [$all_results]
}
JSONEOF

# --- Summary ---

progress "Complete"

info "Results: $OUTFILE"
echo ""
info "Next steps:"
info "  1. Review the JSON file."
info "  2. Commit and push:"
info "       git add results/"
info "       git commit -m 'results: replication from $SITE'"
info "       git push"
echo ""
