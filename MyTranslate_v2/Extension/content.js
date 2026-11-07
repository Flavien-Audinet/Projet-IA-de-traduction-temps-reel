// MyTranslate — traduction de la page, sur place.
// 1. Ce qui est visible (+ un écran d'avance) passe en priorité, avec le moteur choisi dans l'app.
// 2. Tout le reste de la page est traduit en arrière-plan, du plus proche au plus lointain
//    (l'app confie ces lots à Opus-MT, sur le processeur, en parallèle).
// 3. Les textes identiques ne sont traduits qu'une fois ; le texte dans les images passe par l'OCR (images.js).
(function () {
  "use strict";
  if (window.__mytranslate) return;
  window.__mytranslate = true;

  const C = window.MTCore;
  const api = typeof browser !== "undefined" ? browser : chrome;

  let active = false, starting = false;
  let source = "en", target = "fr";
  let peeking = false;
  const infos = new Map();          // unité → {state, text, slots, plain, tries}
  const queue = new Set();          // visibles : prioritaires
  let bg = [];                      // le reste de la page, trié par distance à l'écran
  const touched = new Set();        // nœuds texte modifiés (pour l'original / la restauration)
  const known = new Map();          // texte balisé → traduction (doublons de la page)
  let io = null, flushTimer = null, inflightFg = 0, inflightBg = 0, sentCount = 0;
  const observers = [];

  // ---------- Démarrage / arrêt ----------

  async function start() {
    if (active || starting) return;
    starting = true;
    const st = await api.runtime.sendMessage({ type: "status" }).catch(() => null);
    starting = false;
    if (!st || !st.ok) { notify("MyTranslate n'est pas lancé (ou son moteur n'est pas prêt)."); return; }
    source = st.source; target = st.target;
    active = true;
    sentCount = 0;
    io = typeof IntersectionObserver !== "undefined"
      ? new IntersectionObserver(onVisible, { rootMargin: "100% 0px 100% 0px" }) : null;
    scan(document.body || document.documentElement);
    watch(document.documentElement);
    if (window.MTImages) window.MTImages.start({ source, target });
    api.runtime.sendMessage({ type: "badge", on: true, text: target.toUpperCase() }).catch(() => {});
  }

  function stop() {
    if (!active) return;
    active = false;
    if (io) io.disconnect();
    io = null;
    observers.splice(0).forEach(o => o.disconnect());
    C.restore(touched);
    touched.clear(); infos.clear(); queue.clear(); bg = [];
    if (window.MTImages) window.MTImages.stop();
    api.runtime.sendMessage({ type: "badge", on: false }).catch(() => {});
  }

  // ---------- Découverte des unités ----------

  function scan(rootNode) {
    const { units, shadowRoots } = C.collectUnits(rootNode);
    for (const sr of shadowRoots) watch(sr);
    const fresh = [];
    for (const u of units) {
      if (infos.has(u)) continue;
      infos.set(u, { state: "new" });
      fresh.push(u);
      if (io) io.observe(u); else queue.add(u);
    }
    // Arrière-plan : tout le reste, du plus proche de l'écran au plus lointain.
    if (fresh.length) {
      const vh = window.innerHeight || 800;
      const withDist = fresh.map(u => {
        const r = u.getBoundingClientRect ? u.getBoundingClientRect() : { top: 0, bottom: 0 };
        return [u, r.bottom < 0 ? -r.bottom : r.top > vh ? r.top - vh : 0];
      });
      bg = bg.concat(withDist).sort((a, b) => a[1] - b[1]);
    }
    scheduleFlush();
  }

  function onVisible(entries) {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      const info = infos.get(e.target);
      if (info && info.state === "new") queue.add(e.target);
      io.unobserve(e.target);
    }
    scheduleFlush();
  }

  // ---------- Envoi par lots ----------

  function scheduleFlush() {
    if (flushTimer) return;
    flushTimer = setTimeout(() => { flushTimer = null; flush(); }, 20);
  }

  /** Prépare un lot : sérialise, applique tout de suite les textes déjà connus (doublons). */
  function take(source, max, maxChars) {
    const batch = [];
    let chars = 0;
    while (source.length && batch.length < max && chars < maxChars) {
      const u = source.shift();
      const info = infos.get(u);
      if (!info || info.state !== "new") continue;
      if (!u.isConnected) { infos.delete(u); continue; }
      const s = C.serialize(u);
      const plain = C.plainOf(s.text);
      if (plain.length < 2 || !/\p{L}/u.test(plain)) { info.state = "skip"; continue; }
      Object.assign(info, { state: "pending", text: s.text, slots: s.slots, plain });
      if (known.has(s.text)) { apply(u, info, known.get(s.text)); continue; }
      batch.push(u);
      chars += s.text.length;
    }
    return batch;
  }

  function flush() {
    if (!active) return;
    // Priorité : ce qui est visible (2 requêtes à la fois ; premier lot petit pour un affichage immédiat).
    while (inflightFg < 2 && queue.size) {
      const list = [...queue];
      queue.clear();
      const batch = take(list, sentCount === 0 ? 8 : 24, 3500);
      list.forEach(u => queue.add(u));          // le reste attend son tour
      if (!batch.length) break;
      sentCount++;
      send(batch, "visible");
    }
    // Arrière-plan : le reste de la page, gros lots, sans gêner les lots visibles.
    while (inflightBg < 2 && bg.length) {
      const list = bg.map(x => x[0]);
      const batch = take(list, 48, 9000);
      const left = new Set(list);
      bg = bg.filter(x => left.has(x[0]));
      if (!batch.length) break;
      send(batch, "background");
    }
  }

  async function send(units, priority) {
    priority === "visible" ? inflightFg++ : inflightBg++;
    try {
      // Langue : on ne traduit que ce qui est dans la langue source.
      const verdicts = await Promise.all(units.map(u => isSourceLanguage(infos.get(u).plain)));
      const keep = [];
      units.forEach((u, k) => { if (verdicts[k]) keep.push(u); else infos.get(u).state = "skip"; });
      if (!keep.length) return;
      // Un seul exemplaire de chaque texte dans le lot.
      const texts = [...new Set(keep.map(u => infos.get(u).text))];
      const context = (document.title || "") + " · " + (document.querySelector("h1")?.textContent || "").trim().slice(0, 200);
      const res = await api.runtime.sendMessage({ type: "translate", units: texts, context, priority }).catch(() => null);
      if (!active) return;
      if (!res || !res.ok) {
        // Échec (app occupée, délai dépassé…) : nouvel essai plus tard, jusqu'à 3 fois.
        keep.forEach(u => {
          const i = infos.get(u);
          if (!i) return;
          i.tries = (i.tries || 0) + 1;
          if (i.tries <= 3) {
            i.state = "new";
            setTimeout(() => { if (active) { queue.add(u); scheduleFlush(); } }, 800 * i.tries);
          } else i.state = "failed";
        });
        return;
      }
      texts.forEach((t, k) => known.set(t, res.translations[k]));
      for (const u of keep) {
        const info = infos.get(u);
        if (info && known.has(info.text)) apply(u, info, known.get(info.text));
      }
    } finally {
      priority === "visible" ? inflightFg-- : inflightBg--;
      scheduleFlush();
    }
  }

  function apply(u, info, translation) {
    if (!u.isConnected) return;
    // Le site a peut-être modifié le texte entre-temps : on vérifie.
    const now = C.serialize(u);
    if (now.text !== info.text) { info.state = "new"; queue.add(u); scheduleFlush(); return; }
    const nodes = C.applyTranslation(now, translation);
    nodes.forEach(n => touched.add(n));
    info.state = "done";
    if (peeking) C.restore(nodes);
  }

  const langCache = new Map();
  async function isSourceLanguage(text) {
    if (langCache.has(text)) return langCache.get(text);
    let verdict = null;
    try {
      const r = await api.i18n.detectLanguage(text);
      const top = r.languages && r.languages[0];
      if (top && r.isReliable) verdict = top.language.startsWith(source);
      else if (top && top.language.startsWith(target) && top.percentage > 60) verdict = false;
    } catch (e) { /* détection indisponible : on se fie à la langue de la page */ }
    if (verdict === null) verdict = !(document.documentElement.lang || "").toLowerCase().startsWith(target);
    langCache.set(text, verdict);
    return verdict;
  }

  // ---------- Pages dynamiques (défilement infini, applis React, etc.) ----------

  function watch(rootNode) {
    const mo = new MutationObserver(muts => {
      if (!active) return;
      const fresh = new Set();
      const redo = u => { if (u) { infos.set(u, { state: "new" }); queue.add(u); } };
      for (const m of muts) {
        if (m.type === "characterData") {
          const n = m.target;
          if (peeking || C.isOurs(n) || C.isOriginal(n)) continue;   // nos propres changements
          // Le site a réécrit ce texte : on oublie l'ancien état et on retraduit l'unité.
          C.forget(n);
          touched.delete(n);
          redo(unitOf(n));
        } else {
          for (const a of m.addedNodes) {
            if (a.nodeType === 1 && !(a.classList && a.classList.contains("mytranslate-skip"))) fresh.add(a);
            else if (a.nodeType === 3 && a.parentElement && !C.isOurs(a)) redo(unitOf(a));
          }
        }
      }
      fresh.forEach(n => { if (n.isConnected) scan(n); });
      // Un nœud ajouté peut être du texte dans une unité déjà traduite : on remonte à son unité.
      fresh.forEach(n => { const u = unitOf(n); if (u && infos.get(u)?.state === "done") redo(u); });
      scheduleFlush();
    });
    mo.observe(rootNode, { childList: true, subtree: true, characterData: true });
    observers.push(mo);
  }

  function unitOf(node) {
    let el = node.nodeType === 1 ? node : node.parentElement;
    while (el) {
      if (infos.has(el)) return el;
      if (C.isUnitRoot(el)) return el;
      el = el.parentElement || (el.getRootNode && el.getRootNode().host) || null;
    }
    return null;
  }

  // ---------- Voir l'original : maintenir ⌥ (Option / Alt) ----------

  window.addEventListener("keydown", e => {
    if (e.key === "Alt" && active && !peeking) {
      peeking = true;
      C.restore(touched);
      if (window.MTImages) window.MTImages.peek(true);
    }
  }, true);
  function unpeek() {
    if (!peeking) return;
    C.reapply(touched);
    if (window.MTImages) window.MTImages.peek(false);
    setTimeout(() => { peeking = false; }, 0);
  }
  window.addEventListener("keyup", e => { if (e.key === "Alt") unpeek(); }, true);
  window.addEventListener("blur", unpeek);

  // ---------- Petit message discret ----------

  function notify(msg) {
    const d = document.createElement("div");
    d.className = "mytranslate-skip";
    d.textContent = msg;
    Object.assign(d.style, { position: "fixed", right: "16px", bottom: "16px", zIndex: 2147483647,
      background: "rgba(30,30,32,.92)", color: "#fff", font: "13px -apple-system, sans-serif",
      padding: "10px 14px", borderRadius: "10px", boxShadow: "0 4px 18px rgba(0,0,0,.3)" });
    document.documentElement.appendChild(d);
    setTimeout(() => d.remove(), 4000);
  }

  // ---------- Messages du bouton / raccourci ----------

  api.runtime.onMessage.addListener(msg => {
    if (msg.type === "toggle") { const was = active || starting; was ? stop() : start(); return Promise.resolve({ active: !was }); }
    if (msg.type === "start") { start(); return Promise.resolve({ active: true }); }
    if (msg.type === "stop") { stop(); return Promise.resolve({ active: false }); }
    if (msg.type === "state") {
      const all = [...infos.values()];
      return Promise.resolve({ active, done: all.filter(i => i.state === "done").length,
                               pending: queue.size + bg.length + inflightFg + inflightBg });
    }
  });

  // ---------- Traduction automatique ----------
  // Par défaut : toute page dont la langue est la langue source est traduite dès son chargement,
  // sauf sur les sites exclus (« Jamais sur ce site »). Les sites cochés « Toujours » sont traduits
  // même si la détection de langue hésite.

  async function pageLooksSource() {
    const st = await api.runtime.sendMessage({ type: "status" }).catch(() => null);
    if (!st || !st.ok) return false;
    source = st.source; target = st.target;
    const lang = (document.documentElement.lang || "").toLowerCase();
    if (lang.startsWith(target)) return false;          // page déclarée dans la langue cible
    const body = document.body;
    const sample = (body ? (body.innerText || body.textContent || "") : "").replace(/\s+/g, " ").slice(0, 3000);
    if (sample.length < 40) return lang.startsWith(source);
    try {
      const r = await api.i18n.detectLanguage(sample);
      const top = r.languages && r.languages[0];
      if (top) return top.language.startsWith(source) && (r.isReliable || top.percentage >= 50);
    } catch (e) { /* détection indisponible */ }
    return lang.startsWith(source);
  }

  async function autoStart() {
    const { autoAll = true, autoSites = [], neverSites = [] } =
      await api.storage.local.get(["autoAll", "autoSites", "neverSites"]).catch(() => ({}));
    const host = location.hostname;
    if (neverSites.includes(host)) return;
    if (autoSites.includes(host)) { start(); return; }
    if (!autoAll) return;
    if (await pageLooksSource()) start();
  }

  // Les pages qui se remplissent après le chargement (applis web) : on attend un peu de texte.
  if (document.readyState === "complete") setTimeout(autoStart, 300);
  else window.addEventListener("load", () => setTimeout(autoStart, 300), { once: true });

  // Changement de page sans rechargement (Reddit, YouTube…) : nouvelle tentative si rien n'est actif.
  let lastURL = location.href;
  setInterval(() => {
    if (location.href !== lastURL) {
      lastURL = location.href;
      if (!active && !starting) setTimeout(autoStart, 800);
    }
  }, 1000);
})();
