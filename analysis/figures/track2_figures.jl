# track2_figures.jl
#
# Publication-ready figures from Track 2 MinIO benchmark summaries.
# Follows Elsevier/FGCS artwork guidelines:
#   - No titles in figures (captions go in the manuscript)
#   - Minimum 7pt font at final printed size
#   - Legends outside the data panel (below)
#   - PDF vector output for submission; PNG for preview
#
# Reads CSVs from analysis/results/, writes PDF+PNG to analysis/figures/.
#
# Usage:
#   cd analysis/
#   julia --project=. figures/track2_figures.jl

using CSV, DataFrames, CairoMakie, Statistics

# --- Configuration ---

const RESULTS_DIR = joinpath(pwd(), "results")
const FIGURES_DIR = joinpath(pwd(), "figures")
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

const FIG_WIDTH = 1000
const FIG_HEIGHT = 585

# Ordered sizes for consistent x-axis.
const SIZE_ORDER = ["4MiB", "64MiB", "512MiB", "2GiB"]
const SIZE_LABELS = ["4 MiB\n(Zarr)", "64 MiB\n(COG)", "512 MiB\n(Sentinel-2)", "2 GiB\n(SAR)"]

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

const PUT_COLOUR = OI.blue
const GET_COLOUR = OI.red
const PUT_LIGHT  = OI.skyblue
const GET_LIGHT  = OI.orange
const MIXED_GET_COLOUR = OI.red
const MIXED_PUT_COLOUR = OI.blue

# --- Helpers ---

function safe_read_csv(name::String)
    path = joinpath(RESULTS_DIR, name)
    isfile(path) || error("CSV not found: $path. Run track2_throughput.jl first.")
    return CSV.read(path, DataFrame)
end

function size_index(s::AbstractString)
    idx = findfirst(x -> x == s, SIZE_ORDER)
    isnothing(idx) && error("Unknown size: $s")
    return idx
end

function size_label(s::AbstractString)
    return SIZE_LABELS[size_index(s)]
end

function savefig(fig, name)
    save(joinpath(FIGURES_DIR, "$(name).pdf"), fig, pt_per_unit=1)
    save(joinpath(FIGURES_DIR, "$(name).png"), fig, px_per_unit=DPI/72)
    println("  Saved: $(name).{pdf,png}")
end

# --- Figure 1: Single vs Distributed throughput by object size ---

function fig_single_vs_distributed()
    summary = safe_read_csv("track2_summary.csv")

    fig = Figure(size=(1000, 563), fontsize=FONT_SIZE)
    gl = fig[1, 1] = GridLayout()

    # Per-panel colour pairs cached so the legend block can read them
    # back without re-deriving from the op string.
    panel_colours = Dict{String, Tuple}()

    for (col, op) in enumerate(["PUT", "GET"])
        single = filter(r -> r.experiment == "single" && r.operation == op && r.rate == "100gbps", summary)
        dist   = filter(r -> r.experiment == "distributed" && r.operation == op && r.rate == "100gbps", summary)
        sort!(single, :size_bytes)
        sort!(dist, :size_bytes)

        n = nrow(single)
        xs = vcat(collect(1:n), collect(1:n))
        ys = vcat(single.mean_mibs, dist.mean_mibs)
        errs = vcat(single.std_mibs, dist.std_mibs)
        grp = vcat(fill(1, n), fill(2, n))
        colours = op == "PUT" ? [PUT_LIGHT, PUT_COLOUR] : [GET_LIGHT, GET_COLOUR]
        panel_colours[op] = (colours[1], colours[2])

        # Integer ticks with thousands separators; cleaner than the
        # default scientific notation at this magnitude.
        ytick_fmt = v -> begin
            n_int = round(Int, v)
            s = string(n_int)
            length(s) <= 3 && return s
            rev = reverse(s)
            grouped = join([rev[i:min(i+2, length(rev))] for i in 1:3:length(rev)], ",")
            return reverse(grouped)
        end

        ax = Axis(gl[1, col],
            ylabel = col == 1 ? "Throughput (MiB/s)" : "",
            xticks = (1:4, SIZE_LABELS),
            xticklabelsize = TICK_SIZE,
            yticks = 0:5000:20000,
            ytickformat = vs -> [ytick_fmt(v) for v in vs],
            title = op,
            titlealign = :left,
            titlesize = LABEL_SIZE,
        )

        barplot!(ax, xs, ys,
            dodge = grp,
            color = [colours[g] for g in grp],
            strokewidth = 0.5, strokecolor = :black)

        dodge_width = 0.8
        n_grps = 2
        for g in 1:n_grps
            mask = grp .== g
            x_dodge = xs[mask] .+ (g - (n_grps + 1) / 2) * dodge_width / n_grps
            errorbars!(ax, x_dodge, ys[mask], errs[mask],
                whiskerwidth = 6, color = :black)
        end

        # Explicit shared y-range so the two panels are visually
        # comparable. Auto-fit produced PUT max ~17,000 and GET max
        # ~20,000, which looked almost-but-not-quite the same.
        ylims!(ax, 0, 20000)
    end

    # Per-panel legends. The single shared legend at fig[2, 1] only
    # showed PUT colours, leaving the GET panel without a key.
    # Two legends placed under their respective panels resolve this
    # while preserving the Track 2 colour-by-operation convention.
    for (col, op) in enumerate(["PUT", "GET"])
        light, dark = panel_colours[op]
        elems = [PolyElement(color=light, strokecolor=:black, strokewidth=0.5),
                 PolyElement(color=dark,  strokecolor=:black, strokewidth=0.5)]
        Legend(gl[2, col], elems, ["Single-client", "Distributed"],
            orientation=:horizontal, framevisible=false,
            labelsize=LABEL_SIZE, nbanks=1)
    end

    savefig(fig, "track2_single_vs_distributed")
