# AUDSVC.R4X

`AUDSVC.R4X` is an independent R4OS service implemented in Zig.

## Package

- Version: `0.1.26`
- Image target: `/R4OS/SERVICES/AUDSVC.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

The event-driven dispatcher requests the existing bounded preferred work class
through its exact-generation thread handle and verifies adoption after a saved
context boundary. The scheduler limits this preference to four ticks and four
dispatches per activation. Default CPU admission and the policies of separately
joined workers remain with their owners. The audio dispatcher receives this
bounded preference alongside the remote services. PCM data, caller deadlines
and terminal Close acknowledgements are preserved.

Version0.1.22 retires unrequested request-duration collection. Status and
ordinary stream results set `audio_service_flag_duration_unavailable` and
return `audio_duration_ticks_unavailable` (`UINT64_MAX`) in their six/two
duration fields. This is unavailable data, never measured zero. Normal
requests no longer take duration-only clock readings or update timing totals.
The legacy Close keeps its entry tick and unchanged 500 ms deadline; the
selection worker retains its exact-generation Join and request/client keys.
Use SDK0.64.125 / Contract0.64.66 for the public flag name.

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

Open creates a client-bound logical stream. Non-silent PCM or an explicit
continuous flow materializes its backend. Only initial, unmaterialized
discrete silence is suppressed; an active stream's zero frames retain their
duration and backend identity. Explicit Close, producer stop or disconnect
owns the terminal drain. Status version 2 exposes logical/materialized sessions,
lazy opens, suppressed silence and idle closes in the existing fixed record.

Append-only master-state operations expose the selected and effective 16.16
gain, explicit mute, the last audible value, revision, service epoch and
persistence diagnostics. AUDSVC owns this global state and safely persists it
to `C:\R4OS\CONFIG\AUDIO.R4S`; clients do not maintain a second mixer state.
The legacy set-volume operation remains compatible and never changes mute.

Version0.1.21 separates output policy planning from driver selection. One
service-owned worker holds a copied operation of at most four existing policy
candidates. Explicit, automatic and fallback selections use the same path;
the dispatcher publishes a result only after the exact-generation Join.
While selection is pending, pages retain the last display with catalog-busy
reason and no backend-present confirmation. Status, master and permissible
existing-stream operations remain reachable; new backend materialization and
another selection return Busy. No output refresh or hidden fallback waits in
the dispatcher during that operation. With no provider call needed, automatic
policy can settle immediately without claiming new hardware availability.

A successful provider ACK commits the original preference once, including if
its caller already timed out or exited. A fresh catalog independently states
current availability; withdrawal/reordering cannot retain an obsolete selected
reason. Missing replies are benign and never replay the mutation. Callers
resolve ambiguous timeout/Busy results through fresh reads and service epochs.
Shutdown joins selection before flushing its preference and closing streams.
Only an actual Join retires the copied worker data; an arbitrary Join error
keeps that data and handle. The existing RPC/transport budgets are unchanged.

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

# Optional copied PCM input (AUDSVC0.1.23)

Service operation6100 adds explicit Catalog/Open/Read/Query/Stop/Close over
the original service loop. The separate immutable R4D input extension retains
its DMA/backing until actual Stop/Close acknowledgements. Four bounded copied
queues enforce the final caller capacity before activation or dequeue; complete
S16LE frames carry exact source generations, gaps and overrun counts. Source
failure remains a failure after a later Stop acknowledgement.

Use the SDK audio_capture clients and the normative Contract/API/AudioCapture.txt.
Without a qualified input extension, capability is explicitly unavailable.
Shipped HDA/AC97 playback backends supply no qualified ADC; controlled input
qualification does not establish microphone or physical DMA activity. Capture
tests extend the existing test step. No recorder or application migration is
included.

## API migration 0.90.52

The normal service uses App2/Start2 and actual R4SYS/R4AUDIO Query2:2 callbacks. Its lifecycle membership adapter uses the common SDK streaming page validator, preserving positive more-page evidence and complete-only absence, exact owner generations, WouldBlock rollback and explicit restart. Existing queued capture buffers, final caller capacity, output Work joins and separate Stop/Close acknowledgements remain with their original owners. HDA/AC97 still expose no ADC. Source-only pacing stays in source producers, not this dispatcher. SDK 0.64.193; independent resource-record revision1 remains distinct from the platform generation. Native, host-model and Windows compilation qualification are recorded separately in the R4OS ConsumerMigration report.
