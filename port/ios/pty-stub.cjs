"use strict";

// node-pty is a macOS native addon and cannot load on iOS. The server only
// reaches these functions when a terminal is requested; failing lazily keeps
// the HTTP server and agent usable.

function unavailable() {
  throw new Error("PTY is unavailable on this iOS build");
}

module.exports = {
  spawn: unavailable,
  open: unavailable,
  native: {},
};
