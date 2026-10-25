# AirFlit Setup — embedding AirliftFFI

AirFlit (passcode themes + Wallet card images) uses 100% the AirCard
method: file delivery over AirTraffic via the `AirliftFFI` Rust core.
It does NOT use sparse restore.

## What the code expects

- `WorkSlop/AirFlitEngine.swift` calls `al_exploit_write_dir()` from
  the `AirliftFFI` module.
- The import is guarded: `#if canImport(AirliftFFI)`. Without the
  framework the app still compiles; AirFlit actions throw
  `AirFlitError.ffiUnavailable` with a message pointing here.

## Embedding the framework

**CI (automatic):** the `Build IPA` workflow downloads
`AirliftFFI.xcframework` from the AirCard repo automatically
(sparse checkout, cached via `actions/cache` keyed on
`.github/airlift-ffi.pin`). No manual step needed. Bump the SHA in
`.github/airlift-ffi.pin` to pull a newer prebuilt.

**Local dev (manual, one time):**

1. Copy from the AirCard repo (MIT licensed):
   ```
   ~/workspace/research/aircard/AirCard-iOS/AirliftFFI.xcframework
   ```
   into the WorkSlop project, e.g. `WorkSlop/Frameworks/AirliftFFI.xcframework`.

   The xcframework is ~127 MB (device + simulator slices). Only the
   `ios-arm64` slice ships in the IPA; the simulator slice is never
   packaged for device builds.

2. Link it:
   - XcodeGen (`project.yml`): already wired — the WorkSlop target
     links `WorkSlop/Frameworks/AirliftFFI.xcframework` (static lib,
     no embedding needed; Xcode auto-selects the `ios-arm64` slice
     for device builds). The `Frameworks/` dir is git-ignored and
     excluded from xcodegen sources.
   - Xcode GUI: Target → General → Frameworks, Libraries, and Embedded
     Content → add `AirliftFFI.xcframework` (do NOT embed — static).

3. Build. `import AirliftFFI` in `AirFlitEngine.swift` will resolve
   and `#if canImport(AirliftFFI)` becomes true.

   NOTE: without the framework file present, `xcodebuild` fails at
   link time (`framework not found`). The `#if canImport` guard keeps
   the Swift source compiling, but the project-level link requires
   the file — download it per step 1 (or let CI do it).

## Why it is not committed

127 MB of prebuilt binary does not belong in the source repo.
CI builds it fresh or the maintainer drops the xcframework in
before archiving. The guarded import keeps every other build green.

## Also vendored by AirCard (check before shipping)

- `GrappaHelper.m/.h` — private API for the AirTraffic auth token.
  AirliftFFI handles the token internally; the helper is only needed
  if you call lower-level pairing APIs.
- License check: AirCard is MIT, but verify the licenses of the
  vendored `idevice`/Rust crates inside AirliftFFI before
  distributing.

## iOS support window

18.0 – 27.2 beta 2. Apple patched the AirTraffic vector in
27.2 beta 3 — `AirFlitEngine.isSupported` locks the menu there.
Do NOT add 27.2 beta 3+ builds to the supported list.
