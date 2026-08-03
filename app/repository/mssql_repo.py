"""Production backend — Azure SQL Server via pyodbc.

Uses the EXACT SQL from the technical spec (§3) against the objects that already
exist in production: the tables `gold.RegistroProduccion[_Temp]`, the views
`gold.vw_PowerApp_OPsAbiertas` / `gold.vw_PowerApp_HistoricoCompleto`, and the
new `gold.AppUsers` table (sql/schema.sql).

Notes preserved from the spec:
  * Every query uses bound parameters (?) — never string interpolation — which
    also sidesteps the comma-escaping problem the n8n prototype had.
  * `TotalHoras` is a PERSISTED computed column: never written directly. The
    history view returns it already computed.
  * `validate_op` promotes lines in TWO separate statements inside ONE
    transaction, because SQL Server rejects `OUTPUT ... INTO` against a table
    with enabled CHECK constraints.

pyodbc is imported lazily so this module (and the test suite) import cleanly on
hosts where the ODBC driver is not installed.
"""
from __future__ import annotations

import decimal
from typing import Optional

from .base import Repository


def _to_py(value):
    if isinstance(value, decimal.Decimal):
        return float(value)
    return value


def _rows_to_dicts(cursor) -> list[dict]:
    cols = [c[0] for c in cursor.description]
    return [{col: _to_py(val) for col, val in zip(cols, row)} for row in cursor.fetchall()]


