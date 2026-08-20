# paper_values.jl
#
# Single source of truth for every numerical claim in the FGCS paper.
#
# Reads the CSVs under analysis/results/ and emits two artefacts:
#   - paper_values.json  : nested by section, one entry per claim_id with
#                          its value, unit, type, source, and draft status
#   - paper_values.csv   : flat rows (section, claim_id, value, unit, type,
#                          status, source) for spreadsheet review
#
# Every claim_id matches an entry in _fgcs_patches/patch_04_checklist/checklist.md.
# When the paper prose and a claim disagree, the paper is wrong.
#
# The script covers §5 (Network Fabric Characterisation), §6 (Object
# Storage and Data Access Evaluation), §8 (Discussion), and §9
# (Conclusion).
#
# Unit convention:
#   Every Claim value carries a unit string describing its dimension.
#   Measured magnitudes use SI-style units ("Gbps", "MiB/s", "ms", "%",
#   "GB/s", "s"). Counts use "count". Dimensionless ratios with a "N x"
#   presentation (e.g. 2.4x scaling, 78x range factor) use "x".
#   Dimensionless proportions presented as decimals or scientific notation
#   (e.g. 1.9e-10 error rate) use "ratio". Qualitative claims whose value
#   is a prose string or `nothing` use "narrative".
#
# Run from analysis/:
#   julia --project=. paper_values.jl
#
# The script is deterministic: two consecutive runs produce byte-identical
# paper_values.json and paper_values.csv.

using CSV, DataFrames, JSON3, Statistics, Printf

# --- Paths ---

const REPO_ROOT   = dirname(pwd())
const RESULTS_DIR = joinpath(pwd(), "results")

# --- Testbed constants (CONFIG) ---
#
# Properties of the deployment, not measurements. Changes here signal
# changes to the physical testbed, not to the analysis.

const BOND_CAPACITY_GBPS         = 400    # 4 ports x 100 Gbps per node, LACP-bonded
const N_PARALLEL_STREAMS         = 8      # iperf3 -P 8
const FM_THEORETICAL_GBPS        = 1200   # 3 app nodes x 400 Gbps (full-mesh upper bound)
const STST_THEORETICAL_GBPS      = 1600   # 4 x 400 Gbps (st-to-st 4->4 upper bound)
const R6525_MEMORY_BW_GBPS       = 51.2   # 2 x DDR4-3200 channels (25.6 GB/s each)
const R750_MEMORY_BW_GBPS        = 307.2  # 12 x DDR4-3200 channels
const R7615_MEMORY_BW_GBPS       = 153.6  # 4 x DDR5-4800 channels (38.4 GB/s each); deployed config per datacenter_info/rds_servers/hardware_lshw.txt (r05-rds03 block, A1-A4 populated)
const R7625_MEMORY_BW_GBPS       = 921.6  # 24 x DDR5-4800 channels (38.4 GB/s each); deployed config per datacenter_info/server_pool.md r04-rds02 block (12 DIMMs per socket, all channels populated). Chassis model confirmed as R7625 by out-of-band inspection (dual-socket Genoa class).
const R7625_CPU_MODEL            = "AMD EPYC 9634"  # 84-core Zen 4, 2 sockets on r04-rds02
const R7625_CPU_SOCKETS          = 2
const R7625_CPU_CORES_TOTAL      = 168
const R7625_MEMORY_TOTAL_GIB     = 1536
const R7625_DIMMS_POPULATED      = 24
const R7625_CHANNELS_POPULATED   = 24
const R6525_NPS                  = 4      # Nodes Per Socket (AMD EPYC NUMA partitioning)
const R6525_NUMA_NODES_TOTAL     = 8      # 2 sockets x NPS=4
const R6525_NUMA_NODES_POPULATED = 2      # only one DIMM per socket populated

# --- Claim record ---
#
# Every claim emitted by this script is represented as a Claim. The
# claims vector preserves insertion order, which drives JSON section
# nesting and CSV row order.

struct Claim
    section::String         # e.g. "5.2.table2"
    id::String              # e.g. "sec5_2_table2_perpair_aggregate_gbps_mean"
    value::Any              # Float64 | Int | String | nothing
    unit::String            # "Gbps", "MiB/s", "ms", "%", "count", "x", "ratio", "narrative"
    type::String            # DIRECT | DERIVED | CONFIG | NARRATIVE
    status::String          # OK | NARRATIVE | CONFIG
    source::String          # CSV file + filter description, or "config" for constants
    notes::String           # FGCS paper notes. Optional human context (empty by default).
    notes_connectivity::String  # Connectivity paper notes (empty by default).
    notes_dbcomparison::String  # Database comparison paper notes (empty by default).
end

Claim(section, id, value, unit, type, status, source) =
    Claim(section, id, value, unit, type, status, source, "", "", "")

Claim(section, id, value, unit, type, status, source, notes) =
    Claim(section, id, value, unit, type, status, source, notes, "", "")

# --- Load CSVs used by §5 ---

println("Loading Track 1 CSVs...")

const T1_RAW           = CSV.read(joinpath(RESULTS_DIR, "track1_throughput_raw.csv"), DataFrame)
const T1_AGG           = CSV.read(joinpath(RESULTS_DIR, "track1_aggregate_per_rep.csv"), DataFrame)
const T1_CROSS         = CSV.read(joinpath(RESULTS_DIR, "track1_throughput_cross_mode.csv"), DataFrame)
const T1_PERPAIR_PP    = CSV.read(joinpath(RESULTS_DIR, "track1_per_pair_per_pair.csv"), DataFrame)
const T1_STINBOUND_PP  = CSV.read(joinpath(RESULTS_DIR, "track1_st_inbound_per_pair.csv"), DataFrame)
const T1_FULLMESH_PP   = CSV.read(joinpath(RESULTS_DIR, "track1_full_mesh_per_pair.csv"), DataFrame)
const T1_STSTST_PP     = CSV.read(joinpath(RESULTS_DIR, "track1_st_to_st_per_pair.csv"), DataFrame)
const T1_PERPAIR_APP   = CSV.read(joinpath(RESULTS_DIR, "track1_per_pair_per_app.csv"), DataFrame)
const T1_STINBOUND_APP = CSV.read(joinpath(RESULTS_DIR, "track1_st_inbound_per_app.csv"), DataFrame)
const T1_APPOUT_APP    = CSV.read(joinpath(RESULTS_DIR, "track1_app_outbound_per_app.csv"), DataFrame)
const T1_FULLMESH_APP  = CSV.read(joinpath(RESULTS_DIR, "track1_full_mesh_per_app.csv"), DataFrame)
const T1_STSTST_APP    = CSV.read(joinpath(RESULTS_DIR, "track1_st_to_st_per_app.csv"), DataFrame)
const T1_STSTST_STORE  = CSV.read(joinpath(RESULTS_DIR, "track1_st_to_st_per_storage.csv"), DataFrame)
const T1_FANOUT_PP     = CSV.read(joinpath(RESULTS_DIR, "track1_rds02_fanout_per_pair.csv"), DataFrame)
const T1_FANOUT_APP    = CSV.read(joinpath(RESULTS_DIR, "track1_rds02_fanout_per_app.csv"), DataFrame)
const T1_LAT_BYCOND    = CSV.read(joinpath(RESULTS_DIR, "track1_latency_by_condition.csv"), DataFrame)
const T1_PACKETLOSS    = CSV.read(joinpath(RESULTS_DIR, "track1_packet_loss_summary.csv"), DataFrame)

# --- Load CSVs used by §6 ---

println("Loading Track 2 CSVs...")

const T2_SUMMARY       = CSV.read(joinpath(RESULTS_DIR, "track2_summary.csv"), DataFrame)
const T2_MIXED         = CSV.read(joinpath(RESULTS_DIR, "track2_mixed_per_op.csv"), DataFrame)
const T2_DIST_GET_HOST = CSV.read(joinpath(RESULTS_DIR, "track2_distributed_get_per_host.csv"), DataFrame)
const T2_DIST_PUT_HOST = CSV.read(joinpath(RESULTS_DIR, "track2_distributed_put_per_host.csv"), DataFrame)


# --- Helpers ---

"""
    agg_by_mode(mode)

Filter T1_AGG to a single mode and return its rows (one per rep). Errors
if no rows found, to surface typos in mode strings.
"""
function agg_by_mode(mode::String)
    rows = filter(r -> r.mode == mode, T1_AGG)
    @assert nrow(rows) > 0 "No rows in track1_aggregate_per_rep.csv for mode=$mode"
    return rows
end

"""
    raw_by_mode(mode)

Filter T1_RAW (per-(mode,rep,client,server) rows) to a single mode.
"""
function raw_by_mode(mode::String)
    rows = filter(r -> r.mode == mode, T1_RAW)
    @assert nrow(rows) > 0 "No rows in track1_throughput_raw.csv for mode=$mode"
    return rows
end

"""
    round1(x) / round3(x)

Formatting helpers. round1 for values reported to one decimal in the
paper (most Gbps cells); round3 for percentages and sub-Gbps values.
"""
round1(x) = round(x, digits=1)
round3(x) = round(x, digits=3)

"""
    summary_row(experiment, operation, rate, size_str)

Return the single row of T2_SUMMARY matching the given filter. Errors if
zero or multiple rows match -- the combination is meant to be unique.
"""
function summary_row(experiment::String, operation::String, rate::String, size_str::String)
    rows = filter(r ->
        r.experiment == experiment &&
        r.operation == operation &&
        r.rate == rate &&
        r.size_str == size_str,
        T2_SUMMARY)
    @assert nrow(rows) == 1 "track2_summary.csv: expected 1 row for ($experiment, $operation, $rate, $size_str), got $(nrow(rows))"
    return rows[1, :]
end

"""
    mixed_row(size_str, op_type)

Return the single row of T2_MIXED matching the given filter.
"""
function mixed_row(size_str::String, op_type::String)
    rows = filter(r -> r.size_str == size_str && r.op_type == op_type, T2_MIXED)
    @assert nrow(rows) == 1 "track2_mixed_per_op.csv: expected 1 row for ($size_str, $op_type), got $(nrow(rows))"
    return rows[1, :]
end

"""
    per_host_rows(frame, size_str)

Return all per-host rows for a given object size, sorted by host for
deterministic iteration.
"""
function per_host_rows(frame::DataFrame, size_str::String)
    rows = filter(r -> r.size_str == size_str, frame)
    @assert nrow(rows) == 8 "Expected 8 host rows for size=$size_str, got $(nrow(rows))"
    return sort(rows, :host)
end

"""
    transfer_ms(size_bytes, mibs)

Time in milliseconds to transfer `size_bytes` at `mibs` MiB/s.
"""
transfer_ms(size_bytes::Integer, mibs::Real) = 1000 * (size_bytes / (1024^2)) / mibs

