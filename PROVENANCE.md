# Provenance

This repository was assembled by copying content out of two private
repositories on 2026-08-20. No git history was imported, so the commit
identifiers below are what make the copy auditable: they name exactly the
state the files were drawn from.

## Sources

| Source | Commit | What came from it |
|---|---|---|
| `AIRCentre/datacenter-benchmarks-for-publication` | `2252ecf` | `analysis/`, `benchmarks/` |
| `AIRCentre/atlantic-cloud-remote-benchmarks` | `cb05cab` | `remote/` |

Both trees were clean and level with their origins at the time of the copy.

## What was excluded, and why

**Metadata database benchmarks (Track 3).** The PostGIS and MongoDB
comparison at EO catalogue scales is the subject of a separate paper. Its
raw output, its reduction script, and its derived CSVs are not here.

`analysis/paper_values.jl` and `analysis/provenance_hints.yaml` were reduced
accordingly — the Track 3 constants, CSV loads, helpers, canonical values,
assertions and claims were removed from the first, and the ten matching
section entries from the second. **This means the artefact's
`paper_values.csv` carries 286 claims where the working copy carries more.
The difference is scope, not omission.** Nothing the paper cites is missing;
the removed claims belong to sections that are not in this paper. The source
files in the private repository are untouched.

**The remote-access analysis pipeline.** `paper_values_remote.jl` and
`remote_figures.jl` compute values and draw figures for both the
direct-download path and the replication path. Direct-download results
belong to the companion paper, and the two paths are interleaved in both
files rather than separable — the figure code builds a direct comparison
between them, and the claims script asserts against a site list that
includes a site not in this paper. Reducing them would have meant deleting
or rewriting those assertions. They are held back whole instead, and will be
released with the companion paper. Table 13 of this paper is generated from
`remote/analysis/path_b_replication_throughput.csv`, which is here.

**Path A raw output and derived CSVs.** The per-site `downloads`, `metadata`
and `system_info` JSON, and the four `path_a_*.csv` files. Companion paper.

**The Nansen Environmental and Remote Sensing Center (Bergen).** It ran the
direct-download baselines but never ran replication, so it is not among this
paper's seven institutional sites. Its `results/` directory is excluded, and
its single row was removed from `remote/analysis/remote_network.csv` — the
only edit made to a derived data file in this repository. No published
number depends on it: no claim in the paper draws on that site.

**Raw hardware inventory.** `datacenter_info/` holds `lshw`, `lsblk`,
`ip addr` and bonding captures for the estate. A reader needs a testbed
specification, and raw tool output is a poor way to deliver one; Table 1 and
Appendix A of the paper carry the description instead. A consequence worth
stating plainly: the DIMM serial numbers and MAC inventories in those files
are simply not carried across.

**Superseded runs.** The `archive/` subtrees under
`benchmarks/outputs/minio/` are an internal audit trail of benchmarks re-run
after configuration faults were fixed. Publishing them invites analysis of
runs the paper does not use.

**Infrastructure-as-code.** The Pulumi stacks that provisioned the
public-cloud comparator regions. Companion paper.

**Working documents.** Issue records, task tracking and internal
conventions.

## What was changed in the copies

Two redactions, applied to the copies only:

- NIC MAC addresses in `benchmarks/outputs/network/packet_loss/` (66 files)
  replaced with `xx:xx:xx:xx:xx:xx`. They identify hardware and have no
  analytical value. Broadcast addresses were left alone.
- An operator's account name in 14 benchctl log paths, replaced with
  `/home/user`.

Nothing else in the raw output was modified. Private RFC 1918 addressing,
host names and interface names remain as the instruments recorded them:
removing them would be rewriting rather than filtering, and the paper
already publishes the host names, the topology and the per-port mapping.

Benchmark credentials were redacted by the harness at capture time, before
any of this — every `warp` invocation in the recorded command lines shows
`--access-key=*REDACTED*`.

## Third-party output

`iperf3`, `ping` and `warp` output is redistributed here. Tool output is not
a derivative work of the tool, and no third-party source is vendored.
