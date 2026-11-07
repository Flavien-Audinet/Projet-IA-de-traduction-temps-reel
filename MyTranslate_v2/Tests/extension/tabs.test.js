// Test : un seul onglet aux commandes du doublage (script de fond réel, Firefox et app imités).
"use strict";
const fs = require("fs"), path = require("path"), vm = require("vm");
const calls = [];
let onMessage = null;
const ctx = {
  console, setTimeout, clearTimeout, AbortController,
  fetch: async (url, opts) => { calls.push([url.replace("http://127.0.0.1:8770", ""), opts && opts.body ? JSON.parse(opts.body) : null]);
    return { ok: true, json: async () => ({ ready: true, readyAhead: true }) }; },
  browser: {
    runtime: { onMessage: { addListener: f => { onMessage = f; } } },
    commands: { onCommand: { addListener() {} } },
    tabs: { onRemoved: { addListener() {} }, query: async () => [] },
    action: { setBadgeText() {}, setBadgeBackgroundColor() {} },
  },
};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(__dirname, "../../Extension/background.js"), "utf8"), ctx);
const sync = (tab, url, paused) => onMessage({ type: "dubSync", url, t: 1, paused, rate: 1, visible: true, title: url }, { tab: { id: tab } });
let fails = 0;
const check = (ok, m) => { console.log((ok ? "  ✓ " : "  ✗ ") + m); if (!ok) fails++; };
(async () => {
  let r = await sync(1, "A", true);  check(r.owner === true, "onglet 1 (vidéo en pause) prend la main faute d'autre");
  r = await sync(2, "B", true);      check(r.owner === false, "onglet 2 en pause : laissé tranquille");
  r = await sync(2, "B", false);     check(r.owner === true, "onglet 2 se met à jouer : il prend la main");
  check(calls.some(([u, b]) => u === "/v1/dub/video" && b.url === "B"), "le moteur passe à la vidéo de l'onglet 2");
  r = await sync(1, "A", true);      check(r.owner === false, "onglet 1 n'a plus la main (ne coupe plus son son)");
  r = await sync(2, "B", true);      r = await sync(1, "A", false);
  check(r.owner === true, "onglet 2 en pause, onglet 1 rejoue : onglet 1 reprend la main");
  console.log(fails ? `${fails} échec(s)` : "Tout est bon.");
  process.exit(fails ? 1 : 0);
})();
