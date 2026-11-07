// Test du cœur de l'extension avec jsdom + la vraie app MyTranslate (127.0.0.1:8770).
//   NODE_PATH=<dossier contenant jsdom>/node_modules node Tests/extension/core.test.js
"use strict";
const fs = require("fs");
const path = require("path");
const { JSDOM } = require("jsdom");

const html = `<!DOCTYPE html><html lang="en"><head><style>
  .blk { display: block } nav span { display: inline }
</style></head><body>
  <h1>How small habits change everything</h1>
  <p id="p1">Click <a href="/read" id="lnk">here</a> to read the <b>full article</b>.</p>
  <ul><li>Reply</li><li><span>Share</span></li><li><a href="/report">Report</a></li></ul>
  <div id="d1">Hello<br>world<div>Nested block of text</div></div>
  <pre>const code = "should stay";</pre>
  <p>Type here: <input value="untouched"></p>
  <button id="btn">Sign in</button>
  <my-card id="card"></my-card>
  <p class="notranslate">Brand Name Inc.</p>
  <p>Posted by <a href="/u/someone">u/someone</a> 3 hours ago</p>
</body></html>`;

const dom = new JSDOM(html, { runScripts: "outside-only" });
const { window } = dom;
// Composant web avec shadow DOM (comme sur Reddit)
const card = window.document.getElementById("card");
card.attachShadow({ mode: "open" }).innerHTML = "<p>Text inside a <em>shadow</em> root</p>";

window.eval(fs.readFileSync(path.join(__dirname, "../../Extension/core.js"), "utf8"));
const C = window.MTCore;

let failures = 0;
const check = (ok, msg) => { console.log((ok ? "  ✓ " : "  ✗ ") + msg); if (!ok) failures++; };

(async () => {
  const { units, shadowRoots } = C.collectUnits(window.document.body);
  const infos = units.map(u => ({ el: u, ...C.serialize(u) }));
  console.log("Unités trouvées :");
  infos.forEach(i => console.log("   «" + i.text + "»"));

  const texts = infos.map(i => i.text);
  check(texts.includes("Click <g0>here</g0> to read the <g1>full article</g1>."), "lien et gras balisés dans la phrase");
  check(texts.includes("Hello<x0/>world<x1/>"), "saut de ligne et bloc imbriqué = balises opaques");
  check(texts.includes("Nested block of text"), "le bloc imbriqué est une unité à part");
  check(!texts.some(t => t.includes("should stay")), "le code <pre> est ignoré");
  check(!texts.some(t => t.includes("untouched")), "le champ de saisie est ignoré");
  check(!texts.some(t => t.includes("Brand Name")), "la classe notranslate est respectée");
  check(texts.includes("Text inside a <g0>shadow</g0> root"), "le texte du shadow DOM est trouvé");
  check(shadowRoots.length === 1, "le shadow root est signalé pour être surveillé");
  check(texts.includes("Sign in") && texts.includes("Reply"), "bouton et éléments de liste trouvés");

  // Traduction par la vraie app
  const r = await fetch("http://127.0.0.1:8770/v1/translate", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ units: texts, context: "How small habits change everything" }),
  });
  const { translations } = await r.json();
  check(translations.length === texts.length, "l'app renvoie une traduction par unité");

  const link = window.document.getElementById("lnk");
  const changed = [];
  infos.forEach((info, k) => changed.push(...C.applyTranslation(info, translations[k])));
  console.log("Après traduction :");
  for (const sel of ["h1", "#p1", "ul", "#d1", "#btn"]) console.log("   " + sel + " → " + window.document.querySelector(sel).textContent.replace(/\s+/g, " ").trim());
  console.log("   shadow → " + card.shadowRoot.textContent.trim());

  const link2 = window.document.getElementById("lnk");
  check(link2 === link && link2.getAttribute("href") === "/read", "le lien est le MÊME élément, href intact");
  check(window.document.querySelector("#p1").textContent !== "Click here to read the full article.", "le paragraphe est traduit");
  check(window.document.querySelector("pre").textContent === 'const code = "should stay";', "le code n'a pas bougé");
  check(window.document.querySelector("input").value === "untouched", "le champ n'a pas bougé");

  C.restore(changed);
  check(window.document.querySelector("#p1").textContent === "Click here to read the full article.", "restauration de l'original");
  C.reapply(changed);
  check(window.document.querySelector("#p1").textContent !== "Click here to read the full article.", "réapplication de la traduction");

  console.log(failures ? `\n${failures} échec(s)` : "\nTout est bon.");
  process.exit(failures ? 1 : 0);
})();
