# track1_figures.jl
#
# Publication-ready figures from Track 1 network benchmark results.
# Follows Elsevier/FGCS artwork guidelines:
#   - No titles (captions in manuscript)
#   - Okabe-Ito palette for categorical, viridis for sequential
#   - Distinct markers per series
#   - Minimum 7pt font at final printed size
#   - Legends below panels, horizontal
#   - PDF vector + PNG raster output
#
# Reads CSVs from analysis/results/ and raw iperf3 JSON from benchmarks/.
# Writes PDF+PNG to analysis/figures/.
#
# Usage:
#   cd analysis/
#   julia --project=. figures/track1_figures.jl

using CSV, DataFrames, CairoMakie, Statistics, JSON3, Random

# --- Configuration ---

const REPO_ROOT = dirname(pwd())
const RESULTS_DIR = joinpath(pwd(), "results")
const FIGURES_DIR = joinpath(pwd(), "figures")
const THROUGHPUT_DIR = joinpath(REPO_ROOT, "benchmarks", "outputs", "network", "throughput")
mkpath(FIGURES_DIR)

const DPI = 300

# Figures are scaled to the text column on typesetting, so what a reader sees is
# type size relative to canvas width, not absolute points. Canvases are
# standardised to 1000 units wide; these sizes then land at 14 (ticks) and 18
# (axis labels) per 1000 units. Calibrated against the acrb replication figure
# as it reads in the manuscript, where 8 was too small and 14 read comfortably.
const FONT_SIZE = 18     # Figure base; Axis xlabelsize/ylabelsize inherit this
const LABEL_SIZE = 14    # legend labels, panel titles, in-plot values
const TICK_SIZE = 14

# Okabe-Ito palette.
const OI = (
    blue    = colorant"#0072B2",
    orange  = colorant"#E69F00",
    red     = colorant"#D55E00",
    green   = colorant"#009E73",
    pink    = colorant"#CC79A7",
    skyblue = colorant"#56B4E9",
    yellow  = colorant"#F0E442",
)

# Mode-to-colour mapping (consistent across all figures).
const MODE_COLOUR = Dict(
    "per-pair"     => OI.blue,
    "app-outbound" => OI.orange,
    "st-inbound"   => OI.pink,
    "full-mesh"    => OI.red,
    "st-to-st"     => OI.green,
)

const MODE_MARKER = Dict(
    "per-pair"     => :circle,
    "app-outbound" => :rect,
    "st-inbound"   => :diamond,
    "full-mesh"    => :utriangle,
    "st-to-st"     => :star5,
)

const MODE_ORDER = ["per-pair", "st-inbound", "app-outbound", "full-mesh", "st-to-st"]
const MODE_LABELS = Dict(
    "per-pair"     => "Per-pair\n(sequential)",
    "app-outbound" => "App→storage\n(1→8)",
    "st-inbound"   => "Storage←apps\n(3→1)",
    "full-mesh"    => "Full-mesh\n(3→8)",
    "st-to-st"     => "St-to-st\n(4→4)",
)

# --- Helpers ---

function safe_read_csv(name::String)
    path = joinpath(RESULTS_DIR, name)
    isfile(path) || error("CSV not found: $path. Run track1_throughput.jl first.")
    return CSV.read(path, DataFrame)
end

function savefig(fig, name)
    save(joinpath(FIGURES_DIR, "$(name).pdf"), fig, pt_per_unit=1)
    save(joinpath(FIGURES_DIR, "$(name).png"), fig, px_per_unit=DPI/72)
    println("  Saved: $(name).{pdf,png}")
end

function strip_ansible_header(raw::String)
    startswith(raw, "{") && return raw
    idx = findfirst("{\n\t\"start\"", raw)
    isnothing(idx) && (idx = findfirst("{\r\n\t\"start\"", raw))
    isnothing(idx) && error("No iperf3 JSON found")
    return raw[first(idx):end]
end

