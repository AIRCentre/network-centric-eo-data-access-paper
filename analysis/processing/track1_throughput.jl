# track1_throughput.jl
#
# Process Track 1 throughput benchmark results from raw iperf3 JSON.
# Handles all 6 modes: per-pair, app-outbound, st-inbound, full-mesh, st-to-st, rds02-fanout.
#
# Extracts: aggregate throughput, per-second stability, per-stream balance,
# CPU utilisation, TCP parameters, retransmits.
#
# Emits:
#   - track1_throughput_raw.csv        : one row per (mode, rep, client, server)
#   - track1_<mode>_per_pair.csv       : per-pair summary per mode
#   - track1_<mode>_per_app.csv        : per-client aggregate per mode
#   - track1_<mode>_per_storage.csv    : per-server aggregate per mode
#   - track1_throughput_cross_mode.csv : per-pair full-mesh vs per-pair baseline
#   - track1_per_stream.csv            : long format, one row per parallel stream
#                                        (mode, rep, client, server, stream_idx, gbps)
#   - track1_aggregate_per_rep.csv     : one row per (mode, rep) with total across pairs
#
# CSV row order is deterministic across runs: the master table and the
# per-rep aggregate iterate MODES explicitly rather than over the Dict of
# loaded modes (Dict iteration order is not guaranteed in Julia).
#
# Usage:
#   cd analysis/
#   julia --project=. processing/track1_throughput.jl

using JSON3, DataFrames, CSV, Statistics

# --- Configuration ---

const REPO_ROOT = dirname(pwd())
const THROUGHPUT_DIR = joinpath(REPO_ROOT, "benchmarks", "outputs", "network", "throughput")
const RESULTS_DIR = joinpath(pwd(), "results")
mkpath(RESULTS_DIR)

const MODES = ["per-pair", "app-outbound", "st-inbound", "full-mesh", "st-to-st", "rds02-fanout"]

# --- Parsing ---

"""
    strip_ansible_header(raw) -> String

Strip Ansible preamble if present, returning clean JSON.
"""
function strip_ansible_header(raw::String)
    startswith(raw, "{") && return raw
    idx = findfirst("{\n\t\"start\"", raw)
    if isnothing(idx)
        idx = findfirst("{\r\n\t\"start\"", raw)
    end
    isnothing(idx) && error("No iperf3 JSON found")
    return raw[first(idx):end]
end

"""
    discover_results(mode) -> Vector{String}

Find all new-format iperf3 JSON files for a given mode.
Files start with epoch (1775...) and end with .json, exclude snapshots.
"""
function discover_results(mode::String)
    dir = joinpath(THROUGHPUT_DIR, mode)
    isdir(dir) || error("Directory not found: $dir")
    files = filter(readdir(dir)) do f
        endswith(f, ".json") &&
        !contains(f, "snapshot") &&
        !isnothing(match(r"^\d+_tp_", f))
    end
    return [joinpath(dir, f) for f in sort(files)]
end

"""
    parse_filename(filepath) -> NamedTuple

Extract metadata from filename.
Pattern: {epoch}_tp_{mode}_rep{n}_{client}_{server}.json
"""
function parse_filename(filepath::String)
    fname = basename(filepath)
    # Modes with snapshot suffix in filenames use different patterns
    m = match(r"^(\d+)_tp_[\w-]+_rep(\d+)_(\w+)_(\w+)\.json$", fname)
    isnothing(m) && error("Cannot parse: $fname")
    return (
        epoch  = parse(Int, m[1]),
        rep    = parse(Int, m[2]),
        client = String(m[3]),
        server = String(m[4]),
    )
end

