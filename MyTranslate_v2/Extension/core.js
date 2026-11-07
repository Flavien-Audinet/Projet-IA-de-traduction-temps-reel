// MyTranslate — cœur de la traduction en place (sans dépendance au navigateur, testable avec jsdom).
//
// Une « unité » est un élément de type bloc (paragraphe, titre, cellule, bouton…) qui contient
// du texte directement ou via des éléments en ligne (liens, gras…). On la sérialise en texte balisé :
//   « Click <g0>here</g0> to read<x1/>more »
// puis, une fois traduite (même suite de balises, garanti par l'app), on remplace UNIQUEMENT le
// contenu des nœuds texte, dans l'ordre. Les éléments eux-mêmes (liens, écouteurs, attributs) ne sont
// jamais déplacés ni recréés : le site continue de fonctionner normalement.

(function (root) {
  "use strict";

  const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "CODE", "PRE", "KBD", "SAMP", "VAR",
    "TEXTAREA", "INPUT", "SELECT", "OPTION", "SVG", "MATH", "CANVAS", "IFRAME", "OBJECT", "EMBED",
    "VIDEO", "AUDIO", "HEAD", "TITLE", "META", "LINK"]);
  const INLINE = new Set(["A", "ABBR", "B", "BDI", "BDO", "CITE", "DFN", "EM", "I", "LABEL", "MARK", "Q", "S",
    "SMALL", "SPAN", "STRONG", "SUB", "SUP", "TIME", "U", "FONT", "DEL", "INS", "BIG", "TT", "DATA", "NOBR"]);
  const VOID = new Set(["BR", "IMG", "WBR", "HR", "PICTURE"]);
  const TAG_RE = /<\/?g\d+>|<x\d+\/>/g;

  /** Élément à ignorer entièrement (code, champs de saisie, contenu marqué « ne pas traduire »…). */
  function skipped(el) {
    if (SKIP.has(el.tagName)) return true;
    if (el.isContentEditable) return true;
    if (el.getAttribute) {
      if (el.getAttribute("translate") === "no") return true;
      if (el.classList && (el.classList.contains("notranslate") || el.classList.contains("mytranslate-skip"))) return true;
      if (el.getAttribute("role") === "textbox") return true;
    }
    return false;
  }

  function displayOf(el) {
    try {
      const v = el.ownerDocument.defaultView;
      return v && v.getComputedStyle ? v.getComputedStyle(el).display : "";
    } catch (e) { return ""; }
  }

  /** Vrai si l'élément se comporte comme du texte en ligne (fait partie de la phrase de son parent). */
  function isInline(el) {
    if (VOID.has(el.tagName)) return false;
    const d = displayOf(el);
    if (d === "none") return false;
    if (d === "contents") return true;
    if (d) return d.startsWith("inline") && d !== "inline-block" && d !== "inline-flex" && d !== "inline-grid"
      || (d === "inline-block" && INLINE.has(el.tagName) && el.children.length === 0);
    return INLINE.has(el.tagName);
  }

  function shadowOf(el) {
    return el.openOrClosedShadowRoot || el.shadowRoot || null;   // openOrClosedShadowRoot : Firefox, extensions
  }

  /** Sérialise une unité : texte balisé + nœuds texte de chaque segment (entre deux balises). */
  function serialize(unit) {
    const slots = [];
    let current = [], text = "", g = 0, x = 0;
    function cut() { slots.push(current); current = []; }
    function visit(node) {
      for (const ch of node.childNodes) {
        if (ch.nodeType === 3) {
          const v = ch.nodeValue.replace(/\s+/g, " ");
          if (v) { text += v; current.push(ch); }
        } else if (ch.nodeType === 1) {
          if (skipped(ch) || !isInline(ch) || shadowOf(ch)) {
            text += `<x${x++}/>`; cut();          // bloc imbriqué, image, code… : opaque
          } else {
            const id = g++;
            text += `<g${id}>`; cut();
            visit(ch);
            text += `</g${id}>`; cut();
          }
        }
      }
    }
    visit(unit);
    cut();
    return { text: text.replace(/^ +| +$/g, ""), slots };
  }

  function plainOf(tagged) { return tagged.replace(TAG_RE, "").replace(/\s+/g, " ").trim(); }

  /** Vrai si l'élément est la racine d'une unité : bloc avec du texte « à lui ». */
  function isUnitRoot(el) {
    if (isInline(el) || VOID.has(el.tagName)) return false;
    for (const ch of el.childNodes) {
      if (ch.nodeType === 3 && /\p{L}/u.test(ch.nodeValue)) return true;
      if (ch.nodeType === 1 && !skipped(ch) && isInline(ch) && /\p{L}/u.test(ch.textContent || "")) return true;
    }
    return false;
  }

  /** Toutes les unités sous `rootNode` (document, élément ou shadow root), y compris dans les shadow DOM. */
  function collectUnits(rootNode, out = [], roots = []) {
    const stack = [rootNode];
    while (stack.length) {
      const n = stack.pop();
      if (n.nodeType === 1) {
        if (skipped(n)) continue;
        if (displayOf(n) === "none") continue;
        if (isUnitRoot(n)) out.push(n);
        const sr = shadowOf(n);
        if (sr) { roots.push(sr); stack.push(sr); }
      }
      const kids = n.children || [];
      for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
    }
    return { units: out, shadowRoots: roots };
  }

  /** Remplace le texte d'une unité par sa traduction. Renvoie la liste des nœuds modifiés. */
  function applyTranslation(info, translated) {
    const segs = translated.split(TAG_RE);
    const slots = info.slots;
    if (segs.length !== slots.length) {
      // Ne devrait pas arriver (l'app garantit les balises) : tout le texte dans le premier segment.
      const all = plainOf(translated);
      const nodes = slots.flat();
      if (!nodes.length) return [];
      return nodes.map((n, i) => setText(n, i === 0 ? all : ""));
    }
    const changed = [];
    let carry = "";
    for (let i = 0; i < slots.length; i++) {
      let seg = carry + segs[i];
      carry = "";
      const nodes = slots[i];
      if (!nodes.length) { if (seg.trim()) carry = seg; continue; }   // texte sans nœud : reporté au segment suivant
      const orig = nodes.map(n => n.nodeValue).join("");
      const lead = (orig.match(/^\s*/) || [""])[0] ? " " : "";
      const trail = (orig.match(/\s*$/) || [""])[0] ? " " : "";
      const body = seg.trim();
      changed.push(setText(nodes[0], body ? lead + body + trail : orig.replace(/\S/g, "") ? " " : ""));
      for (let k = 1; k < nodes.length; k++) changed.push(setText(nodes[k], ""));
    }
    if (carry.trim()) {
      // Reste à placer : ajouté au dernier nœud texte.
      const last = slots.flat().pop();
      if (last) changed.push(setText(last, last.nodeValue + " " + carry.trim()));
    }
    return changed;
  }

  // Mémoire des textes d'origine (pour « afficher l'original ») et des traductions posées.
  const original = new WeakMap(), placed = new WeakMap();

  function setText(node, value) {
    if (!original.has(node)) original.set(node, node.nodeValue);
    node.nodeValue = value;
    placed.set(node, value);
    return node;
  }

  function restore(nodes) { for (const n of nodes) if (original.has(n)) n.nodeValue = original.get(n); }
  function reapply(nodes) { for (const n of nodes) if (placed.has(n)) n.nodeValue = placed.get(n); }
  function isOurs(node) { return placed.has(node) && placed.get(node) === node.nodeValue; }
  function isOriginal(node) { return original.has(node) && original.get(node) === node.nodeValue; }
  function forget(node) { original.delete(node); placed.delete(node); }

  root.MTCore = { serialize, plainOf, collectUnits, isUnitRoot, applyTranslation, restore, reapply,
                  isOurs, isOriginal, forget, skipped };
})(typeof window !== "undefined" ? window : globalThis);