# Find one representative file for a mode+rep.
function find_representative_file(mode::String, rep::Int, client::String, server::String)
    dir = joinpath(THROUGHPUT_DIR, mode)
    files = filter(readdir(dir)) do f
        endswith(f, ".json") && !contains(f, "snapshot") &&
        contains(f, "_rep$(rep)_") && contains(f, "_$(client)_$(server).")
    end
    isempty(files) && return nothing
    return joinpath(dir, first(sort(files)))
end

# Extract per-second interval throughput from raw iperf3 JSON.
function read_intervals(filepath::String)
    raw = read(filepath, String)
    clean = strip_ansible_header(raw)
    data = JSON3.read(clean)
    return [Float64(iv["sum"]["bits_per_second"]) / 1e9 for iv in data["intervals"]]
end

# Extract per-stream aggregate throughput from raw iperf3 JSON.
function read_stream_throughput(filepath::String)
    raw = read(filepath, String)
    clean = strip_ansible_header(raw)
    data = JSON3.read(clean)
    return [Float64(s["sender"]["bits_per_second"]) / 1e9 for s in data["end"]["streams"]]
end

# =====================================================================
# EXISTING FIGURES (1–4)
# =====================================================================

# --- Figure 1: Per-pair baseline heatmap ---

function fig_perpair_heatmap()
    df = safe_read_csv("track1_per_pair_per_pair.csv")
    apps = sort(unique(df.client))
    stores = sort(unique(df.server))

    mat = zeros(length(stores), length(apps))
    for row in eachrow(df)
        i = findfirst(==(row.server), stores)
        j = findfirst(==(row.client), apps)
        mat[i, j] = row.mean_gbps
    end

    fig = Figure(size=(1000, 429), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        xlabel="Storage Node", ylabel="Application Server",
        xticks=(1:length(stores), stores),
        yticks=(1:length(apps), apps),
        xticklabelsize=TICK_SIZE, yticklabelsize=TICK_SIZE,
    )

    hm = heatmap!(ax, 1:length(stores), 1:length(apps), mat,
        colormap=:viridis,
        colorrange=(0, 150),
    )

    for i in 1:length(stores), j in 1:length(apps)
        val = round(mat[i, j], digits=1)
        text!(ax, i, j; text=string(val),
            align=(:center, :center), fontsize=LABEL_SIZE,
            color=:white,
        )
    end

    Colorbar(fig[1, 2], hm, label="Gbps")
    savefig(fig, "track1_perpair_heatmap")
end

# --- Figure 2: Cross-mode aggregate throughput (two-panel layout, v2) ---
#
# Panel (a): the two modes that measure simultaneous fabric-wide load
# (full-mesh, st-to-st), each with the relevant per-mode NIC-bond
# ceiling drawn over the bar.
#
# Panel (b): per-pair (sequential), storage-inbound (3->1), and
# app-outbound (1->8). These are sums of non-concurrent measurements
# — the bar height aggregates across multiple sequential per-source or
# per-target measurements rather than measuring an instantaneous
# fabric load. No reference lines: a fabric-wide ceiling does not
# apply.
#
# Why app-outbound is in panel (b), not (a): app-outbound runs 8
# concurrent flows from one app server at a time, and iterates over
# the 3 app servers sequentially. The reported aggregate sums across
# those 3 sequential measurements (~175 Gbps per app x 3 ~= 522 Gbps),
# so it is not comparable to a single-NIC 400 Gbps ceiling. The story
# lives in panel (b)'s per-mode bar comparison and the §5.2 prose.
#
# The split is driven by §5.1 of the manuscript: "Per-session
# concurrency" and "Inter-configuration sequencing" together determine
# whether a mode's aggregate is an instantaneous fabric load or a sum
# of independent measurements.

