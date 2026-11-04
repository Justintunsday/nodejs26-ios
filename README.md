# Node.js 26.13 for iPhoneOS (arm64)

## Artifacts

| Artifact | Version | Source run | Size | SHA-256 |
| --- | --- | --- | --- | --- |
| `node26_26.13.0-2_iphoneos-arm64.deb` | `26.13.0-2` | [41648623126](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41648623126) | 25,899,420 B | `8e9979639645fb57262653c84dd705a0fab12acf3e8e4e8b9cb5f7ef793f63b9` |
| Node runtime executable | `v26.13.0` | [41549633128](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41549633128) | 134,710,336 B | `84613100b3d31a747a55d1132906bfef9417b15a1e33a4088ff1da5956e61ef9` |
| POSIX compatibility dylib | `26.13.0-2` | [41647498001](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41647498001) | 86,928 B | `5ac7fcb88ce61ece5a2d5acf6bb8373940767e5bfa7babbcc0dec78c92310895` |

The runtime is a reproducible GitHub Actions build of Node.js 26.13.0 for iPhoneOS arm64,
cross-compiled from the upstream `nodejs/node` `v26.13.0` source tarball. The accepted
binary corresponds to source commit `7cd359f377d9d37dfe13d929927cf67274451ec2` and
includes the WebAssembly trap-handler fix, iOS libffi callback fixes and foreground-only
V8 JobHandle handling.

The `node26` package installs the accepted runtime, the POSIX compatibility dylib and the
`node` launcher under `/var/jb/usr/lib/node26`. It contains no OpenCode files and does not
embed a second runtime.

## Requirements

Device installation:

- Jailbroken arm64 iPhone with a rootless bootstrap (`/var/jb`), such as Dopamine.
- Procursus `dpkg`.
- iOS 15.0 or newer. The validated device runs iOS 16.1.1.
- Approximately 150 MB of free space under `/var/jb`.
- A TTY for the interactive REPL. Non-TTY invocations exit with guidance.
- `--single-threaded` is mandatory for JIT and WebAssembly execution.

Building from source:

- macOS runner with Xcode 16.4 and iPhoneOS SDK 18.5, as provided by the `macos-15`
  GitHub Actions runner.
- The pinned Node.js source tarball and the patch series in `patches/nodejs26/`.
- The GitHub Actions workflow is the only supported build path.

## Installation

Download the package artifact from a computer with GitHub CLI authenticated:

```sh
gh run download 41648623126 -R Justintunsday/nodejs26-ios \
  -n node26-rootless -D node26
```

Transfer the directory to the device and install the package:

```sh
cd node26
sha256sum -c SHA256SUMS
sudo dpkg -i node26_26.13.0-2_iphoneos-arm64.deb
```

Verify the runtime and the command:

```sh
node --version                 # v26.13.0
node -p 'process.platform'     # ios
node -e 'console.log(2 + 3)'
```

The `node` launcher performs the following actions:

- Adds `--single-threaded` to every invocation, as required by the iOS W^X model.
- Injects `libios-posix-compat.dylib` through `DYLD_INSERT_LIBRARIES` when the file is
  present.
- Forwards all remaining arguments unchanged.

Direct execution of `/var/jb/usr/lib/node26/node` bypasses the launcher and therefore
requires `--single-threaded` and, when POSIX compatibility is needed,
`DYLD_INSERT_LIBRARIES=/var/jb/usr/lib/node26/libios-posix-compat.dylib`.

Package configuration, upgrade and uninstallation details are documented in
[`docs/ROOTLESS_PACKAGE.md`](docs/ROOTLESS_PACKAGE.md).

## Runtime contents

- Node.js 26.13.0 with V8 14.6.202.34, full ICU and WebAssembly enabled.
- `node:ffi` support through bundled libffi, including callback handling used by the
  OpenTUI renderer.
- mprotect-based RW-to-RX code-page management for V8, with no MAP_JIT or RWX requests.
- The minimal two-key entitlement set: `platform-application` and
  `com.apple.private.security.no-sandbox`.
- `libios-posix-compat.dylib`, an interposition library for POSIX facilities unavailable
  on iOS.

