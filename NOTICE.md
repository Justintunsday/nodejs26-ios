# NOTICE

This repository is a community port of **Node.js 26.13.0** to iPhoneOS (iOS) on
jailbroken ARM64 devices.

- Node.js is licensed under the MIT license; its `LICENSE` file is included
  verbatim (`LICENSE`, from the pinned `node-v26.13.0` source tarball).
- The cross-compilation support in `patches/nodejs26/` (configure/gyp iOS
  flavor support, host-toolset fixes, c-ares darwin config, crypto macOS-only
  API guards, and the V8 iOS executable-memory model) is original work for this
  port and is provided under the same MIT terms.
- No nodejs-mobile code is used: nodejs-mobile has no Node 22+/26 branch, so
  the iOS build patches are derived on the pristine upstream Node.js tree.
- The V8 W^X memory model follows the approach device-verified in the
  OpenCode iOS port (mprotect RW<->RX toggling); see docs/RUNTIME_BUILD.md.