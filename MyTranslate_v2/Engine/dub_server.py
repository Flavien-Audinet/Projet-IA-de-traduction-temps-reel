"""MyTranslate — doublage en direct avec imitation de la voix (« Écouter traduit »).

Chaîne (tout est local, sur le Mac) :
  son de l'app (capté par MyTranslate, coupé à la source)
    → séparation voix / fond (Mel-RoFormer, MLX)
    → découpage de la parole en segments (pauses naturelles)
    → reconnaissance (Parakeet) → traduction (Opus-MT, serveur 8767)
    → voix française imitant la personne qui parle (Chatterbox multilingue ; Qwen3-TTS en option rapide),
      référence = la voix isolée du segment lui-même (suit le changement de personnage)
    → ajustement de la durée (ffmpeg atempo) pour coller à la phrase d'origine
  sortie = fond + voix française, rejoués avec un délai constant D. L'extension Firefox retarde la vidéo
  du même D : image, bruitages et voix restent synchronisés (léger différé, comme une retransmission).

Entrée (stdin, envoyée par l'app) : blocs « MTAU » + nb d'images (u32) + horodatage CLOCK_UPTIME_RAW (ns, u64)
                                   + échantillons float32 stéréo entrelacés à 48 kHz.
Contrôle : HTTP 127.0.0.1:8769  GET /status · POST /config {delay, voice, mode, dubGain, bgGain, origGain}
Simulation (tests) : python dub_server.py --simulate entree.wav --out sortie.wav
"""
import argparse
import glob
import json
import os
import queue
import struct
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from local_guard import reject_if_foreign

import numpy as np

SR = int(os.environ.get("DUB_SR", "48000"))     # fréquence du périphérique de sortie (celle du tap)
CTRL_PORT = int(os.environ.get("DUB_PORT", "8769"))
MT_URL = os.environ.get("MT_URL", "http://127.0.0.1:8767/translate")

CFG = {
    "delay": 7.0,          # D : retard global (s) appliqué au son ET à la vidéo (mesuré : 7 s suffit en mode simultané)
    "voice": "chatterbox",  # chatterbox (meilleur français) | qwen3 (plus rapide)
    "mode": "simultaneous",  # simultaneous (segments courts) | sentence (phrases entières)
    "direction": "enToFr",
    "dubGain": 1.0, "bgGain": 1.0, "origGain": 0.0,   # origGain > 0 : on laisse un peu de la voix d'origine
}
STATS = {"running": False, "segments": 0, "late": 0, "lastLateness": 0.0, "queue": 0,
         "lastEN": "", "lastFR": "", "sepMs": 0, "asrMs": 0, "mtMs": 0, "ttsMs": 0, "margin": 0.0}


def now_ns():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------------------------
# Tampons circulaires horodatés (index = échantillon depuis le premier bloc reçu)

class Ring:
    def __init__(self, seconds, channels):
        self.n = int(seconds * SR)
        self.buf = np.zeros((self.n, channels), np.float32)
        self.lock = threading.Lock()

    def write(self, start, data, add=False):
        with self.lock:
            idx = (np.arange(len(data)) + start) % self.n
            if add:
                self.buf[idx] += data
            else:
                self.buf[idx] = data

    def read(self, start, count):
        with self.lock:
            idx = (np.arange(count) + start) % self.n
            return self.buf[idx].copy()

    def clear(self, start, count):
        with self.lock:
            self.buf[(np.arange(count) + start) % self.n] = 0


class Timeline:
    """Relie l'horloge système aux index d'échantillons de la source."""
    def __init__(self):
        self.t0 = None          # ns du premier échantillon reçu
        self.written = 0        # index du dernier échantillon reçu (+1)

    def index(self, t_ns):
        return int(round((t_ns - self.t0) * SR / 1e9))

    def time(self, idx):
        return self.t0 + idx * 1e9 / SR


# ---------------------------------------------------------------------------------------------
# Fil unique pour MLX : les modèles doivent être utilisés depuis le fil qui les a chargés.
# Les tâches urgentes (séparation, toutes les secondes) passent avant les longues (voix).

