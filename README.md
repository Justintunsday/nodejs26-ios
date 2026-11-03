# Node.js 26.13 for iPhoneOS (arm64) — jailbroken iOS port

A dedicated, reproducible **GitHub Actions build of Node.js 26.13.0 for iPhoneOS arm64**
(`iphoneos-arm64`, rootless `/var/jb` usage), cross-compiled from the pristine upstream
[`nodejs/node`](https://github.com/nodejs/node) `v26.13.0` source tarball.

This repository exists because the OpenCode iOS port needs a **Node >= 26.4 runtime with
`node:ffi`** to enable the real OpenTUI terminal UI. The previously device-verified Node 22.9
iPhoneOS runtime lives in the OpenCode port repository
([`Justintunsday/opencode-ios`](https://github.com/Justintunsday/opencode-ios)); this repository is
the standalone home of the Node 26 port so the runtime work can be reviewed, reused and released
independently.

## Status

The current accepted runtime is the FFI-enabled build from
[run 41549633128](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41549633128),
source `7cd359f377d9d37dfe13d929927cf67274451ec2`: **134,710,336 bytes**, SHA-256
`84613100b3d31a747a55d1132906bfef9417b15a1e33a4088ff1da5956e61ef9`.
It includes wasm trap-handler fix 0013, iOS libffi callback fixes 0014/0015 and
foreground-only V8 JobHandles 0016. This exact binary passed callback, editor,
192 HTTP / 24 wasm-module regression and packaged OpenCode TUI acceptance on
iPhone SE 2 / iOS 16.1.1. Main now contains those accepted source fixes.

An independent **`node26` rootless deb**, exposing **`node`**, is assembled by
[`package-rootless.yml`](.github/workflows/package-rootless.yml). Package
**`node26` `26.13.0-1`**, author **`nodejs`**, from
[run 41620234785](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41620234785)
is **DEVICE-VERIFIED for standalone runtime and dependent OpenCode use**:
**25,893,168 bytes**, SHA-256 `c6cda114912707b5c229178449e0cc0a641fa7165c270a8dd81456196fed9e51`. Installation, 11 runtime checks,
192 HTTP / 24 wasm-module stress, argument/stdin handling and REPL exit all passed.
The dependent OpenCode test.5 normal/3-turn TUI and headless/tool E2E also passed.
Three system Jetsam reports were observed; none lists Node as a terminated victim.
CI performs static checks only. See
[`docs/ROOTLESS_PACKAGE.md`](docs/ROOTLESS_PACKAGE.md) for installation, exact runtime
pin and the required single-threaded/worker-isolate limits. The package contains the
complete runtime under `/var/jb/usr/lib/node26/` and owns no OpenCode files.

Additional **JIT/wasm + POSIX device acceptance**: **19 PASS, 2 UNSUPPORTED,
0 unexpected FAIL**. Native file I/O, read-only sysctl, exec/spawn, cross-process
POSIX shared memory and named semaphores passed with TurboFan code and wasm active.
`sem_init` returns ENOSYS; System V `shmget` terminates its caller with SIGSYS.
The [test report](docs/POSIX_JIT_WASM_DEVICE_RESULTS.md) records those crash reports,
exact returns/errno, the dylib installation-path limitation and cleanup.

### Earlier phase evidence

**Phase A+B+C is DEVICE-VERIFIED.** The Phase B artifact from run
[41394232084](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41394232084) was tested on the
target iPhone (iPhone SE 2, iOS 16.1.1, Dopamine rootless, 2-key entitlements): `--version` v26.13.0,
`--jitless` rc=0, and with `--single-threaded` the JIT loop (`jit_loop=5999999`), WebAssembly
compile+instantiate (`wasm_foo=42`), `fetch https` (HTTP 200) and `Intl.Segmenter` all pass with no crash
logs; node **134,506,304 B**, sha256 `68b63d8acf621bbb9582aed50c1e06ab5db9c3f016bc000e76d4daa1fedd104b` (patches 0001..0011).
The default multithreaded mode still SIGBUSes by design: the mprotect W^X toggle is process-wide, so the
launcher must pass `--single-threaded` (same constraint as the device-verified Node 22.9 runtime).

**Phase C is device-verified too.** The FFI-enabled artifact from run
[41423525481](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41423525481) (`ios-node26-runtime-ffi`, workflow
input `with_ffi=true`; node **134,682,704 B**, sha256
`f4b75cc83c0538010b3bb788d5c916e6ef77180cd94e1f54fed46c71f49218ad`, patches 0001..0012, bundled `deps/libffi`) runs on the same device with:
`process.platform === 'ios'` (patch 0012), `typeof require('node:ffi').dlopen === 'function'`, and a
successful `node:ffi` dlopen of the signed OpenTUI renderer dylib
(`/var/jb/usr/lib/opencode/libopentui.dylib` -> `ffi_dlopen=ok keys=lib,functions`); JIT/wasm/fetch still
pass under `--single-threaded`. The default dispatch (without `with_ffi`) still builds the FFI-less
`ios-node26-runtime` for Phase A/B regression coverage.

Goals, in order:

1. **Phase A** — Node 26.13.0 builds as an iPhoneOS arm64 executable and passes static validation
   (Mach-O platform iOS, arm64, minOS ≤ 16.1.1, only iOS system dylibs, 2-key `ldid` signing,
   full-ICU, WebAssembly compiled in).
2. **Phase B** — V8 14.6 executes JIT/WebAssembly code on iOS 16.1.1 with the only mechanism the
   device allows: explicit `mprotect` RW→RX toggling (`--single-threaded` required, same trade-off
   as the device-verified Node 22 runtime). Patch `0007-v8-ios-mprotect-wx.patch`.
3. **Phase C** — `node:ffi` + a signed iPhoneOS native dylib is loadable on device (consumed by the
   OpenTUI renderer built in the OpenCode port repository).

## Repository layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/build-runtime.yml` | Fetch pinned source, cross-compile, sign and audit the native runtime; publishes standard/FFI runtime artifacts. |
| `.github/workflows/package-rootless.yml` | Assemble the standalone `node26-rootless` deb artifact from the exact accepted runtime; Linux `dpkg-deb` validates the payload. |
| `.github/workflows/build-posix-probe.yml` / `tests/posix-jit-wasm.cjs` | Build a small Apple-signed test bridge and exercise native operations with JIT/wasm on the device; no runtime rebuild. |
| `scripts/package-rootless-node26.py` / `packaging/` | Python deb assembler, `node` launcher and strict runtime pin; package ID `node26`, author `nodejs`. |
| `scripts/build-ios-runtime-node26.sh` | Reproducible build script (`configure` / `build` / `package` / `all`, plus `audit`): pinned source tarball SHA-256, patch series, out/Release cache handling, static audits and `runtime-manifest.json`. |
| `patches/nodejs26/` | The iOS build patch series (applied in filename order with `patch -p1`). |
| `scripts/check_macho.py` | Mach-O/iPhoneOS/arch/minOS/dylib validator used by the workflow. |
| `scripts/ios-runtime/entitlements.plist` | The device-verified minimal 2-key entitlement set (`platform-application`, `com.apple.private.security.no-sandbox`). |
| `docs/RUNTIME_BUILD.md` | Build design, patch rationale, failure-class run log, validation gates and device-verification protocol. |
| `NOTICE.md` / `LICENSE` | Node.js MIT license and this port's attribution notes. |

## Pinned inputs

| Input | Value |
| --- | --- |
| Node.js source | `https://nodejs.org/dist/v26.13.0/node-v26.13.0.tar.gz` |
| Tarball SHA-256 | `986ead18ef18256831bae3e57d94aef680a7b84cfd4044f3e8471f833fbd7191` |
| V8 | 14.6.202.34 |
| Xcode / SDK | 16.4 / iPhoneOS SDK 18.5 (`macos-15` runner) |
| Target | iPhoneOS arm64, min iOS 15.0 |
| Entitlements | exactly 2 keys, `ldid`-signed |

## Patch series (why each exists)

| Patch | Reason |
| --- | --- |
| `0001-configure-ios.patch` | Upstream Node 26 accepts `--dest-os=ios` in `valid_os` but never maps it to gyp `OS=ios` (only `android` is mapped). |
| `0002-common-gypi-ios.patch` | `common.gypi` has no iOS `target_defaults` (SDKROOT/ARCHS/deployment target) and no macOS host-toolset overrides for ICU/node host tools. |
| `0003-gyp-make-ios.patch` | Upstream Node 26's bundled gyp **make generator** only understands the `mac` flavor (Chromium iOS builds do not use gyp), so `--dest-os=ios` emitted no `-isysroot`/`-std=gnu++20` flags (abseil failed with "C++ versions less than C++17 are not supported"). |
| `0004-gyp-empty-ios-deployment-target.patch` | Empty `IPHONEOS_DEPLOYMENT_TARGET` for host toolsets produced an invalid `-miphoneos-version-min=` flag conflicting with `-mmacosx-version-min`. |
| `0005-cares-ios-no-sys-random.patch` | c-ares' shared darwin config requires `sys/random.h`, which the iPhoneOS SDK does not provide (iOS uses `arc4random_buf`). |
| `0006-node-crypto-ios-no-sectrustsettings.patch` | `src/crypto/crypto_context.cc` guards macOS-only `SecTrustSettings*` APIs with `__APPLE__`, which is also true on iOS. |
| `0007-v8-ios-mprotect-wx.patch` | V8 14.6's iOS model assumes RWX/MAP_JIT code pages (Chrome iOS); the device only allows explicit `mprotect` RW↔RX toggling. Implements `RwxMemoryWriteScope` over registered code ranges (`RegisterIOSCodeRange`, new `platform-ios.cc`), never requests RWX/MAP_JIT on iOS, and commits JIT/wasm pages RW→RX. |

## Build / validate

The GitHub Actions workflow is the only supported build path (macOS runner + Xcode SDK required).
Artifact `ios-node26-runtime` contains:

- `node` — thin Mach-O arm64 executable, platform iPhoneOS, signed with the 2-key entitlement set;
- `runtime-manifest.json` — pinned source/patch hashes, configure flags, static audit evidence,
  `device_status` that explicitly says **UNVERIFIED ON DEVICE** unless the binary SHA equals a
  device-verified build;
- `SHA256SUMS`, `check-macho-*.txt`, `ldid` entitlement dump, `vtool`/`otool` evidence and build logs.

## Device verification protocol (maintainers)

On the target iPhone (iOS 16.1.1, rootless):

```sh
# copy the artifact's node binary, chmod +x, then:
./node --version                    # expect v26.13.0
./node --jitless -e 'console.log(1+1)'
./node --single-threaded -e 'let s=0;for(let i=0;i<3e6;i++)s+=i*i%7;console.log(s)'
./node --single-threaded -e 'console.log(typeof WebAssembly)'
./node --single-threaded -e 'fetch("https://nodejs.org/dist/index.json").then(r=>console.log(r.status))'
./node --experimental-ffi -e 'require("node:ffi")'   # Phase C
```

Expected constraints (from the Node 22 port, device-proven): `--single-threaded` is required for
JIT/wasm on iOS (the V8 W^X toggle is process-wide); `--jitless` works without it; 2-key
entitlements are sufficient because no MAP_JIT/JIT entitlement is used.

## License and attribution

Node.js and V8 are MIT-licensed; the upstream `LICENSE` is included. This port's patches are
provided under the same MIT terms. See `NOTICE.md`.
