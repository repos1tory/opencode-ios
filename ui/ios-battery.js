// OpenCode web UI — iOS battery, upstream version, and update state in the title.
//
// Loaded as a module from index.html by patch-ui.mjs. It polls two tiny
// on-device endpoints and keeps the tab title at:
//
//   OpenCode • 72% • v2.2.0
//   OpenCode • 72% • v2.2.0 ↑2.2.1   (when a newer official release exists)
//
// It does not create or modify any element in the application, so web UI
// upgrades cannot break it. Missing endpoints simply omit that part.

const BATTERY_ENDPOINT = "/_ios/battery.json";
const PORT_ENDPOINT = "/_ios/port.json";
const POLL_MS = 60_000;
const RETRY_MS = 15_000;
const SEPARATOR = "\u2022";
const BASE_TITLE = "OpenCode";
const CHARGING_EMOJI = "\u26A1\uFE0F";

let level = null;
let charging = false;
let version = null;
let update = null;
let failures = 0;
let timer = null;
let inFlight = false;

function nextTitle() {
  const parts = [BASE_TITLE];
  if (level !== null) parts.push(`${level}%${charging ? ` ${CHARGING_EMOJI}` : ""}`);
  if (version) parts.push(`v${version}`);
  if (update) parts.push(`\u2191${update}`);
  return parts.join(` ${SEPARATOR} `);
}

function apply() {
  const title = nextTitle();
  if (document.title !== title) document.title = title;
}

async function readJSON(url) {
  const response = await fetch(`${url}?t=${Date.now()}`, {
    cache: "no-store",
    credentials: "same-origin",
    headers: { accept: "application/json" },
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

async function refresh() {
  if (inFlight) return;
  inFlight = true;
  try {
    const [battery, port] = await Promise.allSettled([readJSON(BATTERY_ENDPOINT), readJSON(PORT_ENDPOINT)]);

    if (battery.status === "fulfilled" && battery.value && battery.value.ok === true && typeof battery.value.level === "number") {
      level = Math.max(0, Math.min(100, Math.round(battery.value.level)));
      charging = battery.value.charging === true;
    }

    if (port.status === "fulfilled" && port.value && typeof port.value.upstream === "string") {
      version = port.value.upstream;
      update = port.value.update === true && typeof port.value.latest === "string" ? port.value.latest : null;
    }

    failures = battery.status === "fulfilled" || port.status === "fulfilled" ? 0 : failures + 1;
    apply();
  } catch {
    failures += 1;
  } finally {
    inFlight = false;
  }
  if (timer) clearTimeout(timer);
  timer = setTimeout(refresh, failures === 0 ? POLL_MS : RETRY_MS);
}

function boot() {
  // The app does not currently change the title, but re-apply if a future
  // build does. Comparing first avoids reacting to our own write.
  if (typeof MutationObserver === "function" && document.head) {
    new MutationObserver(apply).observe(document.head, {
      childList: true,
      subtree: true,
      characterData: true,
    });
  }
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) refresh();
  });
  window.addEventListener("focus", refresh);
  refresh();
}

if (document.head) boot();
else document.addEventListener("DOMContentLoaded", boot, { once: true });
