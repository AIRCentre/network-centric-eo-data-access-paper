#!/usr/bin/env bash
# test_network.sh — Network baseline: ping, traceroute, bandwidth estimate.
#
# Ping and traceroute use ICMP and will not work through HTTP proxies.
# If unavailable or blocked, they are skipped or timeout quickly —
# the curl-based bandwidth probe still runs and provides the
# operationally relevant timing data.
#
# Usage: ./scripts/test_network.sh <results_dir> <epoch>
# Run standalone; also invoked by the remote-access harness.

source "$(dirname "$0")/common.sh"

RESULTS_DIR="${1:?Usage: test_network.sh <results_dir> <epoch>}"
EPOCH="${2:?Usage: test_network.sh <results_dir> <epoch>}"
OUTFILE="$RESULTS_DIR/${EPOCH}_network.json"

PING_COUNT="${PING_COUNT:-20}"
PING_TIMEOUT="${PING_TIMEOUT:-5}"
PING_TARGET="${PING_TARGET:-eo-catalog.ac-az1.aircentre.org}"

progress "Network baseline"

# --- Ping (ICMP — skipped if unavailable, bounded if blocked) ---

rtt_min="null"; rtt_avg="null"; rtt_max="null"; rtt_mdev="null"
packet_loss="null"

if command -v ping > /dev/null 2>&1; then
    info "Pinging $PING_TARGET ($PING_COUNT packets, ${PING_TIMEOUT}s timeout)..."

    # -W sets per-packet timeout in seconds (Linux). macOS uses -W in ms,
    # but we also wrap the whole command in a total timeout as a safety net.
    if command -v timeout > /dev/null 2>&1; then
        ping_output=$(timeout 60 ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" 2>&1) || true
    else
        # macOS doesn't have timeout by default; -t sets total deadline on some systems.
        ping_output=$(ping -c "$PING_COUNT" -W $(( PING_TIMEOUT * 1000 )) "$PING_TARGET" 2>&1) || true
    fi

    # Extract RTT stats — works on both Linux and macOS.
    rtt_line=$(echo "$ping_output" | grep -E '(rtt|round-trip)' || echo "")
    if [ -n "$rtt_line" ]; then
        rtt_values=$(echo "$rtt_line" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+')
        rtt_min=$(echo "$rtt_values" | cut -d'/' -f1)
        rtt_avg=$(echo "$rtt_values" | cut -d'/' -f2)
        rtt_max=$(echo "$rtt_values" | cut -d'/' -f3)
        rtt_mdev=$(echo "$rtt_values" | cut -d'/' -f4)
        info "RTT: min=${rtt_min}ms avg=${rtt_avg}ms max=${rtt_max}ms stddev=${rtt_mdev}ms"
    else
        warn "Ping returned no RTT data (ICMP may be blocked by firewall/proxy)."
    fi

    loss_line=$(echo "$ping_output" | grep -E 'packet loss' || echo "")
    packet_loss=$(echo "$loss_line" | grep -oE '[0-9]+(\.[0-9]+)?%' | head -1 || echo "null")
else
    warn "ping not found — skipping ICMP latency test."
fi

# --- Traceroute (ICMP/UDP — skipped if unavailable, bounded if blocked) ---

traceroute_output="not available"
traceroute_hops="null"

if command -v traceroute > /dev/null 2>&1; then
    info "Running traceroute (max 15 hops, 2s wait — may take up to 90s)..."
    # Limit hops and wait time to keep total runtime bounded.
    if command -v timeout > /dev/null 2>&1; then
        traceroute_output=$(timeout 90 traceroute -m 15 -w 2 "$PING_TARGET" 2>&1) || true
    else
        traceroute_output=$(traceroute -m 15 -w 2 "$PING_TARGET" 2>&1) || true
    fi
    traceroute_hops=$(echo "$traceroute_output" | grep -cE '^ ' || echo "0")
    info "Traceroute: $traceroute_hops hops"
elif command -v tracepath > /dev/null 2>&1; then
    info "Running tracepath..."
    if command -v timeout > /dev/null 2>&1; then
        traceroute_output=$(timeout 90 tracepath "$PING_TARGET" 2>&1) || true
    else
        traceroute_output=$(tracepath "$PING_TARGET" 2>&1) || true
    fi
    traceroute_hops=$(echo "$traceroute_output" | wc -l | tr -d ' ')
    info "Tracepath: $traceroute_hops lines"
else
    warn "Neither traceroute nor tracepath found — skipping."
fi

# --- Bandwidth probe (curl — works through proxies) ---
# Repeated HTTPS requests to the catalog root to measure round-trip time.
# This is the primary network measurement for proxy environments.

info "Measuring round-trip time to catalog endpoint (5 samples)..."
bw_url="${CATALOG_ENDPOINT:-https://eo-catalog.ac-az1.aircentre.org/api/v1}"

bw_results=""
for i in 1 2 3 4 5; do
    timing=$(curl -s -o /dev/null \
        -w "%{time_namelookup} %{time_connect} %{time_starttransfer} %{time_total} %{speed_download} %{size_download}" \
        --max-time 30 \
        -H "X-API-Key: ${CATALOG_API_KEY:-}" \
        "$bw_url" 2>/dev/null) || true
    t_dns=$(echo "$timing" | awk '{print $1}')
    t_conn=$(echo "$timing" | awk '{print $2}')
    t_ttfb=$(echo "$timing" | awk '{print $3}')
    t_total=$(echo "$timing" | awk '{print $4}')
    speed=$(echo "$timing" | awk '{print $5}')
    size=$(echo "$timing" | awk '{print $6}')
    if [ -n "$bw_results" ]; then bw_results="${bw_results},"; fi
    bw_results="${bw_results}{\"rep\":$i,\"dns_s\":${t_dns:-0},\"connect_s\":${t_conn:-0},\"ttfb_s\":${t_ttfb:-0},\"total_s\":${t_total:-0},\"speed_bytes_s\":${speed:-0},\"size_bytes\":${size:-0}}"
done

info "Done."

# --- Write output ---

traceroute_escaped=$(echo "$traceroute_output" | json_escape)

cat > "$OUTFILE" <<JSONEOF
{
    "test": "network_baseline",
    "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "epoch": $EPOCH,
    "target": "$PING_TARGET",
    "ping": {
        "count": $PING_COUNT,
        "timeout_s": $PING_TIMEOUT,
        "rtt_min_ms": $rtt_min,
        "rtt_avg_ms": $rtt_avg,
        "rtt_max_ms": $rtt_max,
        "rtt_stddev_ms": $rtt_mdev,
        "packet_loss": "$packet_loss"
    },
    "traceroute": {
        "hops": $traceroute_hops,
        "raw": $traceroute_escaped
    },
    "bandwidth_probe": {
        "url": "$bw_url",
        "samples": [$bw_results]
    }
}
JSONEOF

info "Results: $OUTFILE"