# --- §6 iteration conventions (deterministic order) ---

const SIZES_100G      = ("4MiB", "64MiB", "512MiB", "2GiB")
const SIZES_THROTTLED = ("4MiB", "64MiB", "512MiB")  # no 2 GiB at throttled rates
const OPS             = ("PUT", "GET")
const THROTTLED_RATES = ("10gbps", "1gbps")
const SIZE_BYTES = Dict(
    "4MiB"   => 4 * 1024^2,
    "64MiB"  => 64 * 1024^2,
    "512MiB" => 512 * 1024^2,
    "2GiB"   => 2 * 1024^3,
)

# --- §5 canonical values ---

println("Computing canonical values...")

# Per-rep totals summed across pairs, then mean/std across reps
const canonical_perpair_total_gbps_mean   = mean(agg_by_mode("per-pair").total_gbps)
const canonical_perpair_total_gbps_std    = std(agg_by_mode("per-pair").total_gbps)
const canonical_stinbound_total_gbps_mean = mean(agg_by_mode("st-inbound").total_gbps)
const canonical_stinbound_total_gbps_std  = std(agg_by_mode("st-inbound").total_gbps)
const canonical_appout_total_gbps_mean    = mean(agg_by_mode("app-outbound").total_gbps)
const canonical_appout_total_gbps_std     = std(agg_by_mode("app-outbound").total_gbps)
const canonical_fullmesh_total_gbps_mean  = mean(agg_by_mode("full-mesh").total_gbps)
const canonical_fullmesh_total_gbps_std   = std(agg_by_mode("full-mesh").total_gbps)
const canonical_ststst_total_gbps_mean    = mean(agg_by_mode("st-to-st").total_gbps)
const canonical_ststst_total_gbps_std     = std(agg_by_mode("st-to-st").total_gbps)

const canonical_fullmesh_pct_of_theoretical = 100 * canonical_fullmesh_total_gbps_mean / FM_THEORETICAL_GBPS
const canonical_ststst_pct_of_theoretical   = 100 * canonical_ststst_total_gbps_mean / STST_THEORETICAL_GBPS

# Full-mesh per-pair degradation statistics from cross-mode CSV
const canonical_fullmesh_degradation_mean_pct = mean(T1_CROSS.degradation_pct)
const canonical_fullmesh_degradation_min_pct  = minimum(T1_CROSS.degradation_pct)
const canonical_fullmesh_degradation_max_pct  = maximum(T1_CROSS.degradation_pct)

# R6525 per-node throughput under full-mesh (srv01/srv02/srv03)
const canonical_r6525_per_node_min_gbps  = minimum(T1_FULLMESH_APP.mean_total_gbps)
const canonical_r6525_per_node_max_gbps  = maximum(T1_FULLMESH_APP.mean_total_gbps)
const canonical_r6525_per_node_mean_gbps = mean(T1_FULLMESH_APP.mean_total_gbps)
const canonical_r6525_per_node_pct       = 100 * canonical_r6525_per_node_mean_gbps / BOND_CAPACITY_GBPS

# R750 per-node throughput under st-to-st (per-app view = client side)
const canonical_r750_app_min_gbps  = minimum(T1_STSTST_APP.mean_total_gbps)
const canonical_r750_app_max_gbps  = maximum(T1_STSTST_APP.mean_total_gbps)
const canonical_r750_app_mean_gbps = mean(T1_STSTST_APP.mean_total_gbps)
const canonical_r750_app_pct_min   = 100 * canonical_r750_app_min_gbps / BOND_CAPACITY_GBPS
const canonical_r750_app_pct_max   = 100 * canonical_r750_app_max_gbps / BOND_CAPACITY_GBPS

# R750 per-node throughput (per-storage view = server side)
const canonical_r750_store_min_gbps = minimum(T1_STSTST_STORE.mean_total_gbps)
const canonical_r750_store_max_gbps = maximum(T1_STSTST_STORE.mean_total_gbps)

# r04-rds02 fan-out canonicals: aggregate, % of sender bond, per-target balance.
# The fan-out mode has client=rds02, one row per storage target, so the per-pair
# summary CSV (8 rows) is the per-target view. Per-app CSV (1 row) provides the
# aggregate mean and std across reps.
const canonical_rds02_fanout_aggregate_gbps_mean = T1_FANOUT_APP.mean_total_gbps[1]
const canonical_rds02_fanout_aggregate_gbps_std  = T1_FANOUT_APP.std_total_gbps[1]
const canonical_rds02_fanout_pct_of_bond         = 100 * canonical_rds02_fanout_aggregate_gbps_mean / BOND_CAPACITY_GBPS
const canonical_rds02_fanout_target_mean_gbps    = mean(T1_FANOUT_PP.mean_gbps)
const canonical_rds02_fanout_target_min_gbps     = minimum(T1_FANOUT_PP.mean_gbps)
const canonical_rds02_fanout_target_max_gbps     = maximum(T1_FANOUT_PP.mean_gbps)
const canonical_rds02_fanout_target_cv_pct       = 100 * std(T1_FANOUT_PP.mean_gbps) / mean(T1_FANOUT_PP.mean_gbps)
const canonical_rds02_fanout_total_retransmits   = round(Int, T1_FANOUT_APP.mean_retransmits[1])

# Per-pair range across 24 pairs (§5.2 prose)
const canonical_perpair_pair_min_gbps = minimum(T1_PERPAIR_PP.mean_gbps)
const canonical_perpair_pair_max_gbps = maximum(T1_PERPAIR_PP.mean_gbps)

# Per-app aggregate mean throughput by mode (Table 5 "throughput per node")
const canonical_perpair_perapp_mean   = mean(T1_PERPAIR_APP.mean_total_gbps)
const canonical_stinbound_perapp_mean = mean(T1_STINBOUND_APP.mean_total_gbps)
const canonical_appout_perapp_mean    = mean(T1_APPOUT_APP.mean_total_gbps)
const canonical_ststst_perapp_mean    = mean(T1_STSTST_APP.mean_total_gbps)

# Packet loss: errors are per-campaign totals in the CSV (sum across 3 reps).
# Packets are per-rep means -- to get the campaign denominator we multiply
# by n_reps. The assertion below guards against a future re-run with a
# different rep count silently invalidating the campaign total.
const canonical_total_rx_errors = sum(T1_PACKETLOSS.total_rx_errors)
const canonical_total_tx_errors = sum(T1_PACKETLOSS.total_tx_errors)
const canonical_total_errors    = canonical_total_rx_errors + canonical_total_tx_errors

@assert all(T1_PACKETLOSS.n_reps .== T1_PACKETLOSS.n_reps[1]) "Packet-loss n_reps varies across hosts; campaign total needs per-host accounting"
const canonical_n_reps_packetloss = T1_PACKETLOSS.n_reps[1]
const canonical_packets_per_run   = sum(T1_PACKETLOSS.mean_rx_packets) + sum(T1_PACKETLOSS.mean_tx_packets)
const canonical_total_packets     = canonical_packets_per_run * canonical_n_reps_packetloss
const canonical_error_rate        = canonical_total_errors / canonical_total_packets

# --- §6 canonical values ---
#
# Cross-section anchors cited by §6 prose, §8, and §9.

# Distributed 512 MiB GET mean throughput (post rep 1 exclusion; the CSV
# cell already reflects the exclusion per commit c85f40b).
const canonical_distributed_512mib_get_mean_mibs =
    summary_row("distributed", "GET", "100gbps", "512MiB").mean_mibs

# 512 MiB transfer times at the three rate points.
const canonical_512mib_transfer_100g_ms = transfer_ms(
    SIZE_BYTES["512MiB"], canonical_distributed_512mib_get_mean_mibs)
const canonical_512mib_transfer_10g_ms  = transfer_ms(
    SIZE_BYTES["512MiB"], summary_row("throttled", "GET", "10gbps", "512MiB").mean_mibs)
const canonical_512mib_transfer_1g_ms   = transfer_ms(
    SIZE_BYTES["512MiB"], summary_row("throttled", "GET", "1gbps",  "512MiB").mean_mibs)
const canonical_512mib_transfer_1g_s    = canonical_512mib_transfer_1g_ms / 1000

# Range factor cited in §8: 1 Gbps transfer time / 100 Gbps transfer time.
const canonical_throttled_range_factor =
    canonical_512mib_transfer_1g_ms / canonical_512mib_transfer_100g_ms

# §6.3 PUT uniformity: spread = (max - min) / min per object size, pct.
# The checklist prose range "20-38%" excludes the 4 MiB case (near-uniform).
function put_spread_pct(size_str::String)
    rows = per_host_rows(T2_DIST_PUT_HOST, size_str)
    mn, mx = extrema(rows.mean_mibs)
    return 100 * (mx - mn) / mn
end

# §6.3 GET uniformity: spread = (max - min) / min per object size, pct.
# Parallel structure to put_spread_pct above. Post-fix (cubic-vs-BBR
# remediated 2026-05-08, #25/#36), the per-host GET distribution is
# the quantitative basis for the §6.3 prose claim that the former
# tier-shaped asymmetry has collapsed.
function get_spread_pct(size_str::String)
    rows = per_host_rows(T2_DIST_GET_HOST, size_str)
    mn, mx = extrema(rows.mean_mibs)
    return 100 * (mx - mn) / mn
end

const canonical_put_spread_4mib   = put_spread_pct("4MiB")
const canonical_put_spread_64mib  = put_spread_pct("64MiB")
const canonical_put_spread_512mib = put_spread_pct("512MiB")
const canonical_put_spread_2gib   = put_spread_pct("2GiB")

const canonical_get_spread_4mib   = get_spread_pct("4MiB")
const canonical_get_spread_64mib  = get_spread_pct("64MiB")
const canonical_get_spread_512mib = get_spread_pct("512MiB")
const canonical_get_spread_2gib   = get_spread_pct("2GiB")

# §6.3 GET spread range: no exclusions. Unlike the PUT case, no single
# GET size has a structurally separable spread that would justify
# excluding it from the range claim. Reported as 7-20% in §6.3 prose.
const canonical_get_spread_range_min_pct = minimum((
    canonical_get_spread_4mib, canonical_get_spread_64mib,
    canonical_get_spread_512mib, canonical_get_spread_2gib))
const canonical_get_spread_range_max_pct = maximum((
    canonical_get_spread_4mib, canonical_get_spread_64mib,
    canonical_get_spread_512mib, canonical_get_spread_2gib))

const canonical_put_spread_range_min_pct = minimum((
    canonical_put_spread_64mib, canonical_put_spread_512mib, canonical_put_spread_2gib))
const canonical_put_spread_range_max_pct = maximum((
    canonical_put_spread_64mib, canonical_put_spread_512mib, canonical_put_spread_2gib))

# --- Internal consistency checks ---
#
# If any canonical value disagrees with a claim it feeds, the script
# aborts. "Paper cannot drift" backstop.

