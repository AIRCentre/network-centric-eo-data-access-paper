# track2_throughput.jl
#
# Process Track 2 MinIO warp benchmark results across all sub-experiments:
# single-client, distributed, mixed, throttled (1 Gbps, 10 Gbps).
#
# Reads warp JSON files from benchmarks/outputs/minio/,
# computes summary statistics, writes CSV tables to analysis/results/.
#
# Optionally applies per-rep exclusions declared in analysis/excluded_reps.json
# before computing summary statistics. See load_exclusions() and
# apply_exclusions!() for the contract.
#
# Usage:
#   cd analysis/
#   julia --project=. processing/track2_throughput.jl

using JSON3, DataFrames, CSV, Statistics

# --- Configuration ---

const REPO_ROOT = dirname(pwd())
const MINIO_DIR = joinpath(REPO_ROOT, "benchmarks", "outputs", "minio")
const RESULTS_DIR = joinpath(pwd(), "results")
const EXCLUSIONS_PATH = joinpath(pwd(), "excluded_reps.json")
mkpath(RESULTS_DIR)

# Sub-experiment directories and their metadata
const SUBEXPERIMENTS = [
    # (directory, experiment, operation, rate)
    ("warp_put_single",       "single",      "PUT", "100gbps"),
    ("warp_get_single",       "single",      "GET", "100gbps"),
    ("warp_put_distributed",  "distributed", "PUT", "100gbps"),
    ("warp_get_distributed",  "distributed", "GET", "100gbps"),
    ("warp_mixed",            "mixed",       "MIXED", "100gbps"),
    ("warp_put_1gbps",        "throttled",   "PUT", "1gbps"),
    ("warp_get_1gbps",        "throttled",   "GET", "1gbps"),
    ("warp_put_10gbps",       "throttled",   "PUT", "10gbps"),
    ("warp_get_10gbps",       "throttled",   "GET", "10gbps"),
]

# --- File discovery ---

"""
    discover_warp_jsons(subdir) -> Vector{String}

Find all warp JSON result files in a sub-experiment directory.
Excludes snapshot CSVs and archive directories.
"""
function discover_warp_jsons(subdir::String)
    dir = joinpath(MINIO_DIR, subdir)
    isdir(dir) || return String[]
    files = filter(readdir(dir)) do f
        endswith(f, ".json") && !contains(f, "snapshot")
    end
    return [joinpath(dir, f) for f in sort(files)]
end

# --- Filename parsing ---

"""
    parse_filename(filepath) -> NamedTuple

Extract metadata from warp output filename.
Pattern: {epoch}_{op}_{qualifier}-{size}_rep{n}_{host}.json
"""
function parse_filename(filepath::String)
    fname = basename(filepath)
    # Match patterns like:
    #   1774487016_put_single-4MiB_rep1_srv01.json
    #   1774895313_put_distributed-4MiB_rep1_srv01.json
    #   1774914923_mixed-512MiB_rep1_srv01.json
    #   1774970423_put_1gbps-4MiB_rep1_srv01.json
    m = match(r"^(\d+)_(\w+)-(\w+)_rep(\d+)_(\w+)\.json$", fname)
    if isnothing(m)
        # Try mixed format: {epoch}_mixed-{size}_rep{n}_{host}.json
        m = match(r"^(\d+)_(\w+)-(\w+)_rep(\d+)_(\w+)\.json$", fname)
    end
    isnothing(m) && error("Cannot parse filename: $fname")
    epoch = parse(Int, m[1])
    qualifier = m[2]  # e.g. "put_single", "put_distributed", "mixed", "put_1gbps"
    size_str = m[3]   # e.g. "4MiB", "512MiB", "2GiB"
    rep = parse(Int, m[4])
    host = String(m[5])
    return (; epoch, qualifier, size_str, rep, host)
end

"""
    parse_size_bytes(size_str) -> Int

Convert size string to bytes for sorting.
"""
function parse_size_bytes(s::AbstractString)
    m = match(r"^(\d+)(MiB|GiB)$", s)
    isnothing(m) && error("Cannot parse size: $s")
    val = parse(Int, m[1])
    unit = m[2]
    return unit == "GiB" ? val * 1024 * 1024 * 1024 : val * 1024 * 1024
end

# --- JSON parsing ---

