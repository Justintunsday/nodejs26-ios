#!/usr/bin/env python3
"""Package an exact, signed iPhoneOS runtime without rebuilding or resigning it."""
import argparse
import hashlib
import io
import json
import lzma
from pathlib import Path
import plistlib
import re
import tarfile

from check_macho import audit

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = 'node26'
NODE_PATH = 'var/jb/usr/lib/node26/node'
LAUNCHER_PATH = 'var/jb/usr/bin/node'
DOC_PATH = 'var/jb/usr/share/doc/node26'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def tar_xz(entries, epoch, symlinks=None):
    """Fixed ownership, modes, ordering and timestamps; no host path metadata."""
    directories = set()
    symlinks = symlinks or {}
    for name in (*entries, *symlinks):
        parent = Path(name).parent
        while str(parent) != '.':
            directories.add(parent.as_posix())
            parent = parent.parent
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for name in sorted(directories):
            info = tarfile.TarInfo(name + '/')
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            info.uid = info.gid = 0
            info.uname, info.gname = 'root', 'wheel'
            info.mtime = epoch
            archive.addfile(info)
        for name, (data, mode) in sorted(entries.items()):
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(data), mode
            info.uid = info.gid = 0
            info.uname, info.gname = 'root', 'wheel'
            info.mtime = epoch
            archive.addfile(info, io.BytesIO(data))
        for name, target in sorted(symlinks.items()):
            info = tarfile.TarInfo(name)
            info.type, info.linkname, info.mode = tarfile.SYMTYPE, target, 0o777
            info.uid = info.gid = 0
            info.uname, info.gname = 'root', 'wheel'
            info.mtime = epoch
            archive.addfile(info)
    return lzma.compress(buffer.getvalue(), preset=6)


def ar_member(name, data, epoch):
    header = (f'{name + "/":<16}{epoch:<12}{0:<6}{0:<6}{"100644":<8}{len(data):<10}`\n').encode('ascii')
    if len(header) != 60:
        raise ValueError('Invalid ar header size')
    return header + data + (b'\n' if len(data) % 2 else b'')


