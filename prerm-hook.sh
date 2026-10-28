if [ "${1:-}" = remove ] || [ "${1:-}" = deconfigure ]; then
  /var/jb/usr/bin/launchctl bootout system/com.alsinas.opencode-watchdog 2>/dev/null || true
  for relay_name in com.alsinas.opencode-expose-proxy com.alsinas.opencode-lan-proxy com.alsinas.opencode-tailscale-proxy; do
    /var/jb/usr/bin/launchctl bootout "user/501/$relay_name" 2>/dev/null || true
    /var/jb/usr/bin/rm -f "/var/jb/Library/LaunchDaemons/$relay_name.plist"
  done
  /var/jb/usr/bin/rm -f /var/mobile/.config/opencode-ios/server.enabled \
    /var/mobile/.config/opencode-ios/relay.enabled \
    /var/jb/usr/lib/opencode-ios/opencode-expose-proxy
fi
