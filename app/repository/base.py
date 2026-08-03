"""Abstract repository interface.

Both backends (SQLite for dev/test, MSSQL/pyodbc for production) implement this
same surface. Routes and auth depend only on this interface, never on a concrete
driver — so swapping backends, or later adding an Entra-backed user store, is a
localised change.

All datetimes/dates/times exchanged with callers are Python objects
(datetime.date / datetime.time). Rows are returned as plain dicts.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from datetime import date, time
from typing import Optional


class Repository(ABC):
    # --- OPs -----------------------------------------------------------------
    @abstractmethod
    def list_open_ops(self) -> list[dict]:
        """Open OPs for the picker (gold.vw_PowerApp_OPsAbiertas), Due Date asc."""

    @abstractmethod
    def get_op(self, op_no: str) -> Optional[dict]:
        """A single open OP row, or None if it is not currently open."""

    # --- History / lines -----------------------------------------------------
    @abstractmethod
    def get_history_for_op(self, op_no: str) -> list[dict]:
        """Pending + confirmed lines for one OP, newest first
        (gold.vw_PowerApp_HistoricoCompleto WHERE ProductionOrderNo = op)."""

    @abstractmethod
    def list_pending_grouped(self) -> list[dict]:
        """All pending lines grouped by OP (spec §3.2).

        Returns a list of {op, item_description, lineas: [...], total_horas,
        total_unidades} ordered by ProductionOrderNo. Deliberately includes OPs
        already closed in BC that still have pending lines.
        """

    @abstractmethod
    def get_pending_line(self, temp_id: int) -> Optional[dict]:
        """A single pending line by RegistroProduccionTempId, or None."""

    # --- Mutations -----------------------------------------------------------
    @abstractmethod
    def insert_line(self, data: dict, username: str) -> int:
        """Insert a pending line, capturing the OP snapshot (spec §3.3, §6).

        `data` is the dict produced by constants.clean_line_payload.
        Returns the new RegistroProduccionTempId.
        """

    @abstractmethod
    def update_line(self, temp_id: int, data: dict, username: str) -> bool:
        """Update a pending line. Returns True if a row was updated."""

    @abstractmethod
    def delete_line(self, temp_id: int) -> bool:
        """Delete a pending line. Returns True if a row was deleted."""

    @abstractmethod
    def validate_op(self, op_no: str, username: str) -> int:
        """Move ALL pending lines of an OP to the definitive table (spec §3.5).

        Two steps (copy, then delete) inside ONE transaction. Returns the number
        of lines promoted. On any error nothing is committed.
        """

    # --- Users (auth) --------------------------------------------------------
    @abstractmethod
    def get_user(self, username: str) -> Optional[dict]:
        """User row {username, display_name, password_hash, role, is_active} or None."""

    @abstractmethod
    def count_users(self) -> int:
        ...

    @abstractmethod
    def create_user(self, username: str, password_hash: str, display_name: str, role: str) -> None:
        ...
