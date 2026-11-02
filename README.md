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

**Phase A+B is CI-green; device verification is in progress.** The first green artifact is
`ios-node26-runtime` from run
[41356565815](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41356565815): Node.js 26.13.0,
iPhoneOS arm64, minOS 15.0, 2-key `ldid` signature, node **134,506,304 B**, sha256
`1a42c140a07e8489ba08dd28e5457846f50a659fceec266926365a5e50667d40` (patches **0001..0009**, built with
`--without-ffi`). The first Phase-A artifact (run 41354422221, sha `506c5511...`) is device-verified to
run `--version`/`--jitless`; the 0009 build adds the Phase B W^X registration fix for JIT/wasm and is
awaiting device verification. Hosted macOS runners cannot execute iPhoneOS binaries; only the maintainers can run the
artifact on real hardware (iPhone SE 2, iOS 16.1.1, Dopamine rootless). Device results are recorded here
with build/run identifiers and SHA-256 values once available. Phase C (node:ffi + OpenTUI dylib) builds on
this runtime.

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
| `.github/workflows/build-runtime.yml` | The only workflow: fetch pinned tarball, apply patches, configure with `--dest-os=ios --dest-cpu=arm64`, cross-compile, `ldid`-sign, statically validate, upload `ios-node26-runtime` artifact + logs. |
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