function fig_aggregate_by_mode()
    raw = safe_read_csv("track1_throughput_raw.csv")

    # Per-mode mean and std across reps.
    stats = Dict{String, Any}()
    for mode in MODE_ORDER
        mode_data = filter(r -> r.mode == mode, raw)
        agg = combine(groupby(mode_data, :rep), :sent_gbps => sum => :total_gbps)
        stats[mode] = (
            mean_gbps = mean(agg.total_gbps),
            std_gbps  = std(agg.total_gbps),
            colour    = MODE_COLOUR[mode],
        )
    end

    # Panel partitions.
    panel_a_modes = ["full-mesh", "st-to-st"]
    panel_b_modes = ["per-pair", "st-inbound", "app-outbound"]

    # Per-mode reference ceilings for panel (a), in Gbps. These are the
    # sender-side NIC-bond capacities for the concurrent fabric load
    # each mode produces: 3 apps x 400 = 1200; 4 storage x 400 = 1600.
    # §5.1 establishes that these are the relevant ceilings.
    ref_ceiling = Dict(
        "full-mesh"    => 1200.0,
        "st-to-st"     => 1600.0,
    )
    ref_label = Dict(
        "full-mesh"    => "3×400 Gbps",
        "st-to-st"     => "4×400 Gbps",
    )

    fig = Figure(size=(1000, 444), fontsize=FONT_SIZE)

    # --- Panel (a): concurrent fabric-saturating modes ---
    ax_a = Axis(fig[1, 1],
        ylabel="Aggregate throughput (Gbps)",
        xticks=(1:length(panel_a_modes), [MODE_LABELS[m] for m in panel_a_modes]),
        xticklabelsize=TICK_SIZE,
        yticklabelsize=TICK_SIZE,
    )

    means_a = [stats[m].mean_gbps for m in panel_a_modes]
    stds_a  = [stats[m].std_gbps  for m in panel_a_modes]
    colours_a = [stats[m].colour  for m in panel_a_modes]

    barplot!(ax_a, 1:length(means_a), means_a,
        color=colours_a, strokewidth=0.5, strokecolor=:black)
    errorbars!(ax_a, 1:length(means_a), means_a, stds_a,
        whiskerwidth=8, color=:black)

    # Reference lines: drawn over only the relevant bar (x_i ± 0.4),
    # with a short label above each line. Black, linewidth 1.5 for
    # legibility (previous gray60 at linewidth 1 was nearly invisible).
    for (i, m) in enumerate(panel_a_modes)
        y = ref_ceiling[m]
        lines!(ax_a, [i - 0.4, i + 0.4], [y, y],
            color=:black, linestyle=:dash, linewidth=1.5)
        text!(ax_a, i, y + 35;
            text=ref_label[m],
            fontsize=LABEL_SIZE, align=(:center, :bottom), color=:black)
    end

    # Deterministic axis ranges so the panel label sits in a known spot.
    xlims!(ax_a, 0.5, length(panel_a_modes) + 0.5)
    ax_a_ymax = maximum(values(ref_ceiling)) * 1.12
    ylims!(ax_a, 0, ax_a_ymax)

    text!(ax_a, 0.6, ax_a_ymax * 0.96;
        text="(a)", fontsize=LABEL_SIZE + 1,
        align=(:left, :top), color=:black)

    # --- Panel (b): sums of non-concurrent per-source/per-target measurements ---
    ax_b = Axis(fig[1, 2],
        ylabel="Sum of per-session throughputs (Gbps)",
        xticks=(1:length(panel_b_modes), [MODE_LABELS[m] for m in panel_b_modes]),
        xticklabelsize=TICK_SIZE,
        yticklabelsize=TICK_SIZE,
    )

    means_b = [stats[m].mean_gbps for m in panel_b_modes]
    stds_b  = [stats[m].std_gbps  for m in panel_b_modes]
    colours_b = [stats[m].colour  for m in panel_b_modes]

    barplot!(ax_b, 1:length(means_b), means_b,
        color=colours_b, strokewidth=0.5, strokecolor=:black)
    errorbars!(ax_b, 1:length(means_b), means_b, stds_b,
        whiskerwidth=8, color=:black)

    # No reference lines: the bars are sums across non-concurrent
    # measurements, so a fabric-wide ceiling does not apply. §5.1
    # carries the explanation.

    xlims!(ax_b, 0.5, length(panel_b_modes) + 0.5)
    ax_b_ymax = maximum(means_b .+ stds_b) * 1.12
    ylims!(ax_b, 0, ax_b_ymax)

    text!(ax_b, 0.6, ax_b_ymax * 0.96;
        text="(b)", fontsize=LABEL_SIZE + 1,
        align=(:left, :top), color=:black)

    savefig(fig, "track1_aggregate_by_mode")