@assert isapprox(canonical_fullmesh_pct_of_theoretical, 44.08, atol=0.05) "Fullmesh pct drifted: $canonical_fullmesh_pct_of_theoretical"
@assert isapprox(canonical_ststst_pct_of_theoretical,   86.16, atol=0.05) "St-to-st pct drifted: $canonical_ststst_pct_of_theoretical"
@assert isapprox(canonical_r6525_per_node_pct,          44.1,  atol=0.2)  "R6525 pct drifted: $canonical_r6525_per_node_pct"
@assert canonical_total_errors == 3 "Packet-loss error count changed: $canonical_total_errors"
@assert isapprox(canonical_total_packets, canonical_packets_per_run * canonical_n_reps_packetloss; rtol=1e-12) "Campaign-total multiplication drift"

@assert isapprox(canonical_distributed_512mib_get_mean_mibs, 17945.85, atol=0.1) "Distributed 512 MiB GET mean drifted: $canonical_distributed_512mib_get_mean_mibs"
@assert isapprox(canonical_512mib_transfer_100g_ms, 28.54, atol=0.05) "512 MiB 100G transfer drifted: $canonical_512mib_transfer_100g_ms ms"
@assert isapprox(canonical_512mib_transfer_1g_s,    2.26,  atol=0.02) "512 MiB 1G transfer drifted: $canonical_512mib_transfer_1g_s s"
@assert round(Int, canonical_throttled_range_factor) == 79 "Throttled range factor drifted: $canonical_throttled_range_factor"

# Post-fix expected values (#25 resolution, 2026-05-08): pre-fix
# range was 20-38% across 64 MiB / 512 MiB / 2 GiB; post-fix is 4-9%.
@assert round(Int, canonical_put_spread_range_min_pct) == 4 "PUT spread range min drifted: $canonical_put_spread_range_min_pct"
@assert round(Int, canonical_put_spread_range_max_pct) == 9 "PUT spread range max drifted: $canonical_put_spread_range_max_pct"

# Post-fix GET spread (cubic-vs-BBR remediated #25/#36, 2026-05-08):
# 7.3, 12.4, 17.3, 19.5 percent across 2 GiB, 4 MiB, 64 MiB, 512 MiB.
# No tier shape; range reported as 7-20% in §6.3 prose.
@assert round(Int, canonical_get_spread_range_min_pct) == 7 "GET spread range min drifted: $canonical_get_spread_range_min_pct"
@assert round(Int, canonical_get_spread_range_max_pct) == 20 "GET spread range max drifted: $canonical_get_spread_range_max_pct"

# --- Emit §5 claims ---

claims = Claim[]

# =====================================================================
# §5.2 Throughput — Table 2
# =====================================================================

push!(claims, Claim("5.2.table2", "sec5_2_table2_perpair_aggregate_gbps_mean",
    round1(canonical_perpair_total_gbps_mean), "Gbps", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=per-pair, mean(total_gbps)"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_perpair_aggregate_gbps_std",
    round1(canonical_perpair_total_gbps_std), "Gbps", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=per-pair, std(total_gbps)"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_perpair_perpair_mean_gbps",
    round1(mean(T1_PERPAIR_PP.mean_gbps)), "Gbps", "DERIVED", "OK",
    "track1_per_pair_per_pair.csv, mean(mean_gbps) across 24 pairs"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_perpair_retransmits",
    round(Int, mean(agg_by_mode("per-pair").total_retransmits)), "count", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=per-pair, mean(total_retransmits) rounded"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_stinbound_aggregate_gbps_mean",
    round1(canonical_stinbound_total_gbps_mean), "Gbps", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=st-inbound, mean(total_gbps)"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_stinbound_aggregate_gbps_std",
    round1(canonical_stinbound_total_gbps_std), "Gbps", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=st-inbound, std(total_gbps)"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_stinbound_perpair_mean_gbps",
    round1(mean(T1_STINBOUND_PP.mean_gbps)), "Gbps", "DERIVED", "OK",
    "track1_st_inbound_per_pair.csv, mean(mean_gbps) across 24 pairs"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_stinbound_retransmits",
    round(Int, mean(agg_by_mode("st-inbound").total_retransmits)), "count", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=st-inbound, mean(total_retransmits) rounded"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_appoutbound_aggregate_gbps_mean",
    round1(canonical_appout_total_gbps_mean), "Gbps", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=app-outbound, mean(total_gbps)"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_appoutbound_aggregate_gbps_std",
    round1(canonical_appout_total_gbps_std), "Gbps", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=app-outbound, std(total_gbps)"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_appoutbound_retransmits",
    round(Int, mean(agg_by_mode("app-outbound").total_retransmits)), "count", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=app-outbound, mean(total_retransmits) rounded"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_fullmesh_aggregate_gbps_mean",
    round1(canonical_fullmesh_total_gbps_mean), "Gbps", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=full-mesh, mean(total_gbps)"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_fullmesh_aggregate_gbps_std",
    round1(canonical_fullmesh_total_gbps_std), "Gbps", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=full-mesh, std(total_gbps)"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_fullmesh_perpair_mean_gbps",
    round1(mean(T1_FULLMESH_PP.mean_gbps)), "Gbps", "DERIVED", "OK",
    "track1_full_mesh_per_pair.csv, mean(mean_gbps) across 24 pairs"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_fullmesh_retransmits",
    round(Int, mean(agg_by_mode("full-mesh").total_retransmits)), "count", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=full-mesh, mean(total_retransmits) rounded"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_ststst_aggregate_gbps_mean",
    round1(canonical_ststst_total_gbps_mean), "Gbps", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=st-to-st, mean(total_gbps)"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_ststst_aggregate_gbps_std",
    round1(canonical_ststst_total_gbps_std), "Gbps", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=st-to-st, std(total_gbps)"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_ststst_perpair_mean_gbps",
    round1(mean(T1_STSTST_PP.mean_gbps)), "Gbps", "DERIVED", "OK",
    "track1_st_to_st_per_pair.csv, mean(mean_gbps) across 16 pairs"))

push!(claims, Claim("5.2.table2", "sec5_2_table2_ststst_retransmits",
    round(Int, mean(agg_by_mode("st-to-st").total_retransmits)), "count", "DERIVED", "OK",
    "track1_aggregate_per_rep.csv, mode=st-to-st, mean(total_retransmits) rounded"))

# =====================================================================
# §5.2 Throughput — prose
# =====================================================================

push!(claims, Claim("5.2.prose", "sec5_2_prose_perpair_range_min_gbps",
    round1(canonical_perpair_pair_min_gbps), "Gbps", "DERIVED", "OK",
    "track1_per_pair_per_pair.csv, min(mean_gbps)"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_perpair_range_max_gbps",
    round1(canonical_perpair_pair_max_gbps), "Gbps", "DERIVED", "OK",
    "track1_per_pair_per_pair.csv, max(mean_gbps)"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_st04_bios_gbps",
    84, "Gbps", "NARRATIVE", "NARRATIVE",
    "pre-fix historical anomaly; not in current CSVs"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_fullmesh_theoretical_pct",
    round1(canonical_fullmesh_pct_of_theoretical), "%", "DERIVED", "OK",
    "canonical_fullmesh_total_gbps_mean / FM_THEORETICAL_GBPS"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_fullmesh_degradation_mean_pct",
    round1(canonical_fullmesh_degradation_mean_pct), "%", "DERIVED", "OK",
    "track1_throughput_cross_mode.csv, mean(degradation_pct)"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_fullmesh_degradation_min_pct",
    round1(canonical_fullmesh_degradation_min_pct), "%", "DERIVED", "OK",
    "track1_throughput_cross_mode.csv, min(degradation_pct)"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_fullmesh_degradation_max_pct",
    round1(canonical_fullmesh_degradation_max_pct), "%", "DERIVED", "OK",
    "track1_throughput_cross_mode.csv, max(degradation_pct)"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_ststst_theoretical_pct",
    round1(canonical_ststst_pct_of_theoretical), "%", "DERIVED", "OK",
    "canonical_ststst_total_gbps_mean / STST_THEORETICAL_GBPS"))

# R750 per-node ranges: both views (per-app and per-storage).
push!(claims, Claim("5.2.prose", "sec5_2_prose_r750_perapp_min_gbps",
    round1(canonical_r750_app_min_gbps), "Gbps", "DERIVED", "OK",
    "track1_st_to_st_per_app.csv, min(mean_total_gbps)",
    "Per-app view (client side) min."))

push!(claims, Claim("5.2.prose", "sec5_2_prose_r750_perapp_max_gbps",
    round1(canonical_r750_app_max_gbps), "Gbps", "DERIVED", "OK",
    "track1_st_to_st_per_app.csv, max(mean_total_gbps)",
    "Per-app view (client side) max."))

push!(claims, Claim("5.2.prose", "sec5_2_prose_r750_perstore_min_gbps",
    round1(canonical_r750_store_min_gbps), "Gbps", "DERIVED", "OK",
    "track1_st_to_st_per_storage.csv, min(mean_total_gbps)",
    "Per-storage view (server side) min."))

push!(claims, Claim("5.2.prose", "sec5_2_prose_r750_perstore_max_gbps",
    round1(canonical_r750_store_max_gbps), "Gbps", "DERIVED", "OK",
    "track1_st_to_st_per_storage.csv, max(mean_total_gbps)",
    "Per-storage view (server side) max."))

push!(claims, Claim("5.2.prose", "sec5_2_prose_r750_perapp_pct_min",
    round1(canonical_r750_app_pct_min), "%", "DERIVED", "OK",
    "canonical_r750_app_min_gbps / BOND_CAPACITY_GBPS"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_r750_perapp_pct_max",
    round1(canonical_r750_app_pct_max), "%", "DERIVED", "OK",
    "canonical_r750_app_max_gbps / BOND_CAPACITY_GBPS"))

# R6525 per-node range and mean under full-mesh.
# Draft says '~170 Gbps (43%)'; correct is '168-192 Gbps, mean 176 (44%)'.
push!(claims, Claim("5.2.prose", "sec5_2_prose_r6525_per_node_min_gbps",
    round1(canonical_r6525_per_node_min_gbps), "Gbps", "DERIVED", "OK",
    "track1_full_mesh_per_app.csv, min(mean_total_gbps)"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_r6525_per_node_max_gbps",
    round1(canonical_r6525_per_node_max_gbps), "Gbps", "DERIVED", "OK",
    "track1_full_mesh_per_app.csv, max(mean_total_gbps)"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_r6525_per_node_mean_gbps",
    round1(canonical_r6525_per_node_mean_gbps), "Gbps", "DERIVED", "OK",
    "track1_full_mesh_per_app.csv, mean(mean_total_gbps)"))

