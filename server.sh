#!/var/jb/bin/sh
# OpenCode iOS server launcher (hardened for restart persistence).
# Changes vs. the split core+proxy build:
#   * the server owns the public port directly and listens on every interface,
#     so a Wi-Fi/DHCP/Tailscale change never leaves it bound to a stale address
#   * network-gate.cjs enforces the LAN and Tailscale settings per connection
#   * caps the V8 old-space so the process stops growing into jetsam territory
#   * reclaims the public port before bind() so a stale listener cannot wedge
#     startup with EADDRINUSE
#   * logs every start so restart frequency is observable
set -e

export HOME="/var/jb/var/mobile"
export PATH="/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export OPENCODE_DB="$XDG_DATA_HOME/opencode/opencode-ios-port.db"
export OPENCODE_CONFIG_DIR="$XDG_CONFIG_HOME/opencode"
export TMPDIR="/private/var/tmp"
unset OPENCODE_PASSWORD OPENCODE_SERVER_PASSWORD
export OPENCODE_IOS_DISABLE_SERVER_AUTH=1
# The upstream bundle ships macOS native watchers/fff binaries. Neither can
# load on iOS, and both features are optional, so disable them rather than let
# dlopen() terminate the process.
export OPENCODE_DISABLE_FILEWATCHER=1
export OPENCODE_DISABLE_FFF=1

# Workspace for new sessions and the web UI's New Project picker. Keep it out
# of $HOME so a session with no project cannot see .ssh, .config or provider
# credentials. State and the SQLite DB stay in $HOME (never on File Provider).
if [ -d /var/mobile/OpenCode ]; then
  cd /var/mobile/OpenCode
else
  echo "[server.sh] /var/mobile/OpenCode missing; staying in $HOME" >>"$HOME/.local/share/opencode/log/startup.log" 2>/dev/null || true
fi

NODE="/var/jb/usr/bin/node"
ENTRY="/var/jb/usr/lib/opencode-ios/opencode.mjs"
GATE="/var/jb/usr/lib/opencode-ios/network-gate.cjs"
CONFIG="/var/mobile/.config/opencode-ios/settings.conf"
HOST="0.0.0.0"
PORT="4096"
# The session database is large and the server decodes multi-megabyte message
# rows synchronously. 512 MB is not enough headroom for that plus the normal
# provider/session caches, and the process died with a V8 heap OOM. 768 MB
# leaves room for those rows without approaching the 2 GB device's jetsam
# limit.
HEAP_MB="${OPENCODE_HEAP_MB:-768}"
LSOF="/var/jb/usr/sbin/lsof"
LOG="/var/mobile/Library/Logs/OpenCode/server.err.log"

if [ -r "$CONFIG" ]; then
  while IFS='=' read -r key value; do
    [ "$key" = "PORT" ] && PORT="$value"
  done <"$CONFIG"
fi
case "$PORT" in ''|*[!0-9]*) PORT=4096 ;; esac
if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then PORT=4096; fi

if [ ! -r "$GATE" ]; then
  echo "[server.sh] network gate missing at $GATE; refusing to start" >>"$LOG" 2>/dev/null || true
  exit 1
fi

# Single ownership of the public port: terminate any surviving listener so
# the node process we exec below cannot fail with EADDRINUSE. This also
# reclaims the port from the retired opencode-expose-proxy during an upgrade.
if [ -x "$LSOF" ]; then
  stale="$("$LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -n "$stale" ]; then
    echo "[server.sh] reclaiming port $PORT from: $stale" >>"$LOG" 2>/dev/null || true
    for pid in $stale; do kill -TERM "$pid" 2>/dev/null || true; done
    n=0
    while [ "$n" -lt 25 ]; do
      still="$("$LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
      [ -z "$still" ] && break
      sleep 0.2
      n=$((n + 1))
    done
    for pid in $("$LSOF" -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true); do
      kill -KILL "$pid" 2>/dev/null || true
    done
  fi
fi

# A crash leaves time_suspended set on the sessions that were mid-turn. The
# server now resumes those sessions on startup, so discard claims that are too
# old to belong to the outage we are recovering from. Otherwise a restart would
# resurrect abandoned work from previous days (and spend model quota on it).
SQLITE=/var/jb/usr/bin/sqlite3
if [ -x "$SQLITE" ] && [ -f "$OPENCODE_DB" ]; then
  "$SQLITE" "$OPENCODE_DB" \
    "PRAGMA busy_timeout=5000; UPDATE session_v2 SET time_suspended=NULL, resume_attempts=0 WHERE time_suspended IS NOT NULL AND time_updated < (strftime('%s','now') * 1000 - 7200000);" \
    >/dev/null 2>&1 ||
    echo "[server.sh] stale session claim cleanup failed" >>"$LOG" 2>/dev/null || true
fi

echo "[server.sh] starting node pid=$$ heap=${HEAP_MB}MB host=$HOST port=$PORT $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG" 2>/dev/null || true

exec "$NODE" \
  --max-old-space-size="$HEAP_MB" \
  --require "$GATE" \
  "$ENTRY" serve --hostname "$HOST" --port "$PORT"
