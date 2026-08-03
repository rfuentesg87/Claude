"""Repository + business-rule tests (SQLite backend)."""
import os
import sys
import unittest
from datetime import date, time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.constants import ValidationError, clean_line_payload
from app.repository.sqlite_repo import SQLiteRepository


def _payload(op="PO-000123", **over):
    base = dict(op=op, fecha="2026-08-03", horaInicio="08:00", horaFin="12:30",
                numPersonas="3", tipoTrabajo="005 Preparación", unidades="120",
                comentarios="turno mañana")
    base.update(over)
    return clean_line_payload(base)


class ValidationTests(unittest.TestCase):
    def test_unidades_optional_defaults_zero(self):
        self.assertEqual(_payload(unidades="")["unidades"], 0.0)
        self.assertEqual(_payload(unidades=None)["unidades"], 0.0)

    def test_horafin_must_be_after_inicio(self):
        with self.assertRaises(ValidationError):
            _payload(horaInicio="12:00", horaFin="08:00")

    def test_numpersonas_min_one(self):
        with self.assertRaises(ValidationError):
            _payload(numPersonas="0")

    def test_tipo_trabajo_closed_list(self):
        with self.assertRaises(ValidationError):
            _payload(tipoTrabajo="Etiquetado")  # legacy, not allowed for new rows
        self.assertIsNone(_payload(tipoTrabajo="")["tipo_trabajo"])

    def test_negative_units_rejected(self):
        with self.assertRaises(ValidationError):
            _payload(unidades="-5")


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.repo = SQLiteRepository(":memory:", seed=True)

    def test_seeded_open_ops(self):
        ops = self.repo.list_open_ops()
        self.assertTrue(any(o["ProductionOrderNo"] == "PO-000123" for o in ops))
        self.assertIn("OPDisplayLabel", ops[0])

    def test_insert_captures_snapshot(self):
        new_id = self.repo.insert_line(_payload(), "irene")
        line = self.repo.get_pending_line(new_id)
        self.assertEqual(line["Estado"], "Pendiente")
        self.assertEqual(line["ItemNo"], "ART-001")          # snapshot from OP
        self.assertEqual(line["ItemDescription"], "Barrita energética avena 40g")
        self.assertEqual(line["CreatedBy"], "irene")         # real user, not 'n8n'
        self.assertAlmostEqual(line["TotalHoras"], 4.5)      # 08:00->12:30

    def test_history_totals(self):
        self.repo.insert_line(_payload(horaInicio="08:00", horaFin="10:00", unidades="50"), "u")
        self.repo.insert_line(_payload(horaInicio="10:00", horaFin="12:00", unidades="70"), "u")
        hist = self.repo.get_history_for_op("PO-000123")
        self.assertEqual(len(hist), 2)
        total_h = sum(l["TotalHoras"] for l in hist)
        total_u = sum(l["TotalUnidadesProducidas"] for l in hist)
        self.assertAlmostEqual(total_h, 4.0)
        self.assertAlmostEqual(total_u, 120.0)

    def test_update_line(self):
        nid = self.repo.insert_line(_payload(), "u")
        ok = self.repo.update_line(nid, _payload(numPersonas="5", unidades="200"), "pilar")
        self.assertTrue(ok)
        line = self.repo.get_pending_line(nid)
        self.assertEqual(line["NumPersonas"], 5)
        self.assertEqual(line["TotalUnidadesProducidas"], 200)
        self.assertEqual(line["ModifiedBy"], "pilar")

    def test_delete_line(self):
        nid = self.repo.insert_line(_payload(), "u")
        self.assertTrue(self.repo.delete_line(nid))
        self.assertIsNone(self.repo.get_pending_line(nid))
        self.assertFalse(self.repo.delete_line(nid))  # already gone

    def test_validate_moves_to_confirmed(self):
        self.repo.insert_line(_payload(horaInicio="08:00", horaFin="09:00"), "u")
        self.repo.insert_line(_payload(horaInicio="09:00", horaFin="10:00"), "u")
        promoted = self.repo.validate_op("PO-000123", "planta")
        self.assertEqual(promoted, 2)
        hist = self.repo.get_history_for_op("PO-000123")
        self.assertEqual(len(hist), 2)
        self.assertTrue(all(l["Estado"] == "Confirmado" for l in hist))
        self.assertTrue(all(l["ModifiedBy"] == "planta" for l in hist))
        # temp table is now empty for this OP
        self.assertEqual(self.repo.list_pending_grouped(), [])

    def test_validate_nothing_returns_zero(self):
        self.assertEqual(self.repo.validate_op("PO-000999", "planta"), 0)

    def test_pending_survives_closed_op(self):
        # Insert a line for an OP that is NOT in the open-OPs view.
        nid = self.repo.insert_line(_payload(op="PO-CLOSED"), "u")
        self.assertIsNotNone(nid)
        grupos = self.repo.list_pending_grouped()
        ops = [g["op"] for g in grupos]
        self.assertIn("PO-CLOSED", ops)

    def test_pending_grouped_totals(self):
        self.repo.insert_line(_payload(horaInicio="08:00", horaFin="12:00", unidades="100"), "u")
        self.repo.insert_line(_payload(op="PO-000124", horaInicio="08:00", horaFin="09:00", unidades="10"), "u")
        grupos = {g["op"]: g for g in self.repo.list_pending_grouped()}
        self.assertAlmostEqual(grupos["PO-000123"]["total_horas"], 4.0)
        self.assertAlmostEqual(grupos["PO-000123"]["total_unidades"], 100.0)
        self.assertEqual(len(grupos["PO-000124"]["lineas"]), 1)


if __name__ == "__main__":
    unittest.main()