"""
    parse_iperf3(filepath) -> NamedTuple

Parse a raw iperf3 JSON file, extracting all metrics. The returned
NamedTuple includes `stream_gbps::Vector{Float64}` holding the per-stream
sender throughputs. Callers should strip this field before building a
DataFrame that becomes a flat CSV, and expand it separately when a
long-format per-stream CSV is wanted.
"""
function parse_iperf3(filepath::String)
    raw = read(filepath, String)
    clean = strip_ansible_header(raw)
    data = JSON3.read(clean)

    meta = parse_filename(filepath)

    # Aggregate throughput
    sent = data["end"]["sum_sent"]
    recv = data["end"]["sum_received"]
    sent_gbps = Float64(sent["bits_per_second"]) / 1e9
    recv_gbps = Float64(recv["bits_per_second"]) / 1e9
    retransmits = Int(get(sent, "retransmits", 0))
    duration_s = Float64(sent["seconds"])

    # CPU utilisation
    cpu = data["end"]["cpu_utilization_percent"]
    host_cpu_total = Float64(cpu["host_total"])
    host_cpu_user = Float64(cpu["host_user"])
    host_cpu_system = Float64(cpu["host_system"])
    remote_cpu_total = Float64(cpu["remote_total"])

    # TCP congestion
    tcp_cc = String(get(data["end"], "sender_tcp_congestion", "unknown"))

    # Per-second intervals
    intervals = data["intervals"]
    n_intervals = length(intervals)
    interval_gbps = [Float64(iv["sum"]["bits_per_second"]) / 1e9 for iv in intervals]

    # Per-stream balance from intervals (first interval as sample)
    n_streams = length(intervals[1]["streams"])

    # Per-stream aggregate from end section
    end_streams = data["end"]["streams"]
    stream_gbps = [Float64(s["sender"]["bits_per_second"]) / 1e9 for s in end_streams]
    stream_cv = length(stream_gbps) > 1 ? std(stream_gbps) / mean(stream_gbps) * 100 : 0.0

    # Interval statistics
    mean_gbps = mean(interval_gbps)
    std_gbps = n_intervals > 1 ? std(interval_gbps) : 0.0
    cv_pct = mean_gbps > 0 ? std_gbps / mean_gbps * 100 : NaN
    min_gbps = minimum(interval_gbps)
    max_gbps = maximum(interval_gbps)
    p10_gbps = quantile(interval_gbps, 0.10)
    p90_gbps = quantile(interval_gbps, 0.90)

    return (;
        meta...,
        sent_gbps,
        recv_gbps,
        retransmits,
        duration_s,
        n_intervals,
        n_streams,
        mean_gbps,
        std_gbps,
        cv_pct,
        min_gbps,
        max_gbps,
        p10_gbps,
        p90_gbps,
        stream_cv_pct = stream_cv,
        host_cpu_total,
        host_cpu_user,
        host_cpu_system,
        remote_cpu_total,
        tcp_cc,
        stream_gbps,
    )
end

# --- Processing ---

"""
    load_mode(mode) -> (df, stream_df)

Returns a tuple:
  - df: the per-file summary DataFrame (with stream_gbps vector stripped out)
  - stream_df: long-format DataFrame, one row per (rep, client, server, stream_idx, gbps)
"""
function load_mode(mode::String)
    files = discover_results(mode)
    if isempty(files)
        println("  $(mode): no files found")
        return DataFrame(), DataFrame()
    end

    rows = NamedTuple[]
    stream_rows = NamedTuple[]
    for f in files
        try
            row = parse_iperf3(f)
            push!(rows, row)
            for (i, g) in enumerate(row.stream_gbps)
                push!(stream_rows, (
                    mode       = mode,
                    rep        = row.rep,
                    client     = row.client,
                    server     = row.server,
                    stream_idx = i,
                    gbps       = g,
                ))
            end
        catch e
            println("  WARNING: $(basename(f)): $e")
        end
    end

    isempty(rows) && return DataFrame(), DataFrame()

    # Build main DataFrame and drop stream_gbps (Vector column is not CSV-friendly).
    df = DataFrame(rows)
    select!(df, Not(:stream_gbps))
    df.mode .= mode

    stream_df = DataFrame(stream_rows)

    println("  $(mode): $(nrow(df)) files, $(length(unique(df.rep))) reps, " *
            "$(nrow(stream_df)) stream observations")
    return df, stream_df
end

# --- Summary tables ---

function per_pair_summary(df::DataFrame)
    gdf = groupby(df, [:client, :server])
    combine(gdf,
        :sent_gbps       => mean    => :mean_gbps,
        :sent_gbps       => std     => :std_gbps,
        :retransmits     => sum     => :total_retransmits,
        :cv_pct          => mean    => :mean_cv_pct,
        :host_cpu_total  => mean    => :mean_host_cpu,
        :remote_cpu_total => mean   => :mean_remote_cpu,
        :stream_cv_pct   => mean    => :mean_stream_cv_pct,
        nrow             => :n_reps,
    ) |> x -> sort(x, [:client, :server])
end

function per_app_summary(df::DataFrame)
    gdf = groupby(df, [:client, :rep])
    per_rep = combine(gdf,
        :sent_gbps       => sum     => :total_gbps,
        :retransmits     => sum     => :total_retransmits,
        :host_cpu_total  => mean    => :mean_host_cpu,
    )
    gdf2 = groupby(per_rep, :client)
    combine(gdf2,
        :total_gbps         => mean    => :mean_total_gbps,
        :total_gbps         => std     => :std_total_gbps,
        :total_retransmits  => mean    => :mean_retransmits,
        :mean_host_cpu      => mean    => :mean_host_cpu,
        nrow                => :n_reps,
    ) |> x -> sort(x, :client)
