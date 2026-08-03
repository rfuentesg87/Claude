"use strict";

// ---- Flash messages --------------------------------------------------------
function flash(message, kind) {
  const el = document.getElementById("flash");
  if (!el) { alert(message); return; }
  el.textContent = message;
  el.className = "flash flash-" + (kind || "info");
  el.hidden = false;
}

async function postJSON(url, body) {
  const resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  let data = {};
  try { data = await resp.json(); } catch (e) { /* ignore */ }
  return { ok: resp.ok, status: resp.status, data };
}

// ---- OP search filter (client-side, spec §3.1) -----------------------------
function initOpSearch() {
  const search = document.getElementById("op-search");
  if (!search) return;
  search.addEventListener("input", () => {
    const q = search.value.trim().toLowerCase();
    document.querySelectorAll(".op-list li").forEach((li) => {
      const item = li.querySelector(".op-item");
      if (!item) return;
      const hay = item.getAttribute("data-search") || "";
      li.style.display = q === "" || hay.includes(q) ? "" : "none";
    });
  });
}

// ---- Live "Xh Ymin" calculation --------------------------------------------
function minutesBetween(inicio, fin) {
  if (!inicio || !fin) return null;
  const [h1, m1] = inicio.split(":").map(Number);
  const [h2, m2] = fin.split(":").map(Number);
  return (h2 * 60 + m2) - (h1 * 60 + m1);
}

function initLineForm() {
  const form = document.getElementById("line-form");
  if (!form) return;

  const fecha = form.querySelector('input[name="fecha"]');
  const inicio = form.querySelector('input[name="horaInicio"]');
  const fin = form.querySelector('input[name="horaFin"]');
  const calc = document.getElementById("calc-horas");

  // Default date = browser's local today (spec §4), only if empty (not editing).
  if (fecha && !fecha.value) {
    const now = new Date();
    const iso = now.getFullYear() + "-" +
      String(now.getMonth() + 1).padStart(2, "0") + "-" +
      String(now.getDate()).padStart(2, "0");
    fecha.value = iso;
  }

  function updateCalc() {
    const mins = minutesBetween(inicio.value, fin.value);
    if (calc) {
      if (mins === null || mins <= 0) { calc.textContent = "0h 0min"; return; }
      calc.textContent = Math.floor(mins / 60) + "h " + (mins % 60) + "min";
    }
  }
  inicio.addEventListener("input", updateCalc);
  fin.addEventListener("input", updateCalc);
  updateCalc();

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const mins = minutesBetween(inicio.value, fin.value);
    if (mins === null || mins <= 0) {
      flash("La hora de fin debe ser posterior a la de inicio.", "error");
      return;
    }
    const fd = new FormData(form);
    const body = {
      action: form.getAttribute("data-mode"),
      op: form.getAttribute("data-op"),
      id: form.getAttribute("data-id") || undefined,
      fecha: fd.get("fecha"),
      horaInicio: fd.get("horaInicio"),
      horaFin: fd.get("horaFin"),
      numPersonas: fd.get("numPersonas"),
      tipoTrabajo: fd.get("tipoTrabajo"),
      unidades: fd.get("unidades"),
      comentarios: fd.get("comentarios"),
    };
    const btn = form.querySelector('button[type="submit"]');
    btn.disabled = true;
    const { ok, data } = await postJSON("/registros", body);
    if (ok && data.ok) {
      // Reload the OP so the history table and totals refresh.
      window.location = "/?op=" + encodeURIComponent(body.op);
    } else {
      btn.disabled = false;
      flash(data.error || "No se pudo guardar la línea.", "error");
    }
  });
}

// ---- Delete a pending line -------------------------------------------------
function initDeleteButtons() {
  document.querySelectorAll(".btn-borrar").forEach((btn) => {
    btn.addEventListener("click", async () => {
      if (!confirm("¿Borrar esta línea pendiente? Esta acción no se puede deshacer.")) return;
      const id = btn.getAttribute("data-id");
      const { ok, data } = await postJSON("/registros/borrar", { id });
      if (ok && data.ok) {
        window.location.reload();
      } else {
        flash(data.error || "No se pudo borrar la línea.", "error");
      }
    });
  });
}

// ---- Validate all lines of an OP (irreversible, spec §3.5) -----------------
function initValidateButtons() {
  document.querySelectorAll(".btn-validar").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const op = btn.getAttribute("data-op");
      const count = btn.getAttribute("data-count");
      const msg = "Vas a VALIDAR " + count + " línea(s) de la OP " + op +
        ".\n\nUna vez validadas pasan a ser definitivas y NO se pueden editar ni borrar.\n\n¿Continuar?";
      if (!confirm(msg)) return;
      btn.disabled = true;
      const { ok, data } = await postJSON("/registros/validar", { op });
      if (ok && data.ok) {
        window.location.reload();
      } else {
        btn.disabled = false;
        flash(data.error || "No se pudo validar la OP.", "error");
      }
    });
  });
}

document.addEventListener("DOMContentLoaded", () => {
  initOpSearch();
  initLineForm();
  initDeleteButtons();
  initValidateButtons();
});