## Verification

The runtime was validated on an iPhone SE 2 (`iPhone12,8`), iOS 16.1.1, Dopamine rootless.
Results from the accepted build:

| Area | Result |
| --- | --- |
| JIT and WebAssembly | `%GetOptimizationStatus` returns 41; wasm result 42; wasm memory growth and repeated compilation pass |
| File I/O and pipes | `open`, `write`, `fsync`, `read`, `close`, `unlink`, pipe round trip and asynchronous `fs.open` pass |
| sysctl | `sysctlbyname` and `sysctl` MIB reads pass for `kern.osrelease` and `hw.machine` |
| Process control | `posix_spawn`, `waitpid`, `execve`, `spawn`, `spawnSync`, `execFile` and `exec` pass |
| POSIX shared memory and semaphores | `shm_open` mapping, named semaphores, unnamed `sem_init` and System V `shmget`/`shmat`/`shmdt`/`shmctl` pass |
| POSIX matrix summary | **21 PASS / 0 UNSUPPORTED / 0 RESTRICTED / 0 FAIL**, exit status 0 |
| FFI | `node:ffi` loads a signed iPhoneOS dylib and invokes native callbacks |
| Runtime checks | 11 packaged checks, 192 HTTP requests, 24 wasm modules, argument/stdin handling and REPL exit pass |
| OpenCode integration | The dependent OpenCode `2.2.5-5` / `node26test.8` package renders the full terminal interface and completes tool turns |

The detailed device report, including raw returns and errno values, is in
[`docs/POSIX_JIT_WASM_DEVICE_RESULTS.md`](docs/POSIX_JIT_WASM_DEVICE_RESULTS.md).
Structured evidence is in
[`docs/evidence/posix-jit-wasm-20261103-compat.json`](docs/evidence/posix-jit-wasm-20261103-compat.json).

The GitHub Actions workflows perform static validation only. Hosted runners cannot
execute iPhoneOS binaries; device acceptance remains a separate manual step.

## POSIX compatibility shim

The launcher injects `libios-posix-compat.dylib` through dyld interposition. The library
provides the following replacements:

- `sem_init`, `sem_destroy`, `sem_wait`, `sem_trywait`, `sem_post` and `sem_getvalue` for
  unnamed POSIX semaphores. The implementation uses a process-local mutex and condition
  variable table. Named semaphores continue to be handled by libSystem.
- `shmget`, `shmat`, `shmdt` and `shmctl` backed by POSIX `shm_open` and
  `mmap(MAP_SHARED)`. `IPC_PRIVATE` identifiers are mapped to deterministic names derived
  from the identifier, which allows a separate process to attach to the same segment.

Scope and limitations:

- Unnamed semaphores are process-local. The `pshared` argument is accepted but does not
  provide cross-process sharing.
- System V shared memory is emulated on POSIX shared memory. System V semaphores and
  message queues are not implemented.
- Programs that execute the runtime binary directly must set `DYLD_INSERT_LIBRARIES`
  themselves.

The compatibility scope and remaining boundaries are documented in the device report.

## Build pipeline

Pinned inputs:

| Input | Value |
| --- | --- |
| Node.js source | `https://nodejs.org/dist/v26.13.0/node-v26.13.0.tar.gz` |
| Source tarball SHA-256 | `986ead18ef18256831bae3e57d94aef680a7b84cfd4044f3e8471f833fbd7191` |
| V8 | 14.6.202.34 |
| Xcode / SDK | 16.4 / iPhoneOS SDK 18.5 (`macos-15` runner) |
| Target | iPhoneOS arm64, minimum iOS 15.0 |
| Entitlements | exactly two keys, `ldid`-signed |

| Workflow | Purpose |
| --- | --- |
| `build-runtime.yml` | Fetch the pinned source, cross-compile, sign and audit the runtime; publishes the standard and FFI runtime artifacts |
| `package-rootless.yml` | Assemble the `node26-rootless` deb from the accepted runtime and validate the payload with `dpkg-deb` |
| `build-posix-probe.yml` | Build the signed POSIX test bridge used by the device matrix |

