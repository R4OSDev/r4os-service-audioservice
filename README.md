# AUDSVC.R4X

`AUDSVC.R4X` is an independent R4OS service implemented in Zig.

## Package

- Version: `0.1.6`
- Image target: `/R4OS/SERVICES/AUDSVC.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

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

Detailed German technical notes are in `DOCUMENTATION.de.txt`.
Source-transfer provenance is recorded in `PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
