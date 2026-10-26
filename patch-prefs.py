#!/var/jb/usr/bin/python3
"""Remove the passwordless-sudo calls from the compiled Settings bundle.

The bundle and its source are not part of this package patch, but the shell
commands it spawns are stored as plain C strings in __cstring. Every command
now targets the root-free opencode-server helper directly.
"""

import sys
from pathlib import Path

REPLACEMENTS = [
    (
        b"/var/jb/usr/bin/sudo -n /var/jb/usr/bin/opencode-server exposure >/dev/null 2>&1",
        b"/var/jb/usr/bin/opencode-server exposure >/dev/null 2>&1",
    ),
    (
        b"/var/jb/usr/bin/sudo -n /var/jb/usr/bin/opencode-server %@ >/dev/null 2>&1",
        b"/var/jb/usr/bin/opencode-server %@ >/dev/null 2>&1",
    ),
    (
        b"/var/jb/usr/bin/sudo -n /var/jb/usr/bin/opencode-server check >/dev/null 2>&1",
        b"/var/jb/usr/bin/opencode-server check >/dev/null 2>&1",
    ),
    (
        b"Settings could not control the server. Check that passwordless sudo is available.",
        b"Settings could not control the server. Reboot or reinstall, then try again.",
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <OpenCodeServerPrefs>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    data = bytearray(path.read_bytes())

    for old, new in REPLACEMENTS:
        if len(new) > len(old):
            print(f"replacement is longer than original: {old!r}", file=sys.stderr)
            return 1
        offset = data.find(old)
        if offset < 0:
            print(f"string not found: {old!r}", file=sys.stderr)
            return 1
        if data.find(old, offset + 1) >= 0:
            print(f"string is not unique: {old!r}", file=sys.stderr)
            return 1
        data[offset : offset + len(old)] = new + b" " * (len(old) - len(new))

    path.write_bytes(data)
    print(f"patched {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