push!(claims, Claim("5.2.prose", "sec5_2_prose_r6525_per_node_pct",
    round1(canonical_r6525_per_node_pct), "%", "DERIVED", "OK",
    "canonical_r6525_per_node_mean_gbps / BOND_CAPACITY_GBPS"))

# =====================================================================
# §5.3 Throughput Stability — Table 3
# =====================================================================

for mode in ("per-pair", "st-inbound", "app-outbound", "full-mesh", "st-to-st")
    rows = raw_by_mode(mode)
    mode_id = replace(mode, "-" => "")
    push!(claims, Claim("5.3.table3",
        "sec5_3_table3_$(mode_id)_cv_mean",
        round(mean(rows.cv_pct), digits=2), "%", "DIRECT", "OK",
        "track1_throughput_raw.csv, mode=$mode, mean(cv_pct)"))
    push!(claims, Claim("5.3.table3",
        "sec5_3_table3_$(mode_id)_cv_worst",
        round(maximum(rows.cv_pct), digits=2), "%", "DIRECT", "OK",
        "track1_throughput_raw.csv, mode=$mode, max(cv_pct)"))
end

push!(claims, Claim("5.3.prose", "sec5_3_prose_60s_regime_change",
    nothing, "narrative", "NARRATIVE", "NARRATIVE",
    "Figure 5 panel 3 observation; qualitative claim, not a CSV cell"))

# =====================================================================
# §5.4 Stream Balance — Table 4
# =====================================================================

for mode in ("per-pair", "st-inbound", "st-to-st", "app-outbound", "full-mesh")
    rows = raw_by_mode(mode)
    mode_id = replace(mode, "-" => "")
    push!(claims, Claim("5.4.table4",
        "sec5_4_table4_$(mode_id)_streamcv_mean",
        round(mean(rows.stream_cv_pct), digits=2), "%", "DIRECT", "OK",
        "track1_throughput_raw.csv, mode=$mode, mean(stream_cv_pct)"))
    push!(claims, Claim("5.4.table4",
        "sec5_4_table4_$(mode_id)_streamcv_worst",
        round(maximum(rows.stream_cv_pct), digits=2), "%", "DIRECT", "OK",
        "track1_throughput_raw.csv, mode=$mode, max(stream_cv_pct)"))
end

push!(claims, Claim("5.4.prose", "sec5_4_prose_perpair_stream_gbps_approx",
    round1(mean(T1_PERPAIR_PP.mean_gbps) / N_PARALLEL_STREAMS), "Gbps", "DERIVED", "OK",
    "mean(perpair_mean_gbps) / N_PARALLEL_STREAMS"))

push!(claims, Claim("5.4.prose", "sec5_4_prose_fullmesh_stream_range_qualitative",
    "some streams carry 5-6 Gbps while others receive less than 1 Gbps",
    "narrative", "NARRATIVE", "NARRATIVE",
    "track1_per_stream.csv, mode=full-mesh; qualitative summary of distribution"))

# =====================================================================
# §5.5 CPU, Memory, NUMA — Table 5
# =====================================================================

for mode in ("per-pair", "st-inbound", "st-to-st", "app-outbound", "full-mesh")
    rows = raw_by_mode(mode)
    mode_id = replace(mode, "-" => "")
    push!(claims, Claim("5.5.table5",
        "sec5_5_table5_$(mode_id)_cpu_mean",
        round1(mean(rows.host_cpu_total)), "%", "DIRECT", "OK",
        "track1_throughput_raw.csv, mode=$mode, mean(host_cpu_total)"))
    push!(claims, Claim("5.5.table5",
        "sec5_5_table5_$(mode_id)_cpu_std",
        round1(std(rows.host_cpu_total)), "%", "DIRECT", "OK",
        "track1_throughput_raw.csv, mode=$mode, std(host_cpu_total)"))
end

push!(claims, Claim("5.5.table5", "sec5_5_table5_perpair_throughput_per_node",
    round1(canonical_perpair_perapp_mean), "Gbps", "DERIVED", "OK",
    "track1_per_pair_per_app.csv, mean(mean_total_gbps)"))

push!(claims, Claim("5.5.table5", "sec5_5_table5_stinbound_throughput_per_node",
    round1(canonical_stinbound_perapp_mean), "Gbps", "DERIVED", "OK",
    "track1_st_inbound_per_app.csv, mean(mean_total_gbps)"))

push!(claims, Claim("5.5.table5", "sec5_5_table5_ststst_throughput_per_node",
    round1(canonical_ststst_perapp_mean), "Gbps", "DERIVED", "OK",
    "track1_st_to_st_per_app.csv, mean(mean_total_gbps)"))

push!(claims, Claim("5.5.table5", "sec5_5_table5_appoutbound_throughput_per_node",
    round1(canonical_appout_perapp_mean), "Gbps", "DERIVED", "OK",
    "track1_app_outbound_per_app.csv, mean(mean_total_gbps)"))

push!(claims, Claim("5.5.table5", "sec5_5_table5_fullmesh_throughput_per_node",
    round1(canonical_r6525_per_node_mean_gbps), "Gbps", "DERIVED", "OK",
    "track1_full_mesh_per_app.csv, mean(mean_total_gbps); same as canonical_r6525_per_node_mean_gbps"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r6525_nps",
    R6525_NPS, "count", "CONFIG", "CONFIG",
    "hardware configuration: NPS=4 on R6525"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r6525_numa_nodes_total",
    R6525_NUMA_NODES_TOTAL, "count", "CONFIG", "CONFIG",
    "2 sockets x NPS=4"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r6525_numa_nodes_populated",
    R6525_NUMA_NODES_POPULATED, "count", "CONFIG", "CONFIG",
    "only 1 DIMM per socket populated on the current R6525 configuration"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r6525_memory_bw_gbps",
    R6525_MEMORY_BW_GBPS, "GB/s", "CONFIG", "CONFIG",
    "2 x DDR4-3200 channels at 25.6 GB/s each"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r6525_43pct_bond",
    round1(canonical_r6525_per_node_pct), "%", "DERIVED", "OK",
    "canonical_r6525_per_node_pct"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r750_memory_bw_gbps",
    R750_MEMORY_BW_GBPS, "GB/s", "CONFIG", "CONFIG",
    "12 x DDR4-3200 channels at 25.6 GB/s each"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r750_86pct_bond",
    round1(canonical_ststst_pct_of_theoretical), "%", "DERIVED", "OK",
    "canonical_ststst_pct_of_theoretical (86% of 1600 theoretical)"))

push!(claims, Claim("5.5.table5a", "sec5_5_table5a_r7615_memory_bw_gbps",
    R7615_MEMORY_BW_GBPS, "GB/s", "CONFIG", "CONFIG",
    "4 x DDR5-4800 channels at 38.4 GB/s each"))

# §5.5 Table 5b: r04-rds02 hardware (R7625, dual EPYC 9634, DDR5-4800 24-channel)
# Source: datacenter_info/server_pool.md (r04-rds02 block).
push!(claims, Claim("5.5.table5b", "sec5_5_table5b_r7625_cpu_model",
    R7625_CPU_MODEL, "narrative", "CONFIG", "CONFIG",
    "config: R7625_CPU_MODEL; per datacenter_info/server_pool.md r04-rds02 block"))

push!(claims, Claim("5.5.table5b", "sec5_5_table5b_r7625_cpu_sockets",
    R7625_CPU_SOCKETS, "count", "CONFIG", "CONFIG",
    "config: R7625_CPU_SOCKETS"))

push!(claims, Claim("5.5.table5b", "sec5_5_table5b_r7625_cpu_cores_total",
    R7625_CPU_CORES_TOTAL, "count", "CONFIG", "CONFIG",
    "config: R7625_CPU_CORES_TOTAL (2 sockets x 84 cores)"))

push!(claims, Claim("5.5.table5b", "sec5_5_table5b_r7625_memory_total_gib",
    R7625_MEMORY_TOTAL_GIB, "GiB", "CONFIG", "CONFIG",
    "config: R7625_MEMORY_TOTAL_GIB (24 x 64 GiB DDR5-4800)"))

push!(claims, Claim("5.5.table5b", "sec5_5_table5b_r7625_dimms_populated",
    R7625_DIMMS_POPULATED, "count", "CONFIG", "CONFIG",
    "config: R7625_DIMMS_POPULATED"))

push!(claims, Claim("5.5.table5b", "sec5_5_table5b_r7625_channels_populated",
    R7625_CHANNELS_POPULATED, "count", "CONFIG", "CONFIG",
    "config: R7625_CHANNELS_POPULATED (12 channels/socket x 2 sockets)"))

push!(claims, Claim("5.5.table5b", "sec5_5_table5b_r7625_memory_bw_gbps",
    R7625_MEMORY_BW_GBPS, "GB/s", "CONFIG", "CONFIG",
    "24 x DDR5-4800 channels at 38.4 GB/s each"))

push!(claims, Claim("5.5.table5b", "sec5_5_table5b_r7625_bond_capacity_gbps",
    BOND_CAPACITY_GBPS, "Gbps", "CONFIG", "CONFIG",
    "config: BOND_CAPACITY_GBPS (shared across all hosts in the testbed)"))

# §5.5 prose: fan-out measured aggregate and per-target balance.
push!(claims, Claim("5.5.prose", "sec5_5_prose_r7625_fanout_aggregate_gbps_mean",
    round1(canonical_rds02_fanout_aggregate_gbps_mean), "Gbps", "DERIVED", "OK",
    "track1_rds02_fanout_per_app.csv, mean_total_gbps (sum across 8 targets per rep, mean across 3 reps)"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r7625_fanout_aggregate_gbps_std",
    round1(canonical_rds02_fanout_aggregate_gbps_std), "Gbps", "DERIVED", "OK",
    "track1_rds02_fanout_per_app.csv, std_total_gbps"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r7625_fanout_pct_of_bond",
    round1(canonical_rds02_fanout_pct_of_bond), "%", "DERIVED", "OK",
    "canonical_rds02_fanout_aggregate_gbps_mean / BOND_CAPACITY_GBPS"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r7625_fanout_target_mean_gbps",
    round1(canonical_rds02_fanout_target_mean_gbps), "Gbps", "DERIVED", "OK",
    "track1_rds02_fanout_per_pair.csv, mean(mean_gbps) across 8 targets"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r7625_fanout_target_min_gbps",
    round1(canonical_rds02_fanout_target_min_gbps), "Gbps", "DERIVED", "OK",
    "track1_rds02_fanout_per_pair.csv, min(mean_gbps) across 8 targets"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r7625_fanout_target_max_gbps",
    round1(canonical_rds02_fanout_target_max_gbps), "Gbps", "DERIVED", "OK",
    "track1_rds02_fanout_per_pair.csv, max(mean_gbps) across 8 targets"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r7625_fanout_target_cv_pct",
    round(canonical_rds02_fanout_target_cv_pct, digits=2), "%", "DERIVED", "OK",
    "std(per_target_mean_gbps) / mean(per_target_mean_gbps) * 100 across 8 targets"))

