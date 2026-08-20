# Cohort: prefix-tcp-cc-fix_issue-25

## What is in this directory

24 files (12 JSON warp outputs + 12 snapshot CSVs) from distributed
PUT runs on the AIR Data Centre's 8-node MinIO cluster, captured
between 2026-03-26 and 2026-03-31. Three reps × four sizes
(4 MiB, 64 MiB, 512 MiB, 2 GiB) for each of two date ranges.

## Why these are archived

These runs measured a cluster with a configuration drift on four of
the eight storage hosts (st01, st02, st07, st08) that left long-lived
MinIO peer-to-peer TCP connections stuck on the cubic congestion
control algorithm rather than BBR. Under concurrent multi-endpoint
EC fan-out, this produced an artificial ~17 % throughput deficit on
the affected hosts and a corresponding ~20 % two-tier asymmetry in
distributed-mode PUT throughput at sizes ≥ 64 MiB.

The drift was identified, diagnosed, and remediated on 2026-05-08.
A full re-run on the corrected configuration produced post-fix data
showing tier convergence within ±2.6 %.

The runs in this cohort are therefore not measurements of the
as-designed architecture and have been moved out of the active
analysis pool. The post-fix runs (timestamps `1778199404` onwards,
2026-05-08, kept at the top level of `warp_put_distributed/`) are
the authoritative distributed PUT measurements for the paper.

## Canonical record

- GitHub issue: AIRCentre/datacenter-benchmarks-for-publication#25
- Investigation steps and per-step evidence:
  `issues/25/investigation.md`
- Resolution commit: `e1018eb`
  ("fix(minio): resolve #25 two-tier PUT throughput asymmetry")

## Scope of the fix

The configuration drift affected long-lived MinIO peer-to-peer TCP
connections under concurrent load. By mechanism, this was specific
to distributed-mode operations involving EC fan-out across multiple
endpoints simultaneously. Single-client (Track 2.1) operations did
not exhibit the symptom and are unaffected.

Distributed GET data captured during the same period is retained in
the active pool. The asymmetric treatment is documented in
`decisions/2026-05-08_01.md`.
