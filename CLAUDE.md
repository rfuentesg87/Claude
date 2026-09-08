# CRM Jomipsa

CRM propio para los seis comerciales de Jomipsa (Jose Miguel Poveda S.A., Mutxamel),
fabricante de raciones militares y productos de ayuda humanitaria.

**Objetivo:** clonar las acciones básicas de HubSpot e ir añadiendo funcionalidad, con
un requisito que manda sobre todo lo demás: **el comercial no debe entrar en Business
Central.** Trabaja solo en el CRM, y el CRM habla con el ERP por debajo.

Módulos: primero comercial, después compras/proveedores, después incidencias.

---

## Reglas de oro

Estas diez reglas salen de investigar la base de datos real. Romper cualquiera de
ellas produce un fallo silencioso que no se detecta hasta que un comercial se queja.

1. **Nunca crear, alterar ni borrar objetos en `bc`, `gold`, `silver`, `snap`,
   `stg_raw`, `stg_curated`, `ctl`, `config`, `helpdesk`, `logistica` ni `pbi`.**
   El CRM vive en `core`, `crm` y `crm_v`. Todas las dependencias van en un sentido:
   `crm_v` → `gold` → `bc`. Esto permite migrar el CRM a otra base de datos con un
   export/import si algún día se sustituye el PDE.

2. **Fuente única de facturación: `gold.vw_FactMargenLineaFactura`** (2018–2026,
   facturas y abonos, coste real), normalizada en `crm_v.VentaLinea`.
   **No usar `gold.vw_FacturacionMensualCliente` ni `gold.vw_ResumenComercialCliente`:**
   solo cubren el año en curso porque leen `bc.[Sales Invoice Line]`, que únicamente
   contiene 2026. Mezclarlas da dos cifras distintas del mismo cliente según la pantalla.

3. **Convenio de signos, verificado contra los datos:**
   - `LineAmount_Neto` ya viene negativo en los abonos → se suma directamente.
   - `Profit_Definitivo` ya viene con el signo correcto → se suma directamente.
   - `Quantity` **no** lleva signo → hay que invertirla en abonos.

4. **La cartera se resuelve contra `crm_v.ErpCliente`**, que lee `bc.[Customer]`: el
   maestro vivo, con la asignación de comercial actual. Nunca contra
   `ComercialAsignado` de la vista de margen, que lleva la asignación histórica de cada
   línea. Caso real: `CL00691` está asignado hoy a LBP pero sus líneas de 2025 llevan
   CGA; filtrando mal, LBP no vería el histórico de su cliente y CGA seguiría viéndolo.

5. **Business Central pone los precios.** El CRM manda cliente, artículos y cantidades;
   BC aplica tarifa, divisa y unidad de medida y devuelve las líneas valoradas. El CRM
   no calcula nunca un precio de venta. Lo que sí calcula el CRM, porque BC no se lo da
   fácil al comercial, es el **margen estimado** cruzando el precio de BC con
   `gold.vw_ProductUnitCost`.

6. **Toda escritura hacia BC pasa por `core.ColaEscrituraBC`.** Nunca una llamada
   síncrona desde la API: si BC está caído, el comercial no se queda con la pantalla
   colgada y no se pierde trabajo. Cada entrada lleva clave de idempotencia; los 4xx
   distintos de 429 son error permanente y no se reintentan.

7. **La seguridad falla cerrada.** Sin contexto de sesión, `core.vw_UsuarioActual` no
   devuelve filas y el usuario no ve nada. Nunca añadir un `OR 1=1` para "arreglar" que
   una pantalla salga vacía en desarrollo: usar
   `EXEC sp_set_session_context @key=N'preferred_username', @value=N'...'`.

8. **Toda tabla con datos de cliente lleva `SalespersonCode`** y entra en la política
   de RLS `core.PoliticaCartera`. Una tabla nueva sin esa columna es una fuga.

9. **Los adjuntos guardan metadatos y URL**, nunca el binario. Los ficheros van a
   SharePoint o Blob Storage.

10. **En `gold` solo se leen VISTAS (`gold.vw_*`).** Las tablas de `gold` —
    `DimCustomer`, `DimSalesperson`, `DimProduct`, `DimDate`, `DimLocation`,
    `FactSalesOrderLine`, `InventorySnapshotCurrent` — **no se actualizan**, así que
    leerlas devuelve cifras viejas sin dar ningún error: el fallo silencioso perfecto.
    Todo lo que el CRM necesita del ERP entra por la capa base `crm_v.Erp*` de
    `db/00_vistas_base_erp.sql`, que lee vistas de `gold` y tablas de `bc`. Ninguna
    otra vista del CRM vuelve a nombrar `gold` ni `bc` directamente.