end

# --- Figure 2: Scaling factor (distributed / single) ---

function fig_scaling_factor()
    summary = safe_read_csv("track2_summary.csv")

    fig = Figure(size=(FIG_WIDTH, FIG_HEIGHT), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        ylabel = "Scaling factor (\u00d7)",
        xticks = (1:4, SIZE_LABELS),
        xticklabelsize = TICK_SIZE,
    )

    for (op, colour, marker, offset) in [("PUT", PUT_COLOUR, :circle, -0.15), ("GET", GET_COLOUR, :rect, 0.15)]
        single = filter(r -> r.experiment == "single" && r.operation == op && r.rate == "100gbps", summary)
        dist   = filter(r -> r.experiment == "distributed" && r.operation == op && r.rate == "100gbps", summary)
        sort!(single, :size_bytes)
        sort!(dist, :size_bytes)

        sizes_common = intersect(single.size_str, dist.size_str)
        factors = Float64[]
        xs = Float64[]
        for s in SIZE_ORDER
            s in sizes_common || continue
            s_row = first(filter(r -> r.size_str == s, single))
            d_row = first(filter(r -> r.size_str == s, dist))
            push!(factors, d_row.mean_mibs / s_row.mean_mibs)
            push!(xs, Float64(size_index(s)) + offset)
        end

        barplot!(ax, xs, factors,
            width=0.25, color=colour,
            strokewidth=0.5, strokecolor=:black,
            label=op)
    end

    hlines!(ax, [2.0], color=:gray60, linestyle=:dash, linewidth=1)
    text!(ax, 0.55, 2.05; text="Ideal 2\u00d7 (2 clients)", fontsize=12, color=:gray50)

    Legend(fig[2, 1], ax, orientation=:horizontal, framevisible=false,
        labelsize=LABEL_SIZE, nbanks=1)

    savefig(fig, "track2_scaling_factor")
end

# --- Figure 3: Bandwidth impact (100G vs 10G vs 1G) ---

