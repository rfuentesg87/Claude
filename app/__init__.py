"""Application factory for Registro Horario de Producción."""
from __future__ import annotations

from datetime import date, datetime, time

from flask import Flask

from config import Config
from .auth import ensure_seed_user
from .repository import build_repository


def _fmt_hora(value) -> str:
    if value is None:
        return ""
    if isinstance(value, time):
        return value.strftime("%H:%M")
    s = str(value)
    return s[:5] if len(s) >= 5 else s


def _fmt_fecha(value) -> str:
    if value is None:
        return ""
    if isinstance(value, (date, datetime)):
        return value.strftime("%d/%m/%Y")
    return str(value)


def _fmt_fecha_iso(value) -> str:
    """For <input type=date> value attributes (yyyy-mm-dd)."""
    if value is None:
        return ""
    if isinstance(value, (date, datetime)):
        return value.strftime("%Y-%m-%d")
    return str(value)[:10]


def _fmt_horas_humano(total_horas) -> str:
    """0.0 -> '0h 0min'; 1.5 -> '1h 30min'."""
    if total_horas is None:
        return ""
    minutes = int(round(float(total_horas) * 60))
    return f"{minutes // 60}h {minutes % 60}min"


def _fmt_num(value) -> str:
    """Trim trailing .0 for whole numbers, keep 2 decimals otherwise."""
    if value is None:
        return ""
    f = float(value)
    return str(int(f)) if f == int(f) else f"{f:.2f}"


def create_app(config: type[Config] | None = None) -> Flask:
    config = config or Config
    app = Flask(__name__)
    app.config.from_object(config)

    # Shared repository instance for the app.
    app.repository = build_repository(config)
    app.app_config = config
    ensure_seed_user(app.repository, config)

    # Jinja filters used by the templates.
    app.jinja_env.filters["hora"] = _fmt_hora
    app.jinja_env.filters["fecha"] = _fmt_fecha
    app.jinja_env.filters["fecha_iso"] = _fmt_fecha_iso
    app.jinja_env.filters["horas_humano"] = _fmt_horas_humano
    app.jinja_env.filters["num"] = _fmt_num

    from .routes import bp as main_bp
    app.register_blueprint(main_bp)

    return app