"""
    extract_throughput(data, section="total") -> NamedTuple

Extract throughput metrics from a warp JSON section.
"""
function extract_throughput(section)
    tp = section["throughput"]
    dur_ms = tp["measure_duration_millis"]
    dur_s = dur_ms / 1000.0
    bytes_total = Float64(tp["bytes"])
    ops = Int(tp["ops"])
    mibs = bytes_total / dur_s / (1024.0 * 1024.0)
    gbps = bytes_total * 8.0 / dur_s / 1e9

    # Per-second segment stats
    segments = tp["segmented"]["segments"]
    seg_bps = [Float64(s["bytes_per_sec"]) for s in segments]
    seg_mibs = seg_bps ./ (1024.0 * 1024.0)

    return (;
        throughput_mibs = mibs,
        throughput_gbps = gbps,
        ops_per_sec = ops / dur_s,
        duration_s = dur_s,
        total_bytes = bytes_total,
        total_ops = ops,
        n_segments = length(segments),
        seg_median_mibs = length(seg_mibs) > 0 ? median(seg_mibs) : NaN,
        seg_p10_mibs = length(seg_mibs) > 0 ? quantile(seg_mibs, 0.10) : NaN,
        seg_p90_mibs = length(seg_mibs) > 0 ? quantile(seg_mibs, 0.90) : NaN,
        seg_min_mibs = length(seg_mibs) > 0 ? minimum(seg_mibs) : NaN,
        seg_max_mibs = length(seg_mibs) > 0 ? maximum(seg_mibs) : NaN,
        seg_std_mibs = length(seg_mibs) > 1 ? std(seg_mibs) : NaN,
    )
end

"""
    extract_per_host(section) -> DataFrame

Extract per-host throughput breakdown.
"""
function extract_per_host(section)
    tbh = section["throughput_by_host"]
    rows = NamedTuple[]
    for (host_url, htp) in tbh
        dur_s = htp["measure_duration_millis"] / 1000.0
        bytes_total = Float64(htp["bytes"])
        mibs = bytes_total / dur_s / (1024.0 * 1024.0)
        # Extract short hostname from URL (e.g. "http://192.168.11.21:9000" -> "st01")
        ip = match(r"//(\d+\.\d+\.\d+\.\d+):", String(host_url))
        short = isnothing(ip) ? String(host_url) : ip_to_hostname(ip[1])
        push!(rows, (; host=short, throughput_mibs=mibs))
    end
    return DataFrame(rows)
end

"""
    ip_to_hostname(ip) -> String

Map IP to short hostname.
"""
function ip_to_hostname(ip::AbstractString)
    mapping = Dict(
        "192.168.11.20" => "vip",
        "192.168.11.21" => "st01", "192.168.11.22" => "st02",
        "192.168.11.23" => "st03", "192.168.11.24" => "st04",
        "192.168.11.25" => "st05", "192.168.11.26" => "st06",
        "192.168.11.27" => "st07", "192.168.11.28" => "st08",
        "192.168.11.31" => "srv01", "192.168.11.32" => "srv02",
        "192.168.11.33" => "srv03",
    )
    return get(mapping, String(ip), String(ip))
end

"""
    extract_ttfb(data) -> NamedTuple or nothing

Extract TTFB from GET operations. Returns nothing for PUT/mixed.
"""
function extract_ttfb(data)
    haskey(data, "by_op_type") || return nothing
    bot = data["by_op_type"]
    haskey(bot, "GET") || return nothing
    get_section = bot["GET"]
    rbc = get_section["requests_by_client"]

    # Collect TTFB across all clients and all time windows
    ttfb_avg = Float64[]
    ttfb_median = Float64[]
    ttfb_p99 = Float64[]
    for (client, windows) in rbc
        for w in windows
            ssr = w["single_sized_requests"]
            fb = get(ssr, "first_byte", nothing)
            isnothing(fb) && continue
            push!(ttfb_avg, Float64(fb["average_millis"]))
            push!(ttfb_median, Float64(fb["median_millis"]))
            push!(ttfb_p99, Float64(fb["p99_millis"]))
        end
    end

    isempty(ttfb_avg) && return nothing
    return (;
        ttfb_avg_ms = mean(ttfb_avg),
        ttfb_median_ms = mean(ttfb_median),
        ttfb_p99_ms = mean(ttfb_p99),
        ttfb_n_windows = length(ttfb_avg),
    )
end

