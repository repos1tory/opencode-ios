#!/usr/bin/env python3
"""Combine the arm64 and arm64e preference libraries for rootless iOS."""
import struct
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: make-fat.py <arm64> <arm64e> <output>")
    slices = []
    for filename, expected_subtype in ((sys.argv[1], 0), (sys.argv[2], 2)):
        data = Path(filename).read_bytes()
        if len(data) < 32:
            raise SystemExit(f"truncated Mach-O: {filename}")
        magic, cpu, subtype = struct.unpack_from("<III", data)
        if magic != 0xFEEDFACF or cpu != 0x0100000C or (subtype & 0x00FFFFFF) != expected_subtype:
            raise SystemExit(f"unexpected Mach-O architecture: {filename}")
        slices.append((cpu, subtype, data))

    alignment = 14  # iOS arm64 uses 16 KiB pages.
    page = 1 << alignment
    result = bytearray(page)
    struct.pack_into(">II", result, 0, 0xCAFEBABE, len(slices))
    for index, (cpu, subtype, data) in enumerate(slices):
        offset = (len(result) + page - 1) & ~(page - 1)
        result.extend(b"\0" * (offset - len(result)))
        if offset + len(data) > 0xFFFFFFFF:
            raise SystemExit("Mach-O is too large for a FAT32 header")
        struct.pack_into(">IIIII", result, 8 + index * 20, cpu, subtype, offset, len(data), alignment)
        result.extend(data)
    Path(sys.argv[3]).write_bytes(result)


if __name__ == "__main__":
    main()