class GPUThread:
    def __init__(self):
        import heapq
        self.heapq = heapq
        self.tasks = []
        self.cv = threading.Condition()
        self.seq = 0
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            with self.cv:
                while not self.tasks:
                    self.cv.wait()
                _, _, fn, box, ev = self.heapq.heappop(self.tasks)
            try:
                box["result"] = fn()
            except Exception as e:  # noqa: BLE001
                box["error"] = e
            ev.set()

    def run(self, fn, priority=1):
        box, ev = {}, threading.Event()
        with self.cv:
            self.seq += 1
            self.heapq.heappush(self.tasks, (priority, self.seq, fn, box, ev))
            self.cv.notify()
        ev.wait()
        if "error" in box:
            raise box["error"]
        return box["result"]


GPU = GPUThread()


# ---------------------------------------------------------------------------------------------
# Modèles (chargés une seule fois, sur le fil GPU)

class Models:
    def __init__(self):
        GPU.run(self._load)

    def _load(self):
        import mlx.core as mx
        from mlx_audio.sts.models.mel_roformer import MelRoFormer, MelRoFormerConfig
        from mlx_audio.stt.utils import load_model as load_stt, resample_audio
        self.mx = mx
        self.resample = resample_audio
        snap = glob.glob(os.path.expanduser(
            "~/.cache/huggingface/hub/models--mlx-community--mel-roformer-kim-vocal-2-mlx/snapshots/*"))[0]
        self.sep = MelRoFormer.from_pretrained(snap, config=MelRoFormerConfig.kim_vocal_2())
        self.asr = load_stt("mlx-community/parakeet-tdt-0.6b-v3")
        import mlx.core as mx2
        self.asr.generate(mx2.array(np.zeros(16000, np.float32)))     # préchauffage
        self.sep(mx2.array(np.zeros((1, 2, 44100 * 2), np.float32)))

    def separate(self, stereo48):
        return GPU.run(lambda: self._separate(stereo48), priority=0)     # prioritaire

    def transcribe(self, mono16):
        return GPU.run(lambda: self._transcribe(mono16), priority=1)

    def sentences(self, mono16):
        """Phrases horodatées [(début s, fin s, texte)] (Parakeet), via le fil GPU."""
        def run():
            import mlx.core as mx
            r = self.asr.generate(mx.array(mono16.astype(np.float32)))
            return [(float(x.start), float(x.end), x.text.strip()) for x in (getattr(r, "sentences", None) or [])]
        return GPU.run(run, priority=1)

    def words(self, mono16):
        """Mots horodatés [(début s, fin s, mot)] (fragments Parakeet regroupés), via le fil GPU."""
        def run():
            import mlx.core as mx
            r = self.asr.generate(mx.array(mono16.astype(np.float32)))
            out = []
            for snt in (getattr(r, "sentences", None) or []):
                for t in (getattr(snt, "tokens", None) or []):
                    txt = t.text
                    if out and not txt.startswith(" "):
                        out[-1] = (out[-1][0], float(t.end), out[-1][2] + txt)   # suite du mot / ponctuation
                    elif txt.strip():
                        out.append((float(t.start), float(t.end), txt.strip()))
            return out
        return GPU.run(run, priority=1)

    def _separate(self, stereo48):
        """Voix isolée (stéréo 48 kHz) d'un extrait stéréo 48 kHz."""
        mx = self.mx
        x = np.stack([self.resample(stereo48[:, c], SR, 44100) for c in range(2)])
        v = self.sep(mx.array(x[None]))
        mx.eval(v)
        v = np.array(v[0])
        out = np.stack([self.resample(v[c], 44100, SR) for c in range(2)], axis=1)
        n = len(stereo48)
        if len(out) < n:
            out = np.pad(out, ((0, n - len(out)), (0, 0)))
        return out[:n].astype(np.float32)

    def _transcribe(self, mono16):
        import mlx.core as mx
        r = self.asr.generate(mx.array(mono16.astype(np.float32)))
        return (getattr(r, "text", "") or "").strip()

