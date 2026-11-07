"use strict";
const api = typeof browser !== "undefined" ? browser : chrome;
const $ = id => document.getElementById(id);

(async () => {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  const host = tab && tab.url ? new URL(tab.url).hostname : "";
  $("host").textContent = host || "ce site";

  const st = await api.runtime.sendMessage({ type: "status" });
  $("dot").className = "dot " + (st.ok ? "ok" : "ko");
  $("status").textContent = st.ok
    ? `${st.source.toUpperCase()} → ${st.target.toUpperCase()} · ${st.engineLabel}`
    : (st.error || "Moteur de l'app pas encore prêt");

  let state = await api.tabs.sendMessage(tab.id, { type: "state" }).catch(() => null);
  const render = () => {
    $("toggle").textContent = state && state.active ? "Afficher l'original" : "Traduire cette page";
    $("toggle").className = state && state.active ? "secondary" : "";
  };
  render();
  $("toggle").disabled = !st.ok || !state;
  if (!state) $("status").textContent = "Page non traduisible (page interne du navigateur)";

  $("toggle").onclick = async () => {
    state = await api.tabs.sendMessage(tab.id, { type: "toggle" }).catch(() => state);
    render();
    if (state && state.active) window.close();
  };

  const prefs = await api.storage.local.get(["autoAll", "neverSites"]);
  $("autoAll").checked = prefs.autoAll !== false;            // activé par défaut
  $("never").checked = (prefs.neverSites || []).includes(host);

  $("autoAll").onchange = async () => {
    await api.storage.local.set({ autoAll: $("autoAll").checked });
    if ($("autoAll").checked && !$("never").checked && !(state && state.active)) {
      state = await api.tabs.sendMessage(tab.id, { type: "start" }).catch(() => state);
      render();
    }
  };
  $("never").onchange = async () => {
    const { neverSites = [] } = await api.storage.local.get("neverSites");
    const next = $("never").checked ? [...new Set([...neverSites, host])] : neverSites.filter(h => h !== host);
    await api.storage.local.set({ neverSites: next });
    if ($("never").checked && state && state.active) {
      state = await api.tabs.sendMessage(tab.id, { type: "stop" }).catch(() => state);
      render();
    }
  };
})();
