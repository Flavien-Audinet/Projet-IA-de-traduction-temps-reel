"""MyTranslate — doublage ANTICIPÉ des vidéos web (« Écouter traduit », mode vidéo).

Au lieu d'écouter en même temps que l'utilisateur, on lit la vidéo EN AVANCE dans sa ligne de temps :
  1. audio + sous-titres récupérés d'avance (yt-dlp : YouTube, Vimeo, Twitch… ; sinon le fichier de la page)
  2. par fenêtres de 10 s, devant la tête de lecture :
       séparation voix / fond (Mel-RoFormer, morceaux de 8 s recouvrants ; fondu entre fenêtres)
       phrases : sous-titres écrits par l'auteur s'il y en a (texte exact + minutage), sinon Parakeet ;
         phrases longues coupées aux virgules ; une phrase déjà doublée n'est JAMAIS refaite
       une voix par personne : empreinte de voix de chaque phrase → regroupement par interlocuteur,
         référence = le meilleur extrait de cette personne (stable, s'améliore au fil de la vidéo)
       traduction Opus-MT → voix imitée (Chatterbox, ateliers parallèles) → durée ajustée (≤ ×1,25)
         → léger effet de salle pour se fondre dans la scène ; aucune voix ne se superpose à une autre
  3. lecture calée sur la position de la vidéo envoyée par l'extension (lecture, pause, saut, vitesse).

Contrôle HTTP 127.0.0.1:8771 :
  POST /job {url, src, t, title}  · POST /sync {t, paused, rate}  · POST /stop  · POST /config {…}  · GET /status
"""
import bisect
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ.setdefault("DUB_SR", "48000")
import numpy as np  # noqa: E402
from scipy.signal import lfilter  # noqa: E402

from local_guard import reject_if_foreign  # noqa: E402
import dub_server as core  # séparation, reconnaissance, ateliers de voix, ajustement de durée  # noqa: E402

SR = 48000
PORT = int(os.environ.get("DUB_AHEAD_PORT", "8771"))
W = 10.0                 # taille d'une fenêtre de traitement (s) : petite = démarrage rapide
AHEAD = 240.0            # on ne prépare pas plus de 4 min d'avance (chauffe, mémoire)
KEEP_BEHIND = 90.0       # fenêtres gardées derrière la tête de lecture (retour en arrière)
XF = int(0.08 * SR)      # fondu entre deux fenêtres de fond

CFG = {"voice": "chatterbox", "direction": "enToFr", "dubGain": 1.0, "bgGain": 1.0, "origGain": 0.0,
       "cookies": False, "room": 0.3}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def now_ns():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


# ---------------------------------------------------------------------------------------------
# Récupération de l'audio et des sous-titres

def fetch(url, src, workdir, job):
    """Renvoie (chemin audio, durée, liste de répliques [(début, fin, texte)] ou None)."""
    import yt_dlp
    if os.environ.get("DUB_ALLOW_LOCAL_FILES") == "1" and os.path.exists(url):   # fichier local (tests)
        return url, probe_duration(url), None
    if not re.match(r"https?://", url or ""):
        raise ValueError("adresse de vidéo invalide (http:// ou https:// attendu)")
    opts = {"quiet": True, "no_warnings": True, "noprogress": True, "format": "bestaudio/best",
            "outtmpl": os.path.join(workdir, "audio.%(ext)s"), "noplaylist": True}
    if CFG["cookies"]:
        opts["cookiesfrombrowser"] = ("firefox",)
    try:
        t0 = time.time()
        with yt_dlp.YoutubeDL(opts) as y:
            info = y.extract_info(url, download=False)
            job.duration = float(info.get("duration") or 0) or None
            job.title = info.get("title") or job.title
            job.message = "téléchargement de l'audio…"
            t1 = time.time()
            y.download([url])
        log(f"yt-dlp : infos {t1 - t0:.1f} s, audio {time.time() - t1:.1f} s")
        audio = glob.glob(os.path.join(workdir, "audio.*"))[0]
        cues = None
        subs = (info.get("subtitles") or {})
        lang = CFG["direction"][:2]
        manual = next((subs[k] for k in subs if k == lang or k.startswith(lang + "-")), None)
        if manual:                                   # sous-titres écrits par l'auteur : texte exact + minutage
            vtt = next((s for s in manual if s.get("ext") == "vtt"), manual[0])
            with urllib.request.urlopen(vtt["url"], timeout=20) as r:
                cues = parse_vtt(r.read().decode("utf-8", "replace"))
        return audio, job.duration, cues
    except Exception as e:  # noqa: BLE001
        if not src or not src.startswith("http"):
            raise RuntimeError(f"impossible de récupérer l'audio ({str(e)[:120]})")
        log("yt-dlp a échoué, lecture directe du fichier de la page :", str(e)[:120])
        return src, probe_duration(src), None


