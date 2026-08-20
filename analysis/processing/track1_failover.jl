# track1_failover.jl
#
# Process Track 1 failover benchmark results.
# Reads full iperf3 JSON (per-second intervals) and events JSON,
# correlates throughput with failure/recovery events.
#
# Reads from benchmarks/outputs/network/failover/,
# writes CSV tables to analysis/results/.
#
# Usage:
#   julia --project=analysis analysis/processing/track1_failover.jl

using JSON3, DataFrames, CSV, Statistics

# --- Configuration ---

const REPO_ROOT = dirname(pwd())
const FAILOVER_DIR = joinpath(REPO_ROOT, "benchmarks", "outputs", "network", "failover")
const RESULTS_DIR = joinpath(pwd(), "results")
mkpath(RESULTS_DIR)

# --- Parsing ---

"""
    parse_events(filepath) -> Vector{NamedTuple}

Parse the failover events JSON (scenario injection log).
"""
function parse_events(filepath::String)
    data = JSON3.read(read(filepath, String))
    events = NamedTuple[]
    for ev in data
        push!(events, (
            scenario       = Int(ev.scenario),
            description    = String(ev.description),
            interfaces     = [String(i) for i in ev.interfaces_down],
            t_down_epoch   = Int(ev.t_down_epoch),
            t_up_epoch     = Int(ev.t_up_epoch),
        ))
    end
    return events
end

"""
    parse_iperf3_intervals(filepath) -> DataFrame

Parse full iperf3 JSON, extracting per-second interval data.
"""
function strip_ansible_header(raw::String)
    # Ansible wraps iperf3 output with a preamble containing a Python dict
    # (also starts with '{' but uses single quotes). The iperf3 JSON starts
    # with '{\n\t"start"'. Find that marker.
    idx = findfirst("{\n\t\"start\"", raw)
    if isnothing(idx)
        idx = findfirst("{\r\n\t\"start\"", raw)
    end
    isnothing(idx) && error("No iperf3 JSON found in file")
    return raw[first(idx):end]
end

function parse_iperf3_intervals_from_data(data)
    start_epoch = Int(data.start.timestamp.timesecs)

    rows = NamedTuple[]
    for interval in data.intervals
        streams = interval.streams
        total_bps = sum(Float64(s.bits_per_second) for s in streams)
        total_retransmits = sum(Int(get(s, :retransmits, 0)) for s in streams)
        t_start = Float64(interval.sum.start)
        t_end = Float64(interval.sum.end)

        push!(rows, (
            t_start_s    = t_start,
            t_end_s      = t_end,
            t_mid_epoch  = start_epoch + round(Int, (t_start + t_end) / 2),
            gbps         = total_bps / 1e9,
            retransmits  = total_retransmits,
        ))
    end
    return DataFrame(rows)
end

"""
    extract_scenario_metrics(intervals, event, start_epoch) -> NamedTuple

For a given scenario event, extract:
- baseline_gbps: mean throughput in the 10s before the failure
- trough_gbps: minimum throughput during the failure window
- recovery_gbps: mean throughput in the 10s after recovery
- recovery_time_s: time from link down to throughput returning to 80% of baseline
"""
function extract_scenario_metrics(intervals::DataFrame, event, start_epoch::Int)
    t_down = event.t_down_epoch - start_epoch
    t_up = event.t_up_epoch - start_epoch

    # Baseline: 10s window before failure
    baseline_mask = (intervals.t_start_s .>= t_down - 15) .& (intervals.t_end_s .<= t_down - 2)
    baseline_intervals = intervals[baseline_mask, :]
    baseline_gbps = nrow(baseline_intervals) > 0 ? mean(baseline_intervals.gbps) : NaN

    # During failure: from t_down to t_up
    failure_mask = (intervals.t_start_s .>= t_down) .& (intervals.t_end_s .<= t_up + 5)
    failure_intervals = intervals[failure_mask, :]
    trough_gbps = nrow(failure_intervals) > 0 ? minimum(failure_intervals.gbps) : NaN

    # After recovery: 10s window after link restore
    recovery_mask = (intervals.t_start_s .>= t_up + 5) .& (intervals.t_end_s .<= t_up + 20)
    recovery_intervals = intervals[recovery_mask, :]
    recovery_gbps = nrow(recovery_intervals) > 0 ? mean(recovery_intervals.gbps) : NaN

    # Recovery time: first interval after t_down where throughput >= 80% of baseline
    threshold = baseline_gbps * 0.8
    post_down = intervals[intervals.t_start_s .>= t_down, :]
    recovery_time_s = NaN
    for row in eachrow(post_down)
        if row.gbps >= threshold
            recovery_time_s = row.t_start_s - t_down
            break
        end
    end

    return (
        baseline_gbps       = baseline_gbps,
        trough_gbps         = trough_gbps,
        recovery_gbps       = recovery_gbps,
        recovery_time_s     = recovery_time_s,
        throughput_loss_pct  = isnan(baseline_gbps) ? NaN : (1 - trough_gbps / baseline_gbps) * 100,
    )
