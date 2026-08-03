"""Configuration for the Registro Horario de Producción app.

All settings come from environment variables so the same code runs in local
development (SQLite, plain HTTP) and in production (Azure SQL, HTTPS) without
edits. See README.md for the full list.
"""
from __future__ import annotations

import os


def _as_bool(value: str | None, default: bool) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


class Config:
    # --- Flask / session -----------------------------------------------------
    # A stable secret is required so signed session cookies survive restarts.
    # In production ALWAYS set RHP_SECRET_KEY to a long random value.
    SECRET_KEY = os.environ.get("RHP_SECRET_KEY", "dev-only-insecure-secret-change-me")

    # Cookie hardening (spec §5). Secure defaults to True; set
    # RHP_SESSION_COOKIE_SECURE=false only for local HTTP testing.
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    SESSION_COOKIE_SECURE = _as_bool(os.environ.get("RHP_SESSION_COOKIE_SECURE"), True)
    PERMANENT_SESSION_LIFETIME = int(os.environ.get("RHP_SESSION_LIFETIME_SECONDS", 8 * 3600))

    # --- Database backend ----------------------------------------------------
    # "sqlite" (default, for dev/test) or "mssql" (production Azure SQL).
    DB_BACKEND = os.environ.get("RHP_DB_BACKEND", "sqlite").strip().lower()

    # SQLite dev backend
    SQLITE_PATH = os.environ.get(
        "RHP_SQLITE_PATH",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "instance", "rhp_dev.sqlite3"),
    )
    # Seed the SQLite dev DB with sample OPs + a default user on first run.
    SQLITE_SEED = _as_bool(os.environ.get("RHP_SQLITE_SEED"), True)

    # MSSQL / Azure SQL backend. Provide a full pyodbc connection string, e.g.:
    #   Driver={ODBC Driver 18 for SQL Server};
    #   Server=tcp:sqlserver-jomipsapde-prod-westeu-001.database.windows.net,1433;
    #   Database=sqldb-jomipsapde-prod-westeu-001;UID=...;PWD=...;Encrypt=yes;
    MSSQL_CONNECTION_STRING = os.environ.get("RHP_MSSQL_CONNECTION_STRING", "")

    # --- First-run / seed user (spec §5 reference credentials) ---------------
    # Used to seed the very first user when the users table is empty. Change the
    # password immediately in any real deployment.
    DEFAULT_ADMIN_USER = os.environ.get("RHP_DEFAULT_ADMIN_USER", "User")
    DEFAULT_ADMIN_PASSWORD = os.environ.get("RHP_DEFAULT_ADMIN_PASSWORD", "Cambiar2025!!!")
    DEFAULT_ADMIN_ROLE = os.environ.get("RHP_DEFAULT_ADMIN_ROLE", "planta")

    @classmethod
    def as_dict(cls) -> dict:
        return {
            "SECRET_KEY": cls.SECRET_KEY,
            "SESSION_COOKIE_HTTPONLY": cls.SESSION_COOKIE_HTTPONLY,
            "SESSION_COOKIE_SAMESITE": cls.SESSION_COOKIE_SAMESITE,
            "SESSION_COOKIE_SECURE": cls.SESSION_COOKIE_SECURE,
            "PERMANENT_SESSION_LIFETIME": cls.PERMANENT_SESSION_LIFETIME,
        }