"""
    extract_mixed_ops(data) -> DataFrame

For mixed workloads, extract per-operation-type throughput.
"""
function extract_mixed_ops(data)
    haskey(data, "by_op_type") || return DataFrame()
    bot = data["by_op_type"]
    rows = NamedTuple[]
    for (op, odata) in bot
        tp = extract_throughput(odata)
        push!(rows, (;
            op_type = String(op),
            requests = Int(odata["total_requests"]),
            errors = Int(odata["total_errors"]),
            throughput_mibs = tp.throughput_mibs,
            ops_per_sec = tp.ops_per_sec,
        ))
    end
    return DataFrame(rows)
end

# --- Processing ---

"""
    process_file(filepath) -> NamedTuple

Process a single warp JSON file and return all extracted metrics.
"""
function process_file(filepath::String)
    meta = parse_filename(filepath)
    raw = read(filepath, String)
    data = JSON3.read(raw)

    total = data["total"]
    tp = extract_throughput(total)
    ttfb = extract_ttfb(data)
    hosts = [String(h) for h in total["hosts"]]
    clients = [String(c) for c in total["clients"]]

    return (;
        filepath,
        meta...,
        n_hosts = length(hosts),
        n_clients = length(clients),
        concurrency = Int(total["concurrency"]),
        total_requests = Int(total["total_requests"]),
        total_errors = Int(total["total_errors"]),
        tp...,
        ttfb_avg_ms = isnothing(ttfb) ? missing : ttfb.ttfb_avg_ms,
        ttfb_median_ms = isnothing(ttfb) ? missing : ttfb.ttfb_median_ms,
        ttfb_p99_ms = isnothing(ttfb) ? missing : ttfb.ttfb_p99_ms,
    )
end

"""
    process_subexperiment(subdir, experiment, operation, rate) -> DataFrame

Process all files in a sub-experiment directory.
"""
function process_subexperiment(subdir::String, experiment::String, operation::String, rate::String)
    files = discover_warp_jsons(subdir)
    if isempty(files)
        println("  $(subdir): SKIPPED (no JSON files)")
        return DataFrame()
    end

    rows = NamedTuple[]
    for f in files
        try
            row = process_file(f)
            push!(rows, row)
        catch e
            println("  WARNING: failed to process $(basename(f)): $e")
        end
    end

    isempty(rows) && return DataFrame()
    df = DataFrame(rows)
    df.experiment .= experiment
    df.operation .= operation
    df.rate .= rate
    df.size_bytes = parse_size_bytes.(df.size_str)

    println("  $(subdir): $(nrow(df)) files, sizes=$(join(unique(df.size_str), ", ")), reps=$(length(unique(df.rep)))")
    return df
end

# --- Per-rep exclusions ---

"""
    load_exclusions(path) -> Vector{NamedTuple}

Load per-rep exclusions from excluded_reps.json if it exists.
Returns an empty vector if the file is absent (backward compatible).
Each exclusion entry is a NamedTuple with fields:
  experiment, operation, rate, size_str, rep, reason, raw_json, excluded_by, excluded_date.
"""
function load_exclusions(path::String)
    isfile(path) || return NamedTuple[]
    cfg = JSON3.read(read(path, String))
    haskey(cfg, :exclusions) || return NamedTuple[]
    rows = NamedTuple[]
    for e in cfg.exclusions
        push!(rows, (;
            experiment    = String(e.experiment),
            operation     = String(e.operation),
            rate          = String(e.rate),
            size_str      = String(e.size_str),
            rep           = Int(e.rep),
            reason        = String(get(e, :reason, "")),
            raw_json      = String(get(e, :raw_json, "")),
            excluded_by   = String(get(e, :excluded_by, "")),
            excluded_date = String(get(e, :excluded_date, "")),
        ))
    end
    return rows
end

