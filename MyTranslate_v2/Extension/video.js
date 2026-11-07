// MyTranslate — vidéos pendant le doublage (« Écouter traduit »).
//  • Mode « web » (recommandé) : l'app prépare le doublage EN AVANCE sur la ligne de temps de la vidéo.
//    Ici on lui envoie la vidéo, puis sa position (lecture, pause, saut, vitesse) ; on coupe le son de la
//    vidéo quand le doublage est prêt, et on la met en pause (avec un indicateur) tant qu'il ne l'est pas.
//  • Mode « system » (direct) : l'app rejoue le son avec un délai D ; on affiche alors la vidéo avec le
//    même délai sur un calque (chaque image est redessinée D secondes plus tard).
(function () {
  "use strict";
  if (window.__mytranslateVideo) return;
  window.__mytranslateVideo = true;
  const api = typeof browser !== "undefined" ? browser : chrome;

  let active = false, delay = 7000, mo = null, warned = false;

  // ================= Mode web : doublage préparé à l'avance =================
  const Web = (() => {
    let on = false, v = null, url = "", timer = 0, badge = null, wePaused = false, origMuted = false, busy = false;
    const send = m => api.runtime.sendMessage(m).catch(() => null);

    function enable() {
      if (on) return;
      on = true;
      timer = setInterval(tick, 250);
      document.addEventListener("play", onEvent, true);
      document.addEventListener("pause", onEvent, true);
      document.addEventListener("seeked", onEvent, true);
      document.addEventListener("ratechange", onEvent, true);
    }

    function disable() {
      if (!on) return;
      on = false;
      clearInterval(timer);
      ["play", "pause", "seeked", "ratechange"].forEach(e => document.removeEventListener(e, onEvent, true));
      release();
      send({ type: "dubRelease" });
    }

    function release() {
      if (v) v.muted = origMuted;
      if (badge) badge.remove();
      badge = null; v = null; url = ""; wePaused = false;
    }

    /** Vidéo principale : la plus grande vidéo visible d'au moins 15 s. */
    function pick() {
      let best = null, area = 0;
      for (const x of document.querySelectorAll("video")) {
        const r = x.getBoundingClientRect();
        const a = r.width * r.height;
        if (a > area && a > 40000 && (x.duration || 0) > 15) { best = x; area = a; }
      }
      return best;
    }

    // Publicités YouTube : pas de doublage pendant la pub (le son reste celui de la pub).
    const adPlaying = () => !!document.querySelector(".ad-showing, .ad-interrupting");

    function onEvent(e) { if (e.target === v) tick(); }

    async function tick() {
      if (!on || busy) return;
      const cur = pick();
      if (cur !== v || location.href !== url) {
        release();
        if (!cur) { send({ type: "dubRelease" }); return; }
        v = cur; url = location.href; origMuted = v.muted;
      }
      if (adPlaying()) { v.muted = origMuted; show("publicité : son d'origine"); return; }
      busy = true;
      const src = /^https?:/.test(v.currentSrc || "") ? v.currentSrc : null;
      const res = await send({ type: "dubSync", url, src, title: document.title, visible: document.visibilityState === "visible",
                               t: v.currentTime, paused: v.paused || wePaused, rate: v.playbackRate });
      busy = false;
      if (!on || !v || !res) return;
      if (res.owner === false) {
        // Un autre onglet a la main : on laisse cette vidéo tranquille (son d'origine, pas de pause).
        if (wePaused) { wePaused = false; v.play().catch(() => {}); }
        v.muted = origMuted;
        hide();
        return;
      }
      if (res.ready) {
        v.muted = true;                                   // on entend le doublage de l'app
        if (wePaused && res.readyAhead) { wePaused = false; v.play().catch(() => {}); }
        if (!wePaused) hide();
      } else if (!v.paused || wePaused) {
        // Pas encore prêt ici (démarrage, saut) : pause courte, comme une mise en mémoire tampon.
        if (!v.paused) { wePaused = true; v.pause(); }
        v.muted = origMuted;
        const st = await send({ type: "dubEngine" });
        show(st && st.state === "erreur" ? "doublage impossible : " + (st.message || "") :
             st && st.state === "téléchargement" ? "récupération de la vidéo…" : "préparation du doublage…");
      }
    }

    function show(text) {
      if (!v || !v.parentElement) return;
      if (!badge) {
        badge = document.createElement("div");
        badge.className = "mytranslate-skip";
        Object.assign(badge.style, { position: "absolute", zIndex: "2147483646", pointerEvents: "none",
          background: "rgba(20,20,22,.85)", color: "#fff", font: "600 13px -apple-system, sans-serif",
          padding: "6px 10px", borderRadius: "8px" });
        v.parentElement.appendChild(badge);
      }
      badge.textContent = "MyTranslate · " + text;
      badge.style.left = (v.offsetLeft + 12) + "px";
      badge.style.top = (v.offsetTop + 12) + "px";
    }
    function hide() { if (badge) { badge.remove(); badge = null; } }

    return { enable, disable };
  })();
  const states = new Map();          // vidéo → état

  async function poll() {
    const st = await api.runtime.sendMessage({ type: "dubStatus" }).catch(() => null);
    const on = st && st.active;
    if (on && st.mode === "web") {
      if (active) disable();
      Web.enable(st.offset || 0);
    } else if (on) {
      Web.disable();
      delay = Math.max(0, st.delay * 1000);
      if (!active) enable();
    } else {
      Web.disable();
      if (active) disable();
    }
  }
  setInterval(poll, 1500);
  poll();

  function enable() {
    active = true;
    scan();
    mo = new MutationObserver(scan);
    mo.observe(document.documentElement, { childList: true, subtree: true });
  }

  function disable() {
    active = false;
    if (mo) mo.disconnect();
    mo = null;
    for (const v of [...states.keys()]) detach(v);
  }

  function scan() {
    for (const v of document.querySelectorAll("video")) if (!states.has(v)) attach(v);
    for (const v of [...states.keys()]) if (!v.isConnected) detach(v);
  }

  function attach(v) {
    if (!v.parentElement) return;
    const canvas = document.createElement("canvas");
    canvas.className = "mytranslate-skip";
    Object.assign(canvas.style, { position: "absolute", pointerEvents: "none", margin: "0", padding: "0",
      border: "0", background: "#000", zIndex: getComputedStyle(v).zIndex === "auto" ? "0" : getComputedStyle(v).zIndex });
    v.parentElement.insertBefore(canvas, v.nextSibling);
    const st = { canvas, ctx: canvas.getContext("2d"), frames: [], shown: null, raf: 0, vfc: 0, ok: true, lastT: -1 };
    states.set(v, st);
    capture(v, st);
    const loop = () => { if (!states.has(v)) return; draw(v, st); st.raf = requestAnimationFrame(loop); };
    st.raf = requestAnimationFrame(loop);
  }

  function detach(v) {
    const st = states.get(v);
    if (!st) return;
    states.delete(v);
    cancelAnimationFrame(st.raf);
    if (st.vfc && v.cancelVideoFrameCallback) v.cancelVideoFrameCallback(st.vfc);
    st.frames.forEach(f => f.bmp.close());
    st.canvas.remove();
  }

  /** Mémorise chaque nouvelle image de la vidéo (taille d'affichage, au plus 1280 px de large). */
  function capture(v, st) {
    const grab = async () => {
      if (!states.has(v) || !st.ok) return;
      if (v.readyState >= 2 && v.videoWidth && !v.paused && v.currentTime !== st.lastT) {
        st.lastT = v.currentTime;
        const w = Math.min(1280, Math.round(v.clientWidth * devicePixelRatio)) || 640;
        const h = Math.round(w * v.videoHeight / v.videoWidth);
        try {
          const bmp = await createImageBitmap(v, { resizeWidth: w, resizeHeight: h, resizeQuality: "medium" });
          st.frames.push({ t: performance.now(), bmp });
        } catch (e) {
          // Vidéo protégée (DRM : Netflix, Disney+…) : impossible de la retarder.
          st.ok = false;
          st.canvas.remove();
          if (!warned) { warned = true; console.info("MyTranslate : vidéo protégée, décalage d'image impossible (le son est doublé quand même)."); }
          return;
        }
      }
      if (v.requestVideoFrameCallback) st.vfc = v.requestVideoFrameCallback(grab);
      else setTimeout(grab, 1000 / 60);
    };
    grab();
  }

  function draw(v, st) {
    if (!st.ok) return;
    // Le calque suit la position et la taille de la vidéo.
    const c = st.canvas;
    const L = v.offsetLeft + "px", T = v.offsetTop + "px", W = v.offsetWidth, H = v.offsetHeight;
    if (c.style.left !== L) c.style.left = L;
    if (c.style.top !== T) c.style.top = T;
    if (c.style.width !== W + "px") { c.style.width = W + "px"; }
    if (c.style.height !== H + "px") { c.style.height = H + "px"; }
    const pw = Math.round(W * devicePixelRatio), ph = Math.round(H * devicePixelRatio);
    if (c.width !== pw || c.height !== ph) { c.width = pw; c.height = ph; st.shown = null; }

    // Image d'il y a D secondes ; avant ça (début), la première image reste affichée.
    const target = performance.now() - delay;
    let k = -1;
    for (let i = 0; i < st.frames.length; i++) { if (st.frames[i].t <= target) k = i; else break; }
    const frame = k >= 0 ? st.frames[k] : st.frames[0];
    if (k > 0) st.frames.splice(0, k).forEach(f => f.bmp.close());      // images déjà montrées
    if (!frame || frame === st.shown) return;
    st.shown = frame;
    // Respect du cadrage de la vidéo (object-fit : contain par défaut, cover…)
    const fit = getComputedStyle(v).objectFit || "contain";
    const iw = frame.bmp.width, ih = frame.bmp.height;
    const s = fit === "cover" ? Math.max(pw / iw, ph / ih) : fit === "fill" ? null : Math.min(pw / iw, ph / ih);
    st.ctx.fillStyle = "#000";
    st.ctx.fillRect(0, 0, pw, ph);
    if (s === null) st.ctx.drawImage(frame.bmp, 0, 0, pw, ph);
    else st.ctx.drawImage(frame.bmp, (pw - iw * s) / 2, (ph - ih * s) / 2, iw * s, ih * s);
  }
})();