---

## Arquitectura

```
Internet HTTPS → Cloudflare Tunnel → servidor local (Docker Compose)
                                      ├── Frontend React (móvil primero)
                                      ├── Data API Builder (contenedor)
                                      └── n8n (local)
                                              ↓
                          Azure SQL  sqldb-jomipsapde-prod-westeu-001
                          core.* crm.* crm_v.*   (del CRM, lectura/escritura)
                          gold.* bc.*            (del ERP, solo lectura)
                                              ↓
                                    Business Central API v2.0
```

**Por qué Data API Builder y no un backend a medida:** DAB genera REST y GraphQL sobre
Azure SQL desde un fichero JSON, es open source de Microsoft con licencia MIT, corre
como contenedor, soporta Entra ID nativo y vuelca los claims del token en el
`SESSION_CONTEXT` de SQL Server, que es exactamente lo que necesita la RLS. La API del
CRM es configuración, no código que mantener.

**Por qué n8n no es la API:** no tiene dónde guardar los datos del CRM, no tiene
transacciones, obliga a reimplementar la autorización en cada workflow, no tiene git ni
tests, y cada petición HTTP es una ejecución que guarda su payload entero. n8n se queda
con lo asíncrono: importación de M365, escrituras a BC, IA con OpenRouter, alertas e
informes.

**Regla:** petición síncrona con un comercial esperando → API. Asíncrono, programado,
integraciones e IA → n8n.

---

## Base de datos

Servidor: `sqldb-jomipsapde-prod-westeu-001` (Azure SQL, West Europe).
Alimentado por PDE (Prodware Data Export) desde Business Central. El PDE nunca actúa
sobre la base de datos entera, solo sobre sus tablas.

### Esquemas del CRM

| Esquema | Contenido |
|---|---|
| `core` | Usuario, UsuarioCartera, Empresa, Contacto, Actividad, Tarea, Adjunto, PropiedadDefinicion, PropiedadOpcion, PropiedadHistorico, EmpresaDominio, DominioExcluido, ActividadImportada, SincronizacionBuzon, ColaEscrituraBC |
| `crm` | Etapa, MotivoPerdida, Competidor, Oportunidad, OportunidadLinea, OportunidadCompetidor, OportunidadHistorico, Presupuesto, PresupuestoLinea |
| `crm_v` | Capa de vistas que consume la API. Única frontera con `gold` |

### Capa base de lectura del ERP — `crm_v.Erp*` (script 00)

Única frontera con el ERP. Lo que hay debajo no lo nombra nadie más.

| Vista base | Origen | Sustituye a | Para qué |
|---|---|---|---|
| `crm_v.VentaLinea` | `gold.vw_FactMargenLineaFactura` ✔ vista | — | Facturación y margen 2018–2026. La fuente de todo |
| `crm_v.ErpCliente` | `bc.[Customer]` | `gold.DimCustomer` | Clientes y **cartera actual** (`[Salesperson Code]`) |
| `crm_v.ErpComercial` | `bc.[Salesperson_Purchaser]` | `gold.DimSalesperson` | Nombre del comercial |
| `crm_v.ErpArticulo` | `bc.[Item]` | `gold.DimProduct` | Catálogo |
| `crm_v.ErpPedidoLinea` | `bc.[Sales Line]` + `bc.[Sales Header]` | `gold.FactSalesOrderLine`, `DimDate`, `DimLocation` | Cartera de pedidos y seguimiento |
| `crm_v.ErpCoste` | `gold.vw_ProductUnitCost` ✔ vista | — | Coste para el margen estimado |
| `crm_v.ErpStock` | `bc.[Item Ledger Entry]` | `gold.InventorySnapshotCurrent` | Stock y caducidades. **Pendiente de validar** contra el SQL del panel de logística |
| `crm_v.ErpCompania` | `bc.[Customer]` | — | Empresas de BC en alcance. El único sitio donde se filtra `[$company]` |

`bc.Contact` (3.527 contactos, 2.235 con email) se lee aparte, en la carga inicial de
`core.Contacto`.

