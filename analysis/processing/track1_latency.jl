# track1_latency.jl
#
# Process Track 1 latency benchmark results (ping output files).
# Parses RTT values from ping text output under 3 conditions:
# idle, 50% load, 100% load — for all (app, storage) pairs × 3 reps.
#
# Reads .txt files from benchmarks/outputs/network/latency/,
# writes CSV tables to analysis/results/.
#
# Usage:
#   julia --project=analysis analysis/processing/track1_latency.jl

using DataFrames, CSV, Statistics

# --- Configuration ---

const REPO_ROOT = dirname(pwd())
const LATENCY_DIR = joinpath(REPO_ROOT, "benchmarks", "outputs", "network", "latency")
const RESULTS_DIR = joinpath(pwd(), "results")
mkpath(RESULTS_DIR)

const CONDITIONS = ["idle", "50pct", "100pct"]

# --- Parsing ---

"""
    parse_ping_file(filepath) -> Vector{Float64}

Extract individual RTT values (ms) from ping output.
"""
function parse_ping_file(filepath::String)
    rtts = Float64[]
    for line in eachline(filepath)
        m = match(r"time=(\d+\.?\d*)\s*ms", line)
        if m !== nothing
            push!(rtts, parse(Float64, m.captures[1]))
        end
    end
    return rtts
end

"""
    parse_ping_summary(filepath) -> NamedTuple or nothing

Extract the summary line: `rtt min/avg/max/mdev = A/B/C/D ms`
"""
function parse_ping_summary(filepath::String)
    for line in eachline(filepath)
        m = match(r"rtt min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)", line)
        if m !== nothing
            return (
                min_ms  = parse(Float64, m.captures[1]),
                avg_ms  = parse(Float64, m.captures[2]),
                max_ms  = parse(Float64, m.captures[3]),
                mdev_ms = parse(Float64, m.captures[4]),
            )
        end
    end
    return nothing
end

"""
    parse_packet_loss(filepath) -> Float64

Extract packet loss percentage from ping summary.
"""
function parse_packet_loss(filepath::String)
    for line in eachline(filepath)
        m = match(r"(\d+)% packet loss", line)
        if m !== nothing
            return parse(Float64, m.captures[1])
        end
    end
    return NaN
end

# --- File discovery ---

function discover_latency_files()
    isdir(LATENCY_DIR) || error("Directory not found: $LATENCY_DIR")
    files = filter(f -> endswith(f, ".txt") && !isnothing(match(r"^\d+_lat_", f)), readdir(LATENCY_DIR))
    return sort(files)
end

function parse_filename(f::String)
    m = match(r"^(\d+)_lat_(idle|50pct|100pct)_rep(\d+)_(\w+)_(\w+)\.txt$", f)
    m === nothing && return nothing
    return (
        epoch     = parse(Int, m.captures[1]),
        condition = String(m.captures[2]),
        rep       = parse(Int, m.captures[3]),
        client    = String(m.captures[4]),
        server    = String(m.captures[5]),
    )
end

# --- Main ---

function main()
    println("Track 1 Latency Analysis")
    println("=" ^ 60)
    println("Source: $LATENCY_DIR")
    println("Output: $RESULTS_DIR")
    println()

    files = discover_latency_files()
    println("Found $(length(files)) latency files")

    rows = NamedTuple[]

    for f in files
        meta = parse_filename(f)
        meta === nothing && continue

        filepath = joinpath(LATENCY_DIR, f)
        rtts = parse_ping_file(filepath)
        summary = parse_ping_summary(filepath)
        pkt_loss = parse_packet_loss(filepath)

        if isempty(rtts)
            println("  Warning: no RTTs in $f")
            continue
        end

        push!(rows, (
            client       = meta.client,
            server       = meta.server,
            condition    = meta.condition,
            repetition   = meta.rep,
            n_pings      = length(rtts),
            mean_ms      = mean(rtts),
            std_ms       = std(rtts),
            min_ms       = minimum(rtts),
            max_ms       = maximum(rtts),
            p50_ms       = quantile(rtts, 0.50),
            p95_ms       = quantile(rtts, 0.95),
            p99_ms       = quantile(rtts, 0.99),
            mdev_ms      = summary !== nothing ? summary.mdev_ms : NaN,
            packet_loss  = pkt_loss,
        ))
    end

    df = DataFrame(rows)
    println("Parsed $(nrow(df)) measurements")
    println()

    CSV.write(joinpath(RESULTS_DIR, "track1_latency_raw.csv"), df)
    println("Wrote: track1_latency_raw.csv")

    # Summary: mean across reps per (client, server, condition)
    gdf = groupby(df, [:client, :server, :condition])
    summary = combine(gdf,
        :mean_ms     => mean    => :mean_rtt_ms,
        :mean_ms     => std     => :std_rtt_ms,
        :max_ms      => maximum => :worst_max_ms,
        :p95_ms      => mean    => :mean_p95_ms,
        :p99_ms      => mean    => :mean_p99_ms,
        :packet_loss => maximum => :max_packet_loss,
        nrow         => :n_reps,
    )
    sort!(summary, [:client, :server, :condition])
    CSV.write(joinpath(RESULTS_DIR, "track1_latency_summary.csv"), summary)
    println("Wrote: track1_latency_summary.csv")

    # Condition-level summary (across all pairs)
    cond_summary = combine(groupby(df, :condition),
        :mean_ms     => mean    => :overall_mean_ms,
        :mean_ms     => std     => :overall_std_ms,
        :max_ms      => maximum => :worst_max_ms,
        :p95_ms      => mean    => :overall_p95_ms,
        :p99_ms      => mean    => :overall_p99_ms,
        :packet_loss => maximum => :max_packet_loss,
    )
    sort!(cond_summary, :condition)

    println()
    println("Condition-level summary:")
    show(stdout, cond_summary; allrows=true, allcols=true, truncate=0)
    println()

    CSV.write(joinpath(RESULTS_DIR, "track1_latency_by_condition.csv"), cond_summary)
    println("Wrote: track1_latency_by_condition.csv")

    println("\nDone.")
end

main()
