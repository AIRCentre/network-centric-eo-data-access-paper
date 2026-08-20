# generate_provenance.jl
#
# Reads analysis/results/paper_values.json (authoritative claim list) and
# analysis/provenance_hints.yaml (hand-written paper-location hints) and
# emits analysis/PROVENANCE.md — a human-readable index mapping every
# claim_id to its location in the FGCS paper draft.
#
# Run from analysis/ :
#   julia --project=. generate_provenance.jl            # strict mode
#   julia --project=. generate_provenance.jl --allow-tbd  # build mode
#
# Strict mode (default): any claim whose resolved paper-location equals
# "[LOCATION TBD]" is an error. Use this for regeneration after hints are
# populated, to catch new claims that land without a paper location.
#
# Build mode (--allow-tbd): permits [LOCATION TBD] placeholders and
# reports a summary at the end. Use this while initially populating
# hints, or after a paper_values.jl extension where not every new claim
# has a hint yet.
#
# Invariants checked before any output:
#   1. Every section tag in paper_values.json has an entry in hints.
#   2. Every section tag in hints exists in paper_values.json (prevents
#      stale hints accumulating silently).
#   3. Every per_claim key in hints matches an actual claim_id in JSON
#      (prevents stale overrides pointing at renamed claims).
#
# The script aborts on any invariant violation with a diagnostic listing
# the offending tags or claim_ids. No partial output is written.

using JSON3, YAML, Printf

# --- CLI argument handling ---

const DEFAULT_JSON_PATH    = joinpath(pwd(), "results", "paper_values.json")
const DEFAULT_HINTS_PATH   = joinpath(pwd(), "provenance_hints.yaml")
const DEFAULT_OUTPUT_PATH  = joinpath(pwd(), "PROVENANCE.md")

function parse_args(args)
    opts = Dict(
        :allow_tbd => false,
        :json      => DEFAULT_JSON_PATH,
        :hints     => DEFAULT_HINTS_PATH,
        :output    => DEFAULT_OUTPUT_PATH,
    )
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--allow-tbd"
            opts[:allow_tbd] = true
        elseif a == "--json"
            i += 1; opts[:json] = args[i]
        elseif a == "--hints"
            i += 1; opts[:hints] = args[i]
        elseif a == "--output"
            i += 1; opts[:output] = args[i]
        elseif a == "--help" || a == "-h"
            println("""
            Usage: julia --project=. generate_provenance.jl [--allow-tbd]
                                                            [--json PATH]
                                                            [--hints PATH]
                                                            [--output PATH]

              --allow-tbd   Permit [LOCATION TBD] placeholders (build mode).
                            Default: strict mode (any TBD is an error).
              --json PATH   Path to paper_values.json.
                            Default: ./results/paper_values.json
              --hints PATH  Path to provenance_hints.yaml.
                            Default: ./provenance_hints.yaml
              --output PATH Path to write PROVENANCE.md.
                            Default: ./PROVENANCE.md
            """)
            exit(0)
        else
            error("Unrecognised argument: $a (try --help)")
        end
        i += 1
    end
    return opts
end

# --- Data loading ---

function load_json(path::AbstractString)
    isfile(path) || error("paper_values.json not found at: $path")
    return JSON3.read(read(path, String))
end

function load_hints(path::AbstractString)
    isfile(path) || error("provenance_hints.yaml not found at: $path")
    raw = YAML.load_file(path)
    haskey(raw, "sections") || error("hints file missing top-level 'sections' key: $path")
    return raw["sections"]
end

# --- Invariant checks ---

"""
    check_invariants(sections_json, hints)

Verifies the JSON and hints files agree about which section tags exist,
and that per_claim overrides reference real claim_ids. Aborts with a
diagnostic on any mismatch. Returns the set of JSON claim_ids for reuse
by downstream code.
"""
function check_invariants(sections_json, hints)
    json_tags = Set{String}()
    json_claim_ids = Set{String}()
    for s in sections_json
        push!(json_tags, String(s.section))
        for c in s.claims
            push!(json_claim_ids, String(c.id))
        end
    end
    hint_tags = Set(String.(keys(hints)))

    missing_in_hints = setdiff(json_tags, hint_tags)
    if !isempty(missing_in_hints)
        error("Section tags present in paper_values.json but absent from " *
              "provenance_hints.yaml:\n  " * join(sort(collect(missing_in_hints)), "\n  "))
    end

    stale_in_hints = setdiff(hint_tags, json_tags)
    if !isempty(stale_in_hints)
        error("Section tags present in provenance_hints.yaml but absent " *
              "from paper_values.json (stale hints):\n  " *
              join(sort(collect(stale_in_hints)), "\n  "))
    end

    stale_per_claim = String[]
    for (tag, entry) in hints
        entry === nothing && continue
        haskey(entry, "per_claim") || continue
        pc = entry["per_claim"]
        pc === nothing && continue
        for cid in keys(pc)
            if !(String(cid) in json_claim_ids)
                push!(stale_per_claim, "$tag -> $cid")
            end
        end
    end
    if !isempty(stale_per_claim)
        error("per_claim keys in provenance_hints.yaml that don't match " *
              "any claim_id in paper_values.json:\n  " *
              join(sort(stale_per_claim), "\n  "))
    end

    return json_claim_ids
