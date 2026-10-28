"use strict";
/*
 * OpenCode iOS network gate.
 *
 * The OpenCode server itself listens on 0.0.0.0 so a Wi-Fi change, a DHCP
 * lease change, or a Tailscale reconnect can never leave it bound to a stale
 * address. Access is decided per TCP connection from the peer address:
 *
 *   - loopback is always allowed (the on-device webclip and control scripts)
 *   - 100.64.0.0/10 and fd7a:115c:a1e0::/48 are allowed when TAILSCALE=1
 *   - subnets of physical en, eth, and bridge interfaces are allowed when LAN=1
 *
 * Subnets are re-read from the live interface table, so the iPad's LAN
 * allowlist follows it to a new Wi-Fi network automatically. Settings are
 * re-read from settings.conf, so the Settings switches take effect without
 * restarting the server or interrupting an agent run.
 *
 * Loaded with `node --require network-gate.cjs` by server.sh. It wraps
 * http.createServer, which is how the OpenCode server creates its listener.
 * Disallowed sockets are destroyed before Node parses a request.
 */

const http = require("node:http");
const fs = require("node:fs");
const os = require("node:os");

const CONFIG_PATH =
  process.env.OPENCODE_IOS_GATE_CONFIG ||
  "/var/mobile/.config/opencode-ios/settings.conf";
const STATUS_PATH =
  process.env.OPENCODE_IOS_GATE_STATUS ||
  "/var/mobile/.config/opencode-ios/network.status";
const LOG_PATH =
  process.env.OPENCODE_IOS_GATE_LOG || "/var/mobile/Library/Logs/OpenCode/network.log";

const TAILSCALE_V4_NET = 0x64400000; // 100.64.0.0
const TAILSCALE_V4_MASK = 0xffc00000; // /10
const TAILSCALE_V6_NET = ipv6("fd7a:115c:a1e0::");
const TAILSCALE_V6_BITS = 48;

const IFACE_CACHE_MS = 2000;

function ipv4(value) {
  if (typeof value !== "string") return null;
  const parts = value.split(".");
  if (parts.length !== 4) return null;
  let result = 0;
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const number = Number(part);
    if (number > 255) return null;
    result = result * 256 + number;
  }
  return result >>> 0;
}

function ipv6(value) {
  if (typeof value !== "string") return null;
  let text = value.trim().toLowerCase();
  const zone = text.indexOf("%");
  if (zone >= 0) text = text.slice(0, zone);
  if (!text) return null;

  if (text.includes(".")) {
    const colon = text.lastIndexOf(":");
    if (colon < 0) return null;
    const embedded = ipv4(text.slice(colon + 1));
    if (embedded === null) return null;
    text =
      text.slice(0, colon + 1) +
      ((embedded >>> 16) & 0xffff).toString(16) +
      ":" +
      (embedded & 0xffff).toString(16);
  }

  const halves = text.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  for (const group of head.concat(tail)) {
    if (!/^[0-9a-f]{1,4}$/.test(group)) return null;
  }

  let groups;
  if (halves.length === 2) {
    const missing = 8 - head.length - tail.length;
    if (missing < 0) return null;
    groups = head.concat(new Array(missing).fill("0"), tail);
  } else {
    if (head.length !== 8) return null;
    groups = head;
  }

  let result = 0n;
  for (const group of groups) {
    result = (result << 16n) | BigInt(parseInt(group, 16));
  }
  return result;
}

function ipv6InPrefix(address, network, bits) {
  if (address === null || network === null) return false;
  const shift = BigInt(128 - bits);
  return address >> shift === network >> shift;
}

function v4InNet(address, network, mask) {
  return ((address & mask) >>> 0) === ((network & mask) >>> 0);
}

function v4Prefix(network, mask) {
  return { network, mask };
}

function v6Prefix(network, bits, label) {
  return { network, bits, label };
}

function truthy(value) {
  return value === "1" || value === "true" || value === "yes" || value === "on";
}

let state = {
  lan: false,
  tailscale: false,
  v4: [],
  v6: [],
  loadedAt: 0,
  ifacesAt: 0,
};

