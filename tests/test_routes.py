"""End-to-end route tests via the Flask test client (SQLite, in-memory)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Force an isolated in-memory DB and non-secure cookies before importing config.
os.environ["RHP_SQLITE_PATH"] = ":memory:"
os.environ["RHP_SESSION_COOKIE_SECURE"] = "false"

from app import create_app
from app.auth import ensure_seed_user, hash_password, verify_password
from app.repository.sqlite_repo import SQLiteRepository


class AuthUnitTests(unittest.TestCase):
    def test_hash_roundtrip(self):
        h = hash_password("secret123")
        self.assertTrue(verify_password("secret123", h))
        self.assertFalse(verify_password("wrong", h))
        self.assertFalse(verify_password("secret123", "garbage"))


class RouteTests(unittest.TestCase):
    def setUp(self):
        self.app = create_app()
        # Force a guaranteed-fresh, isolated in-memory DB per test, independent
        # of any RHP_SQLITE_PATH / on-disk dev database.
        self.app.repository = SQLiteRepository(":memory:", seed=True)
        ensure_seed_user(self.app.repository, self.app.app_config)
        self.c = self.app.test_client()

    def _login(self):
        return self.c.post("/login", data={"username": "User", "password": "Cambiar2025!!!"})

    def test_requires_auth(self):
        r = self.c.get("/")
        self.assertEqual(r.status_code, 302)
        self.assertIn("/login", r.headers["Location"])

    def test_bad_login(self):
        r = self.c.post("/login", data={"username": "User", "password": "nope"})
        self.assertEqual(r.status_code, 401)

    def test_registros_unauth_401(self):
        r = self.c.post("/registros", json={"action": "insert", "op": "PO-000123"})
        self.assertEqual(r.status_code, 401)

    def test_full_flow(self):
        self._login()
        # insert
        r = self.c.post("/registros", json={
            "action": "insert", "op": "PO-000123", "fecha": "2026-08-03",
            "horaInicio": "08:00", "horaFin": "12:00", "numPersonas": "3",
            "tipoTrabajo": "005 Preparación", "unidades": "150", "comentarios": "ok",
        })
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.get_json()["ok"])
        tid = r.get_json()["id"]

        # appears in history
        r = self.c.get("/?op=PO-000123")
        self.assertIn(b"150", r.data)

        # edit
        r = self.c.post("/registros", json={
            "action": "update", "id": tid, "op": "PO-000123", "fecha": "2026-08-03",
            "horaInicio": "08:00", "horaFin": "12:00", "numPersonas": "4",
            "tipoTrabajo": "005 Preparación", "unidades": "200", "comentarios": "edit",
        })
        self.assertTrue(r.get_json()["ok"])

        # pending screen shows it
        r = self.c.get("/lineas")
        self.assertIn(b"PO-000123", r.data)
        self.assertIn(b"VALIDAR TODAS LAS L", r.data)

        # validate
        r = self.c.post("/registros/validar", json={"op": "PO-000123"})
        self.assertTrue(r.get_json()["ok"])
        self.assertEqual(r.get_json()["validadas"], 1)

        # now pending screen is empty
        r = self.c.get("/lineas")
        self.assertIn("No hay líneas pendientes".encode("utf-8"), r.data)

    def test_insert_validation_error(self):
        self._login()
        r = self.c.post("/registros", json={
            "action": "insert", "op": "PO-000123", "fecha": "2026-08-03",
            "horaInicio": "12:00", "horaFin": "08:00", "numPersonas": "3",
        })
        self.assertEqual(r.status_code, 400)
        self.assertFalse(r.get_json()["ok"])

    def test_delete(self):
        self._login()
        r = self.c.post("/registros", json={
            "action": "insert", "op": "PO-000124", "fecha": "2026-08-03",
            "horaInicio": "08:00", "horaFin": "09:00", "numPersonas": "1",
        })
        tid = r.get_json()["id"]
        r = self.c.post("/registros/borrar", json={"id": tid})
        self.assertTrue(r.get_json()["ok"])
        r = self.c.post("/registros/borrar", json={"id": tid})
        self.assertEqual(r.status_code, 404)


if __name__ == "__main__":
    unittest.main()
