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
    return p


def main() -> None:
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
