#!/usr/bin/env bash
#
# Build, sign and statically validate a native iPhoneOS arm64 Node.js 26.13.0
# runtime executable (the `node` CLI) from the upstream nodejs/node tarball.
#
# This is the Phase A feasibility gate for a future real TUI: OpenTUI's Node
# binding needs Node >= 26.4 + node:ffi, which the device-verified Node 22.9
# runtime cannot provide. Phase A only proves that Node 26 can be cross-built
# for iPhoneOS arm64 and statically validated; V8 14.6's iOS executable-memory
# model is NOT adapted to iOS 16.1.1 in this build (Phase B), so JIT execution
# on the device is expected to require that follow-up work.
#
# Source of truth (pinned):
#   https://nodejs.org/dist/v26.13.0/node-v26.13.0.tar.gz
#   sha256 986ead18ef18256831bae3e57d94aef680a7b84cfd4044f3e8471f833fbd7191
#   Node.js 26.13.0, V8 14.6.202.34
#
# Patches (patches/nodejs26/*.patch, applied in filename order with patch -p1):
#   0001 configure.py: map --dest-os=ios to gyp OS=ios / iossim=false
#   0002 common.gypi: iPhoneOS arm64 target defaults + macOS host-toolset
#        overrides so ICU/node host tools stay runnable during the cross build
#
# Usage: scripts/build-ios-runtime-node26.sh <subcommand>
#   prepare           download+verify+extract the pinned tarball, apply patches
#   normalize-cache   prepare a restored out/Release tree for incremental make
#   configure         run ./configure for iPhoneOS arm64 (fast gate)
#   build             run make -j N (produces out/Release/node)
#   package           ldid-sign, statically validate, write manifest/checksums
#   all               prepare + configure + build + package
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE_SRC="${NODE_SRC:-$ROOT/nodejs26}"
DIST="${DIST:-$ROOT/dist/ios-node26-runtime}"
LOG_DIR="${NODE26_LOG_DIR:-$ROOT/dist/node26-build-logs}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
ENTITLEMENTS="$ROOT/scripts/ios-runtime/entitlements.plist"
CHECK_MACHO="$ROOT/scripts/check_macho.py"
PATCH_DIR="$ROOT/patches/nodejs26"
TARBALL_CACHE="${TARBALL_CACHE:-$ROOT/.cache/nodejs26}"

NODE_VERSION="26.13.0"
NODE_TARBALL="node-v${NODE_VERSION}.tar.gz"
NODE_TARBALL_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"
NODE_TARBALL_SHA256="986ead18ef18256831bae3e57d94aef680a7b84cfd4044f3e8471f833fbd7191"

CONFIGURE_FLAGS=(
  --dest-os=ios
  --dest-cpu=arm64
  --cross-compiling
  --with-intl=full-icu
  --openssl-no-asm
  --without-node-code-cache
  --without-node-snapshot
  # Temporal support needs a Rust toolchain and cross-compiling Rust to
  # arm64-apple-ios is out of scope for the Phase A gate (FFI/TUI is Phase C).
  --v8-disable-temporal-support
)

# FFI (node:ffi via bundled deps/libffi) is enabled only when the workflow is
# dispatched with with_ffi=true (artifact ios-node26-runtime-ffi); the standard
# runtime keeps --without-ffi.
FFI_ENABLED="${NODE26_ENABLE_FFI:-0}"
if [[ "$FFI_ENABLED" != "1" ]]; then
  CONFIGURE_FLAGS+=(--without-ffi)
fi

log()  { printf '\033[36;1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33;1m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[31;1m[error] %s\033[0m\n' "$*" >&2; exit 1; }
stage() { log "$*"; }

require_tools() {
  [[ -f "$CHECK_MACHO" ]] || die "missing static validator: $CHECK_MACHO"
  for tool in python3 make curl tar shasum patch; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
  done
  [[ -f "$ENTITLEMENTS" ]] || die "missing entitlements: $ENTITLEMENTS"
}

version_from_source() {
  local header="$NODE_SRC/src/node_version.h"
  local major minor patch
  major="$(sed -n 's/^#define NODE_MAJOR_VERSION \([0-9]*\)/\1/p' "$header")"
  minor="$(sed -n 's/^#define NODE_MINOR_VERSION \([0-9]*\)/\1/p' "$header")"
  patch="$(sed -n 's/^#define NODE_PATCH_VERSION \([0-9]*\)/\1/p' "$header")"
  printf '%s.%s.%s' "$major" "$minor" "$patch"
}

require_patched_source() {
  [[ -d "$NODE_SRC" ]] || die "nodejs source not found: $NODE_SRC (run: $0 prepare)"
  [[ -f "$NODE_SRC/configure.py" ]] || die "$NODE_SRC does not look like a node source tree"
  local v
  v="$(version_from_source)"
  [[ "$v" == "$NODE_VERSION" ]] || die "expected Node $NODE_VERSION source, found $v"
  # One stable marker per patch in the series: a missing marker means the patch
  # series was not applied (or a patch changed without updating this check).
  grep -q "o\['variables'\]\['OS'\] = 'ios'" "$NODE_SRC/configure.py" \
    || die "patch series not applied: 0001 marker (configure.py OS=ios) missing"
  grep -q "'IPHONEOS_DEPLOYMENT_TARGET': '15.0'" "$NODE_SRC/common.gypi" \
    || die "patch series not applied: 0002 marker (common.gypi iPhoneOS target) missing"
  grep -q "SDKROOT': 'macosx'" "$NODE_SRC/common.gypi" \
    || die "patch series not applied: 0002 marker (common.gypi host-toolset override) missing"
  grep -q 'constexpr size_t job_worker_threads = 0' "$NODE_SRC/src/node_platform.cc" \
    || die "patch series not applied: 0016 marker (iOS foreground-only V8 JobHandles) missing"
}

