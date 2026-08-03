"""SQLite backend — for local development and the test suite.

It mirrors the production schema closely enough to exercise every business rule
(snapshot on insert, per-OP totals, two-step transactional validation, pending
lines surviving OP closure) without needing a live Azure SQL instance. The
PERSISTED computed column `TotalHoras` and the view's `UnidadesPorHoraPersona`
are computed in Python on read, matching the SQL Server formulas exactly.

Row/column names match the production views (vw_PowerApp_*) so routes and
templates are backend-agnostic.
"""
from __future__ import annotations

import os
import sqlite3
from datetime import date, datetime, time, timedelta
from typing import Optional

from .base import Repository

# ISO formats used to (de)serialise TIME/DATE columns in SQLite text storage.
_TIME_FMT = "%H:%M:%S"
_DATE_FMT = "%Y-%m-%d"


def _t(value: time) -> str:
    return value.strftime(_TIME_FMT)


def _d(value: date) -> str:
    return value.strftime(_DATE_FMT)


def _parse_t(s: str) -> time:
    return datetime.strptime(s, _TIME_FMT).time()


def _parse_d(s: str) -> date:
    return datetime.strptime(s, _DATE_FMT).date()


def _total_horas(inicio: time, fin: time) -> float:
    """DATEDIFF(MINUTE, HoraInicio, HoraFin) / 60.0, rounded to 2 dp."""
    minutes = (
        datetime.combine(date.min, fin) - datetime.combine(date.min, inicio)
    ) / timedelta(minutes=1)
    return round(minutes / 60.0, 2)


def _unidades_por_hora_persona(total_horas: float, num_personas: int, unidades: float):
    if total_horas > 0 and num_personas > 0:
        return round(unidades / (total_horas * num_personas), 2)
    return None


