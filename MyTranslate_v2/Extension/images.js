// MyTranslate — texte DANS les images et les canvas (bannières, captures, schémas, Google Docs…).
// L'image est envoyée à l'app (OCR Apple Vision + style + traduction) ; la traduction est posée
// par-dessus, au même endroit, dans la même police / taille / couleur. Le calque laisse passer
// la souris (pointer-events: none) : les images-liens restent cliquables.
(function () {
  "use strict";
  const api = typeof browser !== "undefined" ? browser : chrome;

  let active = false, io = null, layer = null, ro = null, raf = 0, timer = 0;
  const done = new WeakMap();        // élément → {box, blocks, w, h}
  const pending = new Set();
  let inflight = 0;
  const wait = [];

  const MIN_W = 120, MIN_H = 40;

  function start() {
    if (active || typeof IntersectionObserver === "undefined" || typeof ResizeObserver === "undefined") return;
    active = true;
    layer = document.createElement("div");
    layer.className = "mytranslate-skip";
    Object.assign(layer.style, { position: "absolute", left: "0", top: "0", width: "0", height: "0",
      pointerEvents: "none", zIndex: "2147483646" });
    document.documentElement.appendChild(layer);
    io = new IntersectionObserver(onVisible, { rootMargin: "50% 0px 50% 0px" });
    ro = new ResizeObserver(() => schedule());
    scanAll();
    window.addEventListener("scroll", schedule, true);       // conteneurs défilants internes
    window.addEventListener("resize", schedule);
    timer = setInterval(() => { scanAll(); schedule(); }, 1500);   // nouvelles images, mise en page qui bouge
  }

  function stop() {
    active = false;
    if (io) io.disconnect();
    if (ro) ro.disconnect();
    io = ro = null;
    clearInterval(timer);
    window.removeEventListener("scroll", schedule, true);
    window.removeEventListener("resize", schedule);
    if (layer) layer.remove();
    layer = null;
  }

  function peek(on) { if (layer) layer.style.display = on ? "none" : ""; }

  // ---------- Repérage des images ----------

  function candidates(root) {
    const out = [];
    for (const el of root.querySelectorAll("img, canvas")) {
      if (done.has(el) || pending.has(el) || el.__mtSeen) continue;
      el.__mtSeen = true;
      if (el.closest && el.closest(".mytranslate-skip, [translate='no'], .notranslate")) continue;
      out.push(el);
    }
    return out;
  }

  function scanAll() { if (active) candidates(document).forEach(el => io.observe(el)); }

  function worth(el) {
    const r = el.getBoundingClientRect();
    if (r.width < MIN_W || r.height < MIN_H) return false;
    if (el.tagName === "IMG") {
      if (!el.complete || el.naturalWidth < MIN_W || el.naturalHeight < MIN_H) return false;
      const src = el.currentSrc || el.src || "";
      if (/\.svg(\?|#|$)/i.test(src) || src.startsWith("data:image/svg")) return false;   // le texte SVG est déjà du texte
    }
    return true;
  }

  function onVisible(entries) {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      const el = e.target;
      io.unobserve(el);
      if (!worth(el)) {
        // Image pas encore chargée : on réessaiera quand elle le sera.
        if (el.tagName === "IMG" && !el.complete) el.addEventListener("load", () => { el.__mtSeen = false; scanAll(); }, { once: true });
        continue;
      }
      wait.push(el);
    }
    pump();
  }

  // ---------- Envoi à l'app (2 à la fois) ----------

  async function pump() {
    while (active && inflight < 2 && wait.length) {
      const el = wait.shift();
      pending.add(el);
      inflight++;
      ocr(el).finally(() => { inflight--; pending.delete(el); pump(); });
    }
  }

  async function ocr(el) {
    const msg = { type: "ocr", context: document.title || "" };
    if (el.tagName === "CANVAS") {
      try { msg.dataURL = el.toDataURL("image/png"); } catch (e) { return; }   // canvas protégé : impossible
    } else {
      msg.src = el.currentSrc || el.src;
    }
    const res = await api.runtime.sendMessage(msg).catch(() => null);
    if (!active || !res || !res.ok || !res.blocks || !res.blocks.length) return;
    done.set(el, { blocks: res.blocks, w: res.width, h: res.height, nodes: [] });
    ro.observe(el);
    render(el);
  }

  // ---------- Rendu ----------

  /** Zone réellement occupée par l'image dans sa boîte (object-fit : contain / cover / fill). */
  function contentBox(el, iw, ih) {
    const r = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    const bl = parseFloat(cs.borderLeftWidth) + parseFloat(cs.paddingLeft);
    const bt = parseFloat(cs.borderTopWidth) + parseFloat(cs.paddingTop);
    const cw = r.width - bl - parseFloat(cs.borderRightWidth) - parseFloat(cs.paddingRight);
    const ch = r.height - bt - parseFloat(cs.borderBottomWidth) - parseFloat(cs.paddingBottom);
    let w = cw, h = ch, x = r.left + bl, y = r.top + bt;
    const fit = el.tagName === "IMG" ? cs.objectFit : "fill";
    if (fit === "contain" || fit === "cover" || fit === "scale-down") {
      const s = fit === "cover" ? Math.max(cw / iw, ch / ih) : Math.min(cw / iw, ch / ih, fit === "scale-down" ? 1 : Infinity);
      w = iw * s; h = ih * s; x += (cw - w) / 2; y += (ch - h) / 2;
    }
    return { x: x + window.scrollX, y: y + window.scrollY, w, h, clip: { x: r.left + bl + window.scrollX, y: r.top + bt + window.scrollY, w: cw, h: ch } };
  }

  function render(el) {
    const d = done.get(el);
    if (!d || !layer) return;
    d.nodes.forEach(n => n.remove());
    d.nodes = [];
    if (!el.isConnected) return;
    const box = contentBox(el, d.w, d.h);
    const visible = getComputedStyle(el).visibility !== "hidden" && box.w > 0 && box.h > 0;
    if (!visible) return;
    // Conteneur à la taille de la boîte de l'image (coupe ce qui dépasse, comme l'image elle-même).
    const wrap = document.createElement("div");
    wrap.className = "mytranslate-skip";
    Object.assign(wrap.style, { position: "absolute", left: box.clip.x + "px", top: box.clip.y + "px",
      width: box.clip.w + "px", height: box.clip.h + "px", overflow: "hidden", pointerEvents: "none" });
    const sx = box.w / d.w, sy = box.h / d.h;
    const ox = box.x - box.clip.x, oy = box.y - box.clip.y;
    for (const b of d.blocks) {
      const div = document.createElement("div");
      const fs = Math.max(6, b.fontSize * sy);
      const pad = Math.max(1, fs * 0.15);
      div.textContent = b.text;
      Object.assign(div.style, {
        position: "absolute", boxSizing: "content-box",
        left: (ox + b.x * sx - pad) + "px", top: (oy + b.y * sy - pad) + "px",
        minWidth: (b.w * sx) + "px", maxWidth: (b.maxWidth * sx) + "px",
        minHeight: (b.h * sy) + "px", padding: pad + "px",
        fontFamily: b.serif ? "Georgia, 'Times New Roman', serif" : "-apple-system, 'Helvetica Neue', Arial, sans-serif",
        fontSize: fs + "px", fontWeight: String(b.weight), lineHeight: (fs * 1.2 + b.lineSpacing * sy) + "px",
        color: b.color, background: b.opaque ? b.background : b.background + "e6",
        borderRadius: (fs * 0.2) + "px", textAlign: b.align, textDecoration: b.underline ? "underline" : "none",
        whiteSpace: b.singleLine ? "nowrap" : "normal", overflow: "hidden", pointerEvents: "none",
        margin: "0", letterSpacing: "normal", textTransform: "none", fontStyle: "normal",
      });
      if (b.align === "center") {
        div.style.left = (ox + (b.x + b.w / 2) * sx - (b.maxWidth * sx) / 2 - pad) + "px";
        div.style.width = (b.maxWidth * sx) + "px";
      }
      wrap.appendChild(div);
      // Ajustement : on réduit la police si la traduction ne tient pas dans la place disponible.
      d.nodes.push(div);
    }
    layer.appendChild(wrap);
    d.nodes.push(wrap);
    for (const div of wrap.children) {
      const maxH = parseFloat(div.style.minHeight) * 1.6 + 4;
      let fs = parseFloat(div.style.fontSize);
      for (let i = 0; i < 6 && (div.scrollWidth > div.clientWidth + 1 || div.scrollHeight > maxH); i++) {
        fs *= 0.9;
        div.style.fontSize = fs + "px";
        div.style.lineHeight = (fs * 1.2) + "px";
      }
    }
  }

  /** Repositionnement groupé (défilement interne, redimensionnement, mise en page qui bouge). */
  function schedule() {
    if (raf || !active) return;
    raf = requestAnimationFrame(() => {
      raf = 0;
      for (const el of document.querySelectorAll("img, canvas")) if (done.has(el)) render(el);
    });
  }

  window.MTImages = { start, stop, peek };
})();