function fig_bandwidth_impact()
    summary = safe_read_csv("track2_summary.csv")

    fig = Figure(size=(1000, 563), fontsize=FONT_SIZE)
    gl = fig[1, 1] = GridLayout()

    rates = ["100gbps", "10gbps", "1gbps"]
    rate_labels = ["100 Gbps (native)", "10 Gbps", "1 Gbps"]
    rate_colours = [OI.blue, OI.skyblue, OI.orange]

    # Discover which sizes have throttled data.
    throttled = filter(r -> r.experiment == "throttled", summary)
    sizes_throttled = sort(unique(throttled.size_str), by=size_index)
    size_labels_short = [replace(s, "MiB" => " MiB", "GiB" => " GiB") for s in sizes_throttled]

    for (col, op) in enumerate(["PUT", "GET"])
        xs = Int[]
        ys = Float64[]
        errs = Float64[]
        grp = Int[]
        for (ri, rate) in enumerate(rates)
            for (si, size) in enumerate(sizes_throttled)
                if rate == "100gbps"
                    rows = filter(r -> r.experiment == "distributed" &&
                                       r.operation == op &&
                                       r.rate == rate &&
                                       r.size_str == size, summary)
                else
                    rows = filter(r -> r.experiment == "throttled" &&
                                       r.operation == op &&
                                       r.rate == rate &&
                                       r.size_str == size, summary)
                end
                if !isempty(rows)
                    push!(xs, si)
                    push!(ys, first(rows).mean_mibs)
                    push!(errs, first(rows).std_mibs)
                    push!(grp, ri)
                end
            end
        end

        # Integer formatter with thousands separators. Defined locally
        # because the Track 2 figure functions do not share state.
        # Identical helper appears in fig_single_vs_distributed
        # (patch_49); kept local to each function for readability
        # rather than promoted to module scope.
        ytick_fmt = v -> begin
            n_int = round(Int, v)
            s = string(n_int)
            length(s) <= 3 && return s
            rev = reverse(s)
            grouped = join([rev[i:min(i+2, length(rev))] for i in 1:3:length(rev)], ",")
            return reverse(grouped)
        end

        ax = Axis(gl[1, col],
            ylabel = col == 1 ? "Throughput (MiB/s)" : "",
            yscale = log10,
            yticks = [100, 200, 500, 1000, 2000, 5000, 10000, 20000],
            ytickformat = vs -> [ytick_fmt(v) for v in vs],
            xticks = (1:length(sizes_throttled), size_labels_short),
            xticklabelsize = TICK_SIZE,
            title = op,
            titlealign = :left,
            titlesize = LABEL_SIZE,
        )

        barplot!(ax, xs, ys,
            dodge = grp,
            color = [rate_colours[g] for g in grp],
            strokewidth = 0.5, strokecolor = :black)

        dodge_width = 0.8
        n_grps = 3
        for g in 1:n_grps
            mask = grp .== g
            any(mask) || continue
            x_dodge = xs[mask] .+ (g - (n_grps + 1) / 2) * dodge_width / n_grps
            errorbars!(ax, x_dodge, ys[mask], errs[mask],
                whiskerwidth = 5, color = :black)
        end
    end

    elems = [PolyElement(color=c, strokecolor=:black, strokewidth=0.5) for c in rate_colours]
    Legend(fig[2, 1], elems, rate_labels, orientation=:horizontal,
        framevisible=false, labelsize=LABEL_SIZE, nbanks=1)

    savefig(fig, "track2_bandwidth_impact")
end

# --- Figure 4: Per-host PUT balance (distributed) ---

function fig_per_host_put()
    ph = safe_read_csv("track2_distributed_put_per_host.csv")

    sizes = sort(unique(ph.size_str), by=size_index)
    hosts = sort(unique(ph.host))

    mat = zeros(length(hosts), length(sizes))
    for row in eachrow(ph)
        i = findfirst(==(row.host), hosts)
        j = findfirst(x -> x == row.size_str, sizes)
        mat[i, j] = row.mean_mibs
    end

    fig = Figure(size=(1000, 500), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        xlabel = "Storage Node",
        ylabel = "Object Size",
        xticks = (1:length(hosts), hosts),
        yticks = (1:length(sizes), sizes),
        xticklabelsize = TICK_SIZE,
        yticklabelsize = TICK_SIZE,
    )

    hm = heatmap!(ax, 1:length(hosts), 1:length(sizes), mat,
        colormap = :viridis,
        colorrange = (0, maximum(mat) * 1.05),
    )

    for i in 1:length(hosts), j in 1:length(sizes)
        val = round(mat[i, j], digits=0)
        text!(ax, i, j; text=string(Int(val)),
            align=(:center, :center),
            fontsize=LABEL_SIZE,
            color=mat[i, j] > maximum(mat) * 0.6 ? :white : :black,
        )
    end

    Colorbar(fig[1, 2], hm, label="MiB/s")
    savefig(fig, "track2_per_host_put")