end

# --- Figure 3: Full-mesh degradation heatmap ---

function fig_degradation_heatmap()
    cross = safe_read_csv("track1_throughput_cross_mode.csv")
    apps = sort(unique(cross.client))
    stores = sort(unique(cross.server))

    mat = zeros(length(stores), length(apps))
    for row in eachrow(cross)
        i = findfirst(==(row.server), stores)
        j = findfirst(==(row.client), apps)
        mat[i, j] = row.degradation_pct
    end

    fig = Figure(size=(1000, 429), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        xlabel="Storage Node", ylabel="Application Server",
        xticks=(1:length(stores), stores),
        yticks=(1:length(apps), apps),
        xticklabelsize=TICK_SIZE, yticklabelsize=TICK_SIZE,
    )

    hm = heatmap!(ax, 1:length(stores), 1:length(apps), mat,
        colormap=:viridis, colorrange=(60, 95))

    for i in 1:length(stores), j in 1:length(apps)
        val = round(mat[i, j], digits=0)
        text!(ax, i, j; text="$(Int(val))%",
            align=(:center, :center), fontsize=LABEL_SIZE, color=:black)
    end

    Colorbar(fig[1, 2], hm, label="Throughput Degradation (%)")
    savefig(fig, "track1_degradation_heatmap")
end

# --- Figure 4: CPU utilisation vs throughput ---

function fig_cpu_vs_throughput()
    raw = safe_read_csv("track1_throughput_raw.csv")

    fig = Figure(size=(1000, 646), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        xlabel="Aggregate Throughput per Client (Gbps)",
        ylabel="Host CPU Utilisation (%)",
        xticklabelsize=TICK_SIZE, yticklabelsize=TICK_SIZE,
    )

    mode_config = [
        ("per-pair",     "Per-pair (R6525, sequential)"),
        ("app-outbound", "App-outbound (R6525, 1→8)"),
        ("full-mesh",    "Full-mesh (R6525, 3→8)"),
        ("st-to-st",     "St-to-st (R750, 4→4)"),
    ]

    legend_elems = []
    legend_labels = String[]

    for (mode, label) in mode_config
        colour = MODE_COLOUR[mode]
        marker = MODE_MARKER[mode]
        mode_data = filter(r -> r.mode == mode, raw)

        agg = combine(groupby(mode_data, [:client, :rep]),
            :sent_gbps      => sum  => :total_gbps,
            :host_cpu_total  => mean => :mean_cpu,
        )

        scatter!(ax, agg.total_gbps, agg.mean_cpu,
            color=(colour, 0.7), marker=marker, markersize=12,
            strokewidth=1, strokecolor=colour)
        push!(legend_elems, MarkerElement(color=(colour, 0.7), marker=marker,
            markersize=12, strokecolor=colour, strokewidth=1))
        push!(legend_labels, label)
    end

    Legend(fig[2, 1], legend_elems, legend_labels,
        orientation=:horizontal, framevisible=false,
        labelsize=LABEL_SIZE, nbanks=2)

    savefig(fig, "track1_cpu_vs_throughput")
end

# =====================================================================
# NEW FIGURES (5–8): raw iperf3 metrics
# =====================================================================

# --- Figure 5: Per-second throughput time series ---
# One representative pair (srv02→st03) across modes, showing 120s of intervals.