function readSettings() {
  let text;
  try {
    text = fs.readFileSync(CONFIG_PATH, "utf8");
  } catch {
    return null;
  }
  let lan = false;
  let tailscale = false;
  let sawLan = false;
  let sawTailscale = false;
  for (const raw of text.split("\n")) {
    const separator = raw.indexOf("=");
    if (separator < 0) continue;
    const key = raw.slice(0, separator).trim().toUpperCase();
    const value = raw.slice(separator + 1).trim().toLowerCase();
    if (key === "LAN") {
      lan = truthy(value);
      sawLan = true;
    } else if (key === "TAILSCALE") {
      tailscale = truthy(value);
      sawTailscale = true;
    }
  }
  // A partial read during an atomic Settings write must not silently revoke
  // the other path. The real file always contains both keys.
  if (!sawLan && !sawTailscale) return null;
  return {
    lan: sawLan ? lan : state.lan,
    tailscale: sawTailscale ? tailscale : state.tailscale,
  };
}

function isPhysicalInterface(name) {
  return /^(en\d+|eth\d+|bridge\d+)$/.test(name);
}

function readLanNetworks() {
  const v4 = [];
  const v6 = [];
  let interfaces;
  try {
    interfaces = os.networkInterfaces();
  } catch {
    return { v4, v6 };
  }

  for (const [name, entries] of Object.entries(interfaces)) {
    if (!isPhysicalInterface(name)) continue;
    for (const entry of entries || []) {
      if (!entry || entry.internal) continue;
      const slash = typeof entry.cidr === "string" ? entry.cidr.lastIndexOf("/") : -1;
      const prefix = slash >= 0 ? Number(entry.cidr.slice(slash + 1)) : NaN;

      if (entry.family === "IPv4" || entry.family === 4) {
        const address = ipv4(entry.address);
        if (address === null) continue;
        if (v4InNet(address, TAILSCALE_V4_NET, TAILSCALE_V4_MASK)) continue;
        if (address >>> 24 === 127) continue;
        const mask =
          Number.isInteger(prefix) && prefix >= 0 && prefix <= 32
            ? prefix === 0
              ? 0
              : (0xffffffff << (32 - prefix)) >>> 0
            : ipv4(entry.netmask);
        if (mask === null) continue;
        v4.push(v4Prefix(address & mask, mask));
      } else {
        const address = ipv6(entry.address);
        if (address === null) continue;
        if (ipv6InPrefix(address, TAILSCALE_V6_NET, TAILSCALE_V6_BITS)) continue;
        if (address === 1n) continue;
        const bits =
          Number.isInteger(prefix) && prefix >= 0 && prefix <= 128 ? prefix : 64;
        v6.push(v6Prefix(address, bits, entry.cidr || `${entry.address}/${bits}`));
      }
    }
  }
  return { v4, v6 };
}

const sockets = new Set();
let interval = null;
let lastStateKey = "";

function makeState(forceInterfaces) {
  const settings = readSettings();
  const now = Date.now();
  if (forceInterfaces || now - state.ifacesAt >= IFACE_CACHE_MS) {
    const networks = readLanNetworks();
    state.v4 = networks.v4;
    state.v6 = networks.v6;
    state.ifacesAt = now;
  }
  if (settings) {
    state.lan = settings.lan;
    state.tailscale = settings.tailscale;
  }
  state.loadedAt = now;
  return state;
}

function cidrLabel(prefix) {
  if (prefix.bits !== undefined) {
    return prefix.label || prefix.network.toString(16) + "/" + prefix.bits;
  }
  const mask = prefix.mask >>> 0;
  let bits = 0;
  for (let value = mask; value & 0x80000000; value = (value << 1) >>> 0) bits++;
  const network = (prefix.network & mask) >>> 0;
  return (
    [network >>> 24, (network >>> 16) & 255, (network >>> 8) & 255, network & 255].join(".") +
    "/" +
    bits
  );
}

function stateKey() {
  return [
    state.lan ? "1" : "0",
    state.tailscale ? "1" : "0",
    state.v4.map(cidrLabel).join(","),
    state.v6.map(cidrLabel).join(","),
  ].join("|");
}

function log(message) {
  try {
    fs.appendFileSync(LOG_PATH, `[${new Date().toISOString()}] ${message}\n`);
  } catch {
    // Logging must never take the server down.
  }
}