# ---------------------------------------------------------------------------------------------
# Ateliers de voix : la synthèse tourne dans des processus séparés (mesuré : 2 processus ≈ 2,4× le
# débit d'un seul, le GPU a de la réserve), sans bloquer la séparation ni la reconnaissance.

_TTS = {}


def _tts_init():
    import mlx.core  # noqa: F401  (initialise MLX dans le processus)


def _tts_job(voice, text, ref24, lang, ref_text):
    import tempfile
    import soundfile as sf
    from mlx_audio.tts.utils import load_model
    from mlx_audio.stt.utils import resample_audio
    if voice not in _TTS:
        repo = {"chatterbox": "mlx-community/chatterbox-multilingual-v3",
                "qwen3": "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"}[voice]
        _TTS[voice] = load_model(repo)
    m = _TTS[voice]
    if text is None:                       # préchauffage : plusieurs longueurs (le GPU compile ses calculs par taille)
        ref24 = (np.random.default_rng(0).standard_normal(24000 * 3) * 0.05).astype(np.float32)
        for t in ["Oui.", "Bonjour, ceci est un essai.", "Ceci est une phrase un peu plus longue pour préparer la voix."]:
            _tts_job(voice, t, ref24, "fr", "")
        return np.zeros(0, np.float32)
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    sf.write(tmp.name, ref24, 24000)
    kw = dict(text=text, ref_audio=tmp.name, verbose=False)
    if voice == "chatterbox":
        # Plus expressif que les réglages par défaut (prosodie moins « lue »), recommandé par les auteurs.
        kw.update(lang_code=lang, exaggeration=float(os.environ.get("DUB_EXAGGERATION", "0.5")),
                  cfg_weight=float(os.environ.get("DUB_CFG", "0.4")))
    else:
        kw.update(lang_code={"fr": "french", "en": "english"}[lang], ref_text=ref_text)
    try:
        chunks = [np.array(r.audio).reshape(-1) for r in m.generate(**kw)]
    finally:
        os.unlink(tmp.name)
    audio = np.concatenate(chunks) if chunks else np.zeros(0, np.float32)
    return resample_audio(audio, m.sample_rate, SR).astype(np.float32)


def _embed_job(wavs24):
    """Empreintes de voix (une par extrait), avec l'encodeur de voix de Chatterbox."""
    import mlx.core as mx
    from mlx_audio.tts.utils import load_model
    if "chatterbox" not in _TTS:
        _TTS["chatterbox"] = load_model("mlx-community/chatterbox-multilingual-v3")
    ve = _TTS["chatterbox"].ve
    out = []
    for w in wavs24:
        try:
            e = ve.embeds_from_wavs([mx.array(w.astype(np.float32))], 24000, as_spk=True)
            out.append(np.array(e).reshape(-1))
        except Exception:  # noqa: BLE001
            out.append(None)
    return out


class TTSPool:
    def __init__(self, workers=2):
        import multiprocessing as mp
        from concurrent.futures import ProcessPoolExecutor
        self.pool = ProcessPoolExecutor(max_workers=workers, mp_context=mp.get_context("spawn"), initializer=_tts_init)
        # Chargement du modèle dans chaque atelier, en parallèle.
        for f in [self.pool.submit(_tts_job, CFG["voice"], None, None, "fr", "") for _ in range(workers)]:
            f.result()

    def submit(self, text, ref24, lang, ref_text):
        return self.pool.submit(_tts_job, CFG["voice"], text, ref24, lang, ref_text)

    def embed(self, wavs24):
        return self.pool.submit(_embed_job, wavs24)


# ---------------------------------------------------------------------------------------------
# Traitement

def translate(text):
    req = urllib.request.Request(MT_URL, data=json.dumps({"texts": [text], "direction": CFG["direction"]}).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=20))["translations"][0]