**Cartera de pedidos verificada:** `bc.[Sales Line]` con `[Document Type] = 1` y
`[Outstanding Quantity] <> 0`. Es el mismo criterio que el informe mensual de ventas de
n8n, que llena la hoja «Cartera de Pedidos» y lleva meses cuadrando.

### Cifras reales verificadas (septiembre 2026)

- 1.037 clientes activos, relación 1:1 con `IsCurrent = 1` (sin duplicados)
- 7 comerciales con facturación: PMZ (452 clientes), CGA (187), DLL (112), JNA (100,
  sin facturar desde 2023), AGH (50), DPB (36), MPB (16), LBP (9)
- 205 M€ facturados 2018–2026; 2025 cerró en 37,5 M€ con 8,55 M€ de beneficio
- 101 presupuestos en BC entre enero y septiembre de 2026 (~11/mes). PMZ hace 46
- 764 pedidos. `bc.Opportunity` está vacío: el CRM de BC no se usa
- `bc.[Sales Line Discount]` está vacío; los precios salen de `bc.[Sales Price]` (630 filas)
- **Higiene pendiente:** 58 clientes sin `SalespersonCode` y 100 asignados a JNA. Con
  RLS activa esos clientes no los ve nadie salvo dirección

### Convenciones

- PascalCase en español para tablas y columnas (`FechaCreacion`, `EmpresaId`), igual
  que el esquema `helpdesk` que ya existe.
- Vistas de la API en `crm_v` con nombre de entidad (`crm_v.Presupuesto`).
- Procedimientos `usp_VerboObjeto` (`crm.usp_EnviarPresupuestoABC`).
- Cada tabla lleva `FechaCreacion`, `FechaModificacion` y `ROWVERSION` para
  concurrencia optimista.
- Los scripts son idempotentes: `IF OBJECT_ID(...) IS NULL` y `CREATE OR ALTER`.
- `LineNo` y `Date` son palabras reservadas en T-SQL: van entre corchetes.
- **Las columnas de `bc` conservan la notación de Business Central, con puntos y
  espacios:** `[No.]`, `[Sell-to Customer No.]`, `[Document Type]`,
  `[Outstanding Quantity]`. No es `No_`. Siempre entre corchetes.
- **`bc` es multiempresa:** todas las tablas llevan `[$company]` y hay que unir por ella
  además de por la clave. Sin eso, un cliente que exista en dos empresas de BC se cuenta
  dos veces. El alcance se decide en `crm_v.ErpCompania` y en ningún otro sitio.

---

## Estado del proyecto

### Hecho — scripts en `db/`, ejecutar en orden

Orden de ejecución: **01 → 00 → 02 → 03 → 04 → 05 → 06.** El 00 va después del 01
porque necesita el esquema `crm_v`, y antes del 02 porque el 02 se apoya en él.

| Script | Contenido |
|---|---|
| `01_esquemas_ddl.sql` | Esquemas `core`, `crm`, `crm_v` y todas las tablas base |
| `00_vistas_base_erp.sql` | Capa base `crm_v.Erp*`: única frontera con el ERP |
| `02_vistas_ficha360.sql` | `crm_v.VentaLinea`, identidad, cartera y vistas de la ficha |
| `03_seguridad_rls.sql` | Usuario `crm_app`, permisos y política de RLS |
| `04_propiedades_personalizadas.sql` | Propiedades personalizables (definiciones + JSON) |
| `05_autolog_m365.sql` | Importación de emails y reuniones desde Graph |
| `06_presupuestos_pedidos.sql` | Presupuestos, cola de escritura a BC y seguimiento de pedidos |

**Ninguno se ha ejecutado todavía contra la base de datos.** Están verificados columna
a columna contra el esquema real, pero no aplicados.

También hay un prototipo navegable de la ficha de empresa en
`web/prototipos/ficha-empresa.html`, con datos de ejemplo. Sirve como referencia visual
y de estructura, no como código de producción.

### Pendiente de escribir

**`07_formularios.sql`** — generador de formularios conectados al CRM. Diseño acordado:

- `core.Formulario`: clave, nombre, tipo (web / interno / solicitud), destino, publicado,
  asignación, si crea tarea de seguimiento.
- `core.FormularioCampo`: campos con tipo (reutilizar los tipos de
  `core.PropiedadDefinicion`), obligatorio, orden, opciones, y **mapeo a entidad y campo
  del CRM** (`MapeoEntidad` + `MapeoCampo`), incluidas propiedades personalizadas.
