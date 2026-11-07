// Test du démarrage automatique : page anglaise traduite sans clic, page française ignorée.
//   NODE_PATH=<dossier contenant jsdom>/node_modules node Tests/extension/autostart.test.js  (app lancée)
"use strict";
const fs = require("fs"), path = require("path");
const { JSDOM } = require("jsdom");
const ext = f => fs.readFileSync(path.join(__dirname, "../../Extension", f), "utf8");

function page(html) {
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://example.com/article" });
  const w = dom.window;
  // Imitation minimale de l'API WebExtension de Firefox, branchée sur la vraie app.
  w.browser = {
    runtime: {
      sendMessage: async (m) => {
        if (m.type === "status") return { ok: true, ...(await (await fetch("http://127.0.0.1:8770/v1/status")).json()) };
        if (m.type === "translate") {
          const j = await (await fetch("http://127.0.0.1:8770/v1/translate", { method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ units: m.units, priority: m.priority }) })).json();
          return { ok: true, translations: j.translations };
        }
        return true;
      },
      onMessage: { addListener() {} },
    },
    storage: { local: { get: async () => ({}), set: async () => {} } },
    i18n: { detectLanguage: async t => ({ isReliable: true, languages: [{ language: /\b(the|and|is|of)\b/i.test(t) ? "en" : "fr", percentage: 90 }] }) },
  };
  for (const f of ["core.js", "images.js", "content.js"]) w.eval(ext(f));
  w.dispatchEvent(new w.Event("load"));
  return w;
}

(async () => {
  const en = page(`<!DOCTYPE html><html lang="en"><body><h1>The history of the bicycle</h1>
    <p>The bicycle was invented in the nineteenth century and is one of the most efficient means of transport.</p></body></html>`);
  const fr = page(`<!DOCTYPE html><html lang="fr"><body><h1>Histoire du vélo</h1><p>Le vélo a été inventé au XIXe siècle.</p></body></html>`);
  await new Promise(r => setTimeout(r, 4000));
  const enText = en.document.body.textContent.replace(/\s+/g, " ").trim();
  const frText = fr.document.body.textContent.replace(/\s+/g, " ").trim();
  console.log("page anglaise →", enText);
  console.log("page française →", frText);
  const ok1 = !enText.includes("The bicycle was invented"), ok2 = frText.includes("Le vélo a été inventé au XIXe siècle.");
  console.log(ok1 ? "  ✓ page anglaise traduite sans clic" : "  ✗ page anglaise NON traduite");
  console.log(ok2 ? "  ✓ page française laissée telle quelle" : "  ✗ page française modifiée");
  process.exit(ok1 && ok2 ? 0 : 1);
})();
