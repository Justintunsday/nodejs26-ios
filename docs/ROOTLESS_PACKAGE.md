# Standalone Node.js 26 rootless package

The experimental `node26` package installs the `node` command and a complete
Node.js 26.13.0 iPhoneOS ARM64 executable under `/var/jb/usr/lib/node26/`.
It can be used independently of OpenCode. The package owns its own files; it provides the default `node` command. OpenCode can depend on this package without
embedding another runtime. The package author is `nodejs`.

## Pinned runtime

- Runtime artifact: `ios-node26-runtime-ffi`, run
  [41549633128](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41549633128).
- Runtime source: `7cd359f377d9d37dfe13d929927cf67274451ec2`.
- `node`: 134,710,336 bytes, SHA-256
  `84613100b3d31a747a55d1132906bfef9417b15a1e33a4088ff1da5956e61ef9`.
- Includes iOS W^X, wasm trap-handler/allocator, libffi callback 0014/0015 and
  foreground V8 JobHandle 0016 fixes. The already signed executable is packaged
  without modification or resigning.

## Accepted package and device scope

Package [run 41620234785](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41620234785),
source `7f3f641`, artifact `node26-rootless`: `node26_26.13.0-1_iphoneos-arm64.deb`,
**25,893,168 bytes**, SHA-256 `c6cda114912707b5c229178449e0cc0a641fa7165c270a8dd81456196fed9e51`. Control metadata: `Package: node26`,
`Version: 26.13.0-1`, `Author: nodejs`, maintainer display name `nodejs`.
CI passed 23 runtime/package checks plus native Debian metadata/extraction checks.

**DEVICE-VERIFIED**, iPhone SE 2 / iOS 16.1.1 / Dopamine rootless, 2026-11-03:
installation rc=0; command `node` and independent executable identity passed;
11 checks cover JIT checksum 5999999, wasm function 42/memory, ICU/Unicode, FFI
native/reentrant callback, SQLite persistence, ESM/stdin, fork flag inheritance,
HTTP/HTTPS 200 and exact signed binary SHA. Stress passed 192 HTTP requests and
24 wasm modules; arguments with spaces/stdin passed; real Node REPL `2+3` → `5`,
`.exit` rc=0. `dpkg --verify node26 opencode` returned 0.

OpenCode [package run 41621747546](https://github.com/Justintunsday/opencode-ios/actions/runs/41621747546)
installs app `2.2.5-2` with exact dependency `node26 (= 26.13.0-1)` and no embedded
Node executable. CLI 8/0, strict JSON/tool E2E, normal TUI rc=0 and three-turn
122.328-second TUI rc=0 passed using the independent runtime. Source docs and
[full device evidence](https://github.com/Justintunsday/opencode-ios/blob/main/docs/NODE26_EXTERNAL_DEVICE_RESULTS.md)
record the exact package pair, exits and raw PTY checksum.

CrashReporter changed 0 → 3 system Jetsam reports; none lists a terminated Node
victim and there was no Node crash report. System daemon memory-pressure/per-process
terminations were observed. Runtime verification is scoped to these executed tests;
indefinite uptime and other devices remain unverified. Static CI reports cannot
verify device execution.

## Installation and use

On a rootless jailbroken iPhone with `/var/jb` and Procursus `dpkg`:

```sh
sudo dpkg -i node26_26.13.0-1_iphoneos-arm64.deb
node --version
node -p 'process.platform'
node -e 'console.log(2 + 3)'
node script.cjs
node --input-type=module -e 'console.log(await Promise.resolve(42))'
```

The launcher always passes `--single-threaded`. The executable retains its
`platform-application` and `com.apple.private.security.no-sandbox` entitlements.
JIT, WebAssembly, full ICU, native SQLite and `node:ffi` are included.

## Limits

The later [JIT/wasm + POSIX report](POSIX_JIT_WASM_DEVICE_RESULTS.md) verifies native
open, read-only sysctl, Node/native exec/spawn, POSIX shared-memory mapping and named
semaphore handoff. Unnamed `sem_init` returns ENOSYS=78; System V `shmget` triggers
SIGSYS on this device. A no-sandbox entitlement does not make every dylib path
loadable: the same signed test library was rejected under `/var/mobile` and worked
after root-owned installation under `/var/jb`. Native execve replaced the process
successfully, but its original stdout capture was not preserved. These are measured
limits, not claims about all POSIX calls or other iOS versions.

This is an experimental runtime for jailbroken iPhoneOS, with device coverage on
iPhone SE 2 / iOS 16.1.1 / Dopamine rootless. The binary minimum is iOS 15.0;
other devices and system versions require their own acceptance.

- **Use `node` for launching programs.** Direct execution of the underlying
  binary requires `--single-threaded`: iOS code-page permission changes apply to
  the entire process, so background V8 execution can race JIT writes.
- **Node user `worker_threads` are unsupported.** The flag does not disable user
  worker isolates. OpenCode separately disables its tree-sitter worker; this
  standalone runtime does not patch arbitrary applications.
- Forward `--single-threaded` when explicitly spawning `process.execPath`.
  Standard `child_process.fork()` inherits `process.execArgv` unless overridden.
- Temporal was disabled when this runtime was built. Native addons require an
  iPhoneOS build. npm/npx are separate from this runtime-only package.
- `--jitless` is a diagnostic option; it disables the WebAssembly path needed by
  built-in fetch, so it is unsuitable for normal network applications.

Remove dependent OpenCode first, or switch to an OpenCode variant without this
dependency, before `sudo dpkg -r node26`. The runtime owns no user data and does
not terminate running applications. The earlier prototype package `nodejs26-ios`
must be removed before installing `node26`; it provided the old `node26` command.
The new package keeps a relative internal `usr/lib/nodejs26/node` compatibility
link for processes already running from that prototype path.

## Build the deb

The package workflow consumes the exact runtime in `packaging/runtime-pin.json`.
Assembly uses Python's standard library and does not need Xcode or another native
compilation. Linux CI additionally checks the deb with `dpkg-deb`.

```sh
python3 scripts/package-rootless-node26.py --runtime /path/to/downloaded/runtime
```

Output: `dist/node26-rootless/`, containing the deb, `package-report.json`
and `SHA256SUMS`. File timestamps/ownership are fixed to the pinned source epoch.
