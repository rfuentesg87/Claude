"""HTTP routes (spec §3)."""
from __future__ import annotations

from flask import (
    Blueprint, current_app, g, jsonify, redirect, render_template, request,
    session, url_for,
)

from .auth import authenticate, current_user, login_required, login_user, logout_user
from .constants import TIPO_TRABAJO_OPCIONES, ValidationError, clean_line_payload

bp = Blueprint("main", __name__)


def repo():
    return current_app.repository


def _totales(lineas):
    return {
        "horas": round(sum(float(l["TotalHoras"] or 0) for l in lineas), 2),
        "unidades": round(sum(float(l["TotalUnidadesProducidas"] or 0) for l in lineas), 2),
    }


# --- Auth -------------------------------------------------------------------
@bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user() is not None:
        return redirect(url_for("main.index"))
    error = None
    if request.method == "POST":
        username = (request.form.get("username") or "").strip()
        password = request.form.get("password") or ""
        user = authenticate(repo(), username, password)
        if user:
            login_user(user)
            nxt = request.args.get("next") or request.form.get("next")
            if nxt and nxt.startswith("/") and not nxt.startswith("//"):
                return redirect(nxt)
            return redirect(url_for("main.index"))
        error = "Usuario o contraseña incorrectos."
    return render_template("login.html", error=error), (401 if error else 200)


@bp.route("/logout", methods=["GET", "POST"])
def logout():
    logout_user()
    return redirect(url_for("main.login"))


# --- Main screen (alta + histórico de una OP) -------------------------------
@bp.route("/", methods=["GET"])
@login_required
def index():
    r = repo()
    ops = r.list_open_ops()
    selected_op = (request.args.get("op") or "").strip() or None
    edit_id = request.args.get("edit")

    history, op_info, totales, edit_line = [], None, None, None
    if selected_op:
        op_info = r.get_op(selected_op)
        history = r.get_history_for_op(selected_op)
        totales = _totales(history)
        tiene_pendientes = any(l["Estado"] == "Pendiente" for l in history)
    else:
        tiene_pendientes = False

    if edit_id:
        try:
            edit_line = r.get_pending_line(int(edit_id))
        except (TypeError, ValueError):
            edit_line = None

    return render_template(
        "index.html",
        user=g.current_user,
        ops=ops,
        selected_op=selected_op,
        op_info=op_info,
        history=history,
        totales=totales,
        tiene_pendientes=tiene_pendientes,
        edit_line=edit_line,
        tipos=TIPO_TRABAJO_OPCIONES,
    )


# --- Pending lines screen ---------------------------------------------------
@bp.route("/lineas", methods=["GET"])
@login_required
def lineas():
    grupos = repo().list_pending_grouped()
    return render_template("lineas.html", user=g.current_user, grupos=grupos)


# --- Mutations (JSON) -------------------------------------------------------
@bp.route("/registros", methods=["POST"])
@login_required
def registros():
    payload = request.get_json(silent=True) or request.form.to_dict()
    action = (payload.get("action") or "insert").strip()
    username = g.current_user["username"]
    try:
        data = clean_line_payload(payload)
    except ValidationError as exc:
        return jsonify(ok=False, error=str(exc)), 400

    if action == "insert":
        new_id = repo().insert_line(data, username)
        return jsonify(ok=True, id=new_id, op=data["op"])

    if action == "update":
        try:
            temp_id = int(payload.get("id"))
        except (TypeError, ValueError):
            return jsonify(ok=False, error="Falta el id de la línea a editar."), 400
        # Only pending lines exist in the temp table, so a successful update is
        # implicitly restricted to 'Pendiente'.
        if not repo().get_pending_line(temp_id):
            return jsonify(ok=False, error="La línea no existe o ya fue validada."), 404
        repo().update_line(temp_id, data, username)
        return jsonify(ok=True, id=temp_id, op=data["op"])

    return jsonify(ok=False, error=f"Acción no válida: {action!r}"), 400


@bp.route("/registros/borrar", methods=["POST"])
@login_required
def borrar():
    payload = request.get_json(silent=True) or request.form.to_dict()
    try:
        temp_id = int(payload.get("id"))
    except (TypeError, ValueError):
        return jsonify(ok=False, error="Falta el id de la línea."), 400
    deleted = repo().delete_line(temp_id)
    if not deleted:
        return jsonify(ok=False, error="La línea no existe o ya fue validada."), 404
    return jsonify(ok=True, id=temp_id)


@bp.route("/registros/validar", methods=["POST"])
@login_required
def validar():
    payload = request.get_json(silent=True) or request.form.to_dict()
    op = (payload.get("op") or "").strip()
    if not op:
        return jsonify(ok=False, error="Falta la Orden de Producción."), 400
    username = g.current_user["username"]
    try:
        promoted = repo().validate_op(op, username)
    except Exception as exc:  # pragma: no cover - surfaced to the UI
        current_app.logger.exception("validate_op failed for %s", op)
        return jsonify(ok=False, error=f"Error al validar: {exc}"), 500
    if promoted == 0:
        return jsonify(ok=False, error="No había líneas pendientes para esta OP."), 404
    return jsonify(ok=True, op=op, validadas=promoted)
