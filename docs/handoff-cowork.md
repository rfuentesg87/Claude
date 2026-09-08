# Traspaso de la sesión a Cowork

Este fichero es el punto de entrada para seguir el proyecto desde Cowork, en la máquina
de Rodrigo, donde sí está conectado el MCP de SQL. Escrito el 8 de septiembre de 2026 al
final de la primera sesión de Claude Code en la nube.

**Leer primero `CLAUDE.md`.** Ahí están el contexto, las diez reglas de oro y las
decisiones cerradas, que no hay que volver a abrir. Este fichero solo cuenta en qué punto
estamos y qué toca ahora.

---

## Estado en una página

El paquete de arranque está en el repositorio, **revisado y sin ejecutar**. Ningún script
se ha aplicado contra la base de datos, y no se ha tocado nada en producción.

Lo que se hizo en la sesión de la nube:

1. **Revisión crítica de `db/01`–`db/06`** → `docs/revision-scripts-db.md`. Ocho
   bloqueantes y once puntos importantes. Los tres que más pesan: `crm_v.ClienteCronologia`
   está roto por un `UNION ALL` con `NULL` sin tipar; n8n escribe con la RLS puesta y sin
   contexto de sesión, así que pierde datos en silencio; y cinco tablas con datos de
   cliente están fuera de la política de RLS, entre ellas `core.Contacto`, que además está
   expuesta en `dab-config.json` con permiso de borrado para el rol comercial.
2. **Capa base del ERP** → `db/00_vistas_base_erp.sql`. En `gold` solo se leen vistas; las
   tablas no se actualizan. Los scripts 02 y 06 se reescribieron para consumir
   `crm_v.Erp*` y ya no nombran ninguna tabla de `gold`. Es la regla de oro 10.
3. **Dos prototipos navegables** en `web/prototipos/`: la ficha de empresa y la home del
   comercial, con datos de ejemplo y el mismo sistema de tokens CSS.
4. **Comprobaciones previas** → `db/comprobaciones_previas.sql`, sin ejecutar.

### Qué está verificado y qué no

Verificado, porque sale del SQL que ya corre en producción en los workflows de n8n
(informe mensual de ventas):

- Las columnas de `bc` llevan puntos y espacios: `[No.]`, `[Sell-to Customer No.]`,
  `[Document Type]`, `[Outstanding Quantity]`, `[Shipment Date]`, `[Order Date]`.
- `bc` es **multiempresa**: todas las tablas llevan `[$company]` y hay que unir por ella.
- La cartera de pedidos viva es `bc.[Sales Line]` con `[Document Type] = 1` y
  `[Outstanding Quantity] <> 0`, unida a `bc.[Sales Header]`.

Verificado contra el servidor, por el error que devolvió:

- La base de datos usa la collation `Latin1_General_CI_AS_KS_WS` y el catálogo
  `SQL_Latin1_General_CP1_CI_AS`. Es **sensible a acentos**.

**No verificado** — es justo lo primero que hay que hacer en Cowork. Todo lo marcado
`/* CONFIRMAR */` en `db/00_vistas_base_erp.sql`:

- `bc.[Customer]`: `[Salesperson Code]`, `[Country_Region Code]`, `[Blocked]`.
- El nombre real de la tabla de comerciales: `[Salesperson_Purchaser]` o `[Salesperson/Purchaser]`.
- `bc.[Sales Line]`: `[Line No.]`, `[Type]`, `[Quantity]`, `[Quantity Shipped]`, `[Location Code]`.
- `bc.[Item]`: `[Item Category Code]`, `[Base Unit of Measure]`, `[Blocked]`.
- Toda `crm_v.ErpStock` sobre `bc.[Item Ledger Entry]`.
- Qué objetos de `gold` son vistas y cuáles tablas.
- El propietario de los esquemas `crm_v`, `gold` y `bc`.

---

## El primer trabajo en Cowork

Ejecutar `db/comprobaciones_previas.sql` por el MCP de SQL y corregir con la salida los
nombres de columna de `db/00_vistas_base_erp.sql`. Son once comprobaciones de solo
lectura, separadas por `GO` para que un fallo no arrastre a las demás.

Dos de ellas valen por sí solas:

- **La número 6, propietarios de esquema.** Los `DENY` del script 03 sobre `bc` y `gold`
  solo funcionan sin romper la ficha si `crm_v`, `gold` y `bc` comparten propietario. Si
  no, la ficha 360 arranca vacía con «permiso denegado» y parecerá culpa de las vistas.
- **La número 8, cartera por comercial.** Se compara con las cifras de `CLAUDE.md`: PMZ
  452, CGA 187, DLL 112, JNA 100, AGH 50, DPB 36, MPB 16, LBP 9. Toda diferencia es un
  comercial que vería una cartera distinta de la que esperamos, y decide si el bloque de
  alta de usuarios de `db/01` está bien (falta `LBP` y sobra `JSF`).

Después, por orden: B-1 (una línea, desbloquea la cronología), B-5 y A-9 (las dos que
dejan datos al aire), B-2 (obliga a decidir el principal de n8n) y A-1 (decisión de
negocio: si una reasignación de cliente arrastra el histórico o no).

---

## Prompt para arrancar en Cowork

```
Proyecto CRM Jomipsa. Lee CLAUDE.md y docs/handoff-cowork.md antes de nada.

Estamos en la rama claude/proyecto-crm-jomipsa-uz7ct1 del repo rfuentesg87/Claude.
Ningún script se ha ejecutado todavía contra la base de datos.

Primer trabajo: ejecuta db/comprobaciones_previas.sql por el MCP de SQL, que es de
solo lectura, y con la salida corrige los nombres de columna marcados CONFIRMAR en
db/00_vistas_base_erp.sql. Dime qué no cuadra antes de tocar otra cosa.

No ejecutes ningún script de db/ contra la base de datos sin preguntarme. Es
producción y la comparten los pipelines de datos y los paneles que ya están en marcha.

Trabajamos en español.
```

---

## Mapa de ficheros

| Fichero | Qué es |
|---|---|
| `CLAUDE.md` | Contexto, diez reglas de oro, decisiones cerradas. **Lo primero.** |
| `docs/revision-scripts-db.md` | La revisión crítica: 8 bloqueantes, 11 importantes, 12 menores |
| `docs/arquitectura.md` | Documento de arquitectura v2.0. Ojo: anterior a la regla 10 |
| `docs/handoff-cowork.md` | Este fichero |
| `db/comprobaciones_previas.sql` | Once comprobaciones de solo lectura. **Empezar por aquí** |
| `db/00_vistas_base_erp.sql` | Capa base `crm_v.Erp*`: única frontera con el ERP |
| `db/01`–`db/06` | Esquema, vistas de la ficha, RLS, propiedades, M365, presupuestos |
| `db/usuario_solo_lectura.sql` | Usuario de lectura para herramientas y agentes. Comentado |
| `api/dab-config.json` | Data API Builder. **Tiene un agujero: `Contacto` con delete** |
| `web/prototipos/` | Ficha de empresa y home del comercial, con datos de ejemplo |
| `PROMPT-INICIAL.md` | El arranque original. Histórico, ya superado en parte |

Orden de ejecución de la base de datos: **01 → 00 → 02 → 03 → 04 → 05 → 06.**

## Decisiones abiertas, que son de negocio y no técnicas

1. **Reasignación de cliente y histórico.** Cuando dirección cambia el comercial de un
   cliente en BC, ¿el nuevo hereda las visitas, actividades y oportunidades del anterior,
   o no las ve? Hay que elegir antes de la carga inicial, porque determina si el job de
   sincronización toca solo `core.Empresa` o también las tablas hijas.
2. **Multiempresa.** Si `bc` tiene más de una empresa, ¿el CRM ve todas o solo JOMIPSA?
   Se decide en `crm_v.ErpCompania` y en ningún otro sitio.
3. **Higiene de datos.** 58 clientes sin `SalespersonCode` y 100 asignados a JNA, que no
   factura desde 2023. Con la RLS activa no los ve nadie salvo dirección. La home del
   prototipo es donde se va a notar.
4. **El principal de n8n.** Un usuario SQL propio (`crm_sync`) al que los predicados de
   RLS dejen escribir, o los procesos de importación y de escritura a BC fallan en
   silencio.