push!(claims, Claim("5.5.prose", "sec5_5_prose_r7625_fanout_total_retransmits",
    canonical_rds02_fanout_total_retransmits, "count", "DERIVED", "OK",
    "track1_rds02_fanout_per_app.csv, mean_retransmits rounded"))

# =====================================================================
# §5.6 Latency — Table 6
# =====================================================================

for cond in ("idle", "50pct", "100pct")
    rows = filter(r -> r.condition == cond, T1_LAT_BYCOND)
    @assert nrow(rows) == 1 "Expected 1 row for condition=$cond in track1_latency_by_condition.csv"
    r = rows[1, :]
    push!(claims, Claim("5.6.table6",
        "sec5_6_table6_$(cond)_mean_ms",
        round(r.overall_mean_ms, digits=3), "ms", "DIRECT", "OK",
        "track1_latency_by_condition.csv, condition=$cond, overall_mean_ms"))
    push!(claims, Claim("5.6.table6",
        "sec5_6_table6_$(cond)_p95_ms",
        round(r.overall_p95_ms, digits=3), "ms", "DIRECT", "OK",
        "track1_latency_by_condition.csv, condition=$cond, overall_p95_ms"))
    push!(claims, Claim("5.6.table6",
        "sec5_6_table6_$(cond)_max_ms",
        round(r.worst_max_ms, digits=2), "ms", "DIRECT", "OK",
        "track1_latency_by_condition.csv, condition=$cond, worst_max_ms"))
end

# =====================================================================
# §5.7 Packet Loss
# =====================================================================

push!(claims, Claim("5.7.prose", "sec5_7_prose_total_rx_errors",
    canonical_total_rx_errors, "count", "DIRECT", "OK",
    "track1_packet_loss_summary.csv, sum(total_rx_errors)"))

push!(claims, Claim("5.7.prose", "sec5_7_prose_total_tx_errors",
    canonical_total_tx_errors, "count", "DIRECT", "OK",
    "track1_packet_loss_summary.csv, sum(total_tx_errors)"))

push!(claims, Claim("5.7.prose", "sec5_7_prose_total_errors",
    canonical_total_errors, "count", "DERIVED", "OK",
    "sum of rx + tx errors across all hosts (campaign total)"))

push!(claims, Claim("5.7.prose", "sec5_7_prose_packets_per_run",
    round(canonical_packets_per_run, digits=0), "count", "DERIVED", "OK",
    "track1_packet_loss_summary.csv, sum(mean_rx_packets) + sum(mean_tx_packets)",
    "Mean packets transported by the fabric in a single benchmark rep."))

push!(claims, Claim("5.7.prose", "sec5_7_prose_n_reps_packetloss",
    canonical_n_reps_packetloss, "count", "DIRECT", "OK",
    "track1_packet_loss_summary.csv, n_reps column (uniform across hosts)",
    "Number of benchmark reps aggregated by the packet-loss summary."))

push!(claims, Claim("5.7.prose", "sec5_7_prose_total_packets_campaign",
    round(canonical_total_packets, digits=0), "count", "DERIVED", "OK",
    "canonical_packets_per_run * canonical_n_reps_packetloss",
    "Campaign-total packet count; denominator for the error-rate claim."))

push!(claims, Claim("5.7.prose", "sec5_7_prose_error_rate",
    canonical_error_rate, "ratio", "DERIVED", "OK",
    "canonical_total_errors / canonical_total_packets (campaign-wide)"))

# =====================================================================
# §5.8 Fault Tolerance — Table 7 (qualitative rewrite)
# =====================================================================

push!(claims, Claim("5.8.table7", "sec5_8_table7_scenario1_description",
    "Single link failure on a storage node (1 port to one switch): " *
    "LACP renegotiates; throughput recovers automatically at reduced capacity.",
    "narrative", "NARRATIVE", "NARRATIVE",
    "qualitative description of fault-tolerance behaviour"))

push!(claims, Claim("5.8.table7", "sec5_8_table7_scenario2_description",
    "Symmetric dual link failure (one link per switch): LACP renegotiates " *
    "via surviving ports; throughput recovers automatically at reduced capacity.",
    "narrative", "NARRATIVE", "NARRATIVE",
    "qualitative description of fault-tolerance behaviour"))

push!(claims, Claim("5.8.table7", "sec5_8_table7_scenario3_description",
    "Asymmetric dual link failure (two links to the same switch): recovery " *
    "is markedly slower than scenarios 1 and 2 but completes at reduced capacity.",
    "narrative", "NARRATIVE", "NARRATIVE",
    "qualitative description of fault-tolerance behaviour"))

push!(claims, Claim("5.8.table7", "sec5_8_table7_scenario4_description",
    "Three links disconnected (one port remaining): node remains reachable " *
    "via the surviving port but operates at 1/4 bond capacity.",
    "narrative", "NARRATIVE", "NARRATIVE",
    "qualitative description"))

push!(claims, Claim("5.8.table7", "sec5_8_table7_scenario5_description",
    "Full switch disconnect (both ports to one switch): node is isolated " *
    "when combined with any failure on the other switch; the 4-port bond " *
    "tolerates up to 2 link failures per node distributed across both switches.",
    "narrative", "NARRATIVE", "NARRATIVE",
    "qualitative description"))

push!(claims, Claim("5.8.prose", "sec5_8_prose_recovery_qualitative",
    "Automatic recovery from single-component failures via LACP bond " *
    "renegotiation; multi-component failures exceeding the designed " *
    "redundancy envelope isolate the affected node.",
    "narrative", "NARRATIVE", "NARRATIVE",
    "qualitative description of recovery behaviour"))

# =====================================================================
# §5.9 Summary
# =====================================================================

push!(claims, Claim("5.9.summary", "sec5_9_summary_ststst_pct",
    round1(canonical_ststst_pct_of_theoretical), "%", "DERIVED", "OK",
    "canonical_ststst_pct_of_theoretical"))

push!(claims, Claim("5.9.summary", "sec5_9_summary_fullmesh_gbps",
    round1(canonical_fullmesh_total_gbps_mean), "Gbps", "DERIVED", "OK",
    "canonical_fullmesh_total_gbps_mean"))

# =====================================================================
# §6.2 Single-Client — Table 8
# =====================================================================

for size in SIZES_100G
    for op in OPS
        r = summary_row("single", op, "100gbps", size)
        tag = lowercase(replace(size, "MiB" => "mib", "GiB" => "gib"))
        push!(claims, Claim("6.2.table8",
            "sec6_2_table8_$(tag)_$(lowercase(op))_mean_mibs",
            round(Int, r.mean_mibs), "MiB/s", "DIRECT", "OK",
            "track2_summary.csv, experiment=single, operation=$op, rate=100gbps, size=$size, mean_mibs"))
        push!(claims, Claim("6.2.table8",
            "sec6_2_table8_$(tag)_$(lowercase(op))_std_mibs",
            round(Int, r.std_mibs), "MiB/s", "DIRECT", "OK",
            "track2_summary.csv, experiment=single, operation=$op, rate=100gbps, size=$size, std_mibs"))
        push!(claims, Claim("6.2.table8",
            "sec6_2_table8_$(tag)_$(lowercase(op))_gbps",
            round(r.mean_gbps, digits=1), "Gbps", "DIRECT", "OK",
            "track2_summary.csv, experiment=single, operation=$op, rate=100gbps, size=$size, mean_gbps"))
    end
end

# =====================================================================
# §6.3 Distributed — Table 9
# =====================================================================

for size in SIZES_100G
    for op in OPS
        r = summary_row("distributed", op, "100gbps", size)
        tag = lowercase(replace(size, "MiB" => "mib", "GiB" => "gib"))
        push!(claims, Claim("6.3.table9",
            "sec6_3_table9_$(tag)_$(lowercase(op))_mean_mibs",
            round(Int, r.mean_mibs), "MiB/s", "DIRECT", "OK",
            "track2_summary.csv, experiment=distributed, operation=$op, rate=100gbps, size=$size, mean_mibs"))
        push!(claims, Claim("6.3.table9",
            "sec6_3_table9_$(tag)_$(lowercase(op))_std_mibs",
            round(Int, r.std_mibs), "MiB/s", "DIRECT", "OK",
            "track2_summary.csv, experiment=distributed, operation=$op, rate=100gbps, size=$size, std_mibs"))
        push!(claims, Claim("6.3.table9",
            "sec6_3_table9_$(tag)_$(lowercase(op))_gbps",
            round(r.mean_gbps, digits=1), "Gbps", "DIRECT", "OK",
            "track2_summary.csv, experiment=distributed, operation=$op, rate=100gbps, size=$size, mean_gbps"))
    end
end

# Table 9 footnote: rep 1 excluded for 512 MiB GET.
let r = summary_row("distributed", "GET", "100gbps", "512MiB")
    push!(claims, Claim("6.3.table9", "sec6_3_table9_footnote_n_reps_effective",
        r.n_reps_effective, "count", "DIRECT", "OK",
        "track2_summary.csv, distributed/GET/100gbps/512MiB, n_reps_effective"))
    push!(claims, Claim("6.3.table9", "sec6_3_table9_footnote_n_reps_original",
        r.n_reps_original, "count", "DIRECT", "OK",
        "track2_summary.csv, distributed/GET/100gbps/512MiB, n_reps_original"))
    push!(claims, Claim("6.3.table9", "sec6_3_table9_footnote_excluded_reps",
        r.excluded_reps, "count", "DIRECT", "OK",
        "track2_summary.csv, distributed/GET/100gbps/512MiB"))
end

# =====================================================================
# §6.3 Distributed — prose
# =====================================================================

push!(claims, Claim("6.3.prose", "sec6_3_prose_put_scaling_4mib",
    round(summary_row("distributed", "PUT", "100gbps", "4MiB").mean_mibs /
          summary_row("single",      "PUT", "100gbps", "4MiB").mean_mibs, digits=2),
    "x", "DERIVED", "OK",
    "distributed 4 MiB PUT mean_mibs / single 4 MiB PUT mean_mibs"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_put_scaling_512mib",
    round(summary_row("distributed", "PUT", "100gbps", "512MiB").mean_mibs /
          summary_row("single",      "PUT", "100gbps", "512MiB").mean_mibs, digits=2),
    "x", "DERIVED", "OK",
    "distributed 512 MiB PUT mean_mibs / single 512 MiB PUT mean_mibs"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_st06_pre_fix_mibs",
    137, "MiB/s", "NARRATIVE", "NARRATIVE",
    "pre-SACK-fix historical anomaly; not in current CSVs"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_st06_other_nodes_min_mibs",
    2500, "MiB/s", "NARRATIVE", "NARRATIVE",
    "pre-SACK-fix historical anecdote; qualitative lower bound"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_st06_other_nodes_max_mibs",
    3200, "MiB/s", "NARRATIVE", "NARRATIVE",
    "pre-SACK-fix historical anecdote; qualitative upper bound"))