end

# --- Paper-section grouping ---

const PAPER_SECTION_TITLES = [
    "5" => "§5 Network Fabric Characterisation",
    "6" => "§6 Object Storage and Data Access Evaluation",
    "7" => "§7 Metadata Query Performance at EO Catalogue Scale",
    "8" => "§8 Discussion",
    "9" => "§9 Conclusion and Future Work",
]

"""
    paper_section_of(tag)

Return the leading paper section number ("5", "6", ... "9") for a
section tag like "5.2.table2" or "9.summary". Errors on malformed tags
so that new section numbers can't be silently misfiled.
"""
function paper_section_of(tag::AbstractString)
    m = match(r"^(\d+)\.", tag)
    m === nothing && error("Malformed section tag (no leading digit): $tag")
    sec = m.captures[1]
    sec in ("5", "6", "7", "8", "9") || error("Unexpected paper section: $sec (tag=$tag)")
    return sec
end

# --- Value rendering ---

const TRUNCATE_AT = 80

"""
    render_value(v)

Render a JSON value for inclusion in a markdown table cell. Rules:
  - `nothing` / missing       -> em dash
  - String longer than 80     -> first 79 chars + "…"
  - Float with integer value  -> integer form (avoid "44.0" noise)
  - Everything else           -> string(v)
Pipe characters are escaped to protect the markdown table.
"""
function render_value(v)
    v === nothing && return "—"
    if v isa AbstractString
        s = String(v)
        if length(s) > TRUNCATE_AT
            s = first(s, TRUNCATE_AT - 1) * "…"
        end
        return escape_pipes(s)
    end
    if v isa AbstractFloat
        if isfinite(v) && v == trunc(v) && abs(v) < 1e15
            return string(Int(v))
        else
            return string(v)
        end
    end
    return escape_pipes(string(v))
end

escape_pipes(s::AbstractString) = replace(s, "|" => "\\|")

"""
    truncate_cell(s)

Same truncation rule as render_value, for source/notes/location strings.
"""
function truncate_cell(s::AbstractString)
    s2 = length(s) > TRUNCATE_AT ? first(s, TRUNCATE_AT - 1) * "…" : s
    return escape_pipes(s2)
end

# --- Location resolution ---

"""
    resolve_location(claim_id, section_entry)

Return the paper location for a claim. Checks per_claim first, falls
back to default_location. If neither is set, returns "[LOCATION TBD]"
(strict-mode guard is applied later, after full resolution, so the
generator can report all TBDs at once rather than aborting on the first).
"""
function resolve_location(claim_id::AbstractString, section_entry)
    section_entry === nothing && return "[LOCATION TBD]"
    if haskey(section_entry, "per_claim") &&
       section_entry["per_claim"] !== nothing &&
       haskey(section_entry["per_claim"], claim_id)
        loc = section_entry["per_claim"][claim_id]
        loc = loc === nothing ? "" : strip(String(loc))
        return isempty(loc) ? "[LOCATION TBD]" : loc
    end
    if haskey(section_entry, "default_location")
        loc = section_entry["default_location"]
        loc = loc === nothing ? "" : strip(String(loc))
        return isempty(loc) ? "[LOCATION TBD]" : loc
    end
    return "[LOCATION TBD]"
end

# --- Output writing ---