| Patch | Purpose |
| --- | --- |
| `0001-configure-ios.patch` | Map `--dest-os=ios` to the gyp `ios` target |
| `0002-common-gypi-ios.patch` | Add iOS `target_defaults` and macOS host-toolset overrides |
| `0003-gyp-make-ios.patch` | Add iOS support to the bundled gyp make generator |
| `0004-gyp-empty-ios-deployment-target.patch` | Avoid an invalid deployment-target flag for host toolsets |
| `0005-cares-ios-no-sys-random.patch` | Use `arc4random_buf` instead of the unavailable `sys/random.h` |
| `0006-node-crypto-ios-no-sectrustsettings.patch` | Exclude macOS-only `SecTrustSettings` APIs on iOS |
| `0007-v8-ios-mprotect-wx.patch` | Implement mprotect-based RW-to-RX code-page transitions for V8 on iOS |

Build and validation procedures, including the full patch rationale and failure-class
history, are documented in [`docs/RUNTIME_BUILD.md`](docs/RUNTIME_BUILD.md).

## Repository layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/build-runtime.yml` | Cross-compile, sign and audit the native runtime |
| `.github/workflows/package-rootless.yml` | Assemble and validate the `node26` Debian package |
| `.github/workflows/build-posix-probe.yml` | Build the signed POSIX test bridge |
| `scripts/build-ios-runtime-node26.sh` | Reproducible build script with `configure`, `build`, `package`, `all` and `audit` stages |
| `scripts/package-rootless-node26.py` | Debian package assembler |
| `scripts/check_macho.py` | Mach-O, platform, architecture, minimum-OS and dylib validator |
| `scripts/ios-runtime/entitlements.plist` | The two-key entitlement set used for signing |
| `patches/nodejs26/` | The iOS patch series, applied in filename order |
| `packaging/` | Launcher, runtime pin and compatibility pin |
| `tests/posix-jit-wasm.cjs` | Device POSIX, JIT and WebAssembly matrix |
| `tests/native-posix-probe.c` | Native test bridge source |
| `docs/RUNTIME_BUILD.md` | Build design and validation protocol |
| `docs/POSIX_JIT_WASM_DEVICE_RESULTS.md` | Device test report |
| `LICENSE`, `NOTICE.md` | MIT license and attribution |

## Device verification protocol

On the target iPhone with the runtime binary copied to a writable directory and marked
executable:

```sh
./node --version
./node --jitless -e 'console.log(1 + 1)'
./node --single-threaded -e 'let s=0;for(let i=0;i<3e6;i++)s+=i*i%7;console.log(s)'
./node --single-threaded -e 'console.log(typeof WebAssembly)'
./node --single-threaded -e 'fetch("https://nodejs.org/dist/index.json").then(r=>console.log(r.status))'
./node --single-threaded --experimental-ffi -e 'require("node:ffi")'
```

Required conditions:

- `--single-threaded` is mandatory for JIT and WebAssembly execution. The V8 W^X toggle
  applies to the entire process.
- `--jitless` mode does not require `--single-threaded`.
- The two-key entitlement set is sufficient because the runtime does not request
  MAP_JIT or the JIT entitlement.
- The runtime must reside on a path from which dyld may map executable code; `/var/mobile`
  paths are rejected, while root-owned `/var/jb` paths work.

## Limitations

- Multithreaded execution is not supported and triggers SIGBUS when V8 JIT threads race
  the process-wide mprotect toggle.
- Node user-facing `worker_threads` are not supported for the same reason.
- The POSIX shim implements only the facilities listed above. System V semaphores and
  message queues are not available, and unnamed semaphores are process-local.
- Native `execve` replaces the process correctly, but output written by the new process to
  an inherited stdout pipe is not captured in the test environment. Programs that require
  captured output should use `child_process.spawn`, `execFile` or `exec`.
- Only iPhone SE 2 / iOS 16.1.1 has been validated. Other devices and iOS versions require
  separate acceptance.
- CI validates assembly and static properties only.

## License and attribution

Node.js and V8 are MIT-licensed; the upstream `LICENSE` is included. The patches in this
repository are provided under the same MIT terms. See [`NOTICE.md`](NOTICE.md) for
attribution details.