function fig_throughput_timeseries()
    # Representative pair: srv02→st03 (mid-range per-pair throughput, clean data).
    client, server = "srv02", "st03"
    rep = 1

    # For st-to-st, use st01→st05.
    st_client, st_server = "st01", "st05"

    modes_to_plot = [
        ("per-pair",     client, server,    "Per-pair (sequential)"),
        ("app-outbound", client, server,    "App-outbound (1→8, contended)"),
        ("full-mesh",    client, server,    "Full-mesh (3→8, contended)"),
        ("st-to-st",     st_client, st_server, "St-to-st (4→4, R750)"),
    ]

    fig = Figure(size=(1000, 750), fontsize=FONT_SIZE)

    for (idx, (mode, c, s, label)) in enumerate(modes_to_plot)
        ax = Axis(fig[idx, 1],
            ylabel="Gbps",
            xticklabelsize=TICK_SIZE, yticklabelsize=TICK_SIZE,
        )
        if idx < length(modes_to_plot)
            hidexdecorations!(ax, grid=false)
        else
            ax.xlabel = "Time (seconds)"
        end

        filepath = find_representative_file(mode, rep, c, s)
        if isnothing(filepath)
            text!(ax, 60, 0.5; text="No data", align=(:center, :center))
            continue
        end

        intervals = read_intervals(filepath)
        t = collect(1:length(intervals))
        colour = MODE_COLOUR[mode]

        lines!(ax, t, intervals, color=(colour, 0.8), linewidth=1.2)

        # Mean reference line.
        m = mean(intervals)
        cv = std(intervals) / m * 100
        hlines!(ax, [m], color=colour, linestyle=:dash, linewidth=0.8)

        # Per-axis title: rendered above the plot area, cannot collide
        # with the data line. Replaces an earlier in-plot text annotation
        # that overlapped the line in panels with full vertical range.
        ax.title = "$(label)  —  mean = $(round(m, digits=1)) Gbps, CV = $(round(cv, digits=1))%"
        ax.titlealign = :left
        ax.titlesize = LABEL_SIZE
    end

    savefig(fig, "track1_throughput_timeseries")
end

# --- Figure 6: Stream balance — per-pair vs full-mesh ---
# Same pair, showing how 8 streams distribute under no contention vs full contention.

function fig_stream_balance()
    client, server = "srv02", "st03"
    rep = 1

    modes = [
        ("per-pair",  "Per-pair (no contention)"),
        ("full-mesh", "Full-mesh (24 concurrent sessions)"),
    ]

    fig = Figure(size=(1000, 500), fontsize=FONT_SIZE)

    for (col, (mode, label)) in enumerate(modes)
        ax = Axis(fig[1, col],
            xlabel="Stream",
            ylabel=col == 1 ? "Throughput (Gbps)" : "",
            xticks=(1:8, string.(1:8)),
            xticklabelsize=TICK_SIZE, yticklabelsize=TICK_SIZE,
        )

        filepath = find_representative_file(mode, rep, client, server)
        if isnothing(filepath)
            text!(ax, 4, 0.5; text="No data", align=(:center, :center))
            continue
        end

        streams = read_stream_throughput(filepath)
        colour = MODE_COLOUR[mode]

        barplot!(ax, 1:length(streams), streams,
            color=(colour, 0.7), strokewidth=0.5, strokecolor=colour)

        m = mean(streams)
        cv = std(streams) / m * 100
        hlines!(ax, [m], color=:gray40, linestyle=:dash, linewidth=0.8)

        # Per-axis title: rendered above the plot area, consistent with
        # Fig 5 (fig_throughput_timeseries) for per-panel descriptors.
        ax.title = "$(label)  —  CV = $(round(cv, digits=1))%"
        ax.titlealign = :left
        ax.titlesize = LABEL_SIZE
    end

    # Link y-axes for comparison.
    linkyaxes!(contents(fig[1, 1])[1], contents(fig[1, 2])[1])

    savefig(fig, "track1_stream_balance")
end

# --- Figure 7: Throughput stability across modes (CV% box plot) ---

