# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for RegistroHorario.exe.

Build (on Windows):
    pip install -r requirements.txt -r requirements-packaging.txt
    pyinstaller --clean --noconfirm packaging/registro-horario.spec
    -> dist/RegistroHorario.exe

Notes:
  * Jinja2 templates and static assets are NOT Python modules, so PyInstaller
    cannot discover them by following imports — they must be listed in `datas`.
    app/__init__.py resolves them from sys._MEIPASS at runtime.
  * mssql_repo imports pyodbc lazily inside a function; it is listed in
    hiddenimports so the production backend also works from the executable.
"""
import os

ROOT = os.path.abspath(os.path.join(SPECPATH, os.pardir))

a = Analysis(
    [os.path.join(ROOT, "launcher.py")],
    pathex=[ROOT],
    binaries=[],
    datas=[
        (os.path.join(ROOT, "app", "templates"), os.path.join("app", "templates")),
        (os.path.join(ROOT, "app", "static"), os.path.join("app", "static")),
        (os.path.join(ROOT, "sql"), "sql"),
    ],
    hiddenimports=[
        "waitress",
        "pyodbc",
        "app.repository.sqlite_repo",
        "app.repository.mssql_repo",
    ],
    hookspath=[],
    runtime_hooks=[],
    excludes=["tkinter", "unittest", "pytest", "playwright"],
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    name="RegistroHorario",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,          # keep the console: it shows the URL and any startup error
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