def probe_duration(path):
    p = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                       capture_output=True, text=True)
    try:
        return float(p.stdout.strip())
    except ValueError:
        return None


def decode(path, start, dur):
    """Extrait [start, start+dur] en stéréo 48 kHz float32 (via ffmpeg, recherche rapide)."""
    start = max(0.0, start)
    p = subprocess.run(["ffmpeg", "-loglevel", "error", "-ss", f"{start:.3f}", "-t", f"{dur:.3f}", "-i", path,
                        "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"], capture_output=True)
    return np.frombuffer(p.stdout, np.float32).reshape(-1, 2).copy()


def parse_vtt(text):
    """Répliques d'un fichier WebVTT, regroupées en phrases (ponctuation, pauses, longueur)."""
    def ts(s):
        h, m, rest = ([0] + s.split(":"))[-3:]
        return int(h) * 3600 + int(m) * 60 + float(rest.replace(",", "."))
    cues = []
    for block in re.split(r"\n\s*\n", text):
        m = re.search(r"([\d:.,]+)\s+-->\s+([\d:.,]+)", block)
        if not m:
            continue
        rest = block[m.end():]
        body = rest.split("\n", 1)[1] if "\n" in rest else ""
        body = re.sub(r"<[^>]+>", "", body).replace("&nbsp;", " ").strip()
        body = re.sub(r"\s+", " ", body)
        if body and (not cues or body != cues[-1][2]):
            cues.append([ts(m.group(1)), ts(m.group(2)), body])
    out = []
    for c in cues:
        if out and not re.search(r"[.!?…]$", out[-1][2]) and c[0] - out[-1][1] < 0.6 and c[1] - out[-1][0] < 9:
            out[-1][1] = c[1]
            out[-1][2] += " " + c[2]
        else:
            out.append(list(c))
    return [tuple(c) for c in out]


def split_long(s, e, text, max_len=6.0):
    """Découpe une phrase trop longue aux virgules / points-virgules (temps réparti selon la longueur du texte)."""
    if e - s <= max_len:
        return [(s, e, text)]
    parts = [p.strip() for p in re.split(r"(?<=[,;:])\s+", text) if p.strip()]
    if len(parts) < 2:
        return [(s, e, text)]
    total = sum(len(p) for p in parts)
    groups, cur = [], ""
    for p in parts:
        cur = f"{cur} {p}".strip()
        if (e - s) * len(cur) / total >= 3.0:
            groups.append(cur)
            cur = ""
    if cur:
        if groups:
            groups[-1] += " " + cur
        else:
            groups.append(cur)
    out, t = [], s
    for g in groups:
        d = (e - s) * len(g) / max(1, sum(len(x) for x in groups))
        out.append((t, t + d, g))
        t += d
    return out


def translate_batch(texts):
    req = urllib.request.Request(core.MT_URL, data=json.dumps({"texts": texts, "direction": CFG["direction"]}).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))["translations"]