class SQLiteRepository(Repository):
    def __init__(self, path: str, seed: bool = True):
        self._path = path
        if path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        # check_same_thread=False so the Flask dev server's threads share it;
        # a module-level lock is unnecessary for the low-concurrency dev use.
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._create_schema()
        if seed:
            self._seed()

    # -- schema / seed --------------------------------------------------------
    def _create_schema(self) -> None:
        c = self._conn
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS OPsAbiertas (
                ProductionOrderNo   TEXT PRIMARY KEY,
                ItemNo              TEXT,
                ItemDescription     TEXT,
                LocationCode        TEXT,
                DueDate             TEXT,
                StartDate           TEXT,
                EndingDate          TEXT,
                CantidadPlanificada REAL,
                Status              INTEGER,
                RoutingNo           TEXT,
                MachineCenterNo     TEXT
            );

            CREATE TABLE IF NOT EXISTS RegistroProduccion_Temp (
                RegistroProduccionTempId INTEGER PRIMARY KEY AUTOINCREMENT,
                ProductionOrderNo   TEXT NOT NULL,
                HoraInicio          TEXT NOT NULL,
                HoraFin             TEXT NOT NULL,
                NumPersonas         INTEGER NOT NULL,
                TotalUnidadesProducidas REAL NOT NULL,
                TipoTrabajo         TEXT,
                Comentarios         TEXT,
                FechaRegistro       TEXT NOT NULL,
                CreatedAt           TEXT NOT NULL,
                CreatedBy           TEXT,
                ModifiedAt          TEXT,
                ModifiedBy          TEXT,
                ItemNo              TEXT,
                ItemDescription     TEXT,
                LocationCode        TEXT,
                RoutingNo           TEXT,
                MachineCenterNo     TEXT,
                CantidadPlanificada REAL
            );

            CREATE TABLE IF NOT EXISTS RegistroProduccion (
                RegistroProduccionId INTEGER PRIMARY KEY AUTOINCREMENT,
                ProductionOrderNo   TEXT NOT NULL,
                HoraInicio          TEXT NOT NULL,
                HoraFin             TEXT NOT NULL,
                NumPersonas         INTEGER NOT NULL,
                TotalUnidadesProducidas REAL NOT NULL,
                TipoTrabajo         TEXT,
                Comentarios         TEXT,
                FechaRegistro       TEXT NOT NULL,
                CreatedAt           TEXT NOT NULL,
                CreatedBy           TEXT,
                ModifiedAt          TEXT,
                ModifiedBy          TEXT,
                ItemNo              TEXT,
                ItemDescription     TEXT,
                LocationCode        TEXT,
                RoutingNo           TEXT,
                MachineCenterNo     TEXT,
                CantidadPlanificada REAL
            );

            CREATE TABLE IF NOT EXISTS AppUsers (
                AppUserId     INTEGER PRIMARY KEY AUTOINCREMENT,
                Username      TEXT NOT NULL UNIQUE,
                DisplayName   TEXT,
                PasswordHash  TEXT NOT NULL,
                Role          TEXT NOT NULL DEFAULT 'cadena',
                IsActive      INTEGER NOT NULL DEFAULT 1,
                CreatedAt     TEXT NOT NULL
            );
            """
        )
        c.commit()

    def _seed(self) -> None:
        c = self._conn
        if c.execute("SELECT COUNT(*) FROM OPsAbiertas").fetchone()[0] == 0:
            sample = [
                ("PO-000123", "ART-001", "Barrita energética avena 40g", "ALM01",
                 "2026-08-10", "2026-08-01", "2026-08-09", 5000, 3, "CADENA1", "CAD-01"),
                ("PO-000124", "ART-014", "Galleta integral cacao pack 6", "ALM01",
                 "2026-08-12", "2026-08-02", "2026-08-11", 8200, 3, "CADENA1", "CAD-02"),
                ("PO-000125", "ART-208", "Crema de cacahuete natural 500g", "ALM02",
                 "2026-08-15", "2026-08-03", "2026-08-14", 3000, 3, "CADENA2", "CAD-03"),
            ]
            c.executemany(
                """INSERT INTO OPsAbiertas
                   (ProductionOrderNo, ItemNo, ItemDescription, LocationCode,
                    DueDate, StartDate, EndingDate, CantidadPlanificada, Status,
                    RoutingNo, MachineCenterNo)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                sample,
            )
            c.commit()

    # -- helpers --------------------------------------------------------------
    def _op_display_label(self, op: sqlite3.Row | dict) -> str:
        desc = op["ItemDescription"] or ""
        short = desc[:35] + ("..." if len(desc) > 35 else "")
        due = op["DueDate"]
        due_fmt = _parse_d(due).strftime("%d/%m/%Y") if due else ""
        return (f"{op['ProductionOrderNo']} | {op['ItemNo']} - {short} | "
                f"{op['LocationCode']} | Vence: {due_fmt}")

    def _op_to_dict(self, row: sqlite3.Row) -> dict:
        d = dict(row)
        d["DueDate"] = _parse_d(d["DueDate"]) if d.get("DueDate") else None
        d["StartDate"] = _parse_d(d["StartDate"]) if d.get("StartDate") else None
        d["EndingDate"] = _parse_d(d["EndingDate"]) if d.get("EndingDate") else None
        d["OPDisplayLabel"] = self._op_display_label(row)
        return d

    def _line_row(self, row: sqlite3.Row, estado: str) -> dict:
        inicio = _parse_t(row["HoraInicio"])
        fin = _parse_t(row["HoraFin"])
        total_horas = _total_horas(inicio, fin)
        num = row["NumPersonas"]
        unidades = row["TotalUnidadesProducidas"]
        is_pending = estado == "Pendiente"
        return {
            "Estado": estado,
            "RegistroProduccionTempId": row["RegistroProduccionTempId"] if is_pending else None,
            "RegistroProduccionId": None if is_pending else row["RegistroProduccionId"],
            "RegistroId": str(row["RegistroProduccionTempId"] if is_pending else row["RegistroProduccionId"]),
            "ProductionOrderNo": row["ProductionOrderNo"],
            "FechaRegistro": _parse_d(row["FechaRegistro"]),
            "HoraInicio": inicio,
            "HoraFin": fin,
            "TotalHoras": total_horas,
            "NumPersonas": num,
            "TotalUnidadesProducidas": unidades,
            "TipoTrabajo": row["TipoTrabajo"],
            "Comentarios": row["Comentarios"],
            "CreatedAt": row["CreatedAt"],
            "CreatedBy": row["CreatedBy"],
            "ModifiedAt": row["ModifiedAt"],
            "ModifiedBy": row["ModifiedBy"],
            "ItemNo": row["ItemNo"],
            "ItemDescription": row["ItemDescription"],
            "LocationCode": row["LocationCode"],
            "UnidadesPorHoraPersona": _unidades_por_hora_persona(total_horas, num, unidades),
        }

    # -- OPs ------------------------------------------------------------------
    def list_open_ops(self) -> list[dict]:
        rows = self._conn.execute(
            "SELECT * FROM OPsAbiertas WHERE Status = 3 ORDER BY DueDate ASC"
        ).fetchall()
        return [self._op_to_dict(r) for r in rows]

    def get_op(self, op_no: str) -> Optional[dict]:
        row = self._conn.execute(
            "SELECT * FROM OPsAbiertas WHERE ProductionOrderNo = ?", (op_no,)
        ).fetchone()
        return self._op_to_dict(row) if row else None

    # -- history --------------------------------------------------------------
    def get_history_for_op(self, op_no: str) -> list[dict]:
        temp = self._conn.execute(
            "SELECT * FROM RegistroProduccion_Temp WHERE ProductionOrderNo = ?", (op_no,)
        ).fetchall()
        conf = self._conn.execute(
            "SELECT * FROM RegistroProduccion WHERE ProductionOrderNo = ?", (op_no,)
        ).fetchall()
        rows = [self._line_row(r, "Pendiente") for r in temp] + \
               [self._line_row(r, "Confirmado") for r in conf]
        # newest first (ORDER BY CreatedAt DESC)
        rows.sort(key=lambda r: r["CreatedAt"], reverse=True)
        return rows

    def list_pending_grouped(self) -> list[dict]:
        rows = self._conn.execute(
            "SELECT * FROM RegistroProduccion_Temp ORDER BY ProductionOrderNo, CreatedAt DESC"
        ).fetchall()
        groups: dict[str, dict] = {}
        for r in rows:
            line = self._line_row(r, "Pendiente")
            op_no = line["ProductionOrderNo"]
            g = groups.setdefault(op_no, {
                "op": op_no,
                "item_description": line["ItemDescription"],
                "lineas": [],
                "total_horas": 0.0,
                "total_unidades": 0.0,
            })
            g["lineas"].append(line)
            g["total_horas"] = round(g["total_horas"] + line["TotalHoras"], 2)
            g["total_unidades"] = round(g["total_unidades"] + line["TotalUnidadesProducidas"], 2)
        return [groups[k] for k in sorted(groups)]

    def get_pending_line(self, temp_id: int) -> Optional[dict]:
        row = self._conn.execute(
            "SELECT * FROM RegistroProduccion_Temp WHERE RegistroProduccionTempId = ?",
            (temp_id,),
        ).fetchone()
        return self._line_row(row, "Pendiente") if row else None

    # -- mutations ------------------------------------------------------------
    def insert_line(self, data: dict, username: str) -> int:
        op = self.get_op(data["op"])  # snapshot source (may be None if closed)
        snap = op or {}
        cur = self._conn.execute(
            """INSERT INTO RegistroProduccion_Temp
               (ProductionOrderNo, HoraInicio, HoraFin, NumPersonas,
                TotalUnidadesProducidas, TipoTrabajo, Comentarios, FechaRegistro,
                CreatedAt, CreatedBy, ItemNo, ItemDescription, LocationCode,
                RoutingNo, MachineCenterNo, CantidadPlanificada)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                data["op"], _t(data["hora_inicio"]), _t(data["hora_fin"]),
                data["num_personas"], data["unidades"], data["tipo_trabajo"],
                data["comentarios"], _d(data["fecha"]),
                datetime.utcnow().isoformat(sep=" ", timespec="microseconds"),
                username,
                snap.get("ItemNo"), snap.get("ItemDescription"), snap.get("LocationCode"),
                snap.get("RoutingNo"), snap.get("MachineCenterNo"), snap.get("CantidadPlanificada"),
            ),
        )
        self._conn.commit()
        return int(cur.lastrowid)

    def update_line(self, temp_id: int, data: dict, username: str) -> bool:
        cur = self._conn.execute(
            """UPDATE RegistroProduccion_Temp
               SET HoraInicio=?, HoraFin=?, NumPersonas=?, TotalUnidadesProducidas=?,
                   TipoTrabajo=?, Comentarios=?, FechaRegistro=?, ModifiedAt=?, ModifiedBy=?
               WHERE RegistroProduccionTempId = ?""",
            (
                _t(data["hora_inicio"]), _t(data["hora_fin"]), data["num_personas"],
                data["unidades"], data["tipo_trabajo"], data["comentarios"],
                _d(data["fecha"]),
                datetime.utcnow().isoformat(sep=" ", timespec="microseconds"),
                username, temp_id,
            ),
        )
        self._conn.commit()
        return cur.rowcount > 0

    def delete_line(self, temp_id: int) -> bool:
        cur = self._conn.execute(
            "DELETE FROM RegistroProduccion_Temp WHERE RegistroProduccionTempId = ?",
            (temp_id,),
        )
        self._conn.commit()
        return cur.rowcount > 0

    def validate_op(self, op_no: str, username: str) -> int:
        c = self._conn
        try:
            c.execute("BEGIN")
            now = datetime.utcnow().isoformat(sep=" ", timespec="microseconds")
            # Step 1: copy, with the anti-duplicate guard from spec §3.5.
            c.execute(
                """INSERT INTO RegistroProduccion
                   (ProductionOrderNo, HoraInicio, HoraFin, NumPersonas,
                    TotalUnidadesProducidas, TipoTrabajo, Comentarios, FechaRegistro,
                    CreatedAt, CreatedBy, ModifiedAt, ModifiedBy, ItemNo,
                    ItemDescription, LocationCode, RoutingNo, MachineCenterNo,
                    CantidadPlanificada)
                   SELECT t.ProductionOrderNo, t.HoraInicio, t.HoraFin, t.NumPersonas,
                          t.TotalUnidadesProducidas, t.TipoTrabajo, t.Comentarios,
                          t.FechaRegistro, t.CreatedAt, t.CreatedBy, ?, ?, t.ItemNo,
                          t.ItemDescription, t.LocationCode, t.RoutingNo,
                          t.MachineCenterNo, t.CantidadPlanificada
                   FROM RegistroProduccion_Temp t
                   WHERE t.ProductionOrderNo = ?
                     AND NOT EXISTS (
                         SELECT 1 FROM RegistroProduccion r
                         WHERE r.ProductionOrderNo = t.ProductionOrderNo
                           AND r.FechaRegistro = t.FechaRegistro
                           AND r.HoraInicio = t.HoraInicio
                           AND r.HoraFin = t.HoraFin
                           AND r.CreatedAt = t.CreatedAt
                     )""",
                (now, username, op_no),
            )
            promoted = c.execute(
                "SELECT COUNT(*) FROM RegistroProduccion_Temp WHERE ProductionOrderNo = ?",
                (op_no,),
            ).fetchone()[0]
            # Step 2: delete from the temp table.
            c.execute(
                "DELETE FROM RegistroProduccion_Temp WHERE ProductionOrderNo = ?",
                (op_no,),
            )
            c.commit()
            return int(promoted)
        except Exception:
            c.rollback()
            raise

    # -- users ----------------------------------------------------------------
    def get_user(self, username: str) -> Optional[dict]:
        row = self._conn.execute(
            "SELECT * FROM AppUsers WHERE Username = ?", (username,)
        ).fetchone()
        if not row:
            return None
        return {
            "username": row["Username"],
            "display_name": row["DisplayName"],
            "password_hash": row["PasswordHash"],
            "role": row["Role"],
            "is_active": bool(row["IsActive"]),
        }

    def count_users(self) -> int:
        return int(self._conn.execute("SELECT COUNT(*) FROM AppUsers").fetchone()[0])

    def create_user(self, username: str, password_hash: str, display_name: str, role: str) -> None:
        self._conn.execute(
            """INSERT INTO AppUsers (Username, DisplayName, PasswordHash, Role, IsActive, CreatedAt)
               VALUES (?,?,?,?,1,?)""",
            (username, display_name, password_hash, role,
             datetime.utcnow().isoformat(sep=" ", timespec="microseconds")),
        )
        self._conn.commit()
