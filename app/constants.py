"""Domain constants and shared validation for line records.

Kept separate so both the SQLite and MSSQL backends, the routes, and the tests
share one source of truth for the business rules in spec §4.
"""
from __future__ import annotations

from datetime import date, datetime, time

# Valid "tipo de trabajo" values for NEW rows (spec §4). The empty option is
# also allowed. Legacy values ('Etiquetado', 'Reproceso') are intentionally
# NOT offered for new rows — they only survive in historical data and in the
# CHECK constraint of gold.RegistroProduccion.
TIPO_TRABAJO_OPCIONES = (
    "005 Preparación",
    "010 Fabricación/Comida",
    "006 Reproceso",
)

ESTADO_PENDIENTE = "Pendiente"
ESTADO_CONFIRMADO = "Confirmado"


class ValidationError(ValueError):
    """Raised when a submitted line fails a business rule."""


def _parse_time(value) -> time:
    if isinstance(value, time):
        return value
    if value is None or str(value).strip() == "":
        raise ValidationError("La hora es obligatoria.")
    s = str(value).strip()
    for fmt in ("%H:%M:%S", "%H:%M"):
        try:
            return datetime.strptime(s, fmt).time()
        except ValueError:
            continue
    raise ValidationError(f"Hora con formato inválido: {value!r}")


def _parse_date(value) -> date:
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    if value is None or str(value).strip() == "":
        raise ValidationError("La fecha es obligatoria.")
    s = str(value).strip()
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError as exc:
        raise ValidationError(f"Fecha con formato inválido: {value!r}") from exc


def clean_line_payload(raw: dict) -> dict:
    """Validate and normalise an insert/update payload (spec §3.3, §4).

    Returns a dict with typed values ready for the repository. Raises
    ValidationError with a user-facing Spanish message on the first problem.
    """
    op = (raw.get("op") or "").strip()
    if not op:
        raise ValidationError("Falta la Orden de Producción.")

    fecha = _parse_date(raw.get("fecha"))
    hora_inicio = _parse_time(raw.get("horaInicio"))
    hora_fin = _parse_time(raw.get("horaFin"))
    if hora_fin <= hora_inicio:
        raise ValidationError("La hora de fin debe ser posterior a la hora de inicio.")

    # numPersonas — required, >= 1
    try:
        num_personas = int(raw.get("numPersonas"))
    except (TypeError, ValueError) as exc:
        raise ValidationError("El número de personas es obligatorio.") from exc
    if num_personas < 1:
        raise ValidationError("El número de personas debe ser al menos 1.")

    # unidades — optional; empty -> 0 (column is NOT NULL). Must be >= 0.
    unidades_raw = raw.get("unidades")
    if unidades_raw is None or str(unidades_raw).strip() == "":
        unidades = 0.0
    else:
        try:
            unidades = float(str(unidades_raw).replace(",", "."))
        except ValueError as exc:
            raise ValidationError("Las unidades deben ser un número.") from exc
        if unidades < 0:
            raise ValidationError("Las unidades no pueden ser negativas.")

    # tipoTrabajo — closed list + empty
    tipo = (raw.get("tipoTrabajo") or "").strip()
    if tipo and tipo not in TIPO_TRABAJO_OPCIONES:
        raise ValidationError(f"Tipo de trabajo no válido: {tipo!r}")

    comentarios = raw.get("comentarios")
    comentarios = comentarios.strip() if isinstance(comentarios, str) else None

    return {
        "op": op,
        "fecha": fecha,
        "hora_inicio": hora_inicio,
        "hora_fin": hora_fin,
        "num_personas": num_personas,
        "unidades": round(unidades, 2),
        "tipo_trabajo": tipo or None,
        "comentarios": comentarios or None,
    }