# Post-fix st06 range across object sizes, excluding 2 GiB per checklist.
let st06_4mib   = filter(r -> r.host == "st06" && r.size_str == "4MiB",   T2_DIST_GET_HOST).mean_mibs[1],
    st06_64mib  = filter(r -> r.host == "st06" && r.size_str == "64MiB",  T2_DIST_GET_HOST).mean_mibs[1],
    st06_512mib = filter(r -> r.host == "st06" && r.size_str == "512MiB", T2_DIST_GET_HOST).mean_mibs[1]
    push!(claims, Claim("6.3.prose", "sec6_3_prose_st06_post_fix_min_mibs",
        round(Int, min(st06_4mib, st06_64mib, st06_512mib)), "MiB/s", "DERIVED", "OK",
        "track2_distributed_get_per_host.csv, host=st06, min mean_mibs across 4/64/512 MiB"))
    push!(claims, Claim("6.3.prose", "sec6_3_prose_st06_post_fix_max_mibs",
        round(Int, max(st06_4mib, st06_64mib, st06_512mib)), "MiB/s", "DERIVED", "OK",
        "track2_distributed_get_per_host.csv, host=st06, max mean_mibs across 4/64/512 MiB"))
end

# PUT uniformity per-size spreads.
push!(claims, Claim("6.3.prose", "sec6_3_prose_put_spread_4mib_pct",
    round(canonical_put_spread_4mib, digits=1), "%", "DERIVED", "OK",
    "track2_distributed_put_per_host.csv, size=4MiB, (max-min)/min * 100"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_put_spread_64mib_pct",
    round(canonical_put_spread_64mib, digits=1), "%", "DERIVED", "OK",
    "track2_distributed_put_per_host.csv, size=64MiB, (max-min)/min * 100"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_put_spread_512mib_pct",
    round(canonical_put_spread_512mib, digits=1), "%", "DERIVED", "OK",
    "track2_distributed_put_per_host.csv, size=512MiB, (max-min)/min * 100"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_put_spread_2gib_pct",
    round(canonical_put_spread_2gib, digits=1), "%", "DERIVED", "OK",
    "track2_distributed_put_per_host.csv, size=2GiB, (max-min)/min * 100"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_get_spread_4mib_pct",
    round(canonical_get_spread_4mib, digits=1), "%", "DERIVED", "OK",
    "track2_distributed_get_per_host.csv, size=4MiB, (max-min)/min * 100"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_get_spread_64mib_pct",
    round(canonical_get_spread_64mib, digits=1), "%", "DERIVED", "OK",
    "track2_distributed_get_per_host.csv, size=64MiB, (max-min)/min * 100"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_get_spread_512mib_pct",
    round(canonical_get_spread_512mib, digits=1), "%", "DERIVED", "OK",
    "track2_distributed_get_per_host.csv, size=512MiB, (max-min)/min * 100"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_get_spread_2gib_pct",
    round(canonical_get_spread_2gib, digits=1), "%", "DERIVED", "OK",
    "track2_distributed_get_per_host.csv, size=2GiB, (max-min)/min * 100"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_get_spread_range_min_pct",
    round(Int, canonical_get_spread_range_min_pct), "%", "DERIVED", "OK",
    "min of GET spread across all four object sizes (no exclusions)"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_get_spread_range_max_pct",
    round(Int, canonical_get_spread_range_max_pct), "%", "DERIVED", "OK",
    "max of GET spread across all four object sizes (no exclusions)"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_put_spread_range_min_pct",
    round(Int, canonical_put_spread_range_min_pct), "%", "DERIVED", "OK",
    "min of 64 MiB / 512 MiB / 2 GiB PUT spread (4 MiB excluded: 'near-uniform')"))

push!(claims, Claim("6.3.prose", "sec6_3_prose_put_spread_range_max_pct",
    round(Int, canonical_put_spread_range_max_pct), "%", "DERIVED", "OK",
    "max of 64 MiB / 512 MiB / 2 GiB PUT spread (4 MiB excluded: 'near-uniform')"))

# =====================================================================
# §6.4 Mixed — Table 10
# =====================================================================

for size in ("4MiB", "512MiB")  # mixed CSV only has these two sizes
    for op in OPS
        r = mixed_row(size, op)
        tag = lowercase(replace(size, "MiB" => "mib"))
        push!(claims, Claim("6.4.table10",
            "sec6_4_table10_$(tag)_$(lowercase(op))_mean_mibs",
            round(Int, r.mean_mibs), "MiB/s", "DIRECT", "OK",
            "track2_mixed_per_op.csv, size=$size, op_type=$op, mean_mibs"))
        push!(claims, Claim("6.4.table10",
            "sec6_4_table10_$(tag)_$(lowercase(op))_std_mibs",
            round(Int, r.std_mibs), "MiB/s", "DIRECT", "OK",
            "track2_mixed_per_op.csv, size=$size, op_type=$op, std_mibs"))
    end
    combined = mixed_row(size, "GET").mean_mibs + mixed_row(size, "PUT").mean_mibs
    tag = lowercase(replace(size, "MiB" => "mib"))
    push!(claims, Claim("6.4.table10",
        "sec6_4_table10_$(tag)_combined_mibs",
        round(Int, combined), "MiB/s", "DERIVED", "OK",
        "track2_mixed_per_op.csv, size=$size, sum of GET and PUT mean_mibs"))
    ratio = mixed_row(size, "GET").mean_mibs / mixed_row(size, "PUT").mean_mibs
    push!(claims, Claim("6.4.table10",
        "sec6_4_table10_$(tag)_get_put_ratio",
        round(ratio, digits=2), "x", "DERIVED", "OK",
        "track2_mixed_per_op.csv, size=$size, GET mean_mibs / PUT mean_mibs"))
end

# =====================================================================
# §6.5 Throttled — Table 11
# =====================================================================

# Throttled cells: 3 sizes × 2 ops × 2 rates = 12 cells.
for size in SIZES_THROTTLED
    for op in OPS
        for rate in THROTTLED_RATES
            r = summary_row("throttled", op, rate, size)
            tag = lowercase(replace(size, "MiB" => "mib"))
            rate_tag = replace(rate, "gbps" => "g")
            push!(claims, Claim("6.5.table11",
                "sec6_5_table11_$(tag)_$(lowercase(op))_$(rate_tag)_mean_mibs",
                round(Int, r.mean_mibs), "MiB/s", "DIRECT", "OK",
                "track2_summary.csv, experiment=throttled, operation=$op, rate=$rate, size=$size, mean_mibs"))
        end
    end
end

# Throttled % of 100G distributed baseline.
for size in SIZES_THROTTLED
    for op in OPS
        baseline = summary_row("distributed", op, "100gbps", size).mean_mibs
        for rate in THROTTLED_RATES
            r = summary_row("throttled", op, rate, size)
            tag = lowercase(replace(size, "MiB" => "mib"))
            rate_tag = replace(rate, "gbps" => "g")
            pct = 100 * r.mean_mibs / baseline
            push!(claims, Claim("6.5.table11",
                "sec6_5_table11_$(tag)_$(lowercase(op))_$(rate_tag)_pct_of_100g",
                round(pct, digits=1), "%", "DERIVED", "OK",
                "throttled/$rate/$size/$op mean_mibs / distributed/100gbps/$size/$op mean_mibs"))
        end
    end
end

# §6.5 prose ranges and transfer times.
let rows_10g = filter(r -> r.experiment == "throttled" && r.rate == "10gbps", T2_SUMMARY)
    push!(claims, Claim("6.5.prose", "sec6_5_prose_10g_min_mibs",
        round(Int, minimum(rows_10g.mean_mibs)), "MiB/s", "DERIVED", "OK",
        "track2_summary.csv, experiment=throttled, rate=10gbps, min(mean_mibs)"))
    push!(claims, Claim("6.5.prose", "sec6_5_prose_10g_max_mibs",
        round(Int, maximum(rows_10g.mean_mibs)), "MiB/s", "DERIVED", "OK",
        "track2_summary.csv, experiment=throttled, rate=10gbps, max(mean_mibs)"))
end

let rows_1g = filter(r -> r.experiment == "throttled" && r.rate == "1gbps", T2_SUMMARY)
    push!(claims, Claim("6.5.prose", "sec6_5_prose_1g_min_mibs",
        round(Int, minimum(rows_1g.mean_mibs)), "MiB/s", "DERIVED", "OK",
        "track2_summary.csv, experiment=throttled, rate=1gbps, min(mean_mibs)"))
    push!(claims, Claim("6.5.prose", "sec6_5_prose_1g_max_mibs",
        round(Int, maximum(rows_1g.mean_mibs)), "MiB/s", "DERIVED", "OK",
        "track2_summary.csv, experiment=throttled, rate=1gbps, max(mean_mibs)"))
end

push!(claims, Claim("6.5.prose", "sec6_5_prose_512mib_transfer_1g_s",
    round(canonical_512mib_transfer_1g_s, digits=2), "s", "DERIVED", "OK",
    "512 MiB / throttled/GET/1gbps/512MiB mean_mibs"))

push!(claims, Claim("6.5.prose", "sec6_5_prose_512mib_transfer_100g_ms",
    round(Int, canonical_512mib_transfer_100g_ms), "ms", "DERIVED", "OK",
    "512 MiB / distributed/GET/100gbps/512MiB mean_mibs (post-exclusion mean)"))

push!(claims, Claim("6.5.prose", "sec6_5_prose_ratio_framework",
    "multiply the 1 Gbps numbers by N to estimate throughput at N Gbps",
    "narrative", "NARRATIVE", "NARRATIVE",
    "Practical guidance; not a numeric claim"))

# =====================================================================
# §6.6 TTFB — Table 12 (GET only; PUT TTFB is missing from CSV)
# =====================================================================

for size in SIZES_100G
    for exp in ("single", "distributed")
        r = summary_row(exp, "GET", "100gbps", size)
        tag = lowercase(replace(size, "MiB" => "mib", "GiB" => "gib"))
        push!(claims, Claim("6.6.table12",
            "sec6_6_table12_$(tag)_get_$(exp)_ttfb_ms",
            round(r.mean_ttfb_ms, digits=1), "ms", "DIRECT", "OK",
            "track2_summary.csv, experiment=$exp, operation=GET, rate=100gbps, size=$size, mean_ttfb_ms"))
    end
end