end

function per_storage_summary(df::DataFrame)
    gdf = groupby(df, [:server, :rep])
    per_rep = combine(gdf,
        :sent_gbps       => sum     => :total_gbps,
        :retransmits     => sum     => :total_retransmits,
        :remote_cpu_total => mean   => :mean_remote_cpu,
    )
    gdf2 = groupby(per_rep, :server)
    combine(gdf2,
        :total_gbps         => mean    => :mean_total_gbps,
        :total_gbps         => std     => :std_total_gbps,
        :total_retransmits  => mean    => :mean_retransmits,
        :mean_remote_cpu    => mean    => :mean_remote_cpu,
        nrow                => :n_reps,
    ) |> x -> sort(x, :server)
end

# --- Cross-mode analysis ---

function cross_mode_degradation(per_pair_df::DataFrame, full_mesh_df::DataFrame)
    pp = per_pair_summary(per_pair_df)
    fm = per_pair_summary(full_mesh_df)

    cross = innerjoin(pp, fm, on=[:client, :server], makeunique=true)
    rename!(cross,
        :mean_gbps   => :perpair_gbps,
        :mean_gbps_1 => :fullmesh_gbps,
    )
    cross.degradation_pct = (1.0 .- cross.fullmesh_gbps ./ cross.perpair_gbps) .* 100
    select(cross, :client, :server, :perpair_gbps, :fullmesh_gbps, :degradation_pct,
           :total_retransmits => :pp_retransmits,
           :total_retransmits_1 => :fm_retransmits)
end

# --- Main ---

