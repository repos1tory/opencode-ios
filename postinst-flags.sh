# The watchdog and this script verify startup with curl. Fail loudly instead of
# leaving a running package that can never pass a health check.
if [ ! -x /var/jb/usr/bin/curl ]; then
  echo "OpenCode Server requires curl. Install the curl package and try again." >&2
  exit 1
fi

# The core and relay use KeepAlive PathState flags instead of RunAtLoad so
# that the mobile user can stop/start them from Settings without sudo.
config_dir=/var/mobile/.config/opencode-ios
core_flag="$config_dir/server.enabled"
relay_flag="$config_dir/relay.enabled"
if [ "$auto_start" = "1" ]; then
  : >"$core_flag"
  : >"$relay_flag"
  /var/jb/usr/bin/chown mobile:mobile "$core_flag" "$relay_flag"
  /var/jb/usr/bin/chmod 600 "$core_flag" "$relay_flag"
else
  /var/jb/usr/bin/rm -f "$core_flag" "$relay_flag"
fi