class MSSQLRepository(Repository):
    def __init__(self, connection_string: str):
        if not connection_string:
            raise ValueError(
                "RHP_MSSQL_CONNECTION_STRING is empty. Set it to a valid pyodbc "
                "connection string when RHP_DB_BACKEND=mssql."
            )
        try:
            import pyodbc  # noqa: F401
        except ImportError as exc:  # pragma: no cover - depends on host
            raise RuntimeError(
                "pyodbc is required for the mssql backend. Install it with "
                "`pip install -r requirements-mssql.txt` and the OS-level "
                "'ODBC Driver 18 for SQL Server'."
            ) from exc
        self._pyodbc = pyodbc
        self._cs = connection_string

    def _connect(self):
        # One short-lived connection per operation: robust and thread-safe for
        # this app's low concurrency. pyodbc defaults to autocommit=False.
        return self._pyodbc.connect(self._cs, autocommit=False)

    # -- OPs ------------------------------------------------------------------
    def list_open_ops(self) -> list[dict]:
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute(
                "SELECT * FROM gold.vw_PowerApp_OPsAbiertas ORDER BY DueDate ASC"
            )
            return _rows_to_dicts(cur)

    def get_op(self, op_no: str) -> Optional[dict]:
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute(
                "SELECT * FROM gold.vw_PowerApp_OPsAbiertas WHERE ProductionOrderNo = ?",
                op_no,
            )
            rows = _rows_to_dicts(cur)
            return rows[0] if rows else None

    # -- history --------------------------------------------------------------
    def get_history_for_op(self, op_no: str) -> list[dict]:
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute(
                "SELECT * FROM gold.vw_PowerApp_HistoricoCompleto "
                "WHERE ProductionOrderNo = ? ORDER BY CreatedAt DESC",
                op_no,
            )
            return _rows_to_dicts(cur)

    def list_pending_grouped(self) -> list[dict]:
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute(
                "SELECT * FROM gold.vw_PowerApp_HistoricoCompleto "
                "WHERE Estado = 'Pendiente' ORDER BY ProductionOrderNo, CreatedAt DESC"
            )
            lines = _rows_to_dicts(cur)
        groups: dict[str, dict] = {}
        for line in lines:
            op_no = line["ProductionOrderNo"]
            g = groups.setdefault(op_no, {
                "op": op_no,
                "item_description": line.get("ItemDescription"),
                "lineas": [],
                "total_horas": 0.0,
                "total_unidades": 0.0,
            })
            g["lineas"].append(line)
            g["total_horas"] = round(g["total_horas"] + (line.get("TotalHoras") or 0), 2)
            g["total_unidades"] = round(g["total_unidades"] + (line.get("TotalUnidadesProducidas") or 0), 2)
        return [groups[k] for k in sorted(groups)]

    def get_pending_line(self, temp_id: int) -> Optional[dict]:
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute(
                "SELECT * FROM gold.vw_PowerApp_HistoricoCompleto "
                "WHERE Estado = 'Pendiente' AND RegistroProduccionTempId = ?",
                temp_id,
            )
            rows = _rows_to_dicts(cur)
            return rows[0] if rows else None

    # -- mutations ------------------------------------------------------------
    def insert_line(self, data: dict, username: str) -> int:
        sql = (
            "SET NOCOUNT ON; "
            "INSERT INTO gold.RegistroProduccion_Temp "
            "(ProductionOrderNo, HoraInicio, HoraFin, NumPersonas, TotalUnidadesProducidas, "
            " TipoTrabajo, Comentarios, FechaRegistro, CreatedAt, CreatedBy, "
            " ItemNo, ItemDescription, LocationCode, RoutingNo, MachineCenterNo, CantidadPlanificada) "
            "SELECT ?, ?, ?, ?, COALESCE(?, 0), ?, ?, ?, GETDATE(), ?, "
            "       op.ItemNo, op.ItemDescription, op.LocationCode, op.RoutingNo, "
            "       op.MachineCenterNo, op.CantidadPlanificada "
            "FROM (SELECT 1 AS x) b "
            "LEFT JOIN gold.vw_PowerApp_OPsAbiertas op ON op.ProductionOrderNo = ?; "
            "SELECT CAST(SCOPE_IDENTITY() AS INT) AS NewId;"
        )
        params = (
            data["op"], data["hora_inicio"], data["hora_fin"], data["num_personas"],
            data["unidades"], data["tipo_trabajo"], data["comentarios"], data["fecha"],
            username, data["op"],
        )
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute(sql, params)
            while cur.description is None:
                if not cur.nextset():
                    break
            new_id = cur.fetchone()[0] if cur.description is not None else None
            cn.commit()
            return int(new_id) if new_id is not None else 0

    def update_line(self, temp_id: int, data: dict, username: str) -> bool:
        sql = (
            "UPDATE gold.RegistroProduccion_Temp "
            "SET HoraInicio=?, HoraFin=?, NumPersonas=?, "
            "    TotalUnidadesProducidas=COALESCE(?,0), TipoTrabajo=?, "
            "    Comentarios=?, FechaRegistro=?, ModifiedAt=GETDATE(), ModifiedBy=? "
            "WHERE RegistroProduccionTempId = ?"
        )
        params = (
            data["hora_inicio"], data["hora_fin"], data["num_personas"],
            data["unidades"], data["tipo_trabajo"], data["comentarios"],
            data["fecha"], username, temp_id,
        )
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute(sql, params)
            affected = cur.rowcount
            cn.commit()
            return affected > 0

    def delete_line(self, temp_id: int) -> bool:
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute(
                "DELETE FROM gold.RegistroProduccion_Temp WHERE RegistroProduccionTempId = ?",
                temp_id,
            )
            affected = cur.rowcount
            cn.commit()
            return affected > 0

    def validate_op(self, op_no: str, username: str) -> int:
        insert_sql = (
            "INSERT INTO gold.RegistroProduccion "
            "(ProductionOrderNo, HoraInicio, HoraFin, NumPersonas, TotalUnidadesProducidas, "
            " TipoTrabajo, Comentarios, FechaRegistro, CreatedAt, CreatedBy, ModifiedAt, ModifiedBy, "
            " ItemNo, ItemDescription, LocationCode, RoutingNo, MachineCenterNo, CantidadPlanificada) "
            "SELECT t.ProductionOrderNo, t.HoraInicio, t.HoraFin, t.NumPersonas, t.TotalUnidadesProducidas, "
            "       t.TipoTrabajo, t.Comentarios, t.FechaRegistro, t.CreatedAt, t.CreatedBy, "
            "       GETDATE(), ?, "
            "       t.ItemNo, t.ItemDescription, t.LocationCode, t.RoutingNo, t.MachineCenterNo, t.CantidadPlanificada "
            "FROM gold.RegistroProduccion_Temp t "
            "WHERE t.ProductionOrderNo = ? "
            "  AND NOT EXISTS ( "
            "      SELECT 1 FROM gold.RegistroProduccion r "
            "      WHERE r.ProductionOrderNo = t.ProductionOrderNo AND r.FechaRegistro = t.FechaRegistro "
            "        AND r.HoraInicio = t.HoraInicio AND r.HoraFin = t.HoraFin AND r.CreatedAt = t.CreatedAt "
            "  )"
        )
        with self._connect() as cn:
            cur = cn.cursor()
            try:
                promoted = cur.execute(
                    "SELECT COUNT(*) FROM gold.RegistroProduccion_Temp WHERE ProductionOrderNo = ?",
                    op_no,
                ).fetchone()[0]
                # Step 1: copy (guarded against duplicates on retry).
                cur.execute(insert_sql, (username, op_no))
                # Step 2: delete from temp — only reached if step 1 didn't raise.
                cur.execute(
                    "DELETE FROM gold.RegistroProduccion_Temp WHERE ProductionOrderNo = ?",
                    op_no,
                )
                cn.commit()
                return int(promoted)
            except Exception:
                cn.rollback()
                raise

    # -- users ----------------------------------------------------------------
    def get_user(self, username: str) -> Optional[dict]:
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute(
                "SELECT Username, DisplayName, PasswordHash, Role, IsActive "
                "FROM gold.AppUsers WHERE Username = ?",
                username,
            )
            row = cur.fetchone()
            if not row:
                return None
            return {
                "username": row[0],
                "display_name": row[1],
                "password_hash": row[2],
                "role": row[3],
                "is_active": bool(row[4]),
            }

    def count_users(self) -> int:
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute("SELECT COUNT(*) FROM gold.AppUsers")
            return int(cur.fetchone()[0])

    def create_user(self, username: str, password_hash: str, display_name: str, role: str) -> None:
        with self._connect() as cn:
            cur = cn.cursor()
            cur.execute(
                "INSERT INTO gold.AppUsers (Username, DisplayName, PasswordHash, Role, IsActive, CreatedAt) "
                "VALUES (?, ?, ?, ?, 1, SYSUTCDATETIME())",
                username, display_name, password_hash, role,
            )
            cn.commit()
