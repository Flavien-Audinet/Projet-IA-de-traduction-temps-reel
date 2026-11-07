// MyTranslate — relais entre les pages et l'app (service local 127.0.0.1:8770).
"use strict";
const api = typeof browser !== "undefined" ? browser : chrome;
const APP = "http://127.0.0.1:8770";

async function appStatus() {
  try {
    const r = await fetch(APP + "/v1/status", { cache: "no-store" });
    const j = await r.json();
    return { ok: !!j.ready, ...j };
  } catch (e) {
    return { ok: false, error: "MyTranslate n'est pas lancé" };
  }
}

function toBase64(buf) {
  const bytes = new Uint8Array(buf);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

/** Texte dans une image : on récupère l'image (l'extension a le droit de la lire même si elle vient
 *  d'un autre domaine), puis l'app fait l'OCR + la traduction. */
async function ocr(msg) {
  try {
    let b64;
    if (msg.dataURL) {
      b64 = msg.dataURL.slice(msg.dataURL.indexOf(",") + 1);
    } else {
      const r = await fetch(msg.src, { credentials: "include" });
      if (!r.ok) return { ok: false };
      const buf = await r.arrayBuffer();
      if (buf.byteLength > 25 * 1024 * 1024) return { ok: false };
      b64 = toBase64(buf);
    }
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 30000);
    const r = await fetch(APP + "/v1/ocr", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ image: b64, context: msg.context }), signal: ctrl.signal,
    }).finally(() => clearTimeout(timer));
    const j = await r.json();
    return { ok: !j.error, ...j };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

async function translate(units, context, priority) {
  // Délai maximum : une requête bloquée ne doit pas figer la page (elle sera réessayée).
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 25000);
  try {
    const r = await fetch(APP + "/v1/translate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ units, context, priority }),
      signal: ctrl.signal,
    });
    if (!r.ok) return { ok: false, error: "HTTP " + r.status };
    const j = await r.json();
    return { ok: Array.isArray(j.translations) && j.translations.length === units.length, translations: j.translations, warning: j.warning };
  } catch (e) {
    return { ok: false, error: String(e) };
  } finally {
    clearTimeout(timer);
  }
}

api.runtime.onMessage.addListener((msg, sender) => {
  if (msg.type === "status") return appStatus();
  if (msg.type === "translate") return translate(msg.units, msg.context, msg.priority);
  if (msg.type === "ocr") return ocr(msg);
  if (msg.type === "dubStatus") return fetch(APP + "/v1/dub/status", { cache: "no-store" }).then(r => r.json()).catch(() => ({ active: false }));
  if (msg.type === "dubSync" && sender.tab) return dubSync(sender.tab.id, msg);
  if (msg.type === "dubRelease" && sender.tab) { if (dubOwner === sender.tab.id) { dubOwner = null; dubURL = ""; post("/v1/dub/stop", {}); } return Promise.resolve(true); }
  if (msg.type === "dubStop") { dubOwner = null; dubURL = ""; return post("/v1/dub/stop", {}); }
  if (msg.type === "dubEngine") return fetch("http://127.0.0.1:8771/status").then(r => r.json()).catch(() => null);
  if (msg.type === "badge" && sender.tab) {
    api.action.setBadgeText({ tabId: sender.tab.id, text: msg.on ? (msg.text || "ON") : "" });
    api.action.setBadgeBackgroundColor({ tabId: sender.tab.id, color: "#2a78d6" });
    return Promise.resolve(true);
  }
});

// ---------- Doublage : un seul onglet aux commandes ----------
// L'onglet qui JOUE une vidéo au premier plan prend la main ; tant qu'aucun onglet ne joue, le premier
// qui a une vidéo la garde (le doublage se prépare pendant qu'on lit la page). Les autres onglets
// ne coupent pas leur son et ne se mettent pas en pause.
let dubOwner = null, dubURL = "";
const post = (path, body) => fetch(APP + path, { method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body) }).then(r => r.json()).catch(() => null);

async function dubSync(tab, m) {
  const playing = !m.paused && m.visible;
  if (dubOwner !== tab && (dubOwner === null || playing)) {
    if (playing || dubOwner === null) { dubOwner = tab; dubURL = ""; }
  }
  if (dubOwner !== tab) return { owner: false };
  if (m.url !== dubURL) {
    dubURL = m.url;
    await post("/v1/dub/video", { url: m.url, src: m.src, t: m.t, title: m.title });
  }
  const r = await post("/v1/dub/sync", { t: m.t, paused: m.paused, rate: m.rate });
  return r ? { owner: true, ...r } : null;
}
api.tabs.onRemoved.addListener(tab => { if (tab === dubOwner) { dubOwner = null; dubURL = ""; post("/v1/dub/stop", {}); } });

api.commands.onCommand.addListener(async (cmd) => {
  if (cmd !== "toggle-translation") return;
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (tab) api.tabs.sendMessage(tab.id, { type: "toggle" }).catch(() => {});
});