def fit_duration(audio, target):
    """Accélère / ralentit la voix (sans changer sa hauteur) pour approcher la durée d'origine."""
    if len(audio) == 0 or target <= 0.2:
        return audio
    ratio = len(audio) / SR / target
    ratio = min(float(os.environ.get("DUB_MAX_STRETCH", "1.25")), max(0.9, ratio))   # au-delà : voix artificielle, on accepte un débord
    if abs(ratio - 1) < 0.04:
        return audio
    p = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", "-",
                        "-filter:a", f"atempo={ratio:.4f}", "-f", "f32le", "-"],
                       input=audio.astype(np.float32).tobytes(), capture_output=True)
    out = np.frombuffer(p.stdout, np.float32)
    return out if len(out) else audio


class Engine:
    HOP = 0.5          # la séparation avance par pas de 0,5 s (fin de phrase repérée plus tôt)…
    CONTEXT = 2.0      # … avec 2 s de contexte avant
    FADE = int(0.05 * SR)

    def __init__(self, models, tts):
        self.m = models
        self.tts = tts
        self.tl = Timeline()
        self.mix = Ring(90, 2)       # son reçu
        self.bg = Ring(90, 2)        # fond (son - voix)
        self.voc = Ring(90, 2)       # voix d'origine isolée
        self.dub = Ring(90, 1)       # voix française placée sur la ligne de temps de la source
        self.sep_done = 0            # index jusqu'où la séparation est faite
        self.prev_tail = None
        self.segments = queue.Queue()
        self.vad = {"in": False, "start": 0, "silence": 0, "peak": 0.0, "floor": 1e-4}
        threading.Thread(target=self._separation_loop, daemon=True).start()
        threading.Thread(target=self._worker, daemon=True).start()

    # --- Entrée -------------------------------------------------------------------------------
    def push(self, t_ns, frames):
        if self.tl.t0 is None:
            self.tl.t0 = t_ns
        start = self.tl.index(t_ns)
        self.mix.write(start, frames)
        self.tl.written = max(self.tl.written, start + len(frames))

    # --- Séparation voix / fond, par pas de 1 s ------------------------------------------------
    def _separation_loop(self):
        hop, ctx = int(self.HOP * SR), int(self.CONTEXT * SR)
        while True:
            if self.tl.t0 is None or self.tl.written - self.sep_done < hop:
                time.sleep(0.02)
                continue
            end = self.sep_done + hop
            begin = max(0, end - hop - ctx - self.FADE)
            t0 = time.time()
            window = self.mix.read(begin, end - begin)
            if np.abs(window).max() < 1e-4:
                vocals = np.zeros_like(window)           # silence : rien à séparer
            else:
                vocals = self.m.separate(window)
            STATS["sepMs"] = int((time.time() - t0) * 1000)
            # On garde le dernier pas (+ un fondu avec la fin du pas précédent : pas de clic)
            part = vocals[-(hop + self.FADE):].copy()
            if self.prev_tail is not None:
                w = np.linspace(0, 1, self.FADE, dtype=np.float32)[:, None]
                part[:self.FADE] = part[:self.FADE] * w + self.prev_tail * (1 - w)
            self.prev_tail = part[-self.FADE:].copy()
            seg_start = end - hop
            # Le début de `part` recouvre la fin du pas précédent : on la réécrit avec le fondu.
            w_start = max(0, seg_start - self.FADE) if len(part) > hop else seg_start
            part = part[-(seg_start + hop - w_start):]
            mix = self.mix.read(w_start, len(part))
            self.voc.write(w_start, part)
            self.bg.write(w_start, mix - part)
            self.sep_done = end
            self._vad(seg_start, part[-hop:].mean(axis=1))

    # --- Découpage de la parole --------------------------------------------------------------
    def _vad(self, start, mono):
        sentence = CFG["mode"] == "sentence"
        end_sil = 0.45 if sentence else 0.2
        max_len = 6.0 if sentence else 2.5
        frame = int(0.02 * SR)
        v = self.vad
        for k in range(0, len(mono) - frame + 1, frame):
            e = float(np.sqrt(np.mean(mono[k:k + frame] ** 2)))
            v["floor"] = min(v["floor"] * 1.002 + 1e-7, e) if e < v["floor"] * 3 else v["floor"] * 1.0005
            speaking = e > max(0.008, v["floor"] * 4)
            idx = start + k
            if not v["in"]:
                if speaking:
                    v.update({"in": True, "start": idx, "silence": 0})
            else:
                v["silence"] = 0 if speaking else v["silence"] + frame
                length = idx - v["start"]
                if v["silence"] >= end_sil * SR or length >= max_len * SR:
                    seg_end = idx - v["silence"] + frame
                    if seg_end - v["start"] >= 0.35 * SR:
                        self.segments.put((v["start"], seg_end))
                        STATS["queue"] = self.segments.qsize()
                    v.update({"in": False, "silence": 0})

    # --- Reconnaissance → traduction → voix ---------------------------------------------------
    def _worker(self):
        while True:
            s, e = self.segments.get()
            STATS["queue"] = self.segments.qsize()
            try:
                self._process(s, e)
            except Exception as ex:  # noqa: BLE001
                log("segment ignoré :", ex)

    def _process(self, s, e):
        voc = self.voc.read(s, e - s).mean(axis=1)
        t0 = time.time()
        text = self.m.transcribe(self.m.resample(voc, SR, 16000))
        STATS["asrMs"] = int((time.time() - t0) * 1000)
        if len([c for c in text if c.isalpha()]) < 2:
            return
        t1 = time.time()
        fr = translate(text)
        STATS["mtMs"] = int((time.time() - t1) * 1000)
        # Référence de voix : le segment lui-même (suit le personnage qui parle), complété si trop court.
        ref, ref_text = voc, text
        if len(ref) < 3 * SR:
            ref = self.voc.read(max(0, e - 8 * SR), min(e, 8 * SR)).mean(axis=1)
            ref_text = ""
        ref24 = self.m.resample(ref, SR, 24000)
        t2 = time.time()
        fut = self.tts.submit(fr, ref24, CFG["direction"][-2:].lower(), ref_text)
        fut.add_done_callback(lambda f: self._place(f, s, e, voc, text, fr, t2))

    def _place(self, fut, s, e, voc, text, fr, t2):
        try:
            audio = fut.result()
        except Exception as ex:  # noqa: BLE001
            log("voix impossible :", ex)
            return
        STATS["ttsMs"] = int((time.time() - t2) * 1000)
        audio = fit_duration(audio, (e - s) / SR)
        if len(audio) == 0:
            return
        # Placement : au début du segment d'origine ; s'il est trop tard, dès que possible.
        need = self.tl.time(s) + CFG["delay"] * 1e9           # heure de lecture prévue (ns)
        margin = (need - now_ns()) / 1e9 - 0.15                # marge restante avant d'être en retard
        place = s
        if margin < 0:
            place = s + int(-margin * SR)
            STATS["late"] += 1
        STATS["lastLateness"] = round(max(0.0, -margin), 2)
        STATS["margin"] = round(margin, 2)
        peak = float(np.abs(audio).max() or 1)
        level = float(np.sqrt(np.mean(voc ** 2)) / max(1e-4, np.sqrt(np.mean(audio ** 2))))
        audio = audio * min(level, 0.95 / peak)                # même niveau sonore que la voix d'origine
        self.dub.write(place, audio[:, None], add=True)
        STATS["segments"] += 1
        STATS["lastEN"], STATS["lastFR"] = text[-160:], fr[-160:]
        log(f"[{(s / SR):6.1f} s] marge {margin:+.2f} s · ASR {STATS['asrMs']} · MT {STATS['mtMs']} · "
            f"voix {STATS['ttsMs']} ms · « {text[:60]} » → « {fr[:60]} »")

    # --- Sortie -------------------------------------------------------------------------------
    def render(self, src_index, count):
        """Son à jouer pour les `count` échantillons de la source commençant à `src_index`."""
        if self.tl.t0 is None or src_index < 0:
            return np.zeros((count, 2), np.float32)
        out = self.bg.read(src_index, count) * CFG["bgGain"]
        out += self.dub.read(src_index, count) * CFG["dubGain"]
        if CFG["origGain"] > 0:
            out += self.voc.read(src_index, count) * CFG["origGain"]
        # Ce qui n'est pas encore séparé (retard trop court) : silence plutôt que la voix d'origine.
        late = src_index + count - self.sep_done
        if late > 0:
            out[max(0, count - late):] = 0
        return np.clip(out, -1, 1)

    def consumed(self, src_index, count):
        self.dub.clear(src_index, count)     # la ligne de temps de la voix est réutilisée (tampon circulaire)


