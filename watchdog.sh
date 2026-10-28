#!/var/jb/bin/sh
# Keep the OpenCode server available without tight crash loops. The loaded
# launchd job owns process creation, so this script never forks a second server
# process. Failed recovery is retried forever with capped backoff.
#
# Network exposure is part of the server now (network-gate.cjs), not a second
# process, so this watchdog only supervises one job.

BIN=/var/jb/usr/bin
LAUNCHCTL=$BIN/launchctl
CURL=$BIN/curl
DATE=$BIN/date
GREP=$BIN/grep
TAIL=$BIN/tail
MV=$BIN/mv
MKDIR=$BIN/mkdir
SED=$BIN/sed
SLEEP=$BIN/sleep
CHOWN=$BIN/chown
CHMOD=$BIN/chmod
RM=$BIN/rm
CAT=$BIN/cat

DOMAIN=user/501
CORE=com.alsinas.opencode-server
CORE_PLIST=/var/jb/Library/LaunchDaemons/$CORE.plist
CONFIG=/var/mobile/.config/opencode-ios/settings.conf
FLAG_DIR=/var/mobile/.config/opencode-ios
CORE_FLAG=$FLAG_DIR/server.enabled
RELAY_FLAG=$FLAG_DIR/relay.enabled
MANUAL_LOCK=$FLAG_DIR/manual.lock
LOG=/var/mobile/Library/Logs/OpenCode/watchdog.log
STATE=/private/var/tmp/opencode/watchdog.state
UPDATE_STATE=/private/var/tmp/opencode/update.state
UPDATE_INTERVAL=86400

# A busy server can block its event loop for several seconds while it decodes a
# large session row or finishes a major GC. Killing it at that point aborts
# every running session, so health checks deliberately tolerate a long stall:
# one missed check opens a recovery window, and a termination needs several
# failed checks plus a confirmation probe.
STARTUP_GRACE=60
FAILS_TRIGGER=3
CONFIRM_DELAY=15
HEALTH_CONNECT_TIMEOUT=3
HEALTH_MAX_TIME=20
INITIAL_RETRY=30
MAX_RETRY=300

if ! "$MKDIR" -p /private/var/tmp/opencode /var/mobile/Library/Logs/OpenCode; then
  echo "[watchdog] cannot create state or log directories" >&2
  exit 1
fi

log() {
  echo "[$($DATE -u +%Y-%m-%dT%H:%M:%SZ)] $*" >>"$LOG"
}

configured_port() {
  port=4096
  if [ -r "$CONFIG" ]; then
    while IFS='=' read -r key value; do
      [ "$key" = "PORT" ] && port="$value"
    done <"$CONFIG"
  fi
  case "$port" in ''|*[!0-9]*) port=4096 ;; esac
  if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then port=4096; fi
  echo "$port"
}

core_url() {
  echo "http://127.0.0.1:$(configured_port)/api/info"
}

state_get() {
  key="$1"
  default="$2"
  value=
  if [ -r "$STATE" ]; then
    line=$($GREP "^${key}=" "$STATE" 2>/dev/null | $TAIL -n 1)
    value=${line#*=}
  fi
  [ -n "$value" ] || value="$default"
  printf '%s' "$value"
}

state_set() {
  state_key="$1"
  state_value="$2"
  state_temporary="$STATE.$$"
  if [ -r "$STATE" ]; then
    $GREP -v "^${state_key}=" "$STATE" >"$state_temporary" 2>/dev/null || true
  else
    : >"$state_temporary"
  fi
  printf '%s=%s\n' "$state_key" "$state_value" >>"$state_temporary"
  $MV -f "$state_temporary" "$STATE"
}

auto_start_enabled() {
  auto_start=1
  if [ -r "$CONFIG" ]; then
    while IFS='=' read -r key value; do
      [ "$key" = AUTO_START ] && auto_start="$value"
    done <"$CONFIG"
  fi
  case "$auto_start" in
    0|false|no|NO) return 1 ;;
  esac
  return 0
}

# The server plist uses KeepAlive PathState instead of RunAtLoad, so a
# mobile-user process can stop and start it without privileged launchctl
# calls. The root watchdog owns creating/removing the flag at boot.
ensure_flags() {
  "$MKDIR" -p "$FLAG_DIR"
  [ -e "$CORE_FLAG" ] || : >"$CORE_FLAG"
  "$CHOWN" mobile:mobile "$CORE_FLAG" 2>/dev/null || true
  "$CHMOD" 600 "$CORE_FLAG" 2>/dev/null || true
}

