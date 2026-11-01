# Node.js 26.13.0 iPhoneOS runtime — Phase A (build feasibility gate)

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
| run (cache-resume) | workflow/script-only disk-cleanup + `df`/`du` telemetry changes; patch series and cache epoch unchanged -> expects a cache hit and incremental completion of the 0001..0007 build; awaiting result. |