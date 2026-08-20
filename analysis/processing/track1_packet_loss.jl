# track1_packet_loss.jl
#
# Process Track 1 packet loss benchmark results (error delta JSONs).
# Reads pre-computed delta JSONs, summarises across reps.
#
# Reads .json files from benchmarks/outputs/network/packet_loss/,
# writes CSV tables to analysis/results/.
#
# Usage:
#   julia --project=analysis analysis/processing/track1_packet_loss.jl

using JSON3, DataFrames, CSV, Statistics

# --- Configuration ---

const REPO_ROOT = dirname(pwd())
const PACKET_LOSS_DIR = joinpath(REPO_ROOT, "benchmarks", "outputs", "network", "packet_loss")
const RESULTS_DIR = joinpath(pwd(), "results")
mkpath(RESULTS_DIR)

# --- Parsing ---

function discover_delta_files()
    isdir(PACKET_LOSS_DIR) || error("Directory not found: $PACKET_LOSS_DIR")
    files = filter(f -> contains(f, "_errors_delta_") && endswith(f, ".json"), readdir(PACKET_LOSS_DIR))
    files = filter(f -> !isnothing(match(r"^\d+_", f)), files)
    return [joinpath(PACKET_LOSS_DIR, f) for f in sort(files)]
end

function parse_delta(filepath::String)
    data = JSON3.read(read(filepath, String))
    return (
        host            = String(data.host),
        repetition      = Int(data.repetition),
        epoch           = Int(data.timestamp_epoch),
        rx_errors_delta = Int(data.rx_errors_delta),
        tx_errors_delta = Int(data.tx_errors_delta),
        rx_drops_delta  = Int(data.rx_drops_delta),
        tx_drops_delta  = Int(data.tx_drops_delta),
        rx_packets      = Int(data.rx_packets),
        tx_packets      = Int(data.tx_packets),
        loss_pct        = Float64(data.loss_pct),
    )
end

# --- Main ---

function main()
    println("Track 1 Packet Loss Analysis")
    println("=" ^ 60)
    println("Source: $PACKET_LOSS_DIR")
    println("Output: $RESULTS_DIR")
    println()

    files = discover_delta_files()
    println("Found $(length(files)) delta files")

    rows = [parse_delta(f) for f in files]
    df = DataFrame(rows)

    df.role = [startswith(h, "srv") ? "app" : "storage" for h in df.host]

    CSV.write(joinpath(RESULTS_DIR, "track1_packet_loss_raw.csv"), df)
    println("Wrote: track1_packet_loss_raw.csv")

    # Per-host summary across reps
    summary = combine(groupby(df, [:host, :role]),
        :rx_errors_delta => sum     => :total_rx_errors,
        :tx_errors_delta => sum     => :total_tx_errors,
        :rx_drops_delta  => sum     => :total_rx_drops,
        :tx_drops_delta  => sum     => :total_tx_drops,
        :rx_packets      => mean    => :mean_rx_packets,
        :tx_packets      => mean    => :mean_tx_packets,
        :loss_pct        => maximum => :max_loss_pct,
        nrow             => :n_reps,
    )
    sort!(summary, :host)

    println()
    println("Per-host summary:")
    show(stdout, summary; allrows=true, allcols=true, truncate=0)
    println()

    CSV.write(joinpath(RESULTS_DIR, "track1_packet_loss_summary.csv"), summary)
    println("Wrote: track1_packet_loss_summary.csv")

    # Overall verdict
    total_errors = sum(df.rx_errors_delta) + sum(df.tx_errors_delta)
    total_drops = sum(df.rx_drops_delta) + sum(df.tx_drops_delta)
    max_loss = maximum(df.loss_pct)
    total_packets = sum(df.rx_packets) + sum(df.tx_packets)

    println()
    println("Overall (across all hosts, all reps):")
    println("  Total packets:   $(total_packets)")
    println("  Total errors:    $(total_errors)")
    println("  Total drops:     $(total_drops)")
    println("  Max loss %%:      $(max_loss)")
    println("  Verdict:         $(total_errors == 0 && total_drops == 0 ? "PASS — zero errors" : "INVESTIGATE")")

    println("\nDone.")
end

main()