# ---------------------------------------------------------------------------
# prepare: fetch the pinned tarball, verify it, extract and patch it
# ---------------------------------------------------------------------------
cmd_prepare() {
  require_tools
  mkdir -p "$TARBALL_CACHE" "$DIST" "$LOG_DIR"
  local tar_path="$TARBALL_CACHE/$NODE_TARBALL"
  if [[ ! -f "$tar_path" ]]; then
    log "downloading $NODE_TARBALL_URL"
    curl -fSL --retry 3 --retry-delay 5 -o "$tar_path.part" "$NODE_TARBALL_URL"
    mv "$tar_path.part" "$tar_path"
  fi
  local actual
  actual="$(shasum -a 256 "$tar_path" | awk '{print $1}')"
  [[ "$actual" == "$NODE_TARBALL_SHA256" ]] \
    || die "node26 tarball sha256 mismatch: got $actual want $NODE_TARBALL_SHA256"
  log "node26 tarball verified: sha256 $actual"
  rm -rf "$NODE_SRC"
  mkdir -p "$NODE_SRC"
  tar -xzf "$tar_path" -C "$NODE_SRC" --strip-components=1
  log "applying patches/nodejs26/*.patch"
  local patch_file applied=0
  for patch_file in "$PATCH_DIR"/*.patch; do
    [[ -f "$patch_file" ]] || die "no patches found in $PATCH_DIR"
    log "patch: $(basename "$patch_file")"
    shasum -a 256 "$patch_file"
    ( cd "$NODE_SRC" && patch -p1 --forward --batch < "$patch_file" )
    applied=$((applied + 1))
  done
  [[ "$applied" -gt 0 ]] || die "no patches applied"
  require_patched_source
  log "source prepared at $NODE_SRC (Node $(version_from_source)); patches applied: $applied"
}


# ---------------------------------------------------------------------------
# build-inputs fingerprint (patch series + configure flags) for cache reuse
# ---------------------------------------------------------------------------
patch_touched_files() {
  # Lists every path modified or created by the patch series. Handles both
  # `diff --git a/X b/X` headers and new-file sections (`--- /dev/null` /
  # `+++ b/path`, as used by 0007 for deps/v8/src/base/platform/platform-ios.cc).
  python3 - "$PATCH_DIR" <<'PY'
import pathlib
import re
import sys

patch_dir = pathlib.Path(sys.argv[1])
paths = set()
for patch_file in sorted(patch_dir.glob("*.patch")):
    lines = patch_file.read_text(encoding="utf-8", errors="replace").splitlines()
    prev = ""
    for line in lines:
        m = re.match(r"^diff --git a/(\S+) b/", line)
        if m:
            paths.add(m.group(1))
        elif line.startswith("+++ b/") and prev.startswith("--- /dev/null"):
            paths.add(line[len("+++ b/"):].strip())
        prev = line
for path in sorted(paths):
    print(path)
PY
}

patched_files_manifest() {
  printf '%s\n' "$NODE_SRC/out/Release/.node26-patched-files.sha256"
}

write_patched_files_manifest() {
  local manifest
  manifest="$(patched_files_manifest)"
  mkdir -p "$(dirname "$manifest")"
  python3 - "$NODE_SRC" "$manifest" "$PATCH_DIR" <<'PY'
import hashlib
import pathlib
import re
import sys

node_src, manifest_path, patch_dir = (
    pathlib.Path(sys.argv[1]),
    pathlib.Path(sys.argv[2]),
    pathlib.Path(sys.argv[3]),
)

paths = set()
for patch_file in sorted(patch_dir.glob("*.patch")):
    prev = ""
    for line in patch_file.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^diff --git a/(\S+) b/", line)
        if m:
            paths.add(m.group(1))
        elif line.startswith("+++ b/") and prev.startswith("--- /dev/null"):
            paths.add(line[len("+++ b/"):].strip())
        prev = line

entries = []
for rel in sorted(paths):
    path = node_src / rel
    if not path.is_file():
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    entries.append(f"{digest}  {rel}")
manifest_path.write_text("\n".join(entries) + ("\n" if entries else ""), encoding="utf-8")
print(f"wrote patched-files manifest with {len(entries)} entries")
PY
}

patch_build_system_files() {
  patch_touched_files | grep -E '^(configure\.py|common\.gypi|.*\.gypi?$|tools/gyp/)' | sort -u || true
}

build_inputs_fingerprint() {
  local patch_sha flags_sha build_system_sha
  patch_sha="$(cat "$PATCH_DIR"/*.patch | shasum -a 256 | awk '{print $1}')"
  flags_sha="$(printf '%s\n' "${CONFIGURE_FLAGS[@]}" | shasum -a 256 | awk '{print $1}')"
  build_system_sha="$(patch_build_system_files | shasum -a 256 | awk '{print $1}')"
  printf 'patch_sha=%s\nflags_sha=%s\nbuild_system_sha=%s\nnode_version=%s\n' \
    "$patch_sha" "$flags_sha" "$build_system_sha" "$NODE_VERSION"
}

cmd_normalize_cache() {
  local cache_hit="${1:-false}"
  require_patched_source
  if [[ ! -d "$NODE_SRC/out/Release" ]]; then
    log "no restored out/Release build tree; nothing to normalize (cache_hit=$cache_hit)"
    return 0
  fi
  log "normalizing source mtimes for incremental reuse of the restored build tree (cache_hit=$cache_hit)"
  find "$NODE_SRC" -path "$NODE_SRC/out" -prune -o -type f -exec touch -t 200001010000 {} +

  local marker="$NODE_SRC/out/Release/.node26-build-inputs"
  if [[ ! -f "$marker" ]]; then
    warn "cached tree has no build-inputs fingerprint (older cache); forcing a full rebuild"
    find "$NODE_SRC" -path "$NODE_SRC/out" -prune -o -type f -exec touch {} +
    return 0
  fi
  local cur cached cur_patch cur_flags cached_patch cached_flags
  local cur_bs cached_bs
  cur="$(build_inputs_fingerprint)"
  cached="$(cat "$marker")"
  cur_patch="$(printf '%s\n' "$cur" | sed -n 's/^patch_sha=//p')"
  cur_flags="$(printf '%s\n' "$cur" | sed -n 's/^flags_sha=//p')"
  cached_patch="$(printf '%s\n' "$cached" | sed -n 's/^patch_sha=//p')"
  cached_flags="$(printf '%s\n' "$cached" | sed -n 's/^flags_sha=//p')"
  cur_bs="$(printf '%s\n' "$cur" | sed -n 's/^build_system_sha=//p')"
  cached_bs="$(printf '%s\n' "$cached" | sed -n 's/^build_system_sha=//p')"
  if [[ "$cur_patch" == "$cached_patch" && "$cur_flags" == "$cached_flags" ]]; then
    log "restored tree was built from identical patch series + configure flags; keeping cached objects"
  elif [[ "$cur_flags" != "$cached_flags" ]]; then
    warn "configure flags changed; stamping all sources to now to force a correct full rebuild"
    find "$NODE_SRC" -path "$NODE_SRC/out" -prune -o -type f -exec touch {} +
  elif [[ -n "$cur_bs" && "$cur_bs" == "$cached_bs" ]]; then
    # Only source files changed (no configure.py/gyp change), so the cached
    # objects are still valid for all unchanged TUs. Re-stamp exactly the files
    # the patch series touches; make + the cached .deps rebuild their
    # dependents. This keeps Phase B iterations at minutes instead of ~2h.
    warn "patch series changed (source-only); re-stamping only files whose content changed"
    local manifest
    manifest="$(patched_files_manifest)"
    if [[ -f "$manifest" ]]; then
      # Compare current patched-file hashes against the manifest saved with the
      # cached build tree; touch only changed/new files. This is what keeps
      # Phase B/C iterations at minutes: touching every patched file (including
      # V8 headers) would recompile most of the tree through depfiles.
      python3 - "$NODE_SRC" "$manifest" "$PATCH_DIR" <<'PY'
import hashlib
import pathlib
import re
import sys

node_src, manifest_path, patch_dir = (pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]),
                                      pathlib.Path(sys.argv[3]))
cached = {}
for line in manifest_path.read_text(encoding="utf-8").splitlines():
    if "  " in line:
        digest, rel = line.split("  ", 1)
        cached[rel] = digest

paths = set()
for patch_file in sorted(patch_dir.glob("*.patch")):
    prev = ""
    for line in patch_file.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"^diff --git a/(\S+) b/", line)
        if m:
            paths.add(m.group(1))
        elif line.startswith("+++ b/") and prev.startswith("--- /dev/null"):
            paths.add(line[len("+++ b/"):].strip())
        prev = line

touched = []
for rel in sorted(paths):
    path = node_src / rel
    if not path.is_file():
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if cached.get(rel) != digest:
        path.touch()
        touched.append(rel)
print("touched changed patched files: " + (", ".join(touched) if touched else "(none)"))
PY
    elif [[ -n "${NODE26_TOUCH_FILES:-}" ]]; then
      # No cached manifest yet (first incremental run on this cache): trust the
      # explicitly listed files (workflow sets them for a verified source-only
      # fix); the manifest is written after a successful build so future runs
      # are fully automatic.
      warn "no cached patched-files manifest; NODE26_TOUCH_FILES is set; re-stamping only: $NODE26_TOUCH_FILES"
      local f
      for f in $NODE26_TOUCH_FILES; do
        [[ -f "$NODE_SRC/$f" ]] && touch "$NODE_SRC/$f"
      done
    else
      warn "no cached patched-files manifest and no NODE26_TOUCH_FILES; re-stamping all patched files"
      local f
      while IFS= read -r f; do
        [[ -n "$f" && -f "$NODE_SRC/$f" ]] && touch "$NODE_SRC/$f"
      done < <(patch_touched_files)
    fi
  elif [[ "${NODE26_ALLOW_GYP_INCREMENTAL:-0}" == "1" && "$cur_flags" == "$cached_flags" ]]; then
    # Controlled escape hatch for a gyp/link-only change (e.g. adding iOS
    # frameworks in 0008): configure flags are unchanged, so the cached object
    # files are still valid; configure regenerates out/Makefile with the new
    # link libraries and make only relinks. Re-stamp the build-system files so
    # gyp/make notice the change, but keep all cached objects.
    warn "gyp/link-only change and NODE26_ALLOW_GYP_INCREMENTAL=1 with unchanged configure flags; keeping cached objects (relink only)"
    local bs_file
    while IFS= read -r bs_file; do
      [[ -n "$bs_file" && -f "$NODE_SRC/$bs_file" ]] && touch "$NODE_SRC/$bs_file"
    done < <(patch_build_system_files)
  else
    # The build system (configure/gyp) or the configure flags changed: objects
    # may have been compiled with different flags, and the tarball source has no
    # .git to limit the rebuild safely (this bit us before: abseil/gtest
    # compiled without -std=gnu++20 prior to the gyp make-generator ios fix).
    warn "build-system files changed in the patch series; forcing a clean rebuild"
    find "$NODE_SRC" -path "$NODE_SRC/out" -prune -o -type f -exec touch {} +
  fi
}

# ---------------------------------------------------------------------------
# configure
# ---------------------------------------------------------------------------
cmd_configure() {
  require_tools
  require_patched_source
  cd "$NODE_SRC"
  log "nodejs26 source: $(pwd) (Node $(version_from_source))"
  export GYP_DEFINES="target_arch=arm64 host_os=mac target_os=ios"
  log "GYP_DEFINES=$GYP_DEFINES"
  log "configure ${CONFIGURE_FLAGS[*]}"
  # Snapshot hashes+mtimes of configure outputs so that, when a source-only
  # patch changes nothing about the build configuration, make does not see
  # config.gypi/Makefiles as newer and cascade a broad rebuild of generated
  # builtins (this is what made a 1-TU patch change take ~2h instead of minutes).
  local mtimes_file="$LOG_DIR/configure-output-mtimes.json"
  python3 - "$NODE_SRC" "$mtimes_file" snapshot <<'PY'
import hashlib
import json
import os
import pathlib
import sys

src, out_file = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
paths = [src / "config.gypi", src / "config.mk", src / "out/Makefile"]
paths += sorted((src / "out").rglob("*.mk")) if (src / "out").is_dir() else []
data = {}
for path in paths:
    if not path.is_file():
        continue
    st = path.stat()
    rel = path.relative_to(src).as_posix()
    data[rel] = [hashlib.sha256(path.read_bytes()).hexdigest(), st.st_mtime]
out_file.write_text(json.dumps(data), encoding="utf-8")
print(f"configure-output snapshot: {len(data)} files")
PY
  ./configure "${CONFIGURE_FLAGS[@]}" 2>&1 | tee "$LOG_DIR/configure.log"
  [[ -f out/Makefile ]] || die "configure succeeded but out/Makefile was not generated"
  python3 - "$NODE_SRC" "$mtimes_file" restore <<'PY'
import hashlib
import json
import os
import pathlib
import sys

src, out_file = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
try:
    data = json.loads(out_file.read_text(encoding="utf-8"))
except Exception:  # noqa: BLE001 - missing snapshot is non-fatal
    data = {}
restored = 0
for rel, (old_sha, old_mtime) in data.items():
    path = src / rel
    if not path.is_file():
        continue
    new_sha = hashlib.sha256(path.read_bytes()).hexdigest()
    if new_sha == old_sha:
        os.utime(path, (old_mtime, old_mtime))
        restored += 1
print(f"configure-output mtimes preserved for {restored}/{len(data)} unchanged files")
PY
  # Node 26 writes config.gypi as JSON (json.dumps), so validate the variables
  # as JSON instead of grepping the Node 22 pprint-style single-quote layout.
  python3 - out/Makefile config.gypi <<'PY'
import json
import os
import sys

makefile, gypi = sys.argv[1], sys.argv[2]
text = open(gypi, encoding="utf-8").read()
# Node 26 writes "# Do not edit. Generated by the configure script." followed
# by json.dumps(...); strip comment lines before parsing.
text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
variables = json.loads(text)["variables"]

errors = []
if variables.get("OS") != "ios":
    errors.append(f"OS={variables.get('OS')!r} (want 'ios')")
if int(variables.get("v8_enable_webassembly", 0)) != 1:
    errors.append(f"v8_enable_webassembly={variables.get('v8_enable_webassembly')!r}")
if int(variables.get("v8_enable_i18n_support", 0)) != 1:
    errors.append(f"v8_enable_i18n_support={variables.get('v8_enable_i18n_support')!r}")
if variables.get("target_arch") != "arm64":
    errors.append(f"target_arch={variables.get('target_arch')!r} (want 'arm64')")
want_ffi = os.environ.get("NODE26_ENABLE_FFI", "0") == "1"
have_ffi = str(variables.get("node_use_ffi", "false")).lower() == "true"
if want_ffi != have_ffi:
    errors.append(f"node_use_ffi={variables.get('node_use_ffi')!r} (want {'true' if want_ffi else 'false'})")
if errors:
    sys.exit("config.gypi validation failed: " + "; ".join(errors))
print(
    "config.gypi OK: OS=ios target_arch=arm64 "
    f"v8_enable_webassembly={variables.get('v8_enable_webassembly')} "
    f"v8_enable_i18n_support={variables.get('v8_enable_i18n_support')} "
    f"v8_lite_mode={variables.get('v8_lite_mode')} "
    f"icu_small={variables.get('icu_small')}"
)
PY
  if ! grep -q '^NODE_TARGET_TYPE=executable$' config.mk; then
    warn "config.mk has no NODE_TARGET_TYPE=executable; node may be built as a library"
  fi
  log "config.mk: $(grep -E '^(BUILDTYPE|NODE_TARGET_TYPE)=' config.mk | tr '\n' ' ')"
  mkdir -p out/Release
  build_inputs_fingerprint > out/Release/.node26-build-inputs
  log "configured OK for iPhoneOS arm64 (Node $NODE_VERSION)"
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
disk_report() {
  local label="$1"
  {
    echo "=== disk $label ($(date -u +%H:%M:%SZ)) ==="
    df -h || true
    du -sh "$NODE_SRC/out" 2>/dev/null || true
    du -sh "$NODE_SRC/out/Release/obj.host" 2>/dev/null || true
    du -sh "$NODE_SRC/out/Release/obj.target" 2>/dev/null || true
  } | tee -a "$LOG_DIR/disk.log"
}

cmd_build() {
  require_tools
  require_patched_source
  cd "$NODE_SRC"
  [[ -f out/Makefile ]] || die "out/Makefile missing; run: $0 configure"
  mkdir -p "$DIST" "$LOG_DIR"
  disk_report "before build"
  # Always leave a disk snapshot behind, including on interruption/early exit.
  trap 'disk_report "on exit"' EXIT
  log "make -j$JOBS (Node.js 26.13.0 iPhoneOS arm64; cold build typically 90-150 min on a 3 vCPU runner)"
  set +e
  make -j"$JOBS" 2>&1 | tee "$LOG_DIR/make.log"
  local rc=${PIPESTATUS[0]}
  set -e
  printf '%s\n' "$rc" > "$LOG_DIR/make-exit-code"
  disk_report "after build"
  if [[ "$rc" -eq 0 ]]; then
    write_patched_files_manifest
  fi
  if [[ "$rc" -ne 0 ]]; then
    warn "make failed with exit code $rc; first error lines:"
    grep -nE '(^|: )(error|fatal error|Error [0-9]+)' "$LOG_DIR/make.log" | head -n 30 || true
    disk_report "at failure"
    die "make failed (exit $rc); see $LOG_DIR/make.log"
  fi
  log "make finished OK (exit 0)"
}

# ---------------------------------------------------------------------------
# package: sign + statically validate + manifest
# ---------------------------------------------------------------------------
find_built_node() {
  local candidates=(
    "$NODE_SRC/out/Release/node"
    "$NODE_SRC/out/Release/node.exe"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  find "$NODE_SRC/out" -maxdepth 4 -type f -name node -perm -u+x 2>/dev/null | head -n 1
}

validate_static() {
  local bin="$1" stage="$2" file_out deps bad
  [[ -f "$bin" ]] || die "missing binary: $bin"
  [[ -x "$bin" ]] || die "binary is not executable: $bin"

  log "[$stage] file(1)"
  file "$bin" | tee "$DIST/file.txt"
  grep -q 'Mach-O 64-bit executable arm64' "$DIST/file.txt" \
    || die "unexpected file type (want Mach-O 64-bit executable arm64)"

  log "[$stage] scripts/check_macho.py --max-minos 16.1.1"
  python3 "$CHECK_MACHO" "$bin" --max-minos 16.1.1 | tee "$DIST/check-macho-$stage.txt"

  log "[$stage] xcrun vtool -show-build"
  xcrun vtool -show-build "$bin" | tee "$DIST/vtool-$stage.txt"
  grep -q 'platform IOS' "$DIST/vtool-$stage.txt" \
    || die "vtool did not report platform IOS (not an iPhoneOS binary)"
  grep -qE 'minos 1[0-6]\.' "$DIST/vtool-$stage.txt" \
    || warn "unexpected vtool minos (expected <= 16.1)"
  local minos
  minos="$(sed -n 's/.*minos \([0-9.]*\).*/\1/p' "$DIST/vtool-$stage.txt" | head -n1)"
  python3 - "$minos" <<'PY'
import sys
min_ios = tuple(int(x) for x in sys.argv[1].split('.'))
if min_ios > (16, 1, 1):
    sys.exit(f"minos {sys.argv[1]} is newer than the target device (iOS 16.1.1)")
print(f"minos {sys.argv[1]} is compatible with the target device (iOS 16.1.1)")
PY

  log "[$stage] xcrun otool -L dylib audit"
  xcrun otool -L "$bin" | tee "$DIST/otool-L-$stage.txt"
  deps="$(xcrun otool -L "$bin" | tail -n +2 | awk 'NF {print $1}')"
  bad="$(printf '%s\n' "$deps" | grep -vE '^(/usr/lib/|/System/Library/Frameworks/)' || true)"
  [[ -z "$bad" ]] || die "non-iOS-system dylib dependency detected: $bad"
  # Note: `/Library/Frameworks` must NOT match `/System/Library/Frameworks/`
  # (CoreFoundation/Security are legitimate iOS system frameworks linked by
  # patch 0008); only a path starting with /Library/Frameworks is macOS-only.
  if grep -qE '(/opt/homebrew|/usr/local/|/System/Library/PrivateFrameworks|@rpath)|(^|[[:space:]])/Library/Frameworks' \
      "$DIST/otool-L-$stage.txt"; then
    die "macOS-only or non-system dependency found in otool -L output (see $DIST/otool-L-$stage.txt)"
  fi

  log "[$stage] ICU/full-icu audit"
  local icu_evidence="$DIST/icu-evidence-$stage.txt"
  local nm_file="$DIST/nm-symbols-$stage.txt"
  local icu_signals=0
  nm -a "$bin" 2>/dev/null | grep -i ' _u_' > "$nm_file" || true
  if grep -qE ' (_u_strToUpper|_u_strToLower|_u_strlen|_icu_74|_icu_75|_icu_76|_icu_77|_icu_78)$' "$nm_file" 2>/dev/null; then icu_signals=$((icu_signals + 1)); fi
  if strings -a "$bin" 2>/dev/null | grep -qiE 'icudt[0-9]+[lb]?\.dat|International Components for Unicode|ICU [0-9]+\.[0-9]+'; then icu_signals=$((icu_signals + 1)); fi
  if python3 -c 'import json,sys; t=open(sys.argv[1]).read(); t="\n".join(l for l in t.splitlines() if not l.lstrip().startswith("#")); v=json.loads(t)["variables"]; sys.exit(0 if int(v.get("v8_enable_i18n_support",0))==1 else 1)' "$NODE_SRC/config.gypi"; then icu_signals=$((icu_signals + 1)); fi
  if python3 -c 'import json,sys; t=open(sys.argv[1]).read(); t="\n".join(l for l in t.splitlines() if not l.lstrip().startswith("#")); v=json.loads(t)["variables"]; sys.exit(0 if str(v.get("icu_small","")).lower()=="false" else 1)' "$NODE_SRC/config.gypi"; then icu_signals=$((icu_signals + 1)); fi
  {
    echo "== ICU signals ($icu_signals/4) =="
    echo "config.gypi: $(python3 -c 'import json,sys; t=open(sys.argv[1]).read(); t="\n".join(l for l in t.splitlines() if not l.lstrip().startswith("#")); v=json.loads(t)["variables"]; print(" ".join(f"{k}={v.get(k)}" for k in ("v8_enable_i18n_support","icu_small","icu_path","icu_version")))' "$NODE_SRC/config.gypi")"
    echo "nm u_* symbol matches: $(wc -l < "$nm_file" | tr -d ' ')"
    grep -m3 -iE 'icudt|International Components' "$DIST/nm-symbols-$stage.txt" 2>/dev/null || true
  } | tee "$icu_evidence"
  [[ "$icu_signals" -ge 2 ]] || die "ICU/full-icu not detected (signals $icu_signals/4); CLI Intl/\\p{} would fail"
  log "[$stage] ICU present: full-icu statically linked ($icu_signals/4 signals)"

  log "[$stage] WebAssembly audit"
  local wasm_evidence="$DIST/wasm-evidence-$stage.txt"
  local nm_wasm="$DIST/nm-wasm-$stage.txt"
  local str_wasm="$DIST/strings-wasm-$stage.txt"
  local wasm_signals=0
  # Signal 1: build configuration. Node 26 dropped the v8_lite_mode variable,
  # so only v8_enable_webassembly is checked here.
  if python3 -c 'import json,sys; t=open(sys.argv[1]).read(); t="\n".join(l for l in t.splitlines() if not l.lstrip().startswith("#")); v=json.loads(t)["variables"]; sys.exit(0 if int(v.get("v8_enable_webassembly",0))==1 else 1)' "$NODE_SRC/config.gypi"; then wasm_signals=$((wasm_signals + 1)); fi
  # Signal 2: wasm-related symbols in the linked binary. Capture nm output to a
  # file first: `nm ... | grep -q` is flaky under `set -o pipefail` because grep
  # exits early and nm then dies with SIGPIPE even when the match exists.
  nm -a "$bin" 2>/dev/null | grep -i 'wasm' > "$nm_wasm" || true
  if [[ -s "$nm_wasm" ]]; then wasm_signals=$((wasm_signals + 1)); fi
  # Signal 3: WebAssembly/wasm strings baked into the binary.
  strings -a "$bin" 2>/dev/null | grep -iE 'webassembly|wasm' > "$str_wasm" || true
  if [[ -s "$str_wasm" ]]; then wasm_signals=$((wasm_signals + 1)); fi
  {
    echo "== WebAssembly signals ($wasm_signals/3) =="
    echo "config.gypi: $(python3 -c 'import json,sys; t=open(sys.argv[1]).read(); t="\n".join(l for l in t.splitlines() if not l.lstrip().startswith("#")); v=json.loads(t)["variables"]; print(" ".join(f"{k}={v.get(k)}" for k in ("v8_enable_webassembly","v8_enable_wasm_code_gc","v8_enable_liftoff")))' "$NODE_SRC/config.gypi")"
    echo "nm wasm symbol matches: $(wc -l < "$nm_wasm" | tr -d ' ')"
    echo "strings wasm matches: $(wc -l < "$str_wasm" | tr -d ' ')"
    echo "Phase B note: V8 14.6 W^X is patched in 0007; device JIT/wasm still requires --single-threaded."
  } | tee "$wasm_evidence"
  [[ "$wasm_signals" -ge 2 ]] || die "WebAssembly not detected (signals $wasm_signals/3)"
  log "[$stage] WebAssembly present: enabled ($wasm_signals/3 signals)"

  log "[$stage] static validation PASSED (iPhoneOS arm64, system libraries only, full-icu + WebAssembly)"
}