end

# --- File discovery ---

function discover_failover_reps()
    isdir(FAILOVER_DIR) || error("Directory not found: $FAILOVER_DIR")
    event_files = filter(f -> contains(f, "_events.json") && !isnothing(match(r"^\d+_", f)), readdir(FAILOVER_DIR))
    reps = []
    for f in sort(event_files)
        m = match(r"^(\d+)_failover_rep(\d+)_(\w+)_events\.json$", f)
        m === nothing && continue
        push!(reps, (
            epoch  = parse(Int, m.captures[1]),
            rep    = parse(Int, m.captures[2]),
            client = String(m.captures[3]),
            events_file = f,
        ))
    end
    return reps
end

# --- Main ---

function main()
    println("Track 1 Failover Analysis")
    println("=" ^ 60)
    println("Source: $FAILOVER_DIR")
    println("Output: $RESULTS_DIR")
    println()

    reps = discover_failover_reps()
    println("Found $(length(reps)) failover repetitions")
    println()

    all_rows = NamedTuple[]

    for rep_info in reps
        events_path = joinpath(FAILOVER_DIR, rep_info.events_file)
        events = parse_events(events_path)
        println("Rep $(rep_info.rep) ($(rep_info.client)): $(length(events)) scenarios")

        # Find iperf3 files for this rep
        prefix = "$(rep_info.epoch)_failover_rep$(rep_info.rep)_$(rep_info.client)_"
        iperf_files = filter(f -> startswith(f, prefix) &&
                                  !contains(f, "events") &&
                                  !contains(f, "snapshot") &&
                                  endswith(f, ".json"),
                             readdir(FAILOVER_DIR))

        for iperf_file in sort(iperf_files)
            m = match(r"_(\w+)\.json$", iperf_file)
            m === nothing && continue
            target = String(m.captures[1])

            filepath = joinpath(FAILOVER_DIR, iperf_file)
            local parsed_data
            intervals = try
                raw = read(filepath, String)
                clean = strip_ansible_header(raw)
                parsed_data = JSON3.read(clean)
                parse_iperf3_intervals_from_data(parsed_data)
            catch e
                println("  Warning: failed to parse $iperf_file: $e")
                continue
            end

            start_epoch = Int(parsed_data.start.timestamp.timesecs)

            for event in events
                metrics = extract_scenario_metrics(intervals, event, start_epoch)
                push!(all_rows, (
                    repetition          = rep_info.rep,
                    client              = rep_info.client,
                    target              = target,
                    scenario            = event.scenario,
                    description         = event.description,
                    n_links_down        = length(event.interfaces),
                    baseline_gbps       = metrics.baseline_gbps,
                    trough_gbps         = metrics.trough_gbps,
                    recovery_gbps       = metrics.recovery_gbps,
                    recovery_time_s     = metrics.recovery_time_s,
                    throughput_loss_pct  = metrics.throughput_loss_pct,
                ))
            end
        end
        println()
    end

    df = DataFrame(all_rows)

    CSV.write(joinpath(RESULTS_DIR, "track1_failover_raw.csv"), df)
    println("Wrote: track1_failover_raw.csv")

    # Summary per scenario (aggregate across targets and reps)
    scenario_summary = combine(groupby(df, [:scenario, :description, :n_links_down]),
        :baseline_gbps       => mean    => :mean_baseline_gbps,
        :trough_gbps         => mean    => :mean_trough_gbps,
        :recovery_gbps       => mean    => :mean_recovery_gbps,
        :recovery_time_s     => mean    => :mean_recovery_s,
        :recovery_time_s     => maximum => :worst_recovery_s,
        :throughput_loss_pct  => mean    => :mean_throughput_loss_pct,
        nrow                 => :n_observations,
    )
    sort!(scenario_summary, :scenario)

    println()
    println("Per-scenario summary:")
    show(stdout, scenario_summary; allrows=true, allcols=true, truncate=0)
    println()

    CSV.write(joinpath(RESULTS_DIR, "track1_failover_summary.csv"), scenario_summary)
    println("Wrote: track1_failover_summary.csv")

    # Per-target time series (for figures later)
    CSV.write(joinpath(RESULTS_DIR, "track1_failover_raw.csv"), df)

    println("\nDone.")
end

main()
