# Distributed PUT: archive of superseded raw outputs

This directory holds raw warp distributed-PUT outputs that have been
superseded and are no longer read by the analysis pipeline.

The pipeline's file discovery (in
`analysis/processing/track2_throughput.jl`,
function `discover_warp_jsons`) reads only `*.json` files at the root
of `warp_put_distributed/`. Anything inside `archive/` (and inside any
subdirectory of `archive/`) is invisible to the pipeline and therefore
excluded from analysis automatically.

## Structure

```
archive/
├── README.md                           (this file)
├── <root-level files>                  pre-convention; reasons not individually documented
└── <cohort-name>/                      cohort directory
    ├── README.md                       cohort-specific explanation
    └── <raw output files>
```

Cohort directories are named `<short-slug>_issue-<N>/` where the short
slug describes why the cohort was archived and the issue number cites
the GitHub issue (in
`AIRCentre/datacenter-benchmarks-for-publication`) that documents the
investigation. The cohort README states the reason and points at the
canonical record.

## Cohorts

- `prefix-tcp-cc-fix_issue-25/` — pre-fix runs from late March 2026
  superseded by the post-fix run on 2026-05-08, following the
  resolution of issue #25 (TCP congestion control configuration drift
  on st01/02/07/08). See the cohort README for details.

## Pre-convention root-level files

The files at the root of this directory (timestamps `1774553197` and
`1774628848` onwards, dated 2026-03-23 / 2026-03-24) predate the
cohort-subdirectory convention introduced on 2026-05-08. Their
archival reasons are not individually documented; they are held
here as historical artefacts. New archived runs go into cohort
subdirectories.
