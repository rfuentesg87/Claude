"""Small admin CLI for the Registro Horario app.

Examples:
    # Create / reset a user (prompts for password if --password omitted)
    python3 manage.py create-user --username irene --role cadena --name "Irene G."
    python3 manage.py create-user --username jefa --role planta --password "..."

    # Print a PBKDF2 hash for a password (e.g. to seed gold.AppUsers by hand)
    python3 manage.py hash-password --password "..."

The backend (sqlite/mssql) is chosen by the same env vars as the app.
"""
from __future__ import annotations

import argparse
import getpass
import sys

from config import Config
from app.auth import hash_password
from app.repository import build_repository


def _prompt_password(pw: str | None) -> str:
    if pw:
        return pw
    pw1 = getpass.getpass("Contraseña: ")
    pw2 = getpass.getpass("Repite la contraseña: ")
    if pw1 != pw2:
        sys.exit("Las contraseñas no coinciden.")
    if not pw1:
        sys.exit("La contraseña no puede estar vacía.")
    return pw1


def cmd_create_user(args) -> None:
    repo = build_repository(Config)
    if repo.get_user(args.username):
        sys.exit(f"El usuario {args.username!r} ya existe. Elige otro nombre "
                 f"(la edición/reset de usuarios no está implementada en esta versión).")
    password = _prompt_password(args.password)
    repo.create_user(
        username=args.username,
        password_hash=hash_password(password),
        display_name=args.name or args.username,
        role=args.role,
    )
    print(f"Usuario {args.username!r} creado (rol: {args.role}).")


def cmd_hash_password(args) -> None:
    password = _prompt_password(args.password)
    print(hash_password(password))


def cmd_check_db(args) -> None:
    """Read-only connectivity + schema check against the configured backend.

    Verifies that the app can reach the data warehouse and that every object it
    reads from / writes to actually exists, WITHOUT writing anything.
    """
    print(f"Backend: {Config.DB_BACKEND}")
    repo = build_repository(Config)

    ops = repo.list_open_ops()
    print(f"[OK] gold.vw_PowerApp_OPsAbiertas    -> {len(ops)} OPs abiertas")
    if ops:
        print(f"     ejemplo: {ops[0].get('ProductionOrderNo')} · {ops[0].get('ItemDescription')}")

    grupos = repo.list_pending_grouped()
    pendientes = sum(len(g["lineas"]) for g in grupos)
    print(f"[OK] gold.RegistroProduccion_Temp    -> {pendientes} líneas pendientes "
          f"en {len(grupos)} OP(s)")

    try:
        n_users = repo.count_users()
        print(f"[OK] gold.AppUsers                   -> {n_users} usuario(s)")
    except Exception as exc:
        print(f"[!!] gold.AppUsers no accesible: {exc}")
        print("     -> ejecuta la sección 'APP USERS' de sql/schema.sql")

    print("\nLectura verificada. Para probar la ESCRITURA: python3 manage.py test-write --op <OP>")


def cmd_test_write(args) -> None:
    """End-to-end WRITE test against the data warehouse.

    Inserts a clearly-marked test line into gold.RegistroProduccion_Temp,
    reads it back to confirm the OP snapshot was captured, then DELETES it.
    Nothing is validated, so gold.RegistroProduccion is never touched.
    """
    from datetime import date, time

    repo = build_repository(Config)
    print(f"Backend: {Config.DB_BACKEND}")

    op = args.op
    if not op:
        ops = repo.list_open_ops()
        if not ops:
            sys.exit("No hay OPs abiertas; indica una con --op.")
        op = ops[0]["ProductionOrderNo"]
    print(f"OP de prueba: {op}")

    data = {
        "op": op,
        "fecha": date.today(),
        "hora_inicio": time(8, 0),
        "hora_fin": time(8, 1),
        "num_personas": 1,
        "unidades": 0,
        "tipo_trabajo": None,
        "comentarios": "PRUEBA TECNICA - borrar automaticamente",
    }

    new_id = repo.insert_line(data, args.user)
    print(f"[OK] INSERT en gold.RegistroProduccion_Temp -> Id {new_id}")

    line = repo.get_pending_line(new_id)
    if not line:
        sys.exit(f"[!!] La línea {new_id} no se pudo leer de vuelta. Revisa la vista "
                 f"gold.vw_PowerApp_HistoricoCompleto.")
    print(f"[OK] Lectura de vuelta -> CreatedBy={line.get('CreatedBy')!r} "
          f"TotalHoras={line.get('TotalHoras')}")
    print(f"[OK] Snapshot de la OP -> ItemNo={line.get('ItemNo')!r} "
          f"LocationCode={line.get('LocationCode')!r}")
    if not line.get("ItemNo"):
        print("     [aviso] snapshot vacío: la OP no figura como abierta en la vista.")

    if args.keep:
        print(f"\n--keep indicado: la línea {new_id} NO se ha borrado. Bórrala tú "
              f"desde la pantalla de líneas pendientes.")
        return

    if repo.delete_line(new_id):
        print(f"[OK] DELETE de la línea de prueba {new_id} (warehouse limpio)")
    else:
        print(f"[!!] No se pudo borrar la línea {new_id}. BÓRRALA MANUALMENTE.")

    print("\nEscritura verificada de extremo a extremo.")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Admin CLI — Registro Horario de Producción")
    sub = p.add_subparsers(dest="command", required=True)

    cu = sub.add_parser("create-user", help="Create a new app user")
    cu.add_argument("--username", required=True)
    cu.add_argument("--name", default=None, help="Display name")
    cu.add_argument("--role", default="cadena", choices=["cadena", "planta"])
    cu.add_argument("--password", default=None, help="If omitted, prompts securely")
    cu.set_defaults(func=cmd_create_user)

    hp = sub.add_parser("hash-password", help="Print a PBKDF2 hash for a password")
    hp.add_argument("--password", default=None)
    hp.set_defaults(func=cmd_hash_password)

    cd = sub.add_parser("check-db", help="Read-only connectivity/schema check (writes nothing)")
    cd.set_defaults(func=cmd_check_db)

    tw = sub.add_parser("test-write", help="Insert + read back + delete a test line (write test)")
    tw.add_argument("--op", default=None, help="OP to use; defaults to the first open OP")
    tw.add_argument("--user", default="test-escritura", help="Value written to CreatedBy")
    tw.add_argument("--keep", action="store_true", help="Do not delete the test line")
    tw.set_defaults(func=cmd_test_write)
    return p


def main() -> None:
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
