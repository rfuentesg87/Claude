# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

**Registro Horario de Producción (Cadena)** — internal web app where cadena
supervisors register production/time lines per Production Order (OP) and planta
supervisors validate them in bulk. It is the standalone Python reimplementation
of an n8n prototype (`Produccion_control_horario_cadena`). See
[`README.md`](README.md) for setup, deployment and the full business-rule list.

## Stack

- Python 3 + **Flask** + Jinja2 templates (vanilla JS/CSS frontend).
- Database via a **repository abstraction** with two backends:
  - `sqlite` (default) — dev/test, no external deps, self-seeding.
  - `mssql` — production Azure SQL via `pyodbc`, reusing the existing
    `gold.RegistroProduccion[_Temp]` tables and `gold.vw_PowerApp_*` views.
- Auth: local users, PBKDF2 (stdlib) hashing, signed hardened session cookie.

Only Flask is required at runtime (`requirements.txt`); `pyodbc` is production-only
(`requirements-mssql.txt`).

## Commands

```bash
pip install -r requirements.txt
python3 main.py                              # dev server, sqlite backend

python3 -m unittest discover -s tests -v     # tests
python3 manage.py create-user --username x --role cadena   # admin CLI
```

## Architecture

- `main.py` — WSGI `app` + dev entry point.
- `config.py` — env-driven config (`RHP_*`).
- `app/routes.py` — endpoints (spec §3); `app/constants.py` — business validation.
- `app/repository/` — `base.py` interface, `sqlite_repo.py`, `mssql_repo.py`
  (production SQL is the exact SQL from the spec, always parameterized).
- `app/auth.py` — hashing/session; designed to be swapped for Entra ID/LDAP later.
- `app/templates/`, `app/static/` — UI. `sql/schema.sql` — reference DDL.

## Scope note

Business Central *write* integration (spec §7) is intentionally **not**
implemented — only reads were ever verified against BC. Do not add it without
resolving the open questions in the handoff spec (§7, §10).

## Development Branch

Active development happens on feature branches. The current working branch is
`claude/registro-horario-produccion-ij9qp2`.