sign_binary() {
  local bin="$1"
  command -v ldid >/dev/null 2>&1 || die "ldid not installed (brew install ldid)"
  log "ldid -S<entitlements> $bin"
  ldid -S"$ENTITLEMENTS" "$bin"
  log "embedded entitlements (ldid -e):"
  ldid -e "$bin" > "$DIST/entitlements-signed.xml" 2>&1 || true
  cat "$DIST/entitlements-signed.xml"
  python3 - "$DIST/entitlements-signed.xml" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as fh:
    data = fh.read()
try:
    plist = plistlib.loads(data)
except Exception as exc:  # noqa: BLE001 - report and fail hard
    sys.exit(f"could not parse signed entitlements: {exc}")
expected = {"platform-application", "com.apple.private.security.no-sandbox"}
actual = set(plist)
if actual != expected:
    sys.exit(f"signed entitlement set mismatch: got {sorted(actual)} want {sorted(expected)}")
print(f"entitlements OK: {len(actual)} device-verified keys {sorted(actual)}")
PY
}

write_manifest() {
  local bin="$1"
  export DIST NODE_SRC ROOT NODE_VERSION
  export NODE_TARBALL_SHA256 NODE_TARBALL_URL
  export NODE26_CONFIGURE_FLAGS_STR="${CONFIGURE_FLAGS[*]}"
  python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess

dist = pathlib.Path(os.environ["DIST"])
src = pathlib.Path(os.environ["NODE_SRC"])
root = pathlib.Path(os.environ["ROOT"])
node_version = os.environ["NODE_VERSION"]
tarball_sha = os.environ["NODE_TARBALL_SHA256"]
tarball_url = os.environ["NODE_TARBALL_URL"]
node = dist / "node"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_or(path, default=""):
    p = pathlib.Path(path)
    return p.read_text(encoding="utf-8", errors="replace").strip() if p.is_file() else default


def v8_version():
    header = src / "deps/v8/include/v8-version.h"
    vals = {}
    for line in read_or(header).splitlines():
        for key in ("V8_MAJOR_VERSION", "V8_MINOR_VERSION", "V8_BUILD_NUMBER", "V8_PATCH_LEVEL"):
            if line.startswith(f"#define {key} "):
                vals[key] = line.split()[-1]
    if len(vals) == 4:
        return f"{vals['V8_MAJOR_VERSION']}.{vals['V8_MINOR_VERSION']}.{vals['V8_BUILD_NUMBER']}.{vals['V8_PATCH_LEVEL']}"
    return read_or(src / "deps/v8/include/v8-version.h", "unknown")


vtool = read_or(dist / "vtool-signed.txt") or read_or(dist / "vtool-unsigned.txt")
minos = "unknown"
sdk = "unknown"
for line in vtool.splitlines():
    line = line.strip()
    if line.startswith("minos "):
        minos = line.split()[1]
    elif line.startswith("sdk "):
        sdk = line.split()[1]

dylibs = []
for line in read_or(dist / "otool-L-signed.txt").splitlines():
    line = line.strip()
    if line.startswith("/") and not line.endswith(":"):
        dylibs.append(line.split(" (")[0])

patches = []
for name in sorted(os.listdir(root / "patches/nodejs26")):
    if not name.endswith(".patch"):
        continue
    p = root / "patches/nodejs26" / name
    patches.append({"file": "patches/nodejs26/" + name, "sha256": sha256(p)})

config_gypi = read_or(src / "config.gypi")
configure_flags = os.environ.get("NODE26_CONFIGURE_FLAGS_STR", "").split()

manifest = {
    "artifact": "ios-node26-runtime",
    "variant": ("node26-phaseab-ffi" if os.environ.get("NODE26_ENABLE_FFI", "0") == "1"
                else "node26-phaseab"),
    "phase": (
        "A+B: iPhoneOS arm64 build + V8 14.6 iOS mprotect RW<->RX W^X (patch 0007). "
            + ("Phase C node:ffi enabled with iOS RW-to-RX callback trampoline tables (patches 0014/0015); V8 JobHandles use foreground Join only (patch 0016)."
               if os.environ.get("NODE26_ENABLE_FFI", "0") == "1"
               else "node:ffi disabled (--without-ffi).")
    ),
    "node_version": node_version,
    "v8_version": v8_version(),
    "target": {
        "platform": "iPhoneOS",
        "arch": "arm64",
        "min_ios_from_vtool": minos,
        "sdk_from_vtool": sdk,
        "max_supported_ios_device": "16.1.1 (test device: iPhone SE 2, iOS 16.1.1)",
    },
    "source": {
        "origin": "upstream nodejs/node dist tarball (no nodejs-mobile branch exists for Node 24/26)",
        "tarball_url": tarball_url,
        "tarball_sha256": tarball_sha,
        "node_version": node_version,
        "patches": patches,
        "why_node26": (
            "OpenTUI (real TUI) loads its native Zig core via node:ffi, which exists since Node 26.1 "
            "and requires Node >= 26.4; the device-verified Node 22.9 runtime has no --experimental-ffi. "
            "Phase A proves Node 26 can be cross-built for iPhoneOS; Phase B (patch 0007) ports V8 14.6's "
            "executable-memory model to the iOS 16.1.1-only plain mprotect W^X mechanism. Phase C enables "
            "node:ffi + the OpenTUI dylib."
        ),
    },
    "build": {
        "build_path": "make-executable",
        "configure_flags": configure_flags,
        "gyp_defines": "target_arch=arm64 host_os=mac target_os=ios",
        "xcode_version": os.environ.get("XCODE_VERSION", "16.4"),
        "runner_os": os.environ.get("RUNNER_OS", "macOS"),
        "github_workflow_run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "github_sha": os.environ.get("GITHUB_SHA", ""),
        "temporal_support": "disabled (--v8-disable-temporal-support: Rust cross-compilation is Phase C)",
        "ffi_support": (
            "enabled (node:ffi default-on in Node 26.13; bundled deps/libffi cross-built for iPhoneOS)"
            if os.environ.get("NODE26_ENABLE_FFI", "0") == "1"
            else "disabled (--without-ffi: libffi iOS bring-up is Phase C)"
        ),
        "ffi_callback_policy": (
            "iOS ARM fixed trampoline table copied to anonymous RW then sealed RX (patches 0014/0015), writable metadata kept separate; no malloc execution, MAP_JIT or RWX"
            if os.environ.get("NODE26_ENABLE_FFI", "0") == "1" else "disabled"
        ),
    },
    "binary": {
        "file": "node",
        "size_bytes": node.stat().st_size,
        "sha256": sha256(node),
        "file_output": read_or(dist / "file.txt"),
        "linked_dylibs": dylibs,
        "entitlements_sha256": sha256(dist / "entitlements.plist"),
    },
    "runtime_policy": {
        "v8_jit": (
            "enabled: V8 14.6 JIT compiled in and on by default (no --jitless). On iOS, "
            "RwxMemoryWriteScope is implemented over mprotect, toggling registered code ranges between RW "
            "(writing) and RX (executing) - patch 0007 (RegisterIOSCodeRange + SetJitWriteProtected in "
            "platform-ios.cc); no MAP_JIT, no RWX requests, no BrowserEngineCore (iOS 17.4+ only, absent on "
            "the iOS 16.1.1 target). The launcher MUST pass --single-threaded: the mprotect toggle is "
            "process-wide, so V8 background compiler/marking threads must be off (same trade-off as the "
            "device-verified Node 22.9 runtime)."
        ),
        "webassembly": (
            "enabled: V8 WebAssembly compiled in (v8_enable_webassembly=1); wasm code spaces use the same "
            "mprotect RW<->RX model as JIT (patch 0007). Requires --single-threaded on iOS for the same "
            "process-wide-toggle reason. iOS JobHandles have zero background workers (patch 0016); "
            "the joining foreground thread performs synchronous wasm compilation/publication."
        ),
        "launcher": {
            "required_flags": ["--single-threaded"],
            "required_flags_note": (
                "The launcher MUST pass --single-threaded on iOS: the iOS JIT memory model toggles code-page "
                "permissions process-wide with mprotect (patch 0007), so V8 background compiler/marking "
                "threads must be disabled; without it JIT execution and built-in fetch can SIGBUS "
                "(device-verified on the Node 22.9 runtime)."
            ),
            "optional_flags": ["--no-concurrent-recompilation"],
        },
        "intl": {
            "mode": "full-icu",
            "configure_flag": "--with-intl=full-icu",
            "data_statically_linked": True,
            "why": "The OpenCode CLI needs ECMA-402 Intl and V8 Unicode property escapes (\\p{...}); full-icu is mandatory.",
        },
        "entitlements": [
            "platform-application",
            "com.apple.private.security.no-sandbox",
        ],
        "entitlements_status": "same device-verified minimal 2-key set used by the Node 22.9 runtime",
        "process_platform": "ios (expected; device-verification pending)",
    },
    "device_status": "UNVERIFIED ON DEVICE",
    "device_status_note": (
        "Phase A+B artifact (patches 0001..0008): GitHub-hosted macOS runners cannot execute iPhoneOS "
        "binaries, so all CI checks are static (Mach-O platform/minos, dylib linkage, ldid signature, "
        "ICU/WebAssembly audits). Expected device behaviour: --version works; --jitless works without "
        "flags; JIT/wasm/fetch require --single-threaded (mprotect W^X toggle is process-wide). This is the "
        "first Node 26 iPhoneOS runtime; device verification results will be recorded in the repository."
    ),
}

(dist / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest["target"], indent=2))
print("runtime-manifest.json written; node sha256=" + manifest["binary"]["sha256"])
PY
}