# ---------------------------------------------------------------------------------------------
# Intégration acoustique : petite réverbération de salle + aigus adoucis (comme la bande-son)

_IR = None


def room(audio):
    global _IR
    wet = CFG["room"] * 0.4
    if wet <= 0 or len(audio) == 0:
        return audio
    if _IR is None:
        rng = np.random.default_rng(1)
        t = np.arange(int(0.35 * SR)) / SR
        ir = rng.standard_normal(len(t)) * np.exp(-t / 0.07)
        ir[: int(0.008 * SR)] = 0                     # pré-délai : premières réflexions
        _IR = (ir / np.sqrt(np.sum(ir ** 2))).astype(np.float32)
    n = len(audio) + len(_IR) - 1
    size = 1 << (n - 1).bit_length()
    rev = np.fft.irfft(np.fft.rfft(audio, size) * np.fft.rfft(_IR, size), size)[:len(audio)]
    out = audio * (1 - wet * 0.5) + rev.astype(np.float32) * wet
    k = np.exp(-2 * np.pi * 9000 / SR)                # passe-bas doux à ~9 kHz
    return lfilter([1 - k], [1, -k], out).astype(np.float32)


def fades(audio, fin=0.012, fout=0.04):
    a = audio.copy()
    n1, n2 = min(len(a), int(fin * SR)), min(len(a), int(fout * SR))
    a[:n1] *= np.linspace(0, 1, n1, dtype=np.float32)
    a[len(a) - n2:] *= np.linspace(1, 0, n2, dtype=np.float32)
    return a


# ---------------------------------------------------------------------------------------------
# Interlocuteurs : une voix stable par personne

class Speakers:
    THRESHOLD = 0.72      # ressemblance minimale (cosinus des empreintes) pour « même personne »

    def __init__(self):
        self.list = []                   # [{"emb", "n", "ref", "ref_text", "score"}]
        self.lock = threading.Lock()

    def match(self, emb, audio24, text):
        """Rattache un extrait à un interlocuteur (ou en crée un) ; renvoie (référence 24 kHz, texte)."""
        if emb is None:
            return audio24, text
        dur = len(audio24) / 24000
        e = emb / (np.linalg.norm(emb) + 1e-9)
        with self.lock:
            best, sim = None, -1.0
            for sp in self.list:
                s = float(np.dot(e, sp["emb"]))
                if s > sim:
                    best, sim = sp, s
            if best is None or sim < self.THRESHOLD:
                best = {"emb": e, "n": 0, "ref": audio24, "ref_text": text, "score": 0.0}
                self.list.append(best)
                sim = 1.0
            else:
                m = best["emb"] * best["n"] + e
                best["emb"] = m / (np.linalg.norm(m) + 1e-9)
            best["n"] += 1
            # Meilleur extrait de référence : le plus long possible jusqu'à 10 s, bien ressemblant.
            score = min(dur, 10.0) * sim
            if score > best["score"] and dur >= 1.5:
                best["ref"], best["ref_text"], best["score"] = audio24[: 24000 * 10], text, score
            return best["ref"], best["ref_text"]


# ---------------------------------------------------------------------------------------------
# Une vidéo en cours de doublage

