"""MyTranslate — moteur de traduction rapide (Opus-MT, Université d'Helsinki).

Serveur HTTP local (127.0.0.1:8767), lancé par l'app :
    POST /translate  {"texts": [...], "direction": "enToFr" | "frToEn"}  → {"translations": [...]}
    GET  /health     → {"ok": true}

- Sur le GPU (PyTorch MPS, fp16) : ~12 600 caractères/s mesurés sur M3 Max, 6× plus que le processeur.
  Les requêtes simultanées sont regroupées en gros lots triés par longueur (le GPU ne travaille que
  par courtes pointes). Repli automatique sur le processeur (CTranslate2 int8, ~2 000 caractères/s).
- Les paragraphes sont découpés en phrases, traduites ensemble par gros lots (bien plus rapide
  que des paragraphes entiers : le temps d'un lot dépend de sa phrase la plus longue).
- Les balises de l'extension (<g0>…</g0>, <x1/>) sont converties en [g0]…[/g0] / [x1],
  seule notation que le modèle recopie (il ne connaît pas « < »). L'app vérifie le résultat.
"""
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from local_guard import reject_if_foreign

import ctranslate2
import sentencepiece as spm

MODELS = os.path.expanduser("~/Library/Application Support/MyTranslate/models")
NAMES = {"enToFr": "opus-mt-tc-big-en-fr-ct2", "frToEn": "opus-mt-tc-big-fr-en-ct2"}
HF_NAMES = {"enToFr": "Helsinki-NLP/opus-mt-tc-big-en-fr", "frToEn": "Helsinki-NLP/opus-mt-tc-big-fr-en"}
PORT = int(os.environ.get("MT_PORT", "8767"))
DEVICE = os.environ.get("MT_DEVICE", "auto")      # auto | gpu | cpu

_lock = threading.Lock()
_models = {}


def _use_gpu():
    if DEVICE == "cpu":
        return False
    try:
        import torch
        return torch.backends.mps.is_available()
    except Exception:  # noqa: BLE001
        return False


GPU = _use_gpu()


class GPUModel:
    """Opus-MT sur le GPU : MarianMT (transformers) en fp16 sur MPS."""
    def __init__(self, direction):
        import torch
        from transformers import MarianMTModel, MarianTokenizer
        self.torch = torch
        self.tok = MarianTokenizer.from_pretrained(HF_NAMES[direction])
        self.model = MarianMTModel.from_pretrained(HF_NAMES[direction], torch_dtype=torch.float16).to("mps").eval()

    def run(self, pieces):
        torch = self.torch
        order = sorted(range(len(pieces)), key=lambda i: len(pieces[i]))
        out = [""] * len(pieces)
        with torch.inference_mode():
            for k in range(0, len(order), 64):
                idx = order[k:k + 64]
                enc = self.tok([pieces[i] for i in idx], return_tensors="pt", padding=True,
                               truncation=True, max_length=400).to("mps")
                # Sortie plafonnée à 1,6 × l'entrée : une phrase qui « s'emballe » ne bloque plus tout le lot
                # (mesuré : de ~3 000 à ~9 000 caractères/s sur une vraie page).
                cap = min(400, int(enc["input_ids"].shape[1] * 1.6) + 10)
                g = self.model.generate(**enc, num_beams=1, max_new_tokens=cap, repetition_penalty=1.1)
                for i, t in zip(idx, self.tok.batch_decode(g, skip_special_tokens=True)):
                    out[i] = t
        return out


class CPUModel:
    """Opus-MT sur le processeur : CTranslate2 int8 (4 lots × 3 fils, le plus rapide mesuré)."""
    def __init__(self, direction):
        d = os.path.join(MODELS, NAMES[direction])
        self.tr = ctranslate2.Translator(d, device="cpu", compute_type="int8", inter_threads=4, intra_threads=3)
        self.src = spm.SentencePieceProcessor(model_file=os.path.join(d, "source.spm"))
        self.tgt = spm.SentencePieceProcessor(model_file=os.path.join(d, "target.spm"))

    def run(self, pieces):
        toks = [self.src.encode(p, out_type=str)[:400] + ["</s>"] for p in pieces]
        cap = min(400, int(max((len(t) for t in toks), default=1) * 1.6) + 10)
        res = self.tr.translate_batch(toks, max_batch_size=2048, batch_type="tokens", beam_size=1,
                                      max_decoding_length=cap, repetition_penalty=1.1)
        return [self.tgt.decode(r.hypotheses[0]) for r in res]