write_checksums() {
  log "writing SHA256SUMS"
  (
    cd "$DIST"
    shasum -a 256 node entitlements.plist runtime-manifest.json > SHA256SUMS
    cat SHA256SUMS
  )
}

write_validation_report() {
  local build_path="$1" make_rc="$2"
  {
    echo "# ios-node26-runtime static validation report (Node.js $NODE_VERSION, Phase A)"
    echo
    echo "Generated (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Build path: $build_path (make exit code: $make_rc)"
    echo
    echo "## Verdict"
    echo
    echo "- Mach-O: iPhoneOS arm64 executable, minos <= 16.1.1 (scripts/check_macho.py PASS)"
    echo "- Dylib linkage: iOS system libraries/frameworks only"
    echo "- ICU: full-icu statically linked (ECMA-402 Intl + V8 \\p{...} regexps)"
    echo "- WebAssembly: compiled in (v8_enable_webassembly=1)"
    echo "- ldid signing: ad-hoc signature with the device-verified 2-key entitlement set"
    echo "- Phase A scope: build + static validation only. V8 14.6 iOS executable-memory (JIT) adaptation"
    echo "  to iOS 16.1.1 is Phase B; JIT/wasm device execution is expected to need it."
    echo "- Device execution: **UNVERIFIED ON DEVICE** (GitHub-hosted runners cannot run iOS binaries)"
    echo
    echo "## Evidence files"
    echo
    echo "- file.txt, check-macho-signed.txt, vtool-signed.txt, otool-L-signed.txt"
    echo "- icu-evidence-signed.txt, wasm-evidence-signed.txt"
    echo "- entitlements-signed.xml, runtime-manifest.json, SHA256SUMS"
  } > "$DIST/validation-report.txt"
  cat "$DIST/validation-report.txt"
}