# ---------------------------------------------------------------------------------------------
# Contrôle HTTP

class Ctrl(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if reject_if_foreign(self, CTRL_PORT):
            return
        self.reply({**STATS, **CFG})

    def do_POST(self):
        if reject_if_foreign(self, CTRL_PORT):
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        for k, v in body.items():
            if k in CFG:
                CFG[k] = type(CFG[k])(v)
        self.reply(CFG)


def serve_control():
    ThreadingHTTPServer(("127.0.0.1", CTRL_PORT), Ctrl).serve_forever()


# ---------------------------------------------------------------------------------------------
# Modes d'exécution

def run_live(engine):
    import sounddevice as sd
    out_index = {"i": None}

    def callback(outdata, frames, time_info, status):
        # Heure (horloge système) à laquelle ces échantillons sortiront des haut-parleurs.
        t_play = now_ns() + int(stream.latency * 1e9)
        if engine.tl.t0 is None:
            outdata[:] = 0
            return
        src = engine.tl.index(t_play - int(CFG["delay"] * 1e9))
        outdata[:] = engine.render(src, frames)
        engine.consumed(src - SR * 20, frames)   # nettoyage loin derrière

    stream = sd.OutputStream(samplerate=SR, channels=2, dtype="float32", callback=callback, blocksize=512)
    stream.start()
    STATS["running"] = True
    log("prêt (entrée sur stdin, sortie haut-parleurs)")
    print("READY", flush=True)
    stdin = sys.stdin.buffer
    while True:
        head = stdin.read(16)
        if len(head) < 16:
            break
        magic, n, t_ns = struct.unpack("<4sIQ", head)
        if magic != b"MTAU":
            log("flux audio désynchronisé")
            break
        data = stdin.read(n * 8)
        if len(data) < n * 8:
            break
        engine.push(t_ns, np.frombuffer(data, np.float32).reshape(n, 2))


def run_simulation(engine, path, out_path):
    """Rejoue un fichier comme s'il était capté en direct (temps réel), écrit la sortie différée dans un WAV."""
    import soundfile as sf
    x, sr = sf.read(path, dtype="float32", always_2d=True)
    if sr != SR:
        x = np.stack([engine.m.resample(x[:, c], sr, SR) for c in range(x.shape[1])], axis=1)
    if x.shape[1] == 1:
        x = np.repeat(x, 2, axis=1)
    block = 480
    t_start = now_ns()
    for k in range(0, len(x), block):
        target = t_start + int(k / SR * 1e9)
        while now_ns() < target:
            time.sleep(0.001)
        engine.push(target, x[k:k + block])
    # on laisse finir le traitement du dernier segment
    time.sleep(CFG["delay"] + 4)
    out = engine.render(0, len(x))
    sf.write(out_path, out, SR)
    log(f"sortie écrite : {out_path} ({len(x) / SR:.1f} s) · segments {STATS['segments']} · en retard {STATS['late']}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--simulate")
    ap.add_argument("--out")
    ap.add_argument("--delay", type=float)
    ap.add_argument("--voice")
    ap.add_argument("--mode")
    a = ap.parse_args()
    for k in ("delay", "voice", "mode"):
        if getattr(a, k) is not None:
            CFG[k] = getattr(a, k)
    tts = TTSPool(int(os.environ.get("DUB_TTS_WORKERS", "2")))
    models = Models()
    eng = Engine(models, tts)
    threading.Thread(target=serve_control, daemon=True).start()
    if a.simulate:
        run_simulation(eng, a.simulate, a.out or "dub_out.wav")
    else:
        run_live(eng)
