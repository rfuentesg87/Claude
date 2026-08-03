"""Repository factory — picks the backend from configuration."""
from __future__ import annotations

from .base import Repository


def build_repository(config) -> Repository:
    backend = getattr(config, "DB_BACKEND", "sqlite")
    if backend == "mssql":
        from .mssql_repo import MSSQLRepository
        return MSSQLRepository(config.MSSQL_CONNECTION_STRING)
    if backend == "sqlite":
        from .sqlite_repo import SQLiteRepository
        return SQLiteRepository(config.SQLITE_PATH, seed=config.SQLITE_SEED)
    raise ValueError(f"Unknown RHP_DB_BACKEND: {backend!r} (expected 'sqlite' or 'mssql')")


__all__ = ["Repository", "build_repository"]
