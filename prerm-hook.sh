if [ "${1:-}" = remove ] || [ "${1:-}" = deconfigure ]; then
  /var/jb/usr/bin/launchctl bootout system/com.alsinas.opencode-watchdog 2>/dev/null || true
  /var/jb/usr/bin/rm -f /var/mobile/.config/opencode-ios/server.enabled \
    /var/mobile/.config/opencode-ios/relay.enabled
fi