"""
    apply_exclusions!(master, exclusions) -> DataFrame

Mark rows in the master table matching each exclusion by adding/updating
an `excluded` Bool column. Errors if any exclusion matches zero rows
(silent mismatch is a bug — a typo in the config would otherwise cause
the summary to revert to an unfiltered computation undetected).

The column is added via `master[!, :excluded]` rather than `master.excluded`,
which is the canonical DataFrames idiom for column insertion that survives
subsequent CSV.write calls.

Returns the master table with the added column.
"""
function apply_exclusions!(master::DataFrame, exclusions::Vector{<:NamedTuple})
    master[!, :excluded] = falses(nrow(master))
    isempty(exclusions) && return master

    println()
    println("=" ^ 60)
    println("Applying $(length(exclusions)) per-rep exclusion(s) from excluded_reps.json")
    println("=" ^ 60)

    for (i, e) in enumerate(exclusions)
        mask = (master.experiment .== e.experiment) .&
               (master.operation  .== e.operation) .&
               (master.rate       .== e.rate)      .&
               (master.size_str   .== e.size_str)  .&
               (master.rep        .== e.rep)
        n_matched = sum(mask)
        if n_matched == 0
            error("Exclusion #$(i) matched zero rows: " *
                  "$(e.experiment)/$(e.operation)/$(e.rate)/$(e.size_str)/rep=$(e.rep). " *
                  "Check excluded_reps.json — a silent no-op is not permitted. " *
                  "Either the match keys are wrong, or the raw data for this run is " *
                  "no longer present and the exclusion entry should be removed.")
        end
        master[mask, :excluded] .= true
        println("  #$(i) $(e.experiment)/$(e.operation)/$(e.rate)/$(e.size_str)/rep=$(e.rep): " *
                "matched $(n_matched) row(s)")
        println("     reason: $(e.reason)")
    end
    println()
    return master
end

# --- Summary tables ---

"""
    summary_by_size(df) -> DataFrame

Compute mean ± std across reps for each (experiment, operation, rate, size).
If `df` has an `excluded` column, rows with `excluded == true` are omitted
from the statistics but counted separately (`n_reps_original` vs `n_reps_effective`).
"""
function summary_by_size(df::DataFrame)
    has_excl = hasproperty(df, :excluded)
    filtered = has_excl ? filter(:excluded => !, df) : df

    gdf = groupby(filtered, [:experiment, :operation, :rate, :size_str, :size_bytes])
    summary = combine(gdf,
        :throughput_mibs  => mean    => :mean_mibs,
        :throughput_mibs  => std     => :std_mibs,
        :throughput_gbps  => mean    => :mean_gbps,
        :ops_per_sec      => mean    => :mean_ops,
        :total_errors     => sum     => :total_errors,
        :total_requests   => mean    => :mean_requests,
        :seg_median_mibs  => mean    => :mean_seg_median_mibs,
        :seg_p10_mibs     => mean    => :mean_seg_p10_mibs,
        :seg_p90_mibs     => mean    => :mean_seg_p90_mibs,
        :seg_std_mibs     => mean    => :mean_seg_std_mibs,
        :ttfb_avg_ms      => (x -> all(ismissing, x) ? missing : mean(skipmissing(x))) => :mean_ttfb_ms,
        :concurrency      => first   => :concurrency,
        :n_hosts          => first   => :n_hosts,
        :n_clients        => first   => :n_clients,
        nrow              => :n_reps_effective,
    )

    # n_reps_original: count in unfiltered df for the same group
    if has_excl
        orig_gdf = groupby(df, [:experiment, :operation, :rate, :size_str, :size_bytes])
        orig_counts = combine(orig_gdf, nrow => :n_reps_original)
        summary = leftjoin(summary, orig_counts,
            on=[:experiment, :operation, :rate, :size_str, :size_bytes])
        summary.excluded_reps = summary.n_reps_original .- summary.n_reps_effective
    else
        summary.n_reps_original = summary.n_reps_effective
        summary.excluded_reps = zeros(Int, nrow(summary))
    end

    sort!(summary, [:experiment, :operation, :rate, :size_bytes])
    return summary
end

# --- Per-host analysis ---

"""
    per_host_analysis(subdir) -> DataFrame

Extract per-host throughput for all files in a sub-experiment.
Exclusions are intentionally NOT applied to per-host breakdowns: they are
aggregated across all reps and reflect within-rep per-node distribution,
which is not affected by the run-level contamination that motivates the
aggregate-level exclusions.
"""
function per_host_analysis(subdir::String)
    files = discover_warp_jsons(subdir)
    isempty(files) && return DataFrame()

    all_rows = NamedTuple[]
    for f in files
        meta = parse_filename(f)
        data = JSON3.read(read(f, String))
        total = data["total"]
        host_df = extract_per_host(total)
        for row in eachrow(host_df)
            push!(all_rows, (;
                size_str = meta.size_str,
                rep = meta.rep,
                host = row.host,
                throughput_mibs = row.throughput_mibs,
            ))
        end
    end

    isempty(all_rows) && return DataFrame()
    df = DataFrame(all_rows)

    # Summarise per host per size
    gdf = groupby(df, [:size_str, :host])
    summary = combine(gdf,
        :throughput_mibs => mean => :mean_mibs,
        :throughput_mibs => std  => :std_mibs,
        nrow => :n_reps,
    )
    sort!(summary, [:size_str, :host])
    return summary