def build(runtime, pin, output, version):
    if not re.fullmatch(r'26\.13\.0-[0-9]+(?:[.+~a-z0-9-]*)?', version):
        raise ValueError('Expected a Node 26.13.0 Debian package version, e.g. 26.13.0-1')
    node = (runtime / 'node').read_bytes()
    manifest_data = (runtime / 'runtime-manifest.json').read_bytes()
    manifest = json.loads(manifest_data)
    checks = []

    def require(condition, label):
        if not condition:
            raise ValueError(label)
        checks.append({'name': label, 'status': 'PASS'})

    require(digest(node) == pin['node_sha256'], 'Pinned node SHA-256')
    require(len(node) == pin['node_size'], 'Pinned node size')
    require(manifest['node_version'] == pin['node_version'] == '26.13.0', 'Node version')
    require(str(manifest['build']['github_workflow_run_id']) == str(pin['run_id']), 'Runtime run identity')
    require(manifest['build']['github_sha'] == pin['commit'], 'Runtime source identity')
    require(manifest['binary']['sha256'] == pin['node_sha256'] and manifest['binary']['size_bytes'] == len(node), 'Manifest binary identity')
    require(manifest['target']['platform'] == 'iPhoneOS' and manifest['target']['arch'] == 'arm64', 'iPhoneOS ARM64 manifest')
    require(manifest['build']['ffi_support'].startswith('enabled'), 'FFI enabled')
    patches = {Path(item['file']).name for item in manifest['source']['patches']}
    for patch in ('0013-wasm-ios-no-trap-handler.patch', '0014-libffi-ios-exec-trampoline-table.patch', '0015-libffi-ios-rw-rx-trampoline-table.patch', '0016-ios-v8-jobs-join-only.patch'):
        require(patch in patches, 'Required runtime patch ' + patch)
    for line in (runtime / 'SHA256SUMS').read_text(encoding='utf-8').splitlines():
        sha, name = line.split(None, 1)
        name = name.lstrip('*')
        require('/' not in name and '\\' not in name and name not in ('.', '..'), 'Safe runtime checksum path ' + name)
        require(digest((runtime / name).read_bytes()) == sha, 'Runtime checksum ' + name)
    signed_entitlements = (runtime / 'entitlements-signed.xml').read_bytes()
    require(plistlib.loads(signed_entitlements) == {'platform-application': True, 'com.apple.private.security.no-sandbox': True}, 'Two-key signing evidence')
    require(audit(runtime / 'node') == (15, 0, 0), 'Mach-O iPhoneOS minimum 15.0')
    require(all(name.startswith(('/usr/lib/', '/System/Library/')) for name in manifest['binary']['linked_dylibs']), 'System dylibs only')

    launcher = (ROOT / 'packaging/node').read_bytes()
    require(b'--single-threaded "$@"' in launcher and launcher.startswith(b'#!/var/jb/bin/sh\n'), 'Rootless launcher and argument forwarding')
    info = dict(package=PACKAGE, version=version, architecture='iphoneos-arm64', runtime=pin,
                author='nodejs', maintainer='nodejs <opencode-ios-port@users.noreply.github.com>',
                command='/var/jb/usr/bin/node', executable='/var/jb/usr/lib/node26/node',
                required_flags=['--single-threaded'], device_status='UNVERIFIED ON DEVICE (package assembly only)',
                worker_threads='Unsupported: another JS isolate can race process-wide W^X',
                scope='Independent Node runtime providing the default node command; OpenCode can depend on node26')
    entries = {
        NODE_PATH: (node, 0o755),
        LAUNCHER_PATH: (launcher, 0o755),
        'var/jb/usr/lib/node26/runtime-manifest.json': (manifest_data, 0o644),
        'var/jb/usr/lib/node26/entitlements.xml': (signed_entitlements, 0o644),
        'var/jb/usr/lib/node26/package-info.json': ((json.dumps(info, indent=2) + '\n').encode(), 0o644),
        DOC_PATH + '/LICENSE': ((ROOT / 'LICENSE').read_bytes(), 0o644),
        DOC_PATH + '/NOTICE.md': ((ROOT / 'NOTICE.md').read_bytes(), 0o644),
        DOC_PATH + '/README.md': ((ROOT / 'docs/ROOTLESS_PACKAGE.md').read_bytes(), 0o644),
    }
    require(not any(name.startswith('var/jb/usr/lib/opencode/') for name in entries) and LAUNCHER_PATH in entries, 'Independent package paths and node entry point')
    # Preserve process.execPath for applications started with the first prototype.
    symlinks = {'var/jb/usr/lib/nodejs26/node': '../node26/node'}
    installed_kib = (sum(len(data) for data, _ in entries.values()) + 1023) // 1024
    control = f'''Package: {PACKAGE}
Version: {version}
Architecture: iphoneos-arm64
Maintainer: nodejs <opencode-ios-port@users.noreply.github.com>
Author: nodejs
Installed-Size: {installed_kib}
Section: Development
Priority: optional
Depends: firmware (>= 15.0)
Provides: nodejs26-runtime
Conflicts: nodejs26-ios
Replaces: nodejs26-ios
Homepage: https://github.com/Justintunsday/nodejs26-ios
Description: Node.js 26.13.0 for rootless jailbroken iPhoneOS (experimental)
 Native ARM64 Node runtime with full ICU, JIT, WebAssembly and node:ffi.
 The node command enforces the required --single-threaded W^X policy.
 Tested target: iPhone SE 2, iOS 16.1.1, Dopamine rootless.
 Node user worker_threads remain unsupported. See the packaged README.
'''.encode()
    md5sums = ''.join(f'{hashlib.md5(data, usedforsecurity=False).hexdigest()}  {name}\n' for name, (data, _) in sorted(entries.items())).encode()
    epoch = int(pin['source_date_epoch'])
    control_archive = tar_xz({'control': (control, 0o644), 'md5sums': (md5sums, 0o644)}, epoch)
    data_archive = tar_xz(entries, epoch, symlinks)
    deb = b'!<arch>\n' + b''.join(ar_member(name, data, epoch) for name, data in (
        ('debian-binary', b'2.0\n'), ('control.tar.xz', control_archive), ('data.tar.xz', data_archive)))
    output.mkdir(parents=True, exist_ok=True)
    filename = f'{PACKAGE}_{version}_iphoneos-arm64.deb'
    (output / filename).write_bytes(deb)
    report = dict(info, file=filename, bytes=len(deb), sha256=digest(deb), installed_size_kib=installed_kib,
                  static_checks=checks, symlinks=symlinks, files=[dict(path=name, bytes=len(data), mode=oct(mode), sha256=digest(data)) for name, (data, mode) in sorted(entries.items())])
    report_data = (json.dumps(report, indent=2) + '\n').encode()
    (output / 'package-report.json').write_bytes(report_data)
    (output / 'SHA256SUMS').write_text(f'{digest(deb)}  {filename}\n{digest(report_data)}  package-report.json\n', encoding='utf-8', newline='\n')
    print(json.dumps({key: report[key] for key in ('file', 'bytes', 'sha256', 'device_status')}, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/node26-rootless')
    parser.add_argument('--pin', type=Path, default=ROOT / 'packaging/runtime-pin.json')
    parser.add_argument('--version', default='26.13.0-1')
    args = parser.parse_args()
    build(args.runtime, json.loads(args.pin.read_text(encoding='utf-8')), args.output, args.version)


if __name__ == '__main__':
    main()