function fig_stability_by_mode()
    raw = safe_read_csv("track1_throughput_raw.csv")

    fig = Figure(size=(1000, 585), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        ylabel="Per-second Throughput CV (%)",
        xticks=(1:length(MODE_ORDER), [MODE_LABELS[m] for m in MODE_ORDER]),
        xticklabelsize=TICK_SIZE, yticklabelsize=TICK_SIZE,
    )
    Random.seed!(11)
    for (i, mode) in enumerate(MODE_ORDER)
        mode_data = filter(r -> r.mode == mode, raw)
        colour = MODE_COLOUR[mode]

        # Jittered scatter of all individual file CVs.
        jitter = (rand(nrow(mode_data)) .- 0.5) .* 0.3
        scatter!(ax, fill(i, nrow(mode_data)) .+ jitter, mode_data.cv_pct,
            color=(colour, 0.4), markersize=6, strokewidth=0)

        # Box: median, IQR.
        vals = mode_data.cv_pct
        q25, q50, q75 = quantile(vals, [0.25, 0.5, 0.75])
        m = mean(vals)

        # IQR box.
        poly!(ax, Point2f[(i-0.2, q25), (i+0.2, q25), (i+0.2, q75), (i-0.2, q75)],
            color=(colour, 0.25), strokewidth=1.5, strokecolor=colour)
        # Median line.
        lines!(ax, [i-0.2, i+0.2], [q50, q50], color=colour, linewidth=2)
        # Mean marker.
        scatter!(ax, [i], [m], color=:white, marker=:diamond, markersize=8,
            strokewidth=1.5, strokecolor=colour)
    end

    savefig(fig, "track1_stability_by_mode")
end

# --- Figure 8: Stream balance across modes (CV% box plot) ---

function fig_stream_cv_by_mode()
    raw = safe_read_csv("track1_throughput_raw.csv")

    fig = Figure(size=(1000, 585), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        ylabel="Stream Balance CV (%)",
        xticks=(1:length(MODE_ORDER), [MODE_LABELS[m] for m in MODE_ORDER]),
        xticklabelsize=TICK_SIZE, yticklabelsize=TICK_SIZE,
    )
    Random.seed!(11)
    for (i, mode) in enumerate(MODE_ORDER)
        mode_data = filter(r -> r.mode == mode, raw)
        colour = MODE_COLOUR[mode]

        jitter = (rand(nrow(mode_data)) .- 0.5) .* 0.3
        scatter!(ax, fill(i, nrow(mode_data)) .+ jitter, mode_data.stream_cv_pct,
            color=(colour, 0.4), markersize=6, strokewidth=0)

        vals = mode_data.stream_cv_pct
        q25, q50, q75 = quantile(vals, [0.25, 0.5, 0.75])
        m = mean(vals)

        poly!(ax, Point2f[(i-0.2, q25), (i+0.2, q25), (i+0.2, q75), (i-0.2, q75)],
            color=(colour, 0.25), strokewidth=1.5, strokecolor=colour)
        lines!(ax, [i-0.2, i+0.2], [q50, q50], color=colour, linewidth=2)
        scatter!(ax, [i], [m], color=:white, marker=:diamond, markersize=8,
            strokewidth=1.5, strokecolor=colour)
    end

    savefig(fig, "track1_stream_cv_by_mode")
end

# =====================================================================
# Main
# =====================================================================

function main()
    println("Track 1 Network Figures")
    println("=" ^ 60)
    println("Source: $RESULTS_DIR")
    println("Output: $FIGURES_DIR")
    println()

    println("Fig 1: Per-pair baseline heatmap")
    fig_perpair_heatmap()

    println("Fig 2: Cross-mode aggregate throughput")
    fig_aggregate_by_mode()

    println("Fig 3: Full-mesh degradation heatmap")
    fig_degradation_heatmap()

    println("Fig 4: CPU vs throughput")
    fig_cpu_vs_throughput()

    println("Fig 5: Per-second throughput time series")
    fig_throughput_timeseries()

    println("Fig 6: Stream balance (per-pair vs full-mesh)")
    fig_stream_balance()

    println("Fig 7: Throughput stability by mode (CV%)")
    fig_stability_by_mode()

    println("Fig 8: Stream balance by mode (CV%)")
    fig_stream_cv_by_mode()

    n_png = count(f -> endswith(f, ".png") && startswith(f, "track1_"), readdir(FIGURES_DIR))
    println("\nDone. $n_png Track 1 PNG + PDF pairs in $FIGURES_DIR")
end

main()
