# Node.js 26.13.0 iPhoneOS runtime — Phase A (build feasibility gate)

> Current acceptance includes the standalone Node 26.13.0 package and the
> [JIT/wasm + POSIX device matrix](POSIX_JIT_WASM_DEVICE_RESULTS.md): 19 PASS,
> 2 UNSUPPORTED, no unexpected failures. The phase notes below preserve build history.

Status: **Phase A in progress** — goal is a CI-green native iPhoneOS arm64 Node
26.13.0 `node` executable plus static Mach-O/entitlement validation. V8 14.6's
iOS executable-memory model is **not** adapted to iOS 16.1.1 yet (Phase B), so
JIT/WebAssembly execution on the device is expected to need that follow-up work.

## Why Node 26

The real OpenTUI TUI loads its native Zig core through Node's `node:ffi`, which
exists since Node 26.1 and requires Node >= 26.4. The device-verified runtime is
Node 22.9.0, which has neither `--experimental-ffi` nor `node:ffi`
(device-confirmed: `bad option: --experimental-ffi`). Node 26 is therefore the
Phase A prerequisite; Phase B then ports our V8 W^X work to V8 14.6, and Phase C
covers the OpenTUI Zig kernel/FFI bring-up.

## Pins

| Item | Value |
| --- | --- |
| source | `https://nodejs.org/dist/v26.13.0/node-v26.13.0.tar.gz` (upstream nodejs/node; no nodejs-mobile branch exists for 24/26) |
| tarball sha256 | `986ead18ef18256831bae3e57d94aef680a7b84cfd4044f3e8471f833fbd7191` (127,162,302 B) |
| Node version | 26.13.0 (V8 14.6.202.34) |
| Xcode / SDK | 16.4 / iPhoneOS SDK 18.5 |
| target | iPhoneOS arm64, `IPHONEOS_DEPLOYMENT_TARGET=15.0` |

## Patches (`patches/nodejs26/`)

`0011-wasm-ios-platform-page-allocator.patch` -- **Phase B wasm fix**: with 0009
in place, device testing confirmed JIT works but WebAssembly trapped with
`V8_Fatal` from `WasmCodeManager::TryAllocate`. V8 14.6's Chrome-iOS-only
`GetPageAllocator()` branch requires `IsolateGroup::current()->GetCodeRange()`
(the Chrome assumption: MAP_JIT is usable once and the CodeRange consumed it) and
otherwise hits `UNREACHABLE()`. This Node build has no pointer compression, so
there is no CodeRange, and MAP_JIT is disabled entirely (0005/0007). Patch 0011
falls back to `GetPlatformPageAllocator()` on iOS when no CodeRange allocator
exists and reserves wasm code space with plain `kNoAccess` instead of the
`kNoAccessWillJitLater` MAP_JIT hint; `WasmCodeManager::Commit()` (0007) already
grants RW then RX and registers the range for the write scopes.

`0007-v8-ios-mprotect-wx.patch` -- **Phase B**: V8 14.6 assumes Chrome-iOS
semantics for executable memory (MAP_JIT / RWX code pages / BrowserEngineCore
for iOS 17.4+), none of which work on the target iPhone (iOS 16.1.1: MAP_JIT mmap
= EINVAL, RWX requests silently drop PROT_EXEC, `pthread_jit_write_protect_np`
absent). The patch ports the **device-verified Node 22.9 model** to V8 14.6:
`V8_HAS_PTHREAD_JIT_WRITE_PROTECT=1` on iOS arm64; a new
`src/base/platform/platform-ios.cc` implements `RegisterIOSCodeRange()` and
`SetJitWriteProtected()` as a plain `mprotect` RW<->RX toggler over registered
code ranges; the code range is reserved `PROT_NONE` and each executable chunk is
committed RW and registered (`memory-allocator.cc`); re-embedded builtins and
wasm code spaces commit RW->RX and register; `platform-posix.cc` never requests
MAP_JIT on iOS; `mutable-page.h` never requests RWX when write scopes are
enabled; `code-range.cc`/`wasm-code-manager.cc` iOS branches are adjusted
accordingly; `tools/v8_gypfiles/v8.gyp` compiles `platform-ios.cc` for the iOS
target. Non-iOS behaviour is unchanged (all edits are
`V8_OS_IOS`/`V8_TARGET_OS_IOS`-guarded). This keeps the same launcher constraint
as the Node 22 runtime: **`--single-threaded`** is required for JIT/wasm because
the mprotect toggle is process-wide.