end

# --- Figure 5: Per-host GET balance (distributed) ---

function fig_per_host_get()
    ph = safe_read_csv("track2_distributed_get_per_host.csv")

    sizes = sort(unique(ph.size_str), by=size_index)
    hosts = sort(unique(ph.host))

    mat = zeros(length(hosts), length(sizes))
    for row in eachrow(ph)
        i = findfirst(==(row.host), hosts)
        j = findfirst(x -> x == row.size_str, sizes)
        mat[i, j] = row.mean_mibs
    end

    fig = Figure(size=(1000, 500), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        xlabel = "Storage Node",
        ylabel = "Object Size",
        xticks = (1:length(hosts), hosts),
        yticks = (1:length(sizes), sizes),
        xticklabelsize = TICK_SIZE,
        yticklabelsize = TICK_SIZE,
    )

    hm = heatmap!(ax, 1:length(hosts), 1:length(sizes), mat,
        colormap = :viridis,
        colorrange = (0, maximum(mat) * 1.05),
    )

    for i in 1:length(hosts), j in 1:length(sizes)
        val = round(mat[i, j], digits=0)
        text!(ax, i, j; text=string(Int(val)),
            align=(:center, :center),
            fontsize=LABEL_SIZE,
            color=mat[i, j] > maximum(mat) * 0.6 ? :white : :black,
        )
    end

    Colorbar(fig[1, 2], hm, label="MiB/s")
    savefig(fig, "track2_per_host_get")
end

# --- Figure 6: Mixed workload GET/PUT breakdown ---

function fig_mixed_workload()
    mixed = safe_read_csv("track2_mixed_per_op.csv")

    sizes = sort(unique(mixed.size_str), by=size_index)

    fig = Figure(size=(1000, 727), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        ylabel = "Throughput (MiB/s)",
        xticks = (1:length(sizes), [size_label(s) for s in sizes]),
        xticklabelsize = TICK_SIZE,
    )

    width = 0.35
    for (oi, (op, colour, offset)) in enumerate([
        ("GET", MIXED_GET_COLOUR, -width/2),
        ("PUT", MIXED_PUT_COLOUR,  width/2),
    ])
        rows = filter(r -> r.op_type == op, mixed)
        sort!(rows, order(:size_str, by=size_index))
        xs = [Float64(size_index(r.size_str)) + offset for r in eachrow(rows)]

        barplot!(ax, xs, rows.mean_mibs,
            width=width, color=colour,
            strokewidth=0.5, strokecolor=:black,
            label=op)
        errorbars!(ax, xs, rows.mean_mibs, rows.std_mibs,
            whiskerwidth=6, color=:black)
    end

    Legend(fig[2, 1], ax, orientation=:horizontal, framevisible=false,
        labelsize=LABEL_SIZE, nbanks=1)

    savefig(fig, "track2_mixed_workload")
end

# --- Figure 7: Throttle efficiency ---

function fig_throttle_efficiency()
    summary = safe_read_csv("track2_summary.csv")

    throttled = filter(r -> r.experiment == "throttled", summary)
    sort!(throttled, [:operation, :size_bytes, :rate])

    rates = ["1gbps", "10gbps"]
    rate_labels_short = Dict("1gbps" => "1 Gbps", "10gbps" => "10 Gbps")
    rate_colours = Dict("1gbps" => OI.orange, "10gbps" => OI.skyblue)

    # Build x-axis labels dynamically from the data.
    ops_sizes = sort(unique(select(throttled, :operation, :size_str)),
                     [:operation, :size_str])
    # Ensure consistent ordering within each operation.
    op_size_pairs = [(r.operation, r.size_str) for r in eachrow(ops_sizes)]
    sort!(op_size_pairs, by = p -> (p[1] == "PUT" ? 2 : 1, size_index(p[2])))
    tick_labels = ["$(p[1])\n$(replace(p[2], "MiB"=>" MiB", "GiB"=>" GiB"))" for p in op_size_pairs]

    fig = Figure(size=(FIG_WIDTH, 507), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        ylabel = "Throughput (MiB/s)",
        xticks = (1:length(tick_labels), tick_labels),
        xticklabelsize = TICK_SIZE,
    )

    width = 0.35
    for (ri, rate) in enumerate(rates)
        colour = rate_colours[rate]
        offset = ri == 1 ? -width/2 : width/2

        ys = Float64[]
        es = Float64[]
        xs = Float64[]
        for (xi, (op, sz)) in enumerate(op_size_pairs)
            rows = filter(r -> r.rate == rate && r.operation == op && r.size_str == sz, throttled)
            if !isempty(rows)
                push!(xs, Float64(xi) + offset)
                push!(ys, first(rows).mean_mibs)
                push!(es, first(rows).std_mibs)
            end
        end

        barplot!(ax, xs, ys,
            width=width, color=colour,
            strokewidth=0.5, strokecolor=:black,
            label=rate_labels_short[rate])
        errorbars!(ax, xs, ys, es,
            whiskerwidth=6, color=:black)
    end

    Legend(fig[2, 1], ax, orientation=:horizontal, framevisible=false,
        labelsize=LABEL_SIZE, nbanks=1)

    savefig(fig, "track2_throttle_efficiency")
