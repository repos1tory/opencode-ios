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
    # Network exposure is now part of the server; there is no relay process to
    # restart. Keep the Settings copy truthful without changing its layout.
    (
        b"Check that the server and local relay are responding, or restart both services.",
        b"Check that the OpenCode server is responding, or restart it.         ",
    ),
    (
        b"The relay is responding and the selected network interface is ready. Open the copied URL from another device to confirm end-to-end access.",
        b"The server is responding and the network interface is ready. Open the copied URL from another device to confirm end-to-end access.",
    ),
    (
        b"The network relay could not verify OpenCode, so the share setting was reverted. Use Restart Server to try again.",
        b"The OpenCode server could not verify access, so the setting was reverted. Use Restart Server to try again.",
    ),
    (
        b"The network relay could not verify OpenCode. The setting was reverted, but the relay could not be restarted with the previous setting. Use Restart Server to recover it.",
        b"The OpenCode server could not verify access. The setting was reverted. Use Restart Server to recover it.                                  ",
    ),
    (
        b"OpenCode stays on this iPad unless a path is enabled. LAN access is limited to the current Wi-Fi subnet; Tailscale access is limited to your tailnet. Changes restart only the network relay and are verified before the switch stays on.",
        b"OpenCode stays on this iPad unless a path is enabled. LAN access follows the current Wi-Fi subnet; Tailscale access is limited to your tailnet. Changes apply immediately and are verified.         ",
    ),
    (
        b"%@ The network relay will restart and verify the connection. OpenCode runs will continue; connected browser clients may need to reconnect.",
        b"%@ The server will apply the new access setting immediately. Active runs continue; connected browsers may need to reconnect.           ",
    ),
    (
        b"The OpenCode server and local relay are responding.",
        b"The OpenCode server is responding.                 ",
    ),
    (
        b"The server or local relay is not responding. Restart Server to restore service.",
        b"The OpenCode server is not responding. Restart Server to restore service.      ",
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
