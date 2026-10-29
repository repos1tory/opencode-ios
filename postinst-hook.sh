# The separate exposure proxy is gone. Remove its job, plist, and binary even
# when it was still loaded during the upgrade, so it cannot keep port 4096 or
# reappear at the next boot.
relay_domain=user/501
for relay_name in com.alsinas.opencode-expose-proxy com.alsinas.opencode-lan-proxy com.alsinas.opencode-tailscale-proxy; do
  "$launchctl" bootout "$relay_domain/$relay_name" 2>/dev/null || true
  /var/jb/usr/bin/rm -f "/var/jb/Library/LaunchDaemons/$relay_name.plist"
done
/var/jb/usr/bin/rm -f /var/jb/usr/lib/opencode-ios/opencode-expose-proxy \
  /var/mobile/.config/opencode-ios/relay.enabled \
  /var/mobile/.config/opencode-ios/lan-proxy

# Load the periodic supervisor after the server package's normal setup. It
# remains loaded even when AUTO_START is off; watchdog.sh reads settings.conf
# and stays idle until the user enables the server again.
watchdog_domain=system
watchdog_label="$watchdog_domain/com.alsinas.opencode-watchdog"
watchdog_plist=/var/jb/Library/LaunchDaemons/com.alsinas.opencode-watchdog.plist
watchdog_install_log=/var/mobile/Library/Logs/OpenCode/watchdog-install.log
/var/jb/usr/bin/mkdir -p /var/mobile/Library/Logs/OpenCode
: >"$watchdog_install_log" 2>/dev/null || true
"$launchctl" enable "$watchdog_label" 2>/dev/null || true
"$launchctl" bootout "$watchdog_label" 2>/dev/null || true
attempt=0
while [ "$attempt" -lt 10 ]; do
  if "$launchctl" bootstrap "$watchdog_domain" "$watchdog_plist" >>"$watchdog_install_log" 2>&1; then break; fi
  if "$launchctl" print "$watchdog_label" >/dev/null 2>&1; then break; fi
  /var/jb/usr/bin/sleep 1
  attempt=$((attempt + 1))
done
if [ "$attempt" -ge 10 ]; then
  # The watchdog is supplementary; the server has its own launchd KeepAlive
  # job. A launchd-domain difference on a supported jailbreak must not leave
  # dpkg half-configured or suppress the UIKit preference registration trigger.
  echo "Warning: OpenCode installed, but its uptime watchdog could not be loaded; see $watchdog_install_log." >&2
fi