`0006-node-crypto-ios-no-sectrustsettings.patch` — `src/crypto/crypto_context.cc`
guards the macOS keychain/trust-settings certificate reader with
`#ifdef __APPLE__` (also true on iOS), but the `SecTrustSettings*` APIs only
exist in the macOS Security framework. The iOS build failed with `use of
undeclared identifier 'kSecTrustSettingsApplication'` (and the related
`kSecTrustSettings*`/`SecTrustSettings*` symbols). The patch guards the Apple
trust-store implementation with `defined(__APPLE__) && !TARGET_OS_IPHONE` and
makes the system-certificate dispatch fall through to
`GetOpenSSLSystemCertificates()` on iOS (bundled/default root certs unchanged;
only `--use-system-ca` finds no Apple keychain on iOS).

`0005-cares-ios-no-sys-random.patch` — Node 26's c-ares ships one
`config/darwin/ares_config.h` for macOS and iOS, and it defines
`HAVE_SYS_RANDOM_H` (present in the macOS SDK but NOT in the iPhoneOS SDK). The
iOS build failed with `../deps/cares/src/lib/util/ares_rand.c:37:12: fatal error:
'sys/random.h' file not found`. iOS uses `arc4random_buf()` (already enabled via
`HAVE_ARC4RANDOM_BUF` in that config), so the patch leaves
`HAVE_SYS_RANDOM_H` undefined (matching Node 22's c-ares darwin config).

`0004-gyp-empty-ios-deployment-target.patch` — Node 26's `xcode_emulation.py`
emitted `-miphoneos-version-min=` (empty value) whenever
`IPHONEOS_DEPLOYMENT_TARGET` was present in the merged settings. The
`_toolset=="host"` override intentionally sets it to `''` so ICU/node host tools
build for macOS, which combined with our `-mmacosx-version-min=13.5` and made
clang fail with `error: invalid argument '-mmacosx-version-min=13.5' not allowed
with '-miphoneos-version-min='` (host abseil objects). The patch only emits the
iPhoneOS flag when the deployment target value is non-empty (matching the
truthiness check `xcode_emulation` already uses for `isIOS`).

`0003-gyp-make-ios.patch` (provided by the Lead, verified against pristine
v26.13.0) — Node 26 bundles a newer Chromium gyp whose **make generator** only
recognizes the `mac` flavor (only the Xcode generator understands iOS, and
Chromium does not build iOS through gyp; nodejs-mobile's Node 22 gyp fork carried
the iOS handling). Without this, `--dest-os=ios` emits no `-isysroot`,
`-miphoneos-version-min`, `-arch` or `-std=gnu++20` flags and bundled abseil
fails with `"C++ versions less than C++17 are not supported."`. The patch ports
the minimal `ios` flavor handling into `tools/gyp/pylib/gyp/generator/make.py`
(17 sites: OS default, XcodeSettings creation, cflags/cflags_cc/ldflags from
xcode_settings, action env expansion, library/rpath/install_name handling, flock
helper) and `tools/gyp/pylib/gyp/common.py` (mac_toolchain_dir). No
`xcode_emulation.py` change is needed: Node 26's copy already understands iOS
(`_archs` includes iphoneos/iossim, IPHONEOS_DEPLOYMENT_TARGET and SDKROOT
handling).

`0001-configure-ios.patch` — Node 26 lists `ios` in `valid_os` but only maps
android to a gyp `OS` value. This sets `o['variables']['OS']='ios'` and
`iossim=false` for `--dest-os=ios`, selecting the upstream iOS gyp branches in
`tools/v8_gypfiles/toolchain.gypi`, `tools/v8_gypfiles/v8.gyp`, `deps/uv`,
`deps/zlib`, `deps/cares`, `tools/icu` and `node.gyp(i)`.

`0002-common-gypi-ios.patch` — adds the missing iPhoneOS `target_defaults` block
to `common.gypi` (the equivalent of nodejs-mobile Node 22's `OS=="ios"` block):
Xcode settings (`SDKROOT=iphoneos`, `IPHONEOS_DEPLOYMENT_TARGET=15.0`,
`ARCHS=arm64`, `CLANG_CXX_LANGUAGE_STANDARD=gnu++20`, `-Wl,-no_pie`), plus
`_toolset=="host"` overrides that keep ICU/node host tools as runnable macOS
binaries during the cross build. It also adds `iossim` and includes `ios` in the
V8 archive path variables.

## Build recipe

`scripts/build-ios-runtime-node26.sh` (used by
`.github/workflows/build-runtime.yml`):

```
GYP_DEFINES="target_arch=arm64 host_os=mac target_os=ios"
./configure --dest-os=ios --dest-cpu=arm64 --cross-compiling \
  --with-intl=full-icu --openssl-no-asm \
  --without-node-code-cache --without-node-snapshot \
  --without-ffi --v8-disable-temporal-support
make -j3
```

- `--without-ffi` defers libffi/iOS bring-up to Phase C (FFI is what OpenTUI
  needs, but it is not needed for the Phase A build gate).
- `--v8-disable-temporal-support` avoids a Rust toolchain: Node 26's Temporal
  support (ICU4X) needs cargo/rustc >= 1.86 and cross-compiling Rust to
  `aarch64-apple-ios` is out of scope for Phase A/Phase C's JS-only TUI goal.

The job restores a cached `nodejs26/out/Release` tree (keyed on the patch
series sha256 + cache epoch) so iterations are incremental; a cache miss falls
back to a clean cold build.

## Validation (CI, static only)

- Mach-O iPhoneOS arm64 executable (scripts/check_macho.py --max-minos 16.1.1)
- `xcrun vtool` platform IOS, minos <= 16.1.1
- `xcrun otool -L` allowlist: only `/usr/lib/` and
  `/System/Library/Frameworks/` dependencies
- full-ICU present (`v8_enable_i18n_support=1`, multi-signal audit)
- WebAssembly compiled in (`v8_enable_webassembly=1`)
- ldid ad-hoc signature with the same device-verified **2-key** entitlement set
  used by the Node 22 runtime (`platform-application` +
  `com.apple.private.security.no-sandbox`), exact-set gate
- `runtime-manifest.json` (node sha256/size/dylibs, pins, patch hashes) and
  `SHA256SUMS`

GitHub-hosted runners cannot execute iPhoneOS binaries, so the artifact is
marked `UNVERIFIED ON DEVICE`. Device testing of the Phase A artifact checks the
minimum: `node --version`, `node --jitless -e 'console.log(1+1)'`,
`process.platform`, and what JIT/wasm do before the Phase B W^X work.

## Device verification (iPhone SE 2, iOS 16.1.1, Dopamine rootless)

### Phase A — PASS (run 41354422221 artifact, node sha256 `506c5511...`)

| Check | Device result |
| --- | --- |
| `./node --version` | `v26.13.0`, rc=0 |
| `./node --jitless -e ...` | `jitless_js=2 platform=ios arch=arm64 node=v26.13.0`, rc=0 |
| on-device sha256 | matches the artifact (`506c55110772...`) |

So the first CI-built Node.js 26.13.0 iPhoneOS arm64 runtime **runs on the device**.

### Phase B — **DEVICE-VERIFIED PASS** (artifact sha `68b63d8acf62...`, run 41394232084)

Device: iPhone SE 2 (iPhone12,8) / iOS 16.1.1 20B101 / Dopamine rootless,
runtime at `/var/mobile/ocdev/node26/node-0011`, on-device sha256 matches the artifact,
2-key entitlements. Patch series 0001..0011.

| Check | Device result |
| --- | --- |
| `node --version` | `v26.13.0`, rc=0 |
| `node --jitless -e ...` | rc=0 (`platform=darwin` regression still present in this build; fixed by 0012 in the FFI variant) |
| `node --single-threaded` JIT loop (3M iterations) | `jit_loop=5999999`, rc=0 |
| `node --single-threaded` **WebAssembly compile+instantiate** | **`wasm_foo=42`, rc=0** |
| `node --single-threaded` `fetch("https://nodejs.org/dist/index.json")` | **`fetch_status=200`, rc=0** |
| `node --single-threaded` Intl.Segmenter | `intl=object segs=2`, rc=0 |
| crash logs (`node-0011*.ips`) | **none** |
| default (no `--single-threaded`) JIT | SIGBUS, as designed (process-wide mprotect toggle races V8 background threads) — launcher MUST pass `--single-threaded` |

Failure classes fixed along the way (all device-diagnosed, patches in the series):
0007 (mprotect RW<->RX write-scope machinery + registered ranges), 0009 (register every
executable chunk and start it RX in `AllocateAlignedMemory`; the 0007 registration site was
dead code in V8 14.6), 0011 (wasm code space from the platform page allocator instead of the
Chrome-iOS `UNREACHABLE()` CodeRange/MAP_JIT branch). The crash logs and exact stacks are
summarised in the device-evidence notes; none of them required entitlement changes.

### Phase C — **DEVICE-VERIFIED PASS**: node:ffi + OpenTUI dylib (FFI artifact, run 41423525481)

Dispatch the workflow with `with_ffi=true` to build the FFI-enabled runtime; the artifact is
`ios-node26-runtime-ffi` (node **134,682,704 bytes sha256 `f4b75cc83c0538010b3bb788d5c916e6ef77180cd94e1f54fed46c71f49218ad`**, patches 0001..0012,
bundled `deps/libffi` cross-built for iPhoneOS, manifest variant `node26-phaseab-ffi`,
`ffi_support: enabled`, `launcher.required_flags=["--single-threaded"]`).

| Check | Device result |
| --- | --- |
| `node --version` / `--jitless` | v26.13.0 / rc=0 |
| `process.platform` | **`ios`** (patch 0012 split the macOS node.gypi block from a dedicated iOS block) |
| `--experimental-ffi -e "typeof require('node:ffi').dlopen"` | **`function`** |
| `node:ffi` dlopen `/var/jb/usr/lib/opencode/libopentui.dylib` | **`ffi_dlopen=ok keys=lib,functions`** — signed iPhoneOS renderer dylib loads through libffi |
| `--single-threaded` JIT loop | `jit_loop=5999999`, rc=0 |
| `--single-threaded` wasm | `wasm_foo=42`, rc=0 |
| `--single-threaded` fetch | `fetch_status=200`, rc=0 |

This is the runtime side of Phase D: `node:ffi` (default-on in Node 26.13, libffi closures/trampolines
working on iOS) can load the OpenTUI native renderer, so the CLI/TUI layer (patched OpenTUI asset
resolver for `ios-arm64`, node26 CLI variant, node26 .deb variant) is what remains for the real TUI.

## Remaining work (Phase B/C risks)

- **Phase B -- V8 14.6 iOS W^X: implemented in patch 0007**, pending CI +
  device verification. V8 14.6's iOS model expects MAP_JIT/RWX code pages
  (BrowserEngineCore, iOS 17.4+); iOS 16.1.1 only supports plain `mprotect`
  RW<->RX toggling, so `RwxMemoryWriteScope` is implemented over registered
  ranges with the same design as the device-verified Node 22.9 runtime. Expected
  device constraint: `--single-threaded` for JIT/wasm (process-wide toggle).
- **Phase C — node:ffi + OpenTUI Zig kernel:** enable `--experimental-ffi`
  without `--without-ffi`, cross-build `deps/libffi` for iPhoneOS, adapt
  `src/ffi/jit_memory.cc` to the iOS 16.1.1 mprotect model, then cross-build
  OpenTUI's Zig core (native renderer packages are currently darwin/linux/win32
  only) and load it via `node:ffi`.

## CI runs

| Run | Result |
| --- | --- |
| 41296656414 | failed at configure gate: config.gypi is JSON with a `#` comment header; validation greps fixed. |
| 41297273225 | failed at configure gate: config.gypi comment-prefix handling fixed (JSON parse after stripping comment lines). |
| 41297837897 | configure passed, make failed on the first real error class: bundled abseil/gtest compiled without `-std=gnu++20` because Node 26's gyp make generator had no iOS flavor handling → fixed by patch 0003 (Lead-provided). |
| 41301667378 | make failed on the next class: host-toolset abseil objects got both `-mmacosx-version-min=13.5` and an empty `-miphoneos-version-min=` from `xcode_emulation.py` → fixed by patch 0004. |
| 41302321280 | make failed on `deps/cares`: `'sys/random.h' file not found` (darwin config defines HAVE_SYS_RANDOM_H, absent on iOS) → fixed by patch 0005. |
| 41303097661 | make failed at Node sources after deps+V8 compiled: `src/crypto/crypto_context.cc` macOS SecTrustSettings APIs undeclared on iOS → fixed by patch 0006. |
| 41312400752 | cancelled -- Node 26 work moved to this dedicated repository (opencode-ios is no longer the working repo for Node 26). |
| 41314436929 | first run in this repository: failed at "compute patch hash" because `.gitignore` initially ignored `patches/` (fixed by commit 72019d5). |
| 41314713730 | clean build (cache miss after the 0007 patch hash) of the full series 0001..0007; failed after **181 min** at the host V8 archive step with a runner/I-O class error, not a source error: `LIBTOOL-STATIC .../obj.host/tools/v8_gypfiles/libv8_initializers.a` -> `libtool: can't write to output file (Input/output error)`; `make: *** [node] Error 2` (disk had 58 GiB free at build start; a clean Node 26 build with host+target V8 and full ICU needs more). The run saved its partial out/Release tree to the Actions cache under the **same** key. |
| 41350663077 | cache-restore retry: `Cache restored from key: ...` and `restored tree was built from identical patch series + configure flags; keeping cached objects` (disk: 44 GiB free before cleanup -> 72 GiB after cleanup -> 34 GiB after cache restore). Build resumed incrementally and failed at the first **link** class: `LINK(target) out/Release/embedtest` -> `Undefined symbols for architecture arm64: _CFRelease, _CFStringGetCString, _CFStringGetLength, _CFStringGetMaximumSizeForEncoding, _CFTimeZoneCopyDefault, _CFTimeZoneGetName` from `libabseil.a(time_zone_lookup.o)` (abseil cctz uses CoreFoundation; the make generator does not propagate abseil's xcode_settings OTHER_LDFLAGS to dependent executables). |
| 41351981967 | cache-resume with `-framework CoreFoundation`/`Security` injected into the common.gypi iOS target conditions: **build+link succeeded** in ~4.5 min (`out/Release/node` produced, platform IOS arm64, minOS 15.0, deps libSystem/libc++/CoreFoundation/Security); failed only in static validation because the macOS-only dependency regex substring-matched `/Library/Frameworks` inside `/System/Library/Frameworks/`. |
| 41353212702 | dylib audit regex fixed to allow iOS `/System/Library/Frameworks/`; then failed the WebAssembly audit with 1/4 signals (Node 26 dropped the `v8_lite_mode` config variable, and the `nm | grep -q` signal was lost to SIGPIPE under `pipefail`). |
| **41354422221** | **GREEN — first successful `ios-node26-runtime` artifact** (commit 1d7c4d1): node **134,506,304 bytes sha256 `506c551107727cdcf9da4919d316410e039fdabb3efd3ad391ec54ea77479c9e`**, Mach-O iPhoneOS arm64 minOS 15.0/SDK 18.5, 2-key ldid signature revalidated after signing, dylibs libSystem/libc++/CoreFoundation/Security, ICU full-icu + WebAssembly audits passed (wasm 3/3: 30,737 nm symbols, 1,893 strings, config), patches 0001..0007, built with `--without-ffi` (Phase A/B runtime; node:ffi is Phase C). Whole run ~10 min thanks to the deep out/Release cache resume. Device verification pending. |
| 41380018062 | **GREEN — 0009 page-aligned fix artifact** (patches 0001..0009): node **134,506,304 B sha256 `627f12d374eb3e77f33d464cb87c89187dd5f51dded0312c91df447737db1485`**; device rebase: JIT loop + fetch + TLS pass with `--single-threaded` (see device section); WebAssembly hits the V8 `UNREACHABLE()` described above -> patch 0011. |
| **41394232084** | **GREEN — Phase B device-verified artifact** (patches 0001..0011): node **134,506,304 bytes sha256 `68b63d8acf621bbb9582aed50c1e06ab5db9c3f016bc000e76d4daa1fedd104b`**; on-device tests all pass with `--single-threaded` (JIT loop `jit_loop=5999999`, wasm `wasm_foo=42`, fetch HTTP 200, Intl `segs=2`, no crash logs); `--version`/`--jitless` OK; default multithreaded JIT SIGBUS as designed. First Node 26 iPhoneOS runtime with working JIT + WebAssembly + network. |
| **41423525481** | **GREEN — Phase C device-verified FFI artifact** (branch `ffi-variant`, dispatch `with_ffi=true`; patches 0001..0012): node **134,682,704 bytes sha256 `f4b75cc83c0538010b3bb788d5c916e6ef77180cd94e1f54fed46c71f49218ad`**, artifact **`ios-node26-runtime-ffi`**, bundled deps/libffi, manifest variant `node26-phaseab-ffi`, `ffi_support: enabled`. On device: `process.platform=ios`, `node:ffi.dlopen` is a function, dlopen of the signed OpenTUI renderer dylib succeeds (`ffi_dlopen=ok keys=lib,functions`), JIT/wasm/fetch regressions pass under `--single-threaded`. |
| run (canonical 0008) | canonical rebuild after moving the CoreFoundation/Security linkage into `0008-ios-frameworks.patch` (node.gyp/node.gypi/common.gypi) with the controlled gyp-incremental cache resume (`NODE26_ALLOW_GYP_INCREMENTAL=1`) and the Phase A+B manifest text; expecting the same binary sha; awaiting result. |
| 41355522281 | canonical 0008 rebuild (CoreFoundation/Security in the patch series; Phase A+B manifest text with launcher flags; gyp-incremental cache resume). |
| **41356565815** | **GREEN — Phase B fix artifact** (patches 0001..0009): node **134,506,304 bytes sha256 `1a42c140a07e8489ba08dd28e5457846f50a659fceec266926365a5e50667d40`**, Mach-O iPhoneOS arm64 minOS 15.0/SDK 18.5, 2-key signed, dylibs libSystem/libc++/CoreFoundation/Security, ICU+WebAssembly audits PASS, Phase A+B manifest with `launcher.required_flags=[--single-threaded]`, built with `--without-ffi`. The build took ~165 min because the cache tree was partial after the cancelled canonical run; subsequent iterations are cache-resumed. Device verification of Phase B (JIT/wasm/fetch with --single-threaded) pending. |
