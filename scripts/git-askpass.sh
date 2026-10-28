#!/bin/sh
# Git askpass helper for the device. `gh` is not always on git's PATH, so the
# token is read from an absolute path. The token itself is never printed.
case "$1" in
  *Username*) echo x-access-token ;;
  *Password*) /var/jb/usr/bin/gh auth token ;;
  *) echo ;;
esac