"""
    write_markdown(io, json, hints, opts, tbd_list)

Write PROVENANCE.md to `io`. Populates `tbd_list` with (section_tag,
claim_id) pairs for any claim that resolved to [LOCATION TBD], for
end-of-run reporting.
"""
function write_markdown(io::IO, json, hints, opts, tbd_list)
    all_claims = []
    for s in json.sections
        for c in s.claims
            push!(all_claims, (String(s.section), c))
        end
    end

    type_counts = Dict{String, Int}()
    status_counts = Dict{String, Int}()
    for (_, c) in all_claims
        type_counts[String(c.type)]   = get(type_counts,   String(c.type),   0) + 1
        status_counts[String(c.status)] = get(status_counts, String(c.status), 0) + 1
    end
    total = length(all_claims)

    # Header
    println(io, "# FGCS Paper — Claim Provenance")
    println(io)
    println(io, "Generated by `analysis/generate_provenance.jl` from " *
                "`analysis/results/paper_values.json` and " *
                "`analysis/provenance_hints.yaml`. Do not edit by hand; " *
                "regenerate after any change to `paper_values.jl` or " *
                "`provenance_hints.yaml`.")
    println(io)
    println(io, "Every numerical claim in §5–§9 of the FGCS paper draft " *
                "is listed below with its CSV-derived value, source, and " *
                "location in the paper.")
    println(io)

    # Summary table
    println(io, "## Summary")
    println(io)
    println(io, "### By type")
    println(io)
    println(io, "| Type | Count |")
    println(io, "| --- | --- |")
    for t in sort(collect(keys(type_counts)))
        @printf(io, "| %s | %d |\n", t, type_counts[t])
    end
    @printf(io, "| **Total** | **%d** |\n", total)
    println(io)
    println(io, "### By status")
    println(io)
    println(io, "| Status | Count |")
    println(io, "| --- | --- |")
    for s in sort(collect(keys(status_counts)))
        @printf(io, "| %s | %d |\n", s, status_counts[s])
    end
    @printf(io, "| **Total** | **%d** |\n", total)
    println(io)

    # Per-section content
    sections_by_paper = Dict{String, Vector{Any}}(p.first => [] for p in PAPER_SECTION_TITLES)
    for s in json.sections
        push!(sections_by_paper[paper_section_of(String(s.section))], s)
    end

    for (num, title) in PAPER_SECTION_TITLES
        group = sections_by_paper[num]
        isempty(group) && continue
        println(io, "## $title")
        println(io)
        for s in group
            tag = String(s.section)
            entry = hints[tag]
            println(io, "### $tag")
            println(io)
            if entry !== nothing && haskey(entry, "notes")
                note = entry["notes"]
                note_str = note === nothing ? "" : strip(String(note))
                if !isempty(note_str)
                    println(io, "_Notes._ $note_str")
                    println(io)
                end
            end
            println(io, "| claim_id | paper_location | type | value | source | notes |")
            println(io, "| --- | --- | --- | --- | --- | --- |")
            for c in s.claims
                cid = String(c.id)
                loc = resolve_location(cid, entry)
                if loc == "[LOCATION TBD]"
                    push!(tbd_list, (tag, cid))
                end
                claim_notes = haskey(c, :notes) ? String(c.notes) : ""
                @printf(io, "| `%s` | %s | %s | %s | %s | %s |\n",
                    cid,
                    escape_pipes(loc),
                    String(c.type),
                    render_value(c.value),
                    truncate_cell(String(c.source)),
                    truncate_cell(claim_notes))
            end
            println(io)
        end
    end

    # Footer
    println(io, "---")
    println(io)
    println(io, "_End of PROVENANCE.md._")
end

# --- Main ---

function main(args)
    opts = parse_args(args)

    json_data = load_json(opts[:json])
    hints     = load_hints(opts[:hints])

    check_invariants(json_data.sections, hints)

    # Dry-run rendering to collect tbd_list before writing the real file.
    # This keeps strict-mode aborts from producing a partial PROVENANCE.md.
    tbd_list = Tuple{String, String}[]
    io_buf = IOBuffer()
    write_markdown(io_buf, json_data, hints, opts, tbd_list)

    if !opts[:allow_tbd] && !isempty(tbd_list)
        println(stderr, "ERROR: $(length(tbd_list)) claim(s) resolved to [LOCATION TBD] in strict mode:")
        for (tag, cid) in tbd_list
            println(stderr, "  $tag -> $cid")
        end
        println(stderr, "Fill in provenance_hints.yaml or re-run with --allow-tbd.")
        exit(1)
    end

    open(opts[:output], "w") do io
        write(io, take!(io_buf))
    end

    n_claims = sum(length(s.claims) for s in json_data.sections)
    n_sections = length(json_data.sections)
    @printf("Wrote: %s  (%d claims across %d section tags)\n",
            opts[:output], n_claims, n_sections)

    if !isempty(tbd_list)
        @printf("  WARNING: %d claim(s) resolved to [LOCATION TBD] (build mode):\n",
                length(tbd_list))
        for (tag, cid) in tbd_list
            @printf("    %s -> %s\n", tag, cid)
        end
    end
end

main(ARGS)
