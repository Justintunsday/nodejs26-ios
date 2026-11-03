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

The exact package run, deb SHA and installed-device results are recorded in the
repository README after acceptance. Static CI reports cannot verify device execution.

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

To remove this package, use `sudo dpkg -r node26`. It owns no user data and
does not manage OpenCode or terminate running applications.

## Build the deb

The package workflow consumes the exact runtime in `packaging/runtime-pin.json`.
Assembly uses Python's standard library and does not need Xcode or another native
compilation. Linux CI additionally checks the deb with `dpkg-deb`.

```sh
python3 scripts/package-rootless-node26.py --runtime /path/to/downloaded/runtime
```

Output: `dist/node26-rootless/`, containing the deb, `package-report.json`
and `SHA256SUMS`. File timestamps/ownership are fixed to the pinned source epoch.