def model(direction):
    with _lock:
        if direction not in _models:
            _models[direction] = GPUModel(direction) if GPU else CPUModel(direction)
        return _models[direction]


# --- Regroupement des requêtes simultanées (un seul accès au modèle à la fois) ---

import queue as _queue

_jobs = _queue.Queue()


def _worker():
    while True:
        jobs = [_jobs.get()]
        # On ramasse tout ce qui attend déjà, dans le même sens de traduction.
        while True:
            try:
                jobs.append(_jobs.get_nowait())
            except _queue.Empty:
                break
        by_dir = {}
        for j in jobs:
            by_dir.setdefault(j["direction"], []).append(j)
        for direction, js in by_dir.items():
            pieces = [p for j in js for p in j["pieces"]]
            try:
                res = model(direction).run(pieces) if pieces else []
                k = 0
                for j in js:
                    j["result"] = res[k:k + len(j["pieces"])]
                    k += len(j["pieces"])
            except Exception as e:  # noqa: BLE001
                for j in js:
                    j["error"] = str(e)
            for j in js:
                j["done"].set()


threading.Thread(target=_worker, daemon=True).start()


def run_pieces(pieces, direction):
    job = {"pieces": pieces, "direction": direction, "done": threading.Event()}
    _jobs.put(job)
    job["done"].wait()
    if "error" in job:
        raise RuntimeError(job["error"])
    return job["result"]


# --- Balises -----------------------------------------------------------------

TAG = re.compile(r"<(/?)g(\d+)>|<x(\d+)/>")
BRACKET = re.compile(r"\[\s*(/?)\s*g\s*(\d+)\s*\]|\[\s*x\s*(\d+)\s*\]")


def to_brackets(s):
    return TAG.sub(lambda m: f"[{m.group(1)}g{m.group(2)}]" if m.group(2) else f"[x{m.group(3)}]", s)


def from_brackets(s):
    return BRACKET.sub(lambda m: f"<{m.group(1)}g{m.group(2)}>" if m.group(2) else f"<x{m.group(3)}/>", s)


# --- Découpage en phrases ----------------------------------------------------

# Fin de phrase : . ! ? … suivis d'un espace et d'une majuscule / guillemet / chiffre.
# On évite les abréviations courantes (e.g., Dr., U.S.).
SPLIT = re.compile(r"(?<=[.!?…])\s+(?=[A-Z0-9\"“'(\[])")
ABBREV = re.compile(r"(?:\b(?:e\.g|i\.e|etc|vs|Dr|Mr|Mrs|Ms|St|No|Fig|U\.S|U\.K|Jr|Sr|Inc|Ltd|al)\.)$")


def sentences(text):
    parts, cur = [], ""
    for piece in SPLIT.split(text):
        cur = f"{cur} {piece}" if cur else piece
        if not ABBREV.search(cur):
            parts.append(cur)
            cur = ""
    if cur:
        parts.append(cur)
    return parts or [text]


def translate(texts, direction):
    pieces, owners = [], []
    for i, t in enumerate(texts):
        for s in sentences(to_brackets(t)):
            pieces.append(s)
            owners.append(i)
    if not pieces:
        return list(texts)
    res = run_pieces(pieces, direction)
    outs = [""] * len(texts)
    for o, r in zip(owners, res):
        piece = r.replace(" ⁇ ", " ").replace("⁇", "").strip()
        outs[o] = f"{outs[o]} {piece}" if outs[o] else piece
    return [from_brackets(o) for o in outs]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if reject_if_foreign(self, PORT):
            return
        self.reply(200, {"ok": True}) if self.path == "/health" else self.reply(404, {"error": "inconnu"})

    def do_POST(self):
        if reject_if_foreign(self, PORT):
            return
        if self.path != "/translate":
            return self.reply(404, {"error": "inconnu"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            texts = [str(t) for t in req["texts"]]
            direction = req.get("direction", "enToFr")
            if direction not in NAMES:
                return self.reply(400, {"error": "sens inconnu"})
            self.reply(200, {"translations": translate(texts, direction)})
        except Exception as e:  # noqa: BLE001 — on renvoie l'erreur à l'app
            self.reply(500, {"error": str(e)})


if __name__ == "__main__":
    model("enToFr")  # préchargement du sens par défaut
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"MyTranslate Opus-MT prêt sur 127.0.0.1:{PORT} ({'GPU' if GPU else 'processeur'})", flush=True)
    srv.serve_forever()
