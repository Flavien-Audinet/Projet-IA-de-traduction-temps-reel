"""Protection commune des petits serveurs HTTP locaux de MyTranslate.

Les moteurs n'écoutent que sur 127.0.0.1, mais une page web ouverte dans le navigateur peut quand même
envoyer des requêtes vers 127.0.0.1 (ou passer par un nom de domaine qui pointe vers 127.0.0.1 :
« DNS rebinding »). On n'accepte donc que :
  - l'app elle-même et les scripts locaux (aucun en-tête Origin / Sec-Fetch-Site) ;
  - l'extension navigateur (Origin moz-extension:// ou chrome-extension://) ;
et seulement si l'en-tête Host désigne bien 127.0.0.1 ou localhost sur le bon port.
"""

EXTENSION_ORIGINS = ("moz-extension://", "chrome-extension://")


def refusal(headers, port: int) -> str | None:
    """Renvoie la raison du refus, ou None si la requête est acceptée."""
    host = (headers.get("Host") or "").strip().lower()
    if host not in (f"127.0.0.1:{port}", f"localhost:{port}"):
        return "hôte refusé"
    origin = headers.get("Origin")
    if origin is not None:
        return None if origin.startswith(EXTENSION_ORIGINS) else "origine refusée"
    if (headers.get("Sec-Fetch-Site") or "none") not in ("none", "same-origin"):
        return "requête d'un site web refusée"
    return None


def reject_if_foreign(handler, port: int) -> bool:
    """À appeler en tête de do_GET / do_POST : répond 403 et renvoie True si la requête est refusée."""
    why = refusal(handler.headers, port)
    if why is None:
        return False
    body = ('{"error": "%s"}' % why).encode()
    handler.send_response(403)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)
    return True
