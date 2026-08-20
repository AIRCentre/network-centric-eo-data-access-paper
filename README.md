# Network-centric on-premises EO data access — paper artefact

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.22032257.svg)](https://doi.org/10.5281/zenodo.22032257)

Benchmark data, analysis code and derived results for:

> Design and Empirical Evaluation of a Network-Centric, On-Premises
> Architecture for Earth Observation Data Access

The measurements come from the AIR Data Centre on Terceira, Azores — the
first operational node of the Atlantic Cloud — and from a multi-site
replication campaign with partner institutions across the Atlantic basin.

Everything here is scoped to that one paper. See "What is not here" below.

## Layout

    analysis/          Julia pipeline: raw output in, paper claims out
      results/         derived CSVs, plus paper_values.{csv,json}
      figures/         figure generators and their output
      processing/      per-track reduction from raw benchmark output
      PROVENANCE.md    every claim in the paper, mapped to where it appears
    benchmarks/
      benchctl         benchmark orchestration
      scripts/         the harness
      outputs/network/ iperf3, ping and interface captures (Track 1)
      outputs/minio/   warp object-storage runs (Track 2)
    remote/
      analysis/        Path B replication CSVs and the replication figure
      results/         per-site raw replication and network JSON
      scripts/         the harness partner sites ran

## Reproducing the numbers

`analysis/results/paper_values.csv` is the single source of truth for every
numerical claim in the paper. If the paper and that file disagree, the file
is right. Each row carries the claim, its value and unit, whether it is a
direct measurement or derived, and the CSV and filter it came from.

To rebuild it from the derived CSVs:

    cd analysis
    julia --project=. paper_values.jl
    julia --project=. generate_provenance.jl

The first writes `paper_values.csv` and `paper_values.json`; the second
writes `PROVENANCE.md`, which maps each claim to its location in the paper.
Both are deterministic — two runs produce byte-identical output. The script
asserts on its own headline values, so a change in the inputs that moves a
published number stops the run rather than quietly changing the answer.

To go further back, from raw benchmark output to the derived CSVs, the
per-track scripts under `analysis/processing/` do that reduction.

## The Path B replication data

`§7` of the paper reports replication throughput between seven partner
institutions and the AIR Data Centre, against a 56-region public-cloud
comparator. Table 13 is generated from
`remote/analysis/path_b_replication_throughput.csv`, and the per-repetition
values behind it are in `path_b_replication_per_rep.csv`. Round-trip times
quoted throughout `§7` are in `remote_network.csv`.

`remote/scripts/REPLICATION_SETUP.md` is the guide partner sites followed.

## What is not here

**The remote-access analysis pipeline.** The scripts that compute values and
draw figures for the remote campaign cover both the direct-download path and
the replication path, and the direct-download results belong to a companion
paper. Rather than ship an amputated version, the pipeline is held back and
will be released with that paper. The CSVs above are sufficient to reproduce
every `§7` number in this one.

**The metadata database benchmarks.** A comparison of PostGIS and MongoDB at
EO catalogue scales is a separate paper with its own artefact. The analysis
code here has had that track removed; `PROVENANCE.md` at the repository root
records what was taken out.

**The raw hardware inventory.** `lshw`, `lsblk` and bonding captures for the
estate are not published. Table 1 and Appendix A of the paper carry the
hardware description a reader needs.

**Superseded runs.** The internal audit trail of re-run benchmarks is not
included; only the runs the paper reports.

## Licences

Code is MIT (`LICENSE`). Data, derived results and documentation are
CC BY 4.0 (`LICENSE-CC-BY-4.0`). `NOTICE` covers the AIR Centre and Atlantic
Cloud names, which neither licence grants any rights in.

## Provenance

`PROVENANCE.md` at the repository root names the two private repositories
this content was copied from and the exact commits it was drawn from. No git
history was imported — the SHAs are what make the artefact auditable.

## Citing this artefact

Cite the paper. If you need to cite the artefact itself, use the version DOI
for the exact snapshot the paper's numbers were computed from:

    10.5281/zenodo.22032258   (v1.0.0, the state at submission)

The badge above carries the concept DOI, `10.5281/zenodo.22032257`, which
always resolves to the most recent version.
