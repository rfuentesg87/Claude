"""Registro Horario de Producción — application entry point.

Development:
    python3 main.py                 # runs the Flask dev server on :8000

Production (example, Windows Server behind waitress):
    waitress-serve --port=8000 main:app
    # or with uvicorn/gunicorn via an ASGI/WSGI bridge; `app` is a WSGI app.

Configuration is entirely via environment variables — see config.py / README.md.
"""
from __future__ import annotations

import os

from app import create_app

# WSGI entry point (referenced by waitress/gunicorn as "main:app").
app = create_app()


def main() -> None:
    host = os.environ.get("RHP_HOST", "127.0.0.1")
    port = int(os.environ.get("RHP_PORT", "8000"))
    debug = os.environ.get("RHP_DEBUG", "").lower() in {"1", "true", "yes", "on"}
    app.run(host=host, port=port, debug=debug)


if __name__ == "__main__":
    main()