clear_flags() {
  "$RM" -f "$CORE_FLAG" "$RELAY_FLAG"
}

# The Settings helper holds this lock while it restarts or reconfigures the
# server so the watchdog does not race it. A stale lock expires after five
# minutes, or immediately if it contains an invalid timestamp.
manual_lock_active() {
  [ -r "$MANUAL_LOCK" ] || return 1
  lock_time=$("$CAT" "$MANUAL_LOCK" 2>/dev/null || echo 0)
  case "$lock_time" in ''|*[!0-9]*) lock_time=0 ;; esac
  now=$($DATE +%s)
  age=$((now - lock_time))
  if [ "$age" -ge 0 ] && [ "$age" -lt 300 ]; then
    return 0
  fi
  "$RM" -f "$MANUAL_LOCK"
  return 1
}

# The network relay used to be a separate launchd job. Remove it (and the older
# LAN/Tailscale split proxies) permanently so it cannot reappear after a reboot
# or a reinstall of a stale plist.
retire_legacy_relays() {
  for legacy in com.alsinas.opencode-expose-proxy com.alsinas.opencode-lan-proxy com.alsinas.opencode-tailscale-proxy; do
    "$LAUNCHCTL" bootout "user/501/$legacy" 2>/dev/null || true
    "$RM" -f "/var/jb/Library/LaunchDaemons/$legacy.plist"
  done
  "$RM" -f /var/jb/usr/lib/opencode-ios/opencode-expose-proxy \
    "$RELAY_FLAG" "$FLAG_DIR/lan-proxy" 2>/dev/null || true
}

healthy() {
  $CURL -fsS --connect-timeout "$HEALTH_CONNECT_TIMEOUT" --max-time "$HEALTH_MAX_TIME" "$1" >/dev/null 2>&1
}

retry_delay() {
  level="$1"
  delay=$INITIAL_RETRY
  count=0
  while [ "$count" -lt "$level" ] && [ "$delay" -lt "$MAX_RETRY" ]; do
    delay=$((delay * 2))
    [ "$delay" -le "$MAX_RETRY" ] || delay=$MAX_RETRY
    count=$((count + 1))
  done
  printf '%s' "$delay"
}

