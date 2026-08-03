"""Authentication (spec §5).

A minimal, real local-auth implementation:
  * Passwords hashed with PBKDF2-HMAC-SHA256 (Python stdlib — no bcrypt/argon2
    dependency needed for this first standalone version).
  * Login state kept in Flask's signed session cookie, hardened via config
    (HttpOnly, SameSite=Lax, Secure).
  * The authenticated username is written to CreatedBy / ModifiedBy, fixing the
    prototype's hard-coded 'n8n' and giving real per-user traceability.

Designed to be swapped for Entra ID / LDAP later: routes only depend on
`current_user()` and `login_required`, and credential checking is isolated in
`verify_password` / `authenticate`.
"""
from __future__ import annotations

import functools
import hashlib
import hmac
import secrets
from typing import Optional

from flask import g, redirect, request, session, url_for

_ALGO = "pbkdf2_sha256"
_ITERATIONS = 240_000


def hash_password(password: str, *, iterations: int = _ITERATIONS) -> str:
    """Return an encoded hash: 'pbkdf2_sha256$<iters>$<salt_hex>$<hash_hex>'."""
    salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return f"{_ALGO}${iterations}${salt.hex()}${dk.hex()}"


def verify_password(password: str, encoded: str) -> bool:
    """Constant-time verification of a password against an encoded hash."""
    try:
        algo, iters_s, salt_hex, hash_hex = encoded.split("$")
        if algo != _ALGO:
            return False
        iterations = int(iters_s)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(hash_hex)
    except (ValueError, AttributeError):
        return False
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return hmac.compare_digest(dk, expected)


def authenticate(repo, username: str, password: str) -> Optional[dict]:
    """Return the user dict on success, else None. Always runs the hash to keep
    timing roughly uniform whether or not the user exists."""
    user = repo.get_user(username) if username else None
    encoded = user["password_hash"] if user else hash_password("__nonexistent__")
    ok = verify_password(password or "", encoded)
    if user and ok and user.get("is_active", True):
        return user
    return None


def login_user(user: dict) -> None:
    session.clear()
    session["username"] = user["username"]
    session["display_name"] = user.get("display_name") or user["username"]
    session["role"] = user.get("role")
    session.permanent = True


def logout_user() -> None:
    session.clear()


def current_user() -> Optional[dict]:
    if "username" not in session:
        return None
    return {
        "username": session["username"],
        "display_name": session.get("display_name"),
        "role": session.get("role"),
    }


def login_required(view):
    @functools.wraps(view)
    def wrapped(*args, **kwargs):
        user = current_user()
        if user is None:
            # 401 for API/JSON callers, redirect to login for browsers.
            if request.path.startswith("/registros") or request.is_json:
                return {"ok": False, "error": "No autenticado."}, 401
            return redirect(url_for("main.login", next=request.full_path))
        g.current_user = user
        return view(*args, **kwargs)

    return wrapped


def ensure_seed_user(repo, config) -> None:
    """Create the first user from config if the users table is empty (spec §5)."""
    if repo.count_users() == 0 and config.DEFAULT_ADMIN_USER:
        repo.create_user(
            username=config.DEFAULT_ADMIN_USER,
            password_hash=hash_password(config.DEFAULT_ADMIN_PASSWORD),
            display_name=config.DEFAULT_ADMIN_USER,
            role=config.DEFAULT_ADMIN_ROLE,
        )