cmd_package() {
  require_tools
  mkdir -p "$DIST"
  local built make_rc build_path
  built="$(find_built_node)"
  [[ -n "$built" && -f "$built" ]] || die "no built node executable found under $NODE_SRC/out"
  [[ -s "$built" ]] || die "built node executable is empty: $built"
  make_rc="$(cat "$LOG_DIR/make-exit-code" 2>/dev/null || echo unknown)"
  build_path="make-executable"
  log "built binary: $built ($(stat -f %z "$built") bytes, make exit $make_rc)"
  cp "$built" "$DIST/node"
  cp "$ENTITLEMENTS" "$DIST/entitlements.plist"
  chmod +x "$DIST/node"

  validate_static "$DIST/node" unsigned
  sign_binary "$DIST/node"
  validate_static "$DIST/node" signed
  write_manifest "$DIST/node"
  write_validation_report "$build_path" "$make_rc"
  write_checksums

  # keep the small build logs in the artifact for debuggability
  cp "$LOG_DIR/configure.log" "$DIST/configure.log" 2>/dev/null || true
  cp "$LOG_DIR/make.log" "$DIST/build-make.log" 2>/dev/null || true
  log "artifact ready in $DIST:"
  ls -l "$DIST"
}

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  prepare)         cmd_prepare ;;
  normalize-cache) cmd_normalize_cache "${2:-false}" ;;
  configure)       cmd_configure ;;
  build)           cmd_build ;;
  package)         cmd_package ;;
  all)             cmd_prepare; cmd_configure; cmd_build; cmd_package ;;
  -h|--help|help)  usage ;;
  *) usage; die "unknown subcommand: ${1:-<none>}" ;;
esac