class Job:
    def __init__(self, url, src, t, title, models, tts):
        self.url, self.src, self.title = url, src, title or url
        self.m, self.tts = models, tts
        self.cursor = t
        self.state, self.message = "téléchargement", "récupération de la vidéo…"
        self.duration = None
        self.cues = None
        self.audio = None
        self.n = int(W * SR)
        self.bg = {}                 # fenêtre → fond (stéréo, n + XF échantillons : queue pour le fondu)
        self.voc = {}
        self.ready = set()           # fenêtres traitées : fond prêt + phrases envoyées aux ateliers
        self.pending = {}            # (début, fin) → (fenêtre, future) : voix en cours de fabrication
        self.dubs = []               # [(début en échantillons, audio mono)], triés, sans chevauchement
        self.dub_starts = []
        self.spans = []              # passages source déjà doublés [(début s, fin s)] : jamais refaits
        self.speakers = Speakers()
        self.lock = threading.Lock()
        self.cancelled = False
        self.lastFR = ""
        self.segments = 0
        self.gen = 0                 # incrémenté à chaque saut dans la vidéo
        self.workdir = tempfile.mkdtemp(prefix="mytranslate-dub-")
        threading.Thread(target=self.run, daemon=True).start()

    # --- Orchestration --------------------------------------------------------------------------
    def run(self):
        try:
            self.audio, self.duration, self.cues = fetch(self.url, self.src, self.workdir, self)
            if not self.duration:
                self.duration = probe_duration(self.audio) or 3600
            self.state = "préparation"
            log(f"« {self.title[:60]} » : {self.duration:.0f} s, sous-titres manuels : {'oui' if self.cues else 'non'}")
            while not self.cancelled:
                i = self.next_window()
                if i is None:
                    time.sleep(0.3)
                    continue
                t0 = time.time()
                self.process(i)
                log(f"fenêtre {i} ({i * W:.0f}–{(i + 1) * W:.0f} s) prête en {time.time() - t0:.1f} s")
                self.evict()
        except Exception as e:  # noqa: BLE001
            self.state, self.message = "erreur", str(e)
            log("erreur :", e)

    def next_window(self):
        with self.lock:
            if len(self.pending) > 24:                    # assez de voix en attente : on laisse les ateliers suivre
                return None
        first = int(self.cursor // W)
        last = int(min(self.duration, self.cursor + AHEAD) // W)
        for i in range(first, last + 1):
            if i not in self.ready and i * W < self.duration:
                return i
        return None

    def evict(self):
        keep = int(max(0, self.cursor - KEEP_BEHIND) // W)
        far = int((self.cursor + AHEAD + W) // W)
        with self.lock:
            for i in list(self.bg):
                if i < keep or i > far:
                    self.bg.pop(i, None)
                    self.voc.pop(i, None)
                    self.ready.discard(i)
            lo, hi = keep * W * SR, far * W * SR
            kept = [(s, a) for s, a in self.dubs if lo <= s <= hi]
            self.dubs, self.dub_starts = kept, [s for s, _ in kept]
            self.spans = [(a, b) for a, b in self.spans if lo / SR - 5 <= a <= hi / SR + 5]

    # --- Une fenêtre ------------------------------------------------------------------------------
    def process(self, i):
        a, b = i * W, min(self.duration, (i + 1) * W)
        L, R = 2.0, 6.0                                   # contexte gauche (séparation), droit (phrases à cheval)
        x = decode(self.audio, a - L, (b - a) + L + R)
        if len(x) == 0:
            self.ready.add(i)
            return
        off = int(min(L, a) * SR)
        vocals = self.separate_long(x)
        self.store_background(i, x, vocals, off)
        mono = vocals.mean(axis=1)
        base = a - min(L, a)

        # Phrases à doubler : sous-titres de l'auteur, sinon mots reconnus (au mot près : une tranche ne
        # double que des mots pas encore doublés, et prolonge une phrase commencée jusqu'à sa vraie fin).
        if self.cues is not None:
            sents = [(s, e, t) for s, e, t in self.cues if a <= s < b and not self.already(s, e)]
            sents = [p for s in sents for p in split_long(*s)]
        else:
            words = [(base + s0, base + s1, w) for s0, s1, w in self.m.words(self.m.resample(mono, SR, 16000))]
            sents = self.group_words([w for w in words if not self.covered((w[0] + w[1]) / 2)], a, b)
        sents = [s for s in sents if len([c for c in s[2] if c.isalpha()]) >= 2]
        if sents:
            with self.lock:
                for s, e, _ in sents:
                    bisect.insort(self.spans, (s, e))
            self.dub_sentences(i, sents, mono, base)     # n'attend pas : les voix arrivent au fil de l'eau
        with self.lock:
            self.ready.add(i)

    @staticmethod
    def group_words(words, a, b):
        """Regroupe des mots en phrases : une phrase doit COMMENCER dans [a, b), elle se termine à la
        ponctuation finale, à une pause de plus de 0,6 s, ou (si elle s'allonge) à une virgule / vers 9 s."""
        groups, cur = [], []

        def close():
            if cur:
                groups.append((cur[0][0], cur[-1][1], " ".join(w for _, _, w in cur)))
            cur.clear()
        for w in words:
            if cur and w[0] - cur[-1][1] > 0.6:
                close()
            if not cur and not (a <= w[0] < b):
                continue
            cur.append(w)
            d = cur[-1][1] - cur[0][0]
            if re.search(r"[.!?…]$", w[2]) or (d > 5.0 and re.search(r"[,;:]$", w[2])) or d > 9.0:
                close()
        close()
        return groups

    def covered(self, t):
        """Vrai si l'instant t (s) est déjà dans un passage doublé."""
        with self.lock:
            k = bisect.bisect(self.spans, (t, float("inf")))
            return k > 0 and self.spans[k - 1][0] <= t <= self.spans[k - 1][1]

    def already(self, s, e):
        """Vrai si ce passage recouvre déjà en grande partie une phrase doublée."""
        with self.lock:
            for a, b in self.spans:
                if a > e:
                    break
                if min(b, e) - max(a, s) > 0.4 * max(0.3, e - s):
                    return True
        return False

    def seek(self, t):
        """Saut dans la vidéo : les voix pas encore commencées ailleurs sont annulées (elles bloqueraient
        la file des ateliers) ; leurs fenêtres seront refaites si besoin (les phrases déjà doublées sont gardées)."""
        if abs(t - self.cursor) > 15:
            self.gen += 1
            with self.lock:
                for span, (w, fut) in list(self.pending.items()):
                    if abs(span[0] - t) > 20 and fut.cancel():
                        self.pending.pop(span, None)
                        self.spans = [sp for sp in self.spans if sp != span]
                        self.ready.discard(w)
        self.cursor = t

    def dub_sentences(self, w, sents, mono, base):
        refs = []
        for s, e, t in sents:
            s0, s1 = int((s - base) * SR), int((e - base) * SR)
            refs.append(self.m.resample(mono[max(0, s0):max(s0 + 1, s1)], SR, 24000).astype(np.float32))
        # Une voix par personne : empreintes, puis référence = meilleur extrait de l'interlocuteur.
        try:
            embs = self.tts.embed(refs).result(timeout=30)
        except Exception:  # noqa: BLE001
            embs = [None] * len(refs)
        fr = translate_batch([t for _, _, t in sents])
        for k, ((s, e, t), f, r24, emb) in enumerate(zip(sents, fr, refs, embs)):
            ref, ref_text = self.speakers.match(emb, r24, t)
            if len(ref) < 24000 * 1.5:                       # trop court : quelques secondes autour
                c = int(((s + e) / 2 - base) * SR)
                ref = self.m.resample(mono[max(0, c - 3 * SR):c + 3 * SR], SR, 24000)
                ref_text = ""
            nxt = sents[k + 1][0] if k + 1 < len(sents) else e + 1.0
            fut = self.tts.submit(f, ref, CFG["direction"][-2:].lower(), ref_text)
            with self.lock:
                self.pending[(s, e)] = (w, fut)
            fut.add_done_callback(lambda fu, meta=(s, e, nxt, f, r24): self.finish(fu, *meta))

    def finish(self, fut, s, e, nxt, f, r24):
        """Une voix est prête (rappel de l'atelier) : durée, niveau, effet de salle, placement."""
        try:
            if fut.cancelled() or self.cancelled:
                return
            audio = fut.result()
            target = max(0.3, min(e - s + 0.4, nxt - s))
            audio = core.fit_duration(audio, target)
            if len(audio) == 0:
                return
            rms_ref = float(np.sqrt(np.mean(r24 ** 2))) or 1e-3
            rms = float(np.sqrt(np.mean(audio ** 2))) or 1e-3
            audio = audio * min(rms_ref / rms, 0.95 / (float(np.abs(audio).max()) or 1))
            audio = fades(room(audio.astype(np.float32)))
            self.place(int(s * SR), audio)
            self.segments += 1
            self.lastFR = f[-160:]
        except Exception as ex:  # noqa: BLE001
            log("voix impossible :", ex)
        finally:
            with self.lock:
                self.pending.pop((s, e), None)

    def place(self, start, audio):
        """Ajoute une voix sans JAMAIS la superposer à une autre : la précédente est coupée en fondu,
        la nouvelle s'arrête (en fondu) au début de la suivante."""
        fade = int(0.06 * SR)
        with self.lock:
            k = bisect.bisect(self.dub_starts, start)
            if k > 0:
                ps, pa = self.dubs[k - 1]
                if ps + len(pa) > start:
                    pa = pa[:max(0, start - ps)].copy()
                    f = min(fade, len(pa))
                    if f:
                        pa[len(pa) - f:] *= np.linspace(1, 0, f, dtype=np.float32)
                    self.dubs[k - 1] = (ps, pa)
            if k < len(self.dubs):
                ns = self.dubs[k][0]
                if start + len(audio) > ns:
                    audio = audio[:max(0, ns - start)].copy()
                    f = min(fade, len(audio))
                    if f:
                        audio[len(audio) - f:] *= np.linspace(1, 0, f, dtype=np.float32)
            self.dub_starts.insert(k, start)
            self.dubs.insert(k, (start, audio.astype(np.float32)))

    def store_background(self, i, x, vocals, off):
        """Fond de la fenêtre i (+ une queue de XF échantillons), fondu avec ses voisines déjà prêtes."""
        n = self.n
        bg = (x[off:off + n + XF] - vocals[off:off + n + XF]).astype(np.float32)
        if len(bg) < n + XF:
            bg = np.pad(bg, ((0, n + XF - len(bg)), (0, 0)))
        w = np.linspace(0, 1, XF, dtype=np.float32)[:, None]
        with self.lock:
            prev = self.bg.get(i - 1)
            if prev is not None:                              # début de i ≈ queue de i-1
                bg[:XF] = bg[:XF] * w + prev[n:n + XF] * (1 - w)
            nxt = self.bg.get(i + 1)
            if nxt is not None:                               # fenêtre suivante déjà prête (saut en arrière)
                nxt[:XF] = nxt[:XF] * w + bg[n:n + XF] * (1 - w)
            self.bg[i] = bg
            if CFG["origGain"] > 0:
                v = vocals[off:off + n].astype(np.float32)
                self.voc[i] = np.pad(v, ((0, n - len(v)), (0, 0)))

    def separate_long(self, x):
        """Séparation par morceaux de 8 s avec 1 s de recouvrement (fondu) : pas d'artefact aux jonctions."""
        chunk, hop = 8 * SR, 7 * SR
        out = np.zeros_like(x)
        weight = np.zeros(len(x), np.float32)
        fade = np.ones(chunk, np.float32)
        ramp = np.linspace(0, 1, SR, dtype=np.float32)
        fade[:SR], fade[-SR:] = ramp, ramp[::-1]
        for k in range(0, max(1, len(x) - SR), hop):
            seg = x[k:k + chunk]
            if np.abs(seg).max() < 1e-4:
                continue
            v = self.m.separate(seg)
            w = fade[:len(seg)].copy()
            if k == 0:
                w[:SR] = 1
            if k + chunk >= len(x):
                w[-min(SR, len(w)):] = 1
            out[k:k + len(seg)] += v * w[:, None]
            weight[k:k + len(seg)] += w
        return out / np.maximum(weight, 1e-6)[:, None]

    # --- Lecture -------------------------------------------------------------------------------
    def is_ready(self, t, margin=3.0):
        """Prêt à jouer depuis t : fond disponible et phrases des `margin` prochaines secondes déjà doublées."""
        if self.duration is None or self.state != "préparation":
            return False                                  # audio pas encore récupéré
        end = min(t + margin, self.duration)
        for j in range(int(t // W), int(end // W) + 1):
            if j * W < self.duration and j not in self.ready:
                return False
        with self.lock:
            return not any(t - 0.3 <= s <= end for s, _ in self.pending)

    def ready_ranges(self):
        out = []
        for i in sorted(self.ready):
            if out and out[-1][1] == i * W:
                out[-1][1] = min(self.duration or 0, (i + 1) * W)
            else:
                out.append([i * W, min(self.duration or 0, (i + 1) * W)])
        return out

    def render(self, start, count, step=1.0):
        """`count` échantillons à partir de la position `start` (échantillons de la vidéo), vitesse `step`."""
        out = np.zeros((count, 2), np.float32)
        n = self.n
        with self.lock:
            if step == 1.0:
                # Cas courant : tranches contiguës (rapide : pas de craquement par surcharge du calcul)
                pos, filled = start, 0
                while filled < count:
                    i, local = divmod(pos, n)
                    take = min(count - filled, n - local)
                    bg = self.bg.get(int(i))
                    if bg is not None and pos >= 0:
                        out[filled:filled + take] = bg[local:local + take] * CFG["bgGain"]
                        voc = self.voc.get(int(i))
                        if voc is not None and CFG["origGain"] > 0:
                            out[filled:filled + take] += voc[local:local + take] * CFG["origGain"]
                    pos += take
                    filled += take
                k = bisect.bisect_left(self.dub_starts, start - 20 * SR)
                end = start + count
                while k < len(self.dubs) and self.dubs[k][0] < end:
                    s, a = self.dubs[k]
                    lo, hi = max(start, s), min(end, s + len(a))
                    if hi > lo:
                        out[lo - start:hi - start] += (a[lo - s:hi - s] * CFG["dubGain"])[:, None]
                    k += 1
            else:
                idx = start + (np.arange(count) * step).astype(np.int64)
                for j, p in enumerate(idx):
                    i, local = divmod(int(p), n)
                    bg = self.bg.get(i)
                    if bg is not None and p >= 0:
                        out[j] = bg[local] * CFG["bgGain"]
                k = bisect.bisect_left(self.dub_starts, int(idx[0]) - 20 * SR)
                while k < len(self.dubs) and self.dubs[k][0] <= idx[-1]:
                    s, a = self.dubs[k]
                    rel = idx - s
                    m = (rel >= 0) & (rel < len(a))
                    if m.any():
                        out[m] += (a[rel[m]] * CFG["dubGain"])[:, None]
                    k += 1
        return np.clip(out, -1, 1)

    def cancel(self):
        self.cancelled = True
        subprocess.run(["rm", "-rf", self.workdir])


# ---------------------------------------------------------------------------------------------
# Lecteur calé sur la position de la vidéo

class Player:
    def __init__(self):
        import sounddevice as sd
        self.job = None
        self.t, self.wall, self.rate, self.paused = 0.0, now_ns(), 1.0, True
        self.lock = threading.Lock()
        self.stream = sd.OutputStream(samplerate=SR, channels=2, dtype="float32", blocksize=1024,
                                      latency="high", callback=self.cb)
        self.stream.start()

    def media_time(self, at_ns):
        with self.lock:
            if self.paused:
                return self.t
            return self.t + (at_ns - self.wall) / 1e9 * self.rate

    def sync(self, t, paused, rate):
        with self.lock:
            now = now_ns()
            predicted = self.t if self.paused else self.t + (now - self.wall) / 1e9 * self.rate
            err = t - predicted
            if paused != self.paused or rate != self.rate or abs(err) > 0.25:
                self.t, self.wall = t, now            # vrai saut (avance rapide, pause, reprise) : recalage immédiat
            elif not paused and abs(err) > 0.02:
                self.t, self.wall = predicted + err * 0.1, now   # petite dérive : correction progressive, inaudible
            self.paused, self.rate = paused, rate

    def cb(self, outdata, frames, time_info, status):
        job = self.job
        if job is None or self.paused:
            outdata[:] = 0
            return
        t = self.media_time(now_ns() + int(self.stream.latency * 1e9))
        outdata[:] = job.render(int(round(t * SR)), frames, self.rate)


# ---------------------------------------------------------------------------------------------
# Contrôle HTTP

STATE = {"job": None, "player": None, "models": None, "tts": None}


class Ctrl(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, obj, code=200):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if reject_if_foreign(self, PORT):
            return
        j = STATE["job"]
        if not j:
            return self.reply({"state": "inactif"})
        self.reply({"state": j.state, "message": j.message, "url": j.url, "title": j.title, "duration": j.duration,
                    "ready": j.ready_ranges(), "readyNow": j.is_ready(STATE["player"].media_time(now_ns())),
                    "segments": j.segments, "speakers": len(j.speakers.list), "lastFR": j.lastFR,
                    "pending": len(j.pending),
                    "overlaps": sum(1 for (s1, a1), (s2, _) in zip(j.dubs, j.dubs[1:]) if s1 + len(a1) > s2),
                    "subtitles": j.cues is not None})

    def do_POST(self):
        if reject_if_foreign(self, PORT):
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        p = STATE["player"]
        if self.path == "/job":
            j = STATE["job"]
            if j is None or j.url != body.get("url"):
                if j:
                    p.job = None
                    j.cancel()
                j = Job(body.get("url", ""), body.get("src"), float(body.get("t", 0)), body.get("title"),
                        STATE["models"], STATE["tts"])
                STATE["job"] = j
                p.job = j
            j.seek(float(body.get("t", j.cursor)))
            return self.reply({"ok": True})
        if self.path == "/sync":
            j = STATE["job"]
            t = float(body.get("t", 0))
            if j:
                j.seek(t)
            p.sync(t, bool(body.get("paused", True)), float(body.get("rate", 1.0)))
            return self.reply({"ready": bool(j and j.is_ready(t, 1.5)), "readyAhead": bool(j and j.is_ready(t, 4.0))})
        if self.path == "/stop":
            j = STATE["job"]
            p.job = None
            p.sync(0, True, 1.0)
            if j:
                j.cancel()
            STATE["job"] = None
            return self.reply({"ok": True})
        if self.path == "/config":
            for k, v in body.items():
                if k in CFG:
                    CFG[k] = type(CFG[k])(v)
            core.CFG["voice"] = CFG["voice"]
            core.CFG["direction"] = CFG["direction"]
            return self.reply(CFG)
        self.reply({"error": "inconnu"}, 404)


if __name__ == "__main__":
    for i, a in enumerate(sys.argv):
        if a == "--voice" and i + 1 < len(sys.argv):
            CFG["voice"] = core.CFG["voice"] = sys.argv[i + 1]
    STATE["tts"] = core.TTSPool(int(os.environ.get("DUB_TTS_WORKERS", "2")))
    STATE["models"] = core.Models()
    STATE["player"] = Player()
    threading.Thread(target=lambda: ThreadingHTTPServer(("127.0.0.1", PORT), Ctrl).serve_forever(), daemon=True).start()
    log("prêt (doublage anticipé, port", PORT, ")")
    print("READY", flush=True)
    while True:
        time.sleep(3600)