act() {
  key="$1"
  label="$2"
  plist="$3"
  url="$4"

  fails=$(state_get "${key}_fails" 0)
  level=$(state_get "${key}_level" 0)
  last=$(state_get "${key}_last" 0)
  seen_healthy=$(state_get "${key}_seen_healthy" 0)
  first_failure=$(state_get "${key}_first_failure" 0)

  if healthy "$url"; then
    if [ "$fails" -gt 0 ] || [ "$level" -gt 0 ]; then
      log "$label recovered; resetting retry backoff"
    fi
    state_set "${key}_fails" 0
    state_set "${key}_level" 0
    state_set "${key}_last" 0
    state_set "${key}_first_failure" 0
    state_set "${key}_seen_healthy" 1
    return 0
  fi

  now=$($DATE +%s)
  if [ "$seen_healthy" = 1 ]; then
    # The service answered before, so this is a stall rather than a failed
    # start. Start the recovery window instead of counting a failure; a short
    # GC or a large database decode must not cost the user a running session.
    state_set "${key}_seen_healthy" 0
    first_failure="$now"
    state_set "${key}_first_failure" "$first_failure"
    log "$label missed a health check; allowing ${STARTUP_GRACE}s recovery window"
    return 1
  fi
  if [ "$first_failure" = 0 ]; then
    first_failure="$now"
    state_set "${key}_first_failure" "$first_failure"
  fi
  if [ $((now - first_failure)) -lt "$STARTUP_GRACE" ]; then
    log "$label is not healthy yet; allowing startup grace"
    return 1
  fi

  fails=$((fails + 1))
  state_set "${key}_fails" "$fails"
  log "$label unhealthy (consecutive checks=$fails)"
  if [ "$fails" -lt "$FAILS_TRIGGER" ]; then return 1; fi

  service="$DOMAIN/$label"
  service_state=$($LAUNCHCTL print "$service" 2>/dev/null || true)
  if [ -z "$service_state" ]; then
    # A missing job cannot recover through KeepAlive. Bootstrap it immediately;
    # only failed bootstrap attempts use the exponential retry delay.
    delay=$(retry_delay "$level")
    if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$delay" ]; then
      log "$label bootstrap deferred by backoff ($((delay - (now - last)))s remain)"
      return 1
    fi
    log "$label job is not loaded; bootstrapping through launchd"
    $LAUNCHCTL enable "$service" >>"$LOG" 2>&1 || true
    if $LAUNCHCTL bootstrap "$DOMAIN" "$plist" >>"$LOG" 2>&1; then
      log "$label bootstrap succeeded; launchd will start it"
      state_set "${key}_fails" 0
      state_set "${key}_level" 0
      state_set "${key}_last" 0
    else
      log "bootstrap $label failed; will retry"
      state_set "${key}_last" "$now"
      if [ "$level" -lt 4 ]; then level=$((level + 1)); fi
      state_set "${key}_level" "$level"
      state_set "${key}_fails" 0
    fi
    return 1
  fi

  running_pid=$(printf '%s\n' "$service_state" | $SED -n 's/^[[:space:]]*pid = //p' | $TAIL -n 1)
  if [ -z "$running_pid" ]; then
    # launchd may already have a delayed KeepAlive spawn queued. Don't add our
    # own backoff or block that retry; enabling also repairs an accidental
    # disabled state.
    log "$label job is loaded but has no running process; leaving recovery to launchd KeepAlive"
    $LAUNCHCTL enable "$service" >>"$LOG" 2>&1 || true
    state_set "${key}_fails" 0
    state_set "${key}_seen_healthy" 0
    state_set "${key}_first_failure" 0
    return 1
  fi

  delay=$(retry_delay "$level")
  if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$delay" ]; then
    log "$label recovery deferred by backoff ($((delay - (now - last)))s remain)"
    return 1
  fi

  # Final confirmation with a fresh, longer request. Killing a healthy server
  # aborts every in-flight agent turn, so never do it on the strength of a
  # single burst of timeouts alone.
  log "$label still unhealthy; confirming before termination"
  $SLEEP "$CONFIRM_DELAY"
  if healthy "$url"; then
    log "$label recovered during confirmation; not terminating"
    state_set "${key}_fails" 0
    state_set "${key}_level" 0
    state_set "${key}_last" 0
    state_set "${key}_first_failure" 0
    state_set "${key}_seen_healthy" 1
    return 0
  fi

  log "$label unhealthy; terminating pid=$running_pid through launchd (retry delay=${delay}s)"
  $LAUNCHCTL kill SIGKILL "$service" >>"$LOG" 2>&1 || log "kill $label failed; will retry"
  state_set "${key}_last" "$now"
  if [ "$level" -lt 4 ]; then level=$((level + 1)); fi
  state_set "${key}_level" "$level"
  state_set "${key}_fails" 0
  # The replacement process needs a full startup window even though this
  # service was healthy earlier in the same boot.
  state_set "${key}_seen_healthy" 0
  state_set "${key}_first_failure" 0
  return 1
}

# The web title and `opencode-server version` read update.json. Run the check at
# most once a day; a failed check must never affect supervision.
check_for_updates() {
  now=$($DATE +%s)
  last=0
  if [ -r "$UPDATE_STATE" ]; then
    last=$($CAT "$UPDATE_STATE" 2>/dev/null || echo 0)
  fi
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt "$UPDATE_INTERVAL" ]; then return 0; fi
  if [ -x /var/jb/usr/bin/opencode-server ]; then
    /var/jb/usr/bin/opencode-server check-update --quiet >>"$LOG" 2>&1 || true
  fi
  printf '%s\n' "$now" >"$UPDATE_STATE"
}

retire_legacy_relays

# Without curl every HTTP check would fail and the watchdog would kill a
# healthy server in a loop. Wait for the dependency instead of doing that.
if [ ! -x "$CURL" ]; then
  log "curl is missing at $CURL; waiting before running health checks"
  while [ ! -x "$CURL" ]; do $SLEEP 30; done
  log "curl is available; resuming health checks"
fi

# AUTO_START=0 must win at boot, but a later manual restart from Settings may
# still run the server for this boot. Clear the flag once at startup, not on
# every pass, so a manual restart is not interrupted.
if ! manual_lock_active; then
  if auto_start_enabled; then
    ensure_flags
  else
    clear_flags
  fi
fi

while :; do
  if manual_lock_active; then
    $SLEEP 2
    continue
  fi
  check_for_updates
  if auto_start_enabled; then
    ensure_flags
    act core "$CORE" "$CORE_PLIST" "$(core_url)" || true
  fi
  $SLEEP 10
done