end

# --- Figure 8: TTFB by object size (GET operations) ---

function fig_ttfb()
    summary = safe_read_csv("track2_summary.csv")

    single_gets = filter(r -> r.experiment == "single" && r.operation == "GET" &&
                              r.rate == "100gbps" && !ismissing(r.mean_ttfb_ms), summary)
    dist_gets = filter(r -> r.experiment == "distributed" && r.operation == "GET" &&
                            r.rate == "100gbps" && !ismissing(r.mean_ttfb_ms), summary)
    sort!(single_gets, :size_bytes)
    sort!(dist_gets, :size_bytes)

    common_sizes = intersect(single_gets.size_str, dist_gets.size_str)
    ordered_sizes = filter(s -> s in common_sizes, SIZE_ORDER)

    fig = Figure(size=(FIG_WIDTH, FIG_HEIGHT), fontsize=FONT_SIZE)
    ax = Axis(fig[1, 1],
        ylabel = "TTFB (ms)",
        xticks = (1:length(ordered_sizes), [size_label(s) for s in ordered_sizes]),
        xticklabelsize = TICK_SIZE,
    )

    width = 0.35
    for (exp, colour, offset, label) in [
        ("single",      GET_LIGHT,  -width/2, "Single-client"),
        ("distributed", GET_COLOUR,  width/2, "Distributed"),
    ]
        rows = filter(r -> r.experiment == exp, exp == "single" ? single_gets : dist_gets)
        rows = filter(r -> r.size_str in common_sizes, rows)
        sort!(rows, :size_bytes)

        xs = [Float64(findfirst(x -> x == r.size_str, ordered_sizes)) + offset for r in eachrow(rows)]

        barplot!(ax, xs, rows.mean_ttfb_ms,
            width=width, color=colour,
            strokewidth=0.5, strokecolor=:black,
            label=label)
    end

    Legend(fig[2, 1], ax, orientation=:horizontal, framevisible=false,
        labelsize=LABEL_SIZE, nbanks=1)

    savefig(fig, "track2_ttfb")
end

# --- Main ---

function main()
    println("Track 2 MinIO Figures")
    println("=" ^ 60)
    println("Source: $RESULTS_DIR")
    println("Output: $FIGURES_DIR")
    println()

    println("Fig 1: Single vs Distributed throughput")
    fig_single_vs_distributed()

    println("Fig 2: Scaling factor")
    fig_scaling_factor()

    println("Fig 3: Bandwidth impact (100G / 10G / 1G)")
    fig_bandwidth_impact()

    println("Fig 4: Per-host PUT balance")
    fig_per_host_put()

    println("Fig 5: Per-host GET balance (post st06 fix)")
    fig_per_host_get()

    println("Fig 6: Mixed workload breakdown")
    fig_mixed_workload()

    println("Fig 7: Throttle efficiency")
    fig_throttle_efficiency()

    println("Fig 8: Time to First Byte")
    fig_ttfb()

    n_png = count(f -> endswith(f, ".png") && startswith(f, "track2_"), readdir(FIGURES_DIR))
    println("\nDone. $n_png Track 2 PNG + PDF pairs in $FIGURES_DIR")
end

main()
