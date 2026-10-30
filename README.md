# AUDSVC.R4X

`AUDSVC.R4X` is an independent R4OS service implemented in Zig.

## Package

- Version: `0.1.20`
- Image target: `/R4OS/SERVICES/AUDSVC.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

Since version0.1.16 an active stream's zero PCM goes through its existing
backend, preserving frame duration and identity. Initial unmaterialized
discrete silence stays lazy. Explicit Close/producer stop/disconnect owns
the real generation-bound terminal drain; zero sample values do not trigger
Close or a new prefill. No background idle timer, kernel/HDA/ABI change or
early drain acknowledgement. Silence-byte counters include actual accepted
zero prefixes; only truly omitted initial frames are suppressed.

Version0.1.15 added generation-bound stream progress, continuous source flow,
tracked writes and close-with-progress (RPC11..14). Only initial read-only
discovery accepts zero service/logical keys; mutations require both exact
identities. The service binds the kernel generation before materializing flow.
Progress separates source acceptance, backend/DMA/consumed and unconfirmed
canonical frames. Continuous zero PCM is clocked; ordinary discrete silence
suppression remains separate. A busy optional progress query never changes a
successful write into a retry. The source clock deadline is absolute, including
partial/BUSY retries. Final progress is captured before kernel stream release.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Open creates a client-bound logical stream. The backend stream is materialized
only by the first non-silent PCM block. Complete zero blocks are acknowledged
without a backend payload and close an active backend once; later signal may
materialize it again. Status version 2 exposes logical/materialized sessions,
lazy opens, suppressed silence and idle closes in the existing fixed record.

Append-only master-state operations expose the selected and effective 16.16
gain, explicit mute, the last audible value, revision, service epoch and
persistence diagnostics. AUDSVC owns this global state and safely persists it
to `C:\R4OS\CONFIG\AUDIO.R4S`; clients do not maintain a second mixer state.
The legacy set-volume operation remains compatible and never changes mute.

Detailed German technical notes are in `DOCUMENTATION.de.txt`.
Source-transfer provenance is recorded in `PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
# Complete output capture (0.88.55, AUDSVC0.1.20)

The existing500ms poll uses the complete R4AUDIO catalog capture. A single
registry permit and revalidated provider epochs replace repeated per-index
prefix scans. The service publishes only a complete count/unique-ID catalog,
including new identities when row bytes stay identical. Busy, invalid or
unsupported capture retains the last display while clearing its availability
confirmation. Desired selection, fallback, NoEndpoint invalidation and the
existing service epoch/revision page protocol remain in force. Physical route,
ELD, Stop and DMA acknowledgements are separate observations.
