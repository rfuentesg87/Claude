"""Entry point for the packaged Windows build (RegistroHorario.exe).

Unlike main.py (which runs Flask's development server), this launcher serves the
app with **waitress**, a production-grade WSGI server that works well on Windows.
It is the entry point PyInstaller bundles.

Two usage modes:

  RegistroHorario.exe                  Server mode. Reads its settings from
                                       registro-horario.env next to the
                                       executable. This is what the installed
                                       service runs.

  RegistroHorario.exe --demo           Portable demo. Forces the SQLite backend
                                       with sample data, no database needed, and
                                       opens the browser. For trying the app out.

Configuration precedence: real environment variables win over the .env file, so
a service definition can override anything without editing files.
"""
from __future__ import annotations

import argparse
import os
import sys
import threading
import webbrowser

ENV_FILENAME = "registro-horario.env"


def app_dir() -> str:
    """Folder containing the executable (or this file, when run from source)."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def load_env_file(path: str) -> list[str]:
    """Load KEY=VALUE lines into os.environ. Returns the keys applied.

    Deliberately minimal (no python-dotenv dependency). Values are NOT split on
    '#', because passwords and ODBC connection strings legitimately contain it;
    only whole lines starting with '#' are treated as comments.
    """
    if not os.path.isfile(path):
        return []
    applied: list[str] = []
    # utf-8-sig: Notepad on Windows writes a BOM, which would corrupt the first key.
    with open(path, "r", encoding="utf-8-sig") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            # A real environment variable always wins over the file.
            if key and key not in os.environ:
                os.environ[key] = value
                applied.append(key)
    return applied


def _open_browser_later(url: str, delay: float = 1.5) -> None:
    threading.Timer(delay, lambda: webbrowser.open(url)).start()


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="RegistroHorario",
        description="Registro Horario de Producción — servidor de la aplicación",
    )
    p.add_argument("--host", default=None, help="Interfaz de escucha (por defecto 0.0.0.0, o 127.0.0.1 en --demo)")
    p.add_argument("--port", type=int, default=None, help="Puerto (por defecto 8000)")
    p.add_argument("--demo", action="store_true",
                   help="Modo demostración: SQLite con datos de ejemplo, sin base de datos real")
    p.add_argument("--open-browser", dest="open_browser", action="store_true", default=None,
                   help="Abrir el navegador al arrancar (implícito en --demo)")
    p.add_argument("--no-browser", dest="open_browser", action="store_false",
                   help="No abrir el navegador")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    base = app_dir()

    # 1. Load the .env file sitting next to the executable (server mode).
    env_path = os.path.join(base, ENV_FILENAME)
    applied = load_env_file(env_path)

    # 2. Demo mode overrides: self-contained, zero configuration.
    if args.demo:
        os.environ["RHP_DB_BACKEND"] = "sqlite"
        os.environ["RHP_SQLITE_SEED"] = "true"
        os.environ["RHP_SQLITE_PATH"] = os.path.join(base, "datos", "demo.sqlite3")
        # The demo runs over plain HTTP on localhost, so a Secure-only cookie
        # would never be sent back and login would silently fail.
        os.environ["RHP_SESSION_COOKIE_SECURE"] = "false"
        os.environ.setdefault("RHP_SECRET_KEY", "demo-solo-para-pruebas-no-usar-en-produccion")

    host = args.host or os.environ.get("RHP_HOST") or ("127.0.0.1" if args.demo else "0.0.0.0")
    port = args.port or int(os.environ.get("RHP_PORT", "8000"))

    # 3. Import AFTER the environment is set — config.py reads os.environ at
    #    import time, so importing earlier would freeze the wrong settings.
    try:
        from app import create_app
    except Exception as exc:  # pragma: no cover - packaging safety net
        print(f"ERROR al inicializar la aplicación: {exc}", file=sys.stderr)
        return 2

    backend = os.environ.get("RHP_DB_BACKEND", "sqlite")

    print("=" * 68)
    print(" Registro Horario de Producción (Cadena)")
    print("=" * 68)
    if args.demo:
        print(" MODO DEMOSTRACIÓN — datos de ejemplo, no se conecta a Azure SQL.")
        print(" Usuario: User      Contraseña: Cambiar2025!!!")
    else:
        print(f" Configuración: {env_path if applied else '(variables de entorno)'}")
        print(f" Backend de base de datos: {backend}")
        if backend == "mssql" and not os.environ.get("RHP_MSSQL_CONNECTION_STRING"):
            print(" ERROR: falta RHP_MSSQL_CONNECTION_STRING.", file=sys.stderr)
            print(f" Edita {env_path} y añade la cadena de conexión.", file=sys.stderr)
            return 2
        if not os.environ.get("RHP_SECRET_KEY"):
            print(" AVISO: RHP_SECRET_KEY no está definida; se usará una clave")
            print("        insegura y las sesiones se invalidarán al reiniciar.")

    try:
        app = create_app()
    except Exception as exc:
        print(f"ERROR al arrancar: {exc}", file=sys.stderr)
        if backend == "mssql":
            print("Comprueba la cadena de conexión, el firewall de Azure SQL y "
                  "que el driver ODBC 18 esté instalado.", file=sys.stderr)
        return 2

    shown_host = "127.0.0.1" if host in ("0.0.0.0", "::") else host
    url = f"http://{shown_host}:{port}/"
    print(f" Escuchando en http://{host}:{port}/")
    print(f" Abre: {url}")
    print(" Para detener el servidor: Ctrl+C (o detén la tarea/servicio)")
    print("=" * 68)

    open_browser = args.open_browser if args.open_browser is not None else args.demo
    if open_browser:
        _open_browser_later(url)

    try:
        from waitress import serve
    except ImportError:
        print("waitress no está instalado; usando el servidor de desarrollo.", file=sys.stderr)
        app.run(host=host, port=port)
        return 0

    try:
        serve(app, host=host, port=port, threads=8, ident="RegistroHorario")
    except KeyboardInterrupt:
        print("\nServidor detenido.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