- `core.FormularioEnvio`: datos en JSON, email, dominio, origen, estado y las claves
  resueltas.
- `core.usp_ProcesarEnvioFormulario`: **la deduplicación es el requisito explícito del
  usuario.** Tres pasadas: (1) email exacto de contacto existente → enlaza con ese
  contacto y su empresa, no duplica; (2) dominio conocido en `core.EmpresaDominio` →
  empresa existente, contacto nuevo dentro de ella; (3) nada → crea empresa como
  prospecto y contacto. Después aplica los mapeos, crea la actividad y la tarea.

**`08_secuencias.sql`** — secuencias de seguimiento. Diseño acordado:

- `crm.Secuencia`, `crm.SecuenciaPaso` (tipo, días de espera, asunto, cuerpo con
  variables), `crm.Inscripcion` (contacto, estado, paso actual, próxima acción),
  `crm.InscripcionEvento`.
- `crm.usp_AvanzarSecuencias` devuelve a n8n las acciones que tocan ahora; n8n envía
  con Graph `sendMail` **como el propio comercial**, no desde un buzón genérico.
- **Parada automática al recibir respuesta** reutilizando `core.ActividadImportada`:
  si entra un email de un contacto con inscripción activa, se para la secuencia. Es la
  razón por la que la importación de M365 va antes que las secuencias.
- Sin píxel de apertura: no aporta y complica el cumplimiento de RGPD.
- Límite diario por buzón (empezar en 50) y respeto de horario laboral, o Exchange
  empieza a tratar los envíos como correo masivo.

### Bloqueadores

1. **Registro de aplicación en Entra ID para la API de BC.** Sin esto no hay
   presupuestos ni pedidos, que es el corazón de "el comercial no entra en BC". Estuvo
   bloqueado antes: por eso el workflow de OTIF acabó leyendo por MCP SQL en vez de por
   API. Es el primer desbloqueo que hay que conseguir.
2. **Licencias de BC.** Escribir en BC desde el CRM no ahorra licencias: Microsoft
   cuenta el acceso indirecto igual que el directo (regla de multiplexación), y crear
   presupuestos y pedidos requiere licencia completa, no Team Member. Confirmarlo con
   Prodware antes de prometer ahorro de licencias a dirección.
3. **Permisos de Graph** (`Mail.Read`, `Calendars.Read`, `User.Read.All`) con
   consentimiento de administrador, acotados con una *application access policy* de
   Exchange limitada al grupo de comerciales.
4. **Backup propio de `core` + `crm`.** El point-in-time restore de Azure SQL es a
   nivel de base de datos: recuperar `bc` tras un fallo del PDE se llevaría por delante
   los datos del CRM. Montar el export nocturno **antes** de que entre el primer dato real.

---

## Decisiones ya tomadas — no volver a abrirlas

| Tema | Decisión |
|---|---|
| Base de datos | Esquemas propios en el Azure SQL existente, no un Postgres local |
| API | Data API Builder, no Supabase (es Postgres) ni backend a medida ni n8n |
| Autenticación | Entra ID / Microsoft 365, roles por grupos |
| Autorización | RLS en la base de datos, no filtros en el código |
| Acceso | Público con HTTPS, Cloudflare Tunnel preferido a abrir puertos |
| Frontend | Web responsive, móvil primero (el comercial la usa en casa del cliente) |
| Campos | Propiedades personalizables desde la interfaz, no campos fijos |
| Actividad | Registro automático de emails y reuniones desde M365 |
| Precios | Los pone BC |
| Alcance del comercial | Hasta lanzar el pedido en BC y seguirlo desde el CRM |

Fuera de alcance por ahora: marketing automation y campañas.

---

## Entorno

- MCP de SQL Server contra el Azure SQL (lectura) — ya configurado en el equipo de Rodrigo.
- MCP de n8n contra la instancia (`jomipsa.app.n8n.cloud`, con intención de pasarla a local).
- OpenRouter configurado en n8n para la parte de IA.
- Credenciales por variable de entorno. **Nunca commitear cadenas de conexión,
  contraseñas ni el secreto de la aplicación de Entra ID.**

## Estructura del repositorio

```
crm-jomipsa/
├── CLAUDE.md
├── db/           scripts SQL numerados, en orden de ejecución
├── api/          dab-config.json y su docker-compose
├── web/          frontend React + Vite
│   └── prototipos/   referencia visual, no producción
├── n8n/          workflows exportados en JSON
└── docs/         arquitectura.md
```