end

# --- Mixed workload analysis ---

"""
    mixed_analysis(subdir) -> DataFrame

Extract per-operation throughput for mixed workload files.
"""
function mixed_analysis(subdir::String)
    files = discover_warp_jsons(subdir)
    isempty(files) && return DataFrame()

    all_rows = NamedTuple[]
    for f in files
        meta = parse_filename(f)
        data = JSON3.read(read(f, String))
        ops_df = extract_mixed_ops(data)
        for row in eachrow(ops_df)
            push!(all_rows, (;
                size_str = meta.size_str,
                rep = meta.rep,
                op_type = row.op_type,
                requests = row.requests,
                errors = row.errors,
                throughput_mibs = row.throughput_mibs,
                ops_per_sec = row.ops_per_sec,
            ))
        end
    end

    isempty(all_rows) && return DataFrame()
    df = DataFrame(all_rows)

    gdf = groupby(df, [:size_str, :op_type])
    summary = combine(gdf,
        :throughput_mibs => mean => :mean_mibs,
        :throughput_mibs => std  => :std_mibs,
        :ops_per_sec    => mean => :mean_ops,
        :requests       => mean => :mean_requests,
        nrow => :n_reps,
    )
    sort!(summary, [:size_str, :op_type])
    return summary
end

# --- Per-second time series extraction ---

"""
    extract_timeseries(subdir) -> DataFrame

Extract per-second throughput segments for time-series analysis.
One row per (file, second).
"""
function extract_timeseries(subdir::String)
    files = discover_warp_jsons(subdir)
    isempty(files) && return DataFrame()

    all_rows = NamedTuple[]
    for f in files
        meta = parse_filename(f)
        data = JSON3.read(read(f, String))
        segments = data["total"]["throughput"]["segmented"]["segments"]
        for (i, seg) in enumerate(segments)
            push!(all_rows, (;
                size_str = meta.size_str,
                rep = meta.rep,
                second = i,
                bytes_per_sec = Float64(seg["bytes_per_sec"]),
                mibs = Float64(seg["bytes_per_sec"]) / (1024.0 * 1024.0),
                obj_per_sec = Float64(seg["obj_per_sec"]),
            ))
        end
    end

    isempty(all_rows) && return DataFrame()
    return DataFrame(all_rows)
end

# --- Main ---