for size in SIZES_THROTTLED
    for rate in THROTTLED_RATES
        r = summary_row("throttled", "GET", rate, size)
        tag = lowercase(replace(size, "MiB" => "mib"))
        rate_tag = replace(rate, "gbps" => "g")
        push!(claims, Claim("6.6.table12",
            "sec6_6_table12_$(tag)_get_throttled_$(rate_tag)_ttfb_ms",
            round(r.mean_ttfb_ms, digits=1), "ms", "DIRECT", "OK",
            "track2_summary.csv, experiment=throttled, operation=GET, rate=$rate, size=$size, mean_ttfb_ms"))
    end
end

# §6.6 prose ranges filter by rate subset; see Trap #4 in handover.
let rows_100g = filter(r ->
        r.operation == "GET" && r.rate == "100gbps" &&
        r.experiment in ("single", "distributed"), T2_SUMMARY)
    push!(claims, Claim("6.6.prose", "sec6_6_prose_ttfb_100g_min_ms",
        round(minimum(rows_100g.mean_ttfb_ms), digits=1), "ms", "DERIVED", "OK",
        "track2_summary.csv, GET + 100gbps + (single|distributed), min(mean_ttfb_ms)"))
    push!(claims, Claim("6.6.prose", "sec6_6_prose_ttfb_100g_max_ms",
        round(maximum(rows_100g.mean_ttfb_ms), digits=1), "ms", "DERIVED", "OK",
        "track2_summary.csv, GET + 100gbps + (single|distributed), max(mean_ttfb_ms)"))
end

let rows_thr = filter(r ->
        r.operation == "GET" && r.experiment == "throttled", T2_SUMMARY)
    push!(claims, Claim("6.6.prose", "sec6_6_prose_ttfb_throttled_min_ms",
        round(minimum(rows_thr.mean_ttfb_ms), digits=1), "ms", "DERIVED", "OK",
        "track2_summary.csv, GET + throttled, min(mean_ttfb_ms)"))
    push!(claims, Claim("6.6.prose", "sec6_6_prose_ttfb_throttled_max_ms",
        round(maximum(rows_thr.mean_ttfb_ms), digits=1), "ms", "DERIVED", "OK",
        "track2_summary.csv, GET + throttled, max(mean_ttfb_ms)"))
end

# =====================================================================
# §6.7 Summary
# =====================================================================

push!(claims, Claim("6.7.summary", "sec6_7_summary_single_client_mibs",
    round(Int, mean([summary_row("single", "GET", "100gbps", s).mean_mibs for s in SIZES_100G])),
    "MiB/s", "DERIVED", "OK",
    "mean of single/GET/100gbps mean_mibs across 4 object sizes"))

push!(claims, Claim("6.7.summary", "sec6_7_summary_distributed_put_2gib_mibs",
    round(Int, summary_row("distributed", "PUT", "100gbps", "2GiB").mean_mibs),
    "MiB/s", "DERIVED", "OK",
    "distributed/PUT/100gbps/2GiB mean_mibs"))

push!(claims, Claim("6.7.summary", "sec6_7_summary_distributed_get_2gib_mibs",
    round(Int, summary_row("distributed", "GET", "100gbps", "2GiB").mean_mibs),
    "MiB/s", "DERIVED", "OK",
    "distributed/GET/100gbps/2GiB mean_mibs"))

# =====================================================================
# §8 Discussion
# =====================================================================

# --- §8.1 The Network as a First-Class Resource ---

push!(claims, Claim("8.1.prose", "sec9_1_throttled_81x_factor",
    round(Int,
        summary_row("distributed", "PUT", "100gbps", "512MiB").mean_mibs /
        summary_row("throttled",   "PUT", "1gbps",   "512MiB").mean_mibs),
    "x", "DERIVED", "OK",
    "distributed/PUT/100gbps/512MiB mean_mibs / throttled/PUT/1gbps/512MiB mean_mibs",
    "Size-matched ratio across 100G and 1G PUT at 512 MiB; rounds to 81x."))

push!(claims, Claim("8.1.prose", "sec9_1_prose_1g_512mib_transfer_s",
    round(canonical_512mib_transfer_1g_s, digits=1), "s", "DERIVED", "OK",
    "canonical_512mib_transfer_1g_s",
    "Cross-reference to §6.5 transfer-time claim."))

push!(claims, Claim("8.1.prose", "sec9_1_prose_100g_512mib_transfer_ms",
    round(Int, canonical_512mib_transfer_100g_ms), "ms", "DERIVED", "OK",
    "canonical_512mib_transfer_100g_ms",
    "Cross-reference to sec6_5_prose_512mib_transfer_100g_ms."))

push!(claims, Claim("8.1.prose", "sec9_1_prose_ststst_gbps",
    round1(canonical_ststst_total_gbps_mean), "Gbps", "DERIVED", "OK",
    "canonical_ststst_total_gbps_mean",
    "Cross-reference to §5.2 Table 2 st-to-st aggregate."))

push!(claims, Claim("8.1.prose", "sec9_1_prose_ststst_pct",
    round1(canonical_ststst_pct_of_theoretical), "%", "DERIVED", "OK",
    "canonical_ststst_pct_of_theoretical",
    "Cross-reference to §5.2 prose."))

push!(claims, Claim("8.1.prose", "sec9_1_prose_fullmesh_gbps",
    round1(canonical_fullmesh_total_gbps_mean), "Gbps", "DERIVED", "OK",
    "canonical_fullmesh_total_gbps_mean",
    "Cross-reference to §5.2 Table 2 full-mesh aggregate."))

# --- §8.2 Implications for Hardware Selection and Procurement ---

push!(claims, Claim("8.2.prose", "sec9_2_prose_r6525_numa_75pct",
    round(Int, 100 * (R6525_NUMA_NODES_TOTAL - R6525_NUMA_NODES_POPULATED) / R6525_NUMA_NODES_TOTAL),
    "%", "DERIVED", "OK",
    "(R6525_NUMA_NODES_TOTAL - R6525_NUMA_NODES_POPULATED) / R6525_NUMA_NODES_TOTAL",
    "24 of 32 cores access memory remotely: (8-2)/8 = 75%. Hardware fact derived from NUMA CONFIG."))

push!(claims, Claim("8.2.prose", "sec9_2_prose_r6525_pct_bond",
    round1(canonical_r6525_per_node_pct), "%", "DERIVED", "OK",
    "canonical_r6525_per_node_pct",
    "Cross-reference to sec5_2_prose_r6525_per_node_pct."))

push!(claims, Claim("8.2.prose", "sec9_2_prose_r6525_mean_gbps",
    round1(canonical_r6525_per_node_mean_gbps), "Gbps", "DERIVED", "OK",
    "canonical_r6525_per_node_mean_gbps",
    "Cross-reference to sec5_2_prose_r6525_per_node_mean_gbps."))

push!(claims, Claim("8.2.prose", "sec9_2_prose_r6525_min_gbps",
    round1(canonical_r6525_per_node_min_gbps), "Gbps", "DERIVED", "OK",
    "canonical_r6525_per_node_min_gbps",
    "Cross-reference to sec5_2_prose_r6525_per_node_min_gbps."))

push!(claims, Claim("8.2.prose", "sec9_2_prose_r6525_max_gbps",
    round1(canonical_r6525_per_node_max_gbps), "Gbps", "DERIVED", "OK",
    "canonical_r6525_per_node_max_gbps",
    "Cross-reference to sec5_2_prose_r6525_per_node_max_gbps."))

push!(claims, Claim("8.2.prose", "sec9_2_prose_r750_pct_bond",
    round1(canonical_ststst_pct_of_theoretical), "%", "DERIVED", "OK",
    "canonical_ststst_pct_of_theoretical",
    "Cross-reference to §5.2 prose."))

# --- §8.3 LACP Bonding Under Parallel EO Workloads ---

push!(claims, Claim("8.3.prose", "sec9_3_prose_perpair_stream_cv_pct",
    round(mean(raw_by_mode("per-pair").stream_cv_pct), digits=2), "%", "DIRECT", "OK",
    "track1_throughput_raw.csv, mode=per-pair, mean(stream_cv_pct)",
    "Cross-reference to sec5_4_table4_perpair_streamcv_mean."))

push!(claims, Claim("8.3.prose", "sec9_3_prose_fullmesh_stream_cv_pct",
    round(mean(raw_by_mode("full-mesh").stream_cv_pct), digits=2), "%", "DIRECT", "OK",
    "track1_throughput_raw.csv, mode=full-mesh, mean(stream_cv_pct)",
    "Cross-reference to sec5_4_table4_fullmesh_streamcv_mean."))

push!(claims, Claim("8.3.prose", "sec9_3_prose_ststst_stream_cv_pct",
    round(mean(raw_by_mode("st-to-st").stream_cv_pct), digits=2), "%", "DIRECT", "OK",
    "track1_throughput_raw.csv, mode=st-to-st, mean(stream_cv_pct)",
    "Cross-reference to sec5_4_table4_ststst_streamcv_mean."))

# --- §8.5 Benchmarking as a Diagnostic Tool ---
#
# All three §8.5 claims are pre-fix anecdotes. The underlying 137 MiB/s,
# 2,500-3,200 MiB/s, and 84 Gbps values are not in current CSVs (the
# benchmarks were re-run after the BIOS, Swarm, and SACK fixes). These
# claims document the diagnostic narrative as NARRATIVE, not as
# CSV-backed measurements.

push!(claims, Claim("8.5.prose", "sec9_5_st04_84gbps",
    84, "Gbps", "NARRATIVE", "NARRATIVE",
    "pre-BIOS-fix historical anomaly; st04 CPU-boost-disabled snapshot",
    "Draft cites '84 Gbps - 22% below the cluster mean'. Not in current CSVs. " *
    "Duplicate of sec5_2_prose_st04_bios_gbps (same value, different section)."))

push!(claims, Claim("8.5.prose", "sec9_5_swarm_retransmits",
    1700, "count", "NARRATIVE", "NARRATIVE",
    "pre-drain historical anomaly; srv01 Docker Swarm contention snapshot",
    "Draft cites '1,700 retransmits while the other application nodes had near-zero'. " *
    "Not in current CSVs (benchmarks were re-run after Swarm drain)."))

push!(claims, Claim("8.5.prose", "sec9_5_sack_95pct",
    95, "%", "NARRATIVE", "NARRATIVE",
    "pre-SACK-fix historical anomaly; st06 GET throughput reduction",
    "Draft cites '95% reduction'. Derivation in checklist uses pre-fix 137 MiB/s " *
    "vs post-fix ~2800 MiB/s: 1 - 137/2800 = 95.1%. Inputs are anecdotal; " *
    "treated as narrative. See sec6_3_prose_st06_pre_fix_mibs for the 137 value."))

# --- §8.6 Relevance to Distributed EO Infrastructure ---

