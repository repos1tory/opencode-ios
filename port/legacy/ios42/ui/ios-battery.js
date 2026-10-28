// OpenCode web UI — iOS device battery in the page title.
//
// Loaded as a module from index.html by patch-ui.mjs. It polls the server's
// device endpoint and keeps the tab title at "OpenCode • 72%" (plus a ⚡ while
// charging). It does not create or modify any element in the application, so
// web UI upgrades cannot break it. If the endpoint is unavailable the title is
// left untouched.
//
// No widget, no overlay, no layout changes.

const ENDPOINT = "/_ios/battery.json";
const POLL_MS = 60_000;
const RETRY_MS = 15_000;
const SEPARATOR = "\u2022";
const BASE_TITLE = "OpenCode";
const CHARGING_EMOJI = "\u26A1\uFE0F";

let level = null;
let charging = false;
let failures = 0;
let timer = null;
let inFlight = false;

function nextTitle() {
  return `${BASE_TITLE} ${SEPARATOR} ${level}%${charging ? ` ${CHARGING_EMOJI}` : ""}`;
}

function apply() {
  if (level === null) return;
  const title = nextTitle();
  if (document.title !== title) document.title = title;
}

async function refresh() {
  if (inFlight) return;
  inFlight = true;
  try {
    const response = await fetch(`${ENDPOINT}?t=${Date.now()}`, {
      cache: "no-store",
      credentials: "same-origin",
      headers: { accept: "application/json" },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    if (!data || data.ok !== true || typeof data.level !== "number") throw new Error("no battery data");
    level = Math.max(0, Math.min(100, Math.round(data.level)));
    charging = data.charging === true;
    failures = 0;
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
