#!/var/jb/usr/bin/python3
"""Rewrite the base postinst for the integrated server/network-gate build.

The base package installs a private loopback core plus a separate exposure
proxy. This build removes the proxy and moves the server onto the public port,
so the install script must stop the old pair, remove the relay job, and wait on
the server's public port. Every replacement is exact and must match once; a
missing anchor fails the build instead of producing a silently broken package.
"""

from pathlib import Path
import sys

REPLACEMENTS = [
    # One service, no relay label or plist.
    (
        '''proxy_plist="/var/jb/Library/LaunchDaemons/com.alsinas.opencode-expose-proxy.plist"
label="$domain/com.alsinas.opencode-server"
proxy_label="$domain/com.alsinas.opencode-expose-proxy"
legacy_lan_label="$domain/com.alsinas.opencode-lan-proxy"
legacy_tailscale_label="$domain/com.alsinas.opencode-tailscale-proxy"
''',
        '''label="$domain/com.alsinas.opencode-server"
''',
    ),
    # Never defer this upgrade: the old proxy owns the port the new server
    # needs, so it cannot stay running across the transition.
    (
        '''# Keep every already-loaded server or relay alive through package installation.
defer_activation=0
if "$launchctl" print "$label" >/dev/null 2>&1 || \\
   "$launchctl" print "$proxy_label" >/dev/null 2>&1 || \\
   "$launchctl" print "$legacy_lan_label" >/dev/null 2>&1 || \\
   "$launchctl" print "$legacy_tailscale_label" >/dev/null 2>&1; then
  defer_activation=1
fi
''',
        '''# The server now owns the public port. Always stop the old core and proxy
# and activate the new server during the upgrade.
defer_activation=0
''',
    ),
    ("server_port=4097\n", ""),
    ('/var/jb/usr/bin/chmod 644 "$proxy_plist"\n', ""),
    ('  stop_service "$proxy_label"\n', '  "$launchctl" bootout "$domain/com.alsinas.opencode-expose-proxy" 2>/dev/null || true\n'),
    ('    "$launchctl" enable "$proxy_label" 2>/dev/null || true\n', ""),
    ('    "$launchctl" disable "$proxy_label" 2>/dev/null || true\n', ""),
    (
        '''    start_service "$proxy_label" "$proxy_plist"
    attempt=0
    while [ "$attempt" -lt 30 ]; do
      if /var/jb/usr/bin/curl -fsS --connect-timeout 1 --max-time 2 \\
        "http://127.0.0.1:$port/api/info" >/dev/null 2>&1; then
        break
      fi
      /var/jb/usr/bin/sleep 1
      attempt=$((attempt + 1))
    done
    if [ "$attempt" -ge 30 ]; then
      echo "The OpenCode network relay did not become healthy on port $port." >&2
      exit 1
    fi
''',
        "",
    ),
    ("http://127.0.0.1:$server_port/api/info", "http://127.0.0.1:$port/api/info"),
    (
        'echo "OpenCode core did not start on its private loopback port $server_port." >&2',
        'echo "OpenCode did not start on port $port." >&2',
    ),
    # The base's message still mentions the relay.
    (
        'echo "OpenCode update installed. The running server and relay were left unchanged; press Restart Server in Settings when ready to activate the update."',
        'echo "OpenCode update installed. Press Restart Server in Settings if the server did not start."',
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <postinst>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    text = path.read_text()

    for index, (old, new) in enumerate(REPLACEMENTS, 1):
        count = text.count(old)
        if count != 1:
            print(
                f"replacement {index} matched {count} times, expected 1: {old[:80]!r}",
                file=sys.stderr,
            )
            return 1
        text = text.replace(old, new)

    if "proxy_label" in text or "proxy_plist" in text:
        print("postinst still references the retired relay", file=sys.stderr)
        return 1
    if "server_port" in text:
        print("postinst still references the retired loopback port", file=sys.stderr)
        return 1

    path.write_text(text)
    print(f"patched {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