function main()
    println("Track 1 Throughput Analysis (Raw iperf3)")
    println("=" ^ 60)
    println("Source: $THROUGHPUT_DIR")
    println("Output: $RESULTS_DIR")
    println()

    # Load all modes
    println("Loading data:")
    all_dfs = Dict{String, DataFrame}()
    all_stream_dfs = DataFrame[]
    for mode in MODES
        df, stream_df = load_mode(mode)
        if !isempty(df)
            all_dfs[mode] = df
        end
        if !isempty(stream_df)
            push!(all_stream_dfs, stream_df)
        end
    end

    if isempty(all_dfs)
        println("No data found.")
        return
    end

    # Master table: iterate MODES (Dict iteration order is not deterministic,
    # which previously caused spurious row-order diffs in track1_throughput_raw.csv).
    ordered_dfs = [all_dfs[m] for m in MODES if haskey(all_dfs, m)]
    master = vcat(ordered_dfs...; cols=:union)
    CSV.write(joinpath(RESULTS_DIR, "track1_throughput_raw.csv"), master)
    println("\nMaster table: $(nrow(master)) rows across $(length(all_dfs)) modes")

    # Per-stream long-format CSV: used by paper_values.jl for section 5.4 prose
    # claims about per-stream Gbps distribution (e.g., "some streams carry 5-6 Gbps
    # while others receive less than 1 Gbps").
    if !isempty(all_stream_dfs)
        stream_master = vcat(all_stream_dfs...)
        CSV.write(joinpath(RESULTS_DIR, "track1_per_stream.csv"), stream_master)
        println("Per-stream table: $(nrow(stream_master)) rows " *
                "($(length(unique(stream_master.mode))) modes)")
    end

    # Aggregate per (mode, rep): used by paper_values.jl for Table 2 std values.
    # std across the 3 reps of each mode's total (sum of sent_gbps across pairs).
    # Iterate MODES explicitly for deterministic row order.
    per_rep_rows = DataFrame[]
    for mode in MODES
        haskey(all_dfs, mode) || continue
        df = all_dfs[mode]
        agg = combine(groupby(df, :rep),
            :sent_gbps   => sum => :total_gbps,
            :retransmits => sum => :total_retransmits,
            nrow         => :n_pairs,
        )
        agg.mode .= mode
        push!(per_rep_rows, agg)
    end
    agg_master = vcat(per_rep_rows...)
    select!(agg_master, :mode, :rep, :total_gbps, :total_retransmits, :n_pairs)
    sort!(agg_master, [:mode, :rep])
    CSV.write(joinpath(RESULTS_DIR, "track1_aggregate_per_rep.csv"), agg_master)
    println("Aggregate-per-rep table: $(nrow(agg_master)) rows")

    # Per-mode summaries: iterate MODES for deterministic stdout order.
    for mode in MODES
        haskey(all_dfs, mode) || continue
        df = all_dfs[mode]
        println("\n" * "=" ^ 60)
        println("Mode: $mode")
        println("=" ^ 60)

        # Per-pair summary
        pp = per_pair_summary(df)
        fname = "track1_$(replace(mode, "-" => "_"))_per_pair.csv"
        CSV.write(joinpath(RESULTS_DIR, fname), pp)
        println("  Per-pair: $(nrow(pp)) pairs, mean $(round(mean(pp.mean_gbps), digits=1)) Gbps")

        # Per-app summary
        pa = per_app_summary(df)
        fname = "track1_$(replace(mode, "-" => "_"))_per_app.csv"
        CSV.write(joinpath(RESULTS_DIR, fname), pa)
        println("  Per-app: $(nrow(pa)) apps")
        for row in eachrow(pa)
            println("    $(row.client): $(round(row.mean_total_gbps, digits=1)) ± $(round(row.std_total_gbps, digits=1)) Gbps, " *
                    "retransmits=$(round(row.mean_retransmits, digits=0)), CPU=$(round(row.mean_host_cpu, digits=1))%")
        end

        # Per-storage summary
        ps = per_storage_summary(df)
        fname = "track1_$(replace(mode, "-" => "_"))_per_storage.csv"
        CSV.write(joinpath(RESULTS_DIR, fname), ps)
        println("  Per-storage: $(nrow(ps)) nodes")

        # Aggregate
        agg = combine(groupby(df, :rep), :sent_gbps => sum => :total_gbps, :retransmits => sum => :total_retransmits)
        println("  Aggregate: $(round(mean(agg.total_gbps), digits=1)) ± $(round(std(agg.total_gbps), digits=1)) Gbps, " *
                "retransmits=$(round(mean(agg.total_retransmits), digits=0))")
    end

    # Cross-mode degradation
    if haskey(all_dfs, "per-pair") && haskey(all_dfs, "full-mesh")
        println("\n" * "=" ^ 60)
        println("Cross-mode: full-mesh degradation vs per-pair baseline")
        println("=" ^ 60)
        cross = cross_mode_degradation(all_dfs["per-pair"], all_dfs["full-mesh"])
        CSV.write(joinpath(RESULTS_DIR, "track1_throughput_cross_mode.csv"), cross)
        show(stdout, cross; allrows=true, allcols=true, truncate=0)
        println()
        println("  Mean degradation: $(round(mean(cross.degradation_pct), digits=1))%")
        println("  Range: $(round(minimum(cross.degradation_pct), digits=1))–$(round(maximum(cross.degradation_pct), digits=1))%")
    end

    # CPU summary across modes
    println("\n" * "=" ^ 60)
    println("CPU utilisation by mode (host = sender, remote = receiver)")
    println("=" ^ 60)
    for mode in MODES
        haskey(all_dfs, mode) || continue
        df = all_dfs[mode]
        h_mean = round(mean(df.host_cpu_total), digits=1)
        h_std = round(std(df.host_cpu_total), digits=1)
        r_mean = round(mean(df.remote_cpu_total), digits=1)
        println("  $(rpad(mode, 15)) host: $(h_mean) ± $(h_std)%   remote: $(r_mean)%")
    end

    # Throughput stability summary
    println("\n" * "=" ^ 60)
    println("Throughput stability (per-second CV%)")
    println("=" ^ 60)
    for mode in MODES
        haskey(all_dfs, mode) || continue
        df = all_dfs[mode]
        cv_mean = round(mean(df.cv_pct), digits=2)
        cv_max = round(maximum(df.cv_pct), digits=2)
        println("  $(rpad(mode, 15)) mean CV: $(cv_mean)%   worst: $(cv_max)%")
    end

    # Stream balance summary
    println("\n" * "=" ^ 60)
    println("Stream balance (CV% across 8 parallel streams)")
    println("=" ^ 60)
    for mode in MODES
        haskey(all_dfs, mode) || continue
        df = all_dfs[mode]
        scv_mean = round(mean(df.stream_cv_pct), digits=2)
        scv_max = round(maximum(df.stream_cv_pct), digits=2)
        println("  $(rpad(mode, 15)) mean stream CV: $(scv_mean)%   worst: $(scv_max)%")
    end

    println("\nDone. CSVs written to: $RESULTS_DIR")
end

main()
