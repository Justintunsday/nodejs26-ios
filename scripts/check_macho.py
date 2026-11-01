#!/usr/bin/env python3
"""Verify thin 64-bit little-endian ARM64 Mach-O targets iPhoneOS, not macOS.

Checks build platform and deployment target; does NOT prove device runtime compatibility.
"""
import argparse
import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_IOS = 2


def unpack_version(value):
    return ((value >> 16) & 0xFFFF, (value >> 8) & 0xFF, value & 0xFF)


def audit(path, max_minos=(16, 1, 1)):
    with open(path, "rb") as f:
        hdr = f.read(32)
        if len(hdr) != 32:
            raise ValueError("Mach-O header truncated")
        magic, cpu, subtype, filetype, commands, sizeofcmds, flags, reserved = struct.unpack("<8I", hdr)
        if magic != MH_MAGIC_64 or cpu != CPU_TYPE_ARM64:
            raise ValueError("Not a thin little-endian arm64 Mach-O executable")
        if filetype != 2:
            raise ValueError(f"Not MH_EXECUTE (filetype={filetype})")
        if commands > 10000 or sizeofcmds > 16 * 1024 * 1024:
            raise ValueError("Unreasonable Mach-O load command size")
        buf = f.read(sizeofcmds)
    if len(buf) != sizeofcmds:
        raise ValueError("Truncated Mach-O load commands")
    pos = 0
    platforms = []
    for _ in range(commands):
        if pos + 8 > len(buf):
            raise ValueError("Truncated command header")
        cmd, size = struct.unpack_from("<II", buf, pos)
        if size < 8 or pos + size > len(buf):
            raise ValueError("Malformed load command")
        if cmd == LC_BUILD_VERSION:
            if size < 24:
                raise ValueError("Truncated LC_BUILD_VERSION")
            platform, minos = struct.unpack_from("<II", buf, pos + 8)
            if platform != PLATFORM_IOS:
                raise ValueError(f"Mach-O targets platform {platform} (requires iPhoneOS=2)")
            platforms.append(unpack_version(minos))
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            if size < 16:
                raise ValueError("Truncated LC_VERSION_MIN_IPHONEOS")
            minos, = struct.unpack_from("<I", buf, pos + 8)
            platforms.append(unpack_version(minos))
        pos += size
    if pos != len(buf):
        raise ValueError("Unaccounted Mach-O command bytes")
    if len(platforms) != 1:
        raise ValueError(f"Expected exactly one iOS platform command; found {len(platforms)}")
    version = platforms[0]
    if version > max_minos:
        raise ValueError(f"Minimum supported iOS {version} is newer than target {max_minos}")
    print(f"PASS iPhoneOS arm64 minos={'.'.join(map(str, version))} path={path}")
    return version


def main():
    p = argparse.ArgumentParser()
    p.add_argument("binary", type=Path)
    p.add_argument("--max-minos", default="16.1.1")
    a = p.parse_args()
    audit(a.binary, tuple(map(int, a.max_minos.split("."))))

if __name__ == "__main__":
    main()