let single_get_mibs_mean = mean([summary_row("single", "GET", "100gbps", s).mean_mibs for s in SIZES_100G]),
    single_get_gbps_mean = mean([summary_row("single", "GET", "100gbps", s).mean_gbps for s in SIZES_100G])
    push!(claims, Claim("8.6.prose", "sec9_6_prose_single_client_mibs",
        round(Int, single_get_mibs_mean), "MiB/s", "DERIVED", "OK",
        "mean of single/GET/100gbps mean_mibs across SIZES_100G",
        "Matches sec6_7_summary_single_client_mibs."))

    push!(claims, Claim("8.6.prose", "sec9_6_prose_single_client_gbps",
        round(single_get_gbps_mean, digits=1), "Gbps", "DERIVED", "OK",
        "mean of single/GET/100gbps mean_gbps across SIZES_100G"))
end

let one_gbps_get_mean = mean([
        summary_row("throttled", "GET", "1gbps", s).mean_mibs
        for s in SIZES_THROTTLED])
    push!(claims, Claim("8.6.prose", "sec9_6_prose_1gbps_mibs",
        round(Int, one_gbps_get_mean), "MiB/s", "DERIVED", "OK",
        "mean of throttled/GET/1gbps mean_mibs across SIZES_THROTTLED"))
end

push!(claims, Claim("8.6.prose", "sec9_6_lisbon_rtt",
    29, "ms", "NARRATIVE", "NARRATIVE",
    "preliminary external measurement from Lisbon; not in benchmark CSVs",
    "Draft cites '29 ms RTT, 100 ms API round-trip to the Azores'. " *
    "Preliminary result cited narratively; full Atlantic Cloud remote " *
    "benchmarks are the subject of a separate companion paper."))

# --- §8.7 Limitations ---
#
# Per checklist: "No numeric claims requiring provenance."
# No claims emitted for §8.7.

# =====================================================================
# §9 Conclusion and Future Work
# =====================================================================
#
# v8 §9 prose is largely qualitative; the checklist's sec9_summary_*
# claims anticipate a rewrite that surfaces the network-centric headline
# numbers (1,379 Gbps / 86%; 19,246 MiB/s; 29 ms / 218 ms / 2.26 s / 78x;
# 36 ms / 31 ms PostGIS at 100M). Emitting them now against canonicals
# means the Step 6 docx edit has the full provenance trail ready when
# §9 is rewritten.

push!(claims, Claim("9.summary", "sec10_summary_ststst_gbps",
    round1(canonical_ststst_total_gbps_mean), "Gbps", "DERIVED", "OK",
    "canonical_ststst_total_gbps_mean",
    "Cross-reference to §5.2 Table 2; headline aggregate under symmetric R750 load."))

push!(claims, Claim("9.summary", "sec10_summary_ststst_pct",
    round1(canonical_ststst_pct_of_theoretical), "%", "DERIVED", "OK",
    "canonical_ststst_pct_of_theoretical",
    "Cross-reference to §5.2 prose; '86% of theoretical capacity'."))

push!(claims, Claim("9.summary", "sec10_summary_2gib_get_distributed_mibs",
    round(Int, summary_row("distributed", "GET", "100gbps", "2GiB").mean_mibs),
    "MiB/s", "DIRECT", "OK",
    "track2_summary.csv, experiment=distributed, operation=GET, rate=100gbps, size=2GiB, mean_mibs",
    "Same cell as sec6_7_summary_distributed_get_2gib_mibs."))

push!(claims, Claim("9.summary", "sec10_summary_512mib_100g_ms",
    round(Int, canonical_512mib_transfer_100g_ms), "ms", "DERIVED", "OK",
    "canonical_512mib_transfer_100g_ms"))

push!(claims, Claim("9.summary", "sec10_summary_512mib_10g_ms",
    round(Int, canonical_512mib_transfer_10g_ms), "ms", "DERIVED", "OK",
    "canonical_512mib_transfer_10g_ms"))

push!(claims, Claim("9.summary", "sec10_summary_512mib_1g_s",
    round(canonical_512mib_transfer_1g_s, digits=2), "s", "DERIVED", "OK",
    "canonical_512mib_transfer_1g_s"))

push!(claims, Claim("9.summary", "sec10_summary_range_factor_x",
    round(Int, canonical_throttled_range_factor), "x", "DERIVED", "OK",
    "canonical_throttled_range_factor",
    "Derivation: canonical_512mib_transfer_1g_ms / canonical_512mib_transfer_100g_ms."))

# --- Build nested JSON structure ---

function build_json(claims::Vector{Claim})
    sections = Dict{String, Vector{Dict{Symbol, Any}}}()
    section_order = String[]

    for c in claims
        if !haskey(sections, c.section)
            sections[c.section] = Dict{Symbol, Any}[]
            push!(section_order, c.section)
        end
        entry = Dict{Symbol, Any}(
            :id     => c.id,
            :value  => c.value,
            :unit   => c.unit,
            :type   => c.type,
            :status => c.status,
            :source => c.source,
        )
        if !isempty(c.notes)
            entry[:notes] = c.notes
        end
        if !isempty(c.notes_connectivity)
            entry[:notes_connectivity] = c.notes_connectivity
        end
        if !isempty(c.notes_dbcomparison)
            entry[:notes_dbcomparison] = c.notes_dbcomparison
        end
        push!(sections[c.section], entry)
    end

    return Dict(
        :generated_by => "analysis/paper_values.jl",
        :config => Dict(
            :BOND_CAPACITY_GBPS         => BOND_CAPACITY_GBPS,
            :N_PARALLEL_STREAMS         => N_PARALLEL_STREAMS,
            :FM_THEORETICAL_GBPS        => FM_THEORETICAL_GBPS,
            :STST_THEORETICAL_GBPS      => STST_THEORETICAL_GBPS,
            :R6525_MEMORY_BW_GBPS       => R6525_MEMORY_BW_GBPS,
            :R750_MEMORY_BW_GBPS        => R750_MEMORY_BW_GBPS,
            :R7615_MEMORY_BW_GBPS       => R7615_MEMORY_BW_GBPS,
            :R7625_MEMORY_BW_GBPS       => R7625_MEMORY_BW_GBPS,
            :R6525_NPS                  => R6525_NPS,
            :R6525_NUMA_NODES_TOTAL     => R6525_NUMA_NODES_TOTAL,
            :R6525_NUMA_NODES_POPULATED => R6525_NUMA_NODES_POPULATED,
        ),
        :canonical => Dict(
            :perpair_total_gbps_mean             => round1(canonical_perpair_total_gbps_mean),
            :fullmesh_total_gbps_mean            => round1(canonical_fullmesh_total_gbps_mean),
            :ststst_total_gbps_mean              => round1(canonical_ststst_total_gbps_mean),
            :fullmesh_pct_of_theoretical         => round1(canonical_fullmesh_pct_of_theoretical),
            :ststst_pct_of_theoretical           => round1(canonical_ststst_pct_of_theoretical),
            :r6525_per_node_min_gbps             => round1(canonical_r6525_per_node_min_gbps),
            :r6525_per_node_max_gbps             => round1(canonical_r6525_per_node_max_gbps),
            :r6525_per_node_mean_gbps            => round1(canonical_r6525_per_node_mean_gbps),
            :r6525_per_node_pct                  => round1(canonical_r6525_per_node_pct),
            :r750_app_min_gbps                   => round1(canonical_r750_app_min_gbps),
            :r750_app_max_gbps                   => round1(canonical_r750_app_max_gbps),
            :r750_store_min_gbps                 => round1(canonical_r750_store_min_gbps),
            :r750_store_max_gbps                 => round1(canonical_r750_store_max_gbps),
            :fullmesh_degradation_mean_pct       => round1(canonical_fullmesh_degradation_mean_pct),
            :fullmesh_degradation_min_pct        => round1(canonical_fullmesh_degradation_min_pct),
            :fullmesh_degradation_max_pct        => round1(canonical_fullmesh_degradation_max_pct),
            :total_errors                        => canonical_total_errors,
            :packets_per_run                     => round(canonical_packets_per_run, digits=0),
            :n_reps_packetloss                   => canonical_n_reps_packetloss,
            :total_packets                       => round(canonical_total_packets, digits=0),
            :error_rate                          => canonical_error_rate,
            :distributed_512mib_get_mean_mibs    => round(canonical_distributed_512mib_get_mean_mibs, digits=2),
            :transfer_512mib_100g_ms             => round(canonical_512mib_transfer_100g_ms, digits=2),
            :transfer_512mib_10g_ms              => round(canonical_512mib_transfer_10g_ms,  digits=2),
            :transfer_512mib_1g_s                => round(canonical_512mib_transfer_1g_s,    digits=2),
            :throttled_range_factor              => round(Int, canonical_throttled_range_factor),
            :put_spread_range_min_pct            => round(Int, canonical_put_spread_range_min_pct),
            :put_spread_range_max_pct            => round(Int, canonical_put_spread_range_max_pct),
        ),
        :sections => [Dict(:section => s, :claims => sections[s]) for s in section_order],
    )
end

# --- Build CSV rows ---

function build_csv_rows(claims::Vector{Claim})
    rows = NamedTuple[]
    for c in claims
        val_str = c.value === nothing ? "" :
                  c.value isa String    ? c.value :
                  string(c.value)
        push!(rows, (
            section            = c.section,
            claim_id           = c.id,
            value              = val_str,
            unit               = c.unit,
            type               = c.type,
            status             = c.status,
            source             = c.source,
            notes              = c.notes,
            notes_connectivity = c.notes_connectivity,
            notes_dbcomparison = c.notes_dbcomparison,
        ))
    end
    return DataFrame(rows)
end

# --- Emit ---

println()
println("Building outputs...")
json_payload = build_json(claims)
csv_df       = build_csv_rows(claims)

open(joinpath(RESULTS_DIR, "paper_values.json"), "w") do io
    JSON3.pretty(io, json_payload)
end
CSV.write(joinpath(RESULTS_DIR, "paper_values.csv"), csv_df)

println("Wrote: paper_values.json  ($(length(claims)) claims across " *
        "$(length(unique(c.section for c in claims))) sections)")
println("Wrote: paper_values.csv   ($(nrow(csv_df)) rows)")

# --- Minimal status report to stdout ---
#
# Detailed values go into paper_values.csv and paper_values.json. This
# block exists to confirm the run produced what was expected: claim
# counts by type and status. Mismatches (e.g. unexpected zero claims in
# a type) surface immediately
# without anyone having to open the CSV.

println()
type_counts = Dict{String, Int}()
for c in claims
    type_counts[c.type] = get(type_counts, c.type, 0) + 1
end
status_counts = Dict{String, Int}()
for c in claims
    status_counts[c.status] = get(status_counts, c.status, 0) + 1
end

println("Types:    ", join(["$t=$n" for (t, n) in sort(collect(type_counts))], ", "))
println("Statuses: ", join(["$s=$n" for (s, n) in sort(collect(status_counts))], ", "))
println("Done.")