function main()
    println("Track 2 MinIO Benchmark Analysis")
    println("=" ^ 60)
    println("Source: $MINIO_DIR")
    println("Output: $RESULTS_DIR")
    println("Exclusions config: $EXCLUSIONS_PATH ($(isfile(EXCLUSIONS_PATH) ? "present" : "absent"))")
    println()

    # Process all sub-experiments
    println("Loading data:")
    all_dfs = DataFrame[]
    for (subdir, experiment, operation, rate) in SUBEXPERIMENTS
        df = process_subexperiment(subdir, experiment, operation, rate)
        isempty(df) || push!(all_dfs, df)
    end

    if isempty(all_dfs)
        println("No data found.")
        return
    end

    # Combine into master table
    master = vcat(all_dfs...; cols=:union)

    # Apply per-rep exclusions if declared
    exclusions = load_exclusions(EXCLUSIONS_PATH)
    apply_exclusions!(master, exclusions)

    CSV.write(joinpath(RESULTS_DIR, "track2_all_results.csv"),
        select(master, Not([:filepath])))
    println("\nMaster table: $(nrow(master)) rows ($(sum(master.excluded)) excluded)")

    # Summary by size (filter applied inside summary_by_size)
    println()
    println("=" ^ 60)
    println("Summary by (experiment, operation, rate, size)")
    println("=" ^ 60)
    summary = summary_by_size(master)
    show(stdout, summary; allrows=true, allcols=true, truncate=0)
    println()
    CSV.write(joinpath(RESULTS_DIR, "track2_summary.csv"), summary)

    # Per-host analysis for distributed
    println()
    println("=" ^ 60)
    println("Per-host throughput: distributed PUT")
    println("=" ^ 60)
    ph_put = per_host_analysis("warp_put_distributed")
    if !isempty(ph_put)
        show(stdout, ph_put; allrows=true, allcols=true, truncate=0)
        println()
        CSV.write(joinpath(RESULTS_DIR, "track2_distributed_put_per_host.csv"), ph_put)
    end

    println()
    println("Per-host throughput: distributed GET")
    ph_get = per_host_analysis("warp_get_distributed")
    if !isempty(ph_get)
        show(stdout, ph_get; allrows=true, allcols=true, truncate=0)
        println()
        CSV.write(joinpath(RESULTS_DIR, "track2_distributed_get_per_host.csv"), ph_get)
    end

    # Mixed workload analysis
    println()
    println("=" ^ 60)
    println("Mixed workload: per-operation breakdown")
    println("=" ^ 60)
    mixed = mixed_analysis("warp_mixed")
    if !isempty(mixed)
        show(stdout, mixed; allrows=true, allcols=true, truncate=0)
        println()
        CSV.write(joinpath(RESULTS_DIR, "track2_mixed_per_op.csv"), mixed)
    end

    # Scaling analysis: single vs distributed
    println()
    println("=" ^ 60)
    println("Scaling: single-client vs distributed")
    println("=" ^ 60)
    single = filter(r -> r.experiment == "single", summary)
    dist = filter(r -> r.experiment == "distributed", summary)
    if !isempty(single) && !isempty(dist)
        for op in ["PUT", "GET"]
            s = filter(r -> r.operation == op, single)
            d = filter(r -> r.operation == op, dist)
            for size in intersect(s.size_str, d.size_str)
                s_row = first(filter(r -> r.size_str == size, s))
                d_row = first(filter(r -> r.size_str == size, d))
                factor = d_row.mean_mibs / s_row.mean_mibs
                println("  $(op) $(size): single=$(round(s_row.mean_mibs, digits=1)) MiB/s, " *
                        "distributed=$(round(d_row.mean_mibs, digits=1)) MiB/s, " *
                        "scaling=$(round(factor, digits=2))x")
            end
        end
    end

    # Bandwidth impact: 100G vs 10G vs 1G
    println()
    println("=" ^ 60)
    println("Bandwidth impact: unthrottled vs throttled")
    println("=" ^ 60)
    for op in ["PUT", "GET"]
        for size in ["4MiB", "512MiB"]
            rates_data = []
            for rate in ["100gbps", "10gbps", "1gbps"]
                rows = filter(r -> r.operation == op && r.size_str == size && r.rate == rate, summary)
                # For 100gbps, use distributed experiment; for throttled, use throttled
                if rate == "100gbps"
                    rows = filter(r -> r.experiment == "distributed", rows)
                end
                if !isempty(rows)
                    push!(rates_data, (rate=rate, mibs=first(rows).mean_mibs))
                end
            end
            if length(rates_data) >= 2
                baseline = first(rates_data).mibs
                print("  $(op) $(size):")
                for rd in rates_data
                    pct = round(rd.mibs / baseline * 100, digits=1)
                    print(" $(rd.rate)=$(round(rd.mibs, digits=1)) MiB/s ($(pct)%)")
                end
                println()
            end
        end
    end

    # Per-second time series for single-client (stability analysis)
    println()
    println("=" ^ 60)
    println("Throughput stability (per-second coefficient of variation)")
    println("=" ^ 60)
    for (subdir, label) in [("warp_put_single", "single PUT"), ("warp_get_single", "single GET"),
                            ("warp_put_distributed", "distributed PUT"), ("warp_get_distributed", "distributed GET")]
        ts = extract_timeseries(subdir)
        if !isempty(ts)
            gdf = groupby(ts, [:size_str, :rep])
            cv_df = combine(gdf,
                :mibs => mean => :mean_mibs,
                :mibs => std  => :std_mibs,
                :mibs => (x -> std(x) / mean(x) * 100) => :cv_pct,
            )
            avg_cv = combine(groupby(cv_df, :size_str), :cv_pct => mean => :mean_cv_pct)
            for row in eachrow(avg_cv)
                println("  $(label) $(row.size_str): CV = $(round(row.mean_cv_pct, digits=2))%")
            end
        end
    end

    println()
    println("Done. CSVs written to: $RESULTS_DIR")
end

main()