function writeStatus() {
  const payload = {
    lan: state.lan,
    tailscale: state.tailscale,
    lan_cidrs: state.v4.map(cidrLabel).concat(state.v6.map(cidrLabel)),
    updated: new Date(state.loadedAt).toISOString(),
  };
  const temporary = STATUS_PATH + ".tmp";
  try {
    fs.writeFileSync(temporary, JSON.stringify(payload) + "\n");
    fs.renameSync(temporary, STATUS_PATH);
  } catch {
    // Status is informational only.
  }
}

function refresh(forceInterfaces) {
  makeState(forceInterfaces);
  const key = stateKey();
  if (key !== lastStateKey) {
    lastStateKey = key;
    writeStatus();
    log(
      `access LAN=${state.lan ? 1 : 0} TAILSCALE=${state.tailscale ? 1 : 0} ` +
        `lan=[${state.v4.map(cidrLabel).concat(state.v6.map(cidrLabel)).join(" ")}]`,
    );
    return true;
  }
  return false;
}

function isLoopbackV4(address) {
  return address >>> 24 === 127;
}

function isLoopbackV6(address) {
  return address === 1n;
}

function allowedV4(address) {
  if (isLoopbackV4(address)) return true;
  if (state.tailscale && v4InNet(address, TAILSCALE_V4_NET, TAILSCALE_V4_MASK)) {
    return true;
  }
  if (state.lan) {
    for (const prefix of state.v4) {
      if (v4InNet(address, prefix.network, prefix.mask)) return true;
    }
  }
  return false;
}

function allowedV6(address) {
  if (isLoopbackV6(address)) return true;
  if (state.tailscale && ipv6InPrefix(address, TAILSCALE_V6_NET, TAILSCALE_V6_BITS)) {
    return true;
  }
  if (state.lan) {
    for (const prefix of state.v6) {
      if (ipv6InPrefix(address, prefix.network, prefix.bits)) return true;
    }
  }
  return false;
}

function allowed(remote) {
  if (typeof remote !== "string" || remote.length === 0) return false;

  try {
    // Picks up a toggle change immediately even before the 2s watcher runs.
    refresh(false);
  } catch {
    // Fall through with the last known state.
  }

  if (remote.startsWith("::ffff:")) {
    const mapped = ipv4(remote.slice("::ffff:".length));
    if (mapped !== null) return allowedV4(mapped);
  }

  const four = ipv4(remote);
  if (four !== null) return allowedV4(four);

  const six = ipv6(remote);
  if (six !== null) return allowedV6(six);

  return false;
}

function describePeer(remote) {
  if (typeof remote !== "string") return "unknown";
  return remote;
}

const denialLog = new Map();

function noteDenied(remote) {
  const now = Date.now();
  const last = denialLog.get(remote) || 0;
  if (now - last < 60000) return;
  if (denialLog.size > 256) denialLog.clear();
  denialLog.set(remote, now);
  log(
    `denied ${describePeer(remote)} ` +
      `(LAN=${state.lan ? 1 : 0} TAILSCALE=${state.tailscale ? 1 : 0})`,
  );
}

function sweepSockets() {
  for (const socket of sockets) {
    if (socket.destroyed) {
      sockets.delete(socket);
      continue;
    }
    if (!allowed(socket.remoteAddress)) {
      noteDenied(socket.remoteAddress);
      socket.destroy();
      sockets.delete(socket);
    }
  }
}

function startWatcher() {
  if (interval) return;
  refresh(true);
  interval = setInterval(() => {
    try {
      if (refresh(false)) sweepSockets();
    } catch {
      // Never let a transient interface read stop the server.
    }
  }, 2000);
  if (typeof interval.unref === "function") interval.unref();
}

const originalCreateServer = http.createServer;

http.createServer = function patchedCreateServer(...args) {
  const server = originalCreateServer.apply(this, args);

  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));

    let permitted;
    try {
      permitted = allowed(socket.remoteAddress);
    } catch {
      permitted = false;
    }

    if (!permitted) {
      noteDenied(socket.remoteAddress);
      socket.destroy();
      return;
    }

    startWatcher();
  });

  return server;
};

startWatcher();
