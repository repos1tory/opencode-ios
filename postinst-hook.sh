# Load the periodic supervisor after the server package's normal setup. It
# remains loaded even when AUTO_START is off; watchdog.sh reads settings.conf
# and stays idle until the user enables the server again.
watchdog_domain=system
watchdog_label="$watchdog_domain/com.alsinas.opencode-watchdog"
watchdog_plist=/var/jb/Library/LaunchDaemons/com.alsinas.opencode-watchdog.plist
"$launchctl" enable "$watchdog_label" 2>/dev/null || true
"$launchctl" bootout "$watchdog_label" 2>/dev/null || true
attempt=0
while [ "$attempt" -lt 10 ]; do
  if "$launchctl" bootstrap "$watchdog_domain" "$watchdog_plist" 2>/dev/null; then break; fi
  if "$launchctl" print "$watchdog_label" >/dev/null 2>&1; then break; fi
  /var/jb/usr/bin/sleep 1
  attempt=$((attempt + 1))
done
if [ "$attempt" -ge 10 ]; then
  echo "Could not load the OpenCode uptime watchdog." >&2
  exit 1
fi
