# The server uses a KeepAlive PathState flag instead of RunAtLoad so that the
# mobile user can stop/start it from Settings without sudo. LAN and Tailscale
# exposure are enforced inside the server by network-gate.cjs; there is no
# second relay process and no relay flag.
config_dir=/var/mobile/.config/opencode-ios
core_flag="$config_dir/server.enabled"
relay_flag="$config_dir/relay.enabled"
if [ "$auto_start" = "1" ]; then
  : >"$core_flag"
  /var/jb/usr/bin/chown mobile:mobile "$core_flag"
  /var/jb/usr/bin/chmod 600 "$core_flag"
else
  /var/jb/usr/bin/rm -f "$core_flag"
fi
/var/jb/usr/bin/rm -f "$relay_flag"
