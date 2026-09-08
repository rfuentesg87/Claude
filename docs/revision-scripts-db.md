# Revisión crítica de los scripts db/01–06

**Fecha:** 8 de septiembre de 2026
**Alcance:** revisión estática de `db/01`–`db/06`, `api/dab-config.json` y su encaje con las
nueve reglas de oro de `CLAUDE.md`.
**Estado de ejecución:** ninguno de los scripts se ha ejecutado. Nada se ha modificado.

## Cómo se ha hecho esta revisión

Lectura línea a línea, sin acceso a la base de datos. **No se ha podido re-verificar** contra
el esquema real:

- que existan las columnas de `gold.*` y `bc.*` que usan las vistas (`SalespersonName`,
  `BlockedFlag`, `CountryCode`, `OutstandingAmount`, `QtyOnHand`, `ExpirationDate`,
  `LastDirectCost`, `UnitCost_Standard`, `BaseUOM`, `RequestedDeliveryDateSK`…);
- si `gold.DimSalesperson` y `gold.vw_ProductUnitCost` tienen una fila por clave o varias
  (ver M-2);
- el propietario de los esquemas `gold` y `bc` (ver A-6, es el riesgo nº1 al ejecutar el 03);
- las cifras de negocio (1.037 clientes, 205 M€, etc.).

Todo eso hay que comprobarlo con el MCP de SQL de solo lectura antes de aplicar nada.

---

## Bloqueantes — fallan seguro, o fallan en silencio

### B-1. `crm_v.ClienteCronologia` está roto: UNION ALL con `NULL` sin tipar

`db/02_vistas_ficha360.sql`, rama ERP del `UNION ALL`.

La primera rama devuelve `a.Descripcion` (`NVARCHAR(MAX)`) y `u.Nombre` (`NVARCHAR(200)`);
la segunda devuelve `NULL` pelado en esas dos posiciones. Un `NULL` literal sin `CAST` es
`INT`, y en un `UNION` la precedencia de tipos pone `INT` por encima de `NVARCHAR`: SQL Server
intenta convertir el texto a entero y revienta con «Conversion failed when converting the
nvarchar value … to data type int». La cronología es una de las cuatro pestañas de la ficha,
así que esto tumba la Fase 1.

```sql
-- rama ERP
CAST(NULL AS NVARCHAR(MAX))   AS Detalle,
CAST(NULL AS NVARCHAR(200))   AS Usuario,
-- y en la rama de actividad, por simetría:
CAST(NULL AS DECIMAL(18,2))   AS Importe,
```

### B-2. n8n escribe con la RLS puesta y sin contexto de sesión: pérdida silenciosa

`db/06`, `core.usp_CerrarEscrituraBC`; `db/05`, paso 4 de `core.usp_EmparejarActividadesImportadas`.

Los dos procedimientos los llama n8n, que no lleva token de Entra ID y por tanto no tiene
`SESSION_CONTEXT`. Con `core.PoliticaCartera` activa:

- el `UPDATE crm.Presupuesto SET BcQuoteId = …` de `usp_CerrarEscrituraBC` **no encuentra la
  fila** (el FILTER predicate la oculta) y afecta a 0 filas **sin dar error**: el presupuesto
  se queda para siempre sin `BcQuoteId`, sin totales y en `EstadoSync = 'en_cola'`. Es el
  fallo silencioso que describe la introducción de las reglas de oro;
- el `INSERT INTO core.Actividad` del emparejamiento choca con el BLOCK PREDICATE AFTER INSERT
  y falla con el error 33504, que no dice nada útil.

Arreglo recomendado: un usuario SQL propio para los procesos (`crm_sync`), y una rama explícita
en los dos predicados:

```sql
OR USER_NAME() = N'crm_sync'
```

Con eso el permiso es explícito, no se puede suplantar desde la API (un comercial nunca es
`crm_sync`) y se puede auditar. Ejecutar los procedimientos `WITH EXECUTE AS N'crm_sync'` cierra
el círculo. **No dar por hecho que ejecutar como `dbo` esquiva la RLS**: hay que probarlo, y de
todas formas n8n no debería entrar como `dbo`.

### B-3. La clave de idempotencia se invalida a sí misma → presupuestos duplicados en BC

`db/06`, `crm.usp_EnviarPresupuestoABC`.

La clave incluye el `ROWVERSION` del presupuesto… y el propio procedimiento hace
`UPDATE crm.Presupuesto SET EstadoSync = N'en_cola'` tres líneas más abajo, lo que **cambia el
ROWVERSION**. Resultado: dos clics seguidos generan dos claves distintas, las dos con
`Operacion = 'crear'` (porque `BcQuoteId` sigue NULL hasta que n8n termine), y BC acaba con dos
`salesQuote` del mismo presupuesto. Rompe la regla 6.

Arreglos, por orden de preferencia:

1. guardar un contador de envío en `crm.Presupuesto` (`IntentoEnvio INT`) y componer la clave
   con él, en lugar del `ROWVERSION`;
2. y en cualquier caso, rechazar el encolado si ya existe una entrada para
   `(Entidad, EntidadId, Operacion='crear')` en estado `pendiente`, `en_curso` o `completada`,
   no solo con la misma clave.

### B-4. `usp_SembrarDominiosEmpresa` viola su propio índice único

`db/05`. `UQ_EmpresaDominio` es `UNIQUE (Dominio)` —un dominio pertenece a una empresa—, pero el
`SELECT` agrupa por `(EmpresaId, Dominio)` y solo comprueba que el dominio no exista **ya** en la
tabla. Si dos fichas de `core.Empresa` comparten dominio (filiales, o duplicados de la carga
inicial de `bc.Contact`, que es lo normal con 2.781 empresas), el `INSERT` entero falla.

Arreglo: `ROW_NUMBER() OVER (PARTITION BY Dominio ORDER BY N DESC)` y quedarse con `rn = 1`,
dejando los descartados en una tabla de revisión en vez de perderlos.

### B-5. Cinco tablas con datos de cliente fuera de la RLS (regla 8)

La regla 8 dice literalmente que una tabla nueva sin `SalespersonCode` y fuera de
`core.PoliticaCartera` es una fuga. Están fuera:

| Tabla | Qué expone |
|---|---|
| `core.Contacto` | nombre, cargo, email, móvil y notas de los contactos de **todos** los clientes |
| `core.Adjunto` | nombre de fichero y URL de los adjuntos de todos los clientes |
| `core.ActividadImportada` | **asunto y cuerpo completo** de los correos de todos los comerciales |
| `core.PropiedadHistorico` | valores anteriores y nuevos de cualquier propiedad |
| `core.ColaEscrituraBC` | `PayloadJson` con cliente, artículos y cantidades de los presupuestos |

Y no es teórico: `api/dab-config.json` expone `Contacto` como tabla con
`read, create, update, delete` para el rol `comercial`. Con eso, un `GET /api/Contacto` devuelve
la agenda comercial completa de Jomipsa, y un `DELETE` borra el contacto de otro. Es la fuga
exacta que la regla describe.

Arreglo propuesto:

- `core.Contacto` y `core.Adjunto`: heredar de la empresa con un predicado en línea, igual que
  `fn_FiltroOportunidad` hace con las hijas de oportunidad —
  `core.fn_FiltroEmpresa(@EmpresaId)` que consulte `core.Empresa` (cuya RLS ya filtra). Evita
  desnormalizar y evita el problema de mantener el código sincronizado;
- `core.ActividadImportada`: predicado por `BuzonEmail` contra `core.vw_UsuarioActual` (cada
  comercial ve lo de su buzón; dirección y admin, todo). Ojo: mientras está en `sin_empresa` no
  hay `EmpresaId`, así que el criterio tiene que ser el buzón, no la empresa;
- `core.ColaEscrituraBC` y `core.PropiedadHistorico`: `SalespersonCode` desnormalizado, que es
  lo que dice la regla 8, y dentro de la política.

Mientras eso no esté, quitar `Contacto` de `dab-config.json` o limitarlo a `direccion`/`admin`.

---

## Importantes — no rompen el arranque, pero se pagan pronto

### A-1. Dos fuentes de verdad para la cartera, y ningún proceso que las case

La regla 4 manda resolver la cartera contra `gold.DimCustomer WHERE IsCurrent = 1`, y así lo hace
`core.vw_MiCartera`. Pero la RLS de `core.Empresa`, `core.Actividad`, `core.Tarea`,
`crm.Oportunidad` y `crm.Presupuesto` filtra por **su propia** columna `SalespersonCode`, copiada
en cada fila. Nadie sincroniza las dos.

Cuando dirección reasigna un cliente en BC (que es justo el caso `CL00691` del que habla
`CLAUDE.md`), pasa esto: el comercial nuevo ve la ficha del ERP —porque `DimCustomer` ya dice que
es suyo— pero `core.Empresa` sigue con el código antiguo, así que la RLS le esconde la fila y en
`crm_v.ClienteCabecera` le salen `EmpresaId`, contactos, oportunidades y actividades vacíos. Y el
comercial anterior sigue viendo toda la parte CRM de un cliente que ya no es suyo.

Hay que decidir dos cosas **antes de la carga inicial**, y son de negocio, no técnicas:

1. un job nocturno en n8n que propague `gold.DimCustomer.SalespersonCode` a
   `core.Empresa.SalespersonCode` (esto es mecánico);
2. qué pasa con el histórico: las actividades, tareas y oportunidades ya creadas llevan el
   código congelado. ¿El comercial nuevo hereda las visitas del anterior, o no las ve? Las dos
   respuestas son defendibles, pero hay que elegir una y escribirla, porque determina si el job
   toca solo `core.Empresa` o también las tablas hijas.

### A-2. `crm_v.CatalogoCliente`: producto cartesiano cartera × catálogo

`db/06`. `FROM core.vw_MiCartera mc CROSS JOIN gold.DimProduct dp`, sin filtro por cliente. Para
PMZ son 452 clientes × todo el catálogo de artículos, y encima cada fila arrastra un `LEFT JOIN`
contra una CTE con `ROW_NUMBER()` sobre **todas** las líneas de factura del histórico. La vista es
inutilizable tal cual: en cuanto DAB la pagine sin filtro, se come la instancia.

Arreglo: función en línea con el cliente como parámetro
(`crm_v.fn_CatalogoCliente(@CustomerNo)`), que es lo que la pantalla necesita de verdad —el
catálogo siempre se abre desde un cliente concreto.

### A-3. `crm_v.ClienteCabecera` agrega ocho años enteros para abrir una ficha

`db/02`. La CTE `v` agrupa `crm_v.VentaLinea` **completa** (2018–2026) y luego se une por
`LEFT JOIN` a la cartera. Con un `LEFT JOIN` el optimizador no siempre puede empujar el filtro de
`CustomerNo` dentro del `GROUP BY`, así que abrir un cliente puede costar un escaneo del
histórico entero. Y `crm_v.MiCartera` se apoya en esta vista, con lo que la pantalla de inicio
hereda el coste.

No lo doy por roto sin medirlo, pero es lo primero que hay que mirar con el plan real en cuanto
se ejecuten los scripts. Si duele, la salida limpia es una tabla de resumen en el CRM
(`crm.ResumenCliente`) refrescada de noche por n8n: encaja con la regla 1 (el CRM no crea nada en
`gold`) y hace que la ficha abra en milisegundos.

### A-4. La caché de DAB con RLS puesta puede servir datos de otro comercial

`api/dab-config.json`: `"cache": { "enabled": true, "ttl-seconds": 30 }`.

Con un solo usuario SQL y la fila filtrada por `SESSION_CONTEXT`, la respuesta de
`/api/MiCartera` **depende de quién pregunta**. Si la clave de caché de DAB no incluye la
identidad del usuario, dos comerciales que consulten lo mismo en la misma ventana de 30 segundos
pueden recibir el mismo cuerpo. Hay que confirmarlo contra la versión de DAB que se despliegue
antes de encenderla.

Recomendación para arrancar: `"enabled": false`, y activarla solo para las entidades que no
dependen del usuario (`Etapa`, `MotivoPerdida`, `PropiedadDefinicion`).

### A-5. Los roles de la base de datos y los de DAB no coinciden

La base de datos define cinco roles (`comercial`, `kam`, `direccion`, `admin`, `lectura`);
`dab-config.json` solo declara permisos para `comercial` y `direccion`. Un KAM, un admin o un
usuario de solo lectura recibirán 403 en todas las entidades. Además hay que crear las *app
roles* en el registro de Entra ID y comprobar que el token trae el claim `roles`, porque DAB saca
el rol de ahí.

Detalle relacionado: el bloque de alta de usuarios de `db/01` da a Rodrigo el rol `admin`, que en
DAB no existe. Hoy eso significa que el administrador no puede usar la API.

### A-6. Los DENY del script 03 dependen de que `gold` y `bc` sean de `dbo`

`db/03` deniega `SELECT` sobre `gold` y `bc` y confía en la cadena de propiedad para que las
vistas de `crm_v` sigan funcionando. Eso es correcto **solo si `crm_v`, `gold` y `bc` tienen el
mismo propietario**. `crm_v` se crea con `AUTHORIZATION dbo` en el 01, pero de `gold` y `bc` no
sabemos nada: los creó el PDE.

Comprobar antes de ejecutar el 03:

```sql
SELECT s.name AS Esquema, dp.name AS Propietario
FROM sys.schemas s JOIN sys.database_principals dp ON dp.principal_id = s.principal_id
WHERE s.name IN ('dbo','crm_v','core','crm','gold','bc');
```

Si `gold` no es de `dbo`, la ficha 360 arranca vacía con un «permiso denegado» y parecerá un
problema de las vistas cuando es de propiedad de esquemas.

Del mismo palo: `DENY … ON SCHEMA::dbo` es una brocha ancha. Si algún día una vista de `crm_v`
necesita algo de `dbo`, el diagnóstico será confuso. Dejarlo, pero anotado.

### A-7. `crm_v.VentaLinea` y `crm_v.ColaEscrituraBC` no llevan filtro de cartera

`crm_v.VentaLinea` es la base normalizada y por diseño no filtra: cada vista que cuelga de ella
añade su `EXISTS … core.vw_MiCartera`. Hoy no está expuesta en DAB, y **no debe exponerse nunca**;
conviene dejarlo escrito en el propio script porque es un pie muy fácil de pisar.

`crm_v.ColaEscrituraBC` y `crm_v.ImportacionPendiente` tampoco filtran: la primera muestra los
errores de escritura de todos los comerciales, la segunda agrega asuntos de todos los buzones. Si
se exponen, que sea solo para `direccion`/`admin`.

### A-8. Las hijas de oportunidad se pueden rellenar a ciegas

`db/03`. `crm.OportunidadLinea`, `OportunidadHistorico` y `OportunidadCompetidor` tienen FILTER
predicate pero ningún BLOCK predicate, y un filter predicate no impide el `INSERT`. Un comercial
puede insertar líneas en una oportunidad que no ve (y que después seguirá sin ver, mientras el
dueño real se las encuentra). Añadir el bloqueo equivalente al de la tabla padre.

### A-9. Crear un prospecto va a fallar con un error incomprensible

`core.Empresa.SalespersonCode` es NULL por defecto y hay BLOCK PREDICATE AFTER INSERT. Un
comercial que dé de alta un prospecto sin rellenar ese campo recibirá el error 33504, que no
explica nada. Y si lo rellena mal, la fila se crea y se vuelve invisible para él mismo.

Arreglo: no exponer el alta de `core.Empresa` como tabla en DAB, sino un procedimiento
`core.usp_CrearEmpresa` que rellene `SalespersonCode` desde `core.vw_UsuarioActual`. Además
resuelve `CreadoPor` sin fiarse del cliente.

### A-10. `CK_Oport_Cierre` obliga a cerrar las oportunidades aplazadas

`db/01`: `CHECK (Estado = N'abierta' OR FechaCierreReal IS NOT NULL)`. El estado `aplazada`
existe precisamente para lo que no se ha cerrado, y esta restricción exige fecha de cierre real
para ponerlo. Debe ser `Estado IN (N'abierta', N'aplazada') OR FechaCierreReal IS NOT NULL`.

### A-11. `JSON_VALUE` con la ruta construida por concatenación

`db/04`, `crm_v.EmpresaPropiedad` y `crm_v.OportunidadPropiedad`:
`JSON_VALUE(e.PropiedadesJson, '$.' + pd.Clave)`. El segundo argumento de `JSON_VALUE` tiene que
ser un literal o una variable; una expresión que concatena una columna no está soportada en
SQL Server y da «The argument 2 of the JSON_VALUE … must be a string literal». Hay que probarlo
en el motor actual de Azure SQL antes de darlo por bueno.

En cualquier caso la forma correcta es más rápida: explotar el JSON una vez y unir por clave, en
lugar de un `CROSS JOIN` con una llamada a `JSON_VALUE` por fila y definición.

```sql
FROM core.Empresa e
CROSS APPLY OPENJSON(e.PropiedadesJson) j
JOIN core.PropiedadDefinicion pd ON pd.Clave = j.[key] AND pd.Entidad = N'empresa' AND pd.Activa = 1
```

---

## Menores y limpieza

- **M-1. Script 06 no es idempotente.** `ALTER SECURITY POLICY … ADD FILTER PREDICATE … ON
  crm.Presupuesto` falla en la segunda pasada porque el predicado ya existe. Envolverlo en una
  comprobación sobre `sys.security_predicates`. Y en el 03, el `DROP SECURITY POLICY` deja la
  base sin política si el `CREATE` posterior falla: mejor en una transacción.
- **M-2. Posibles duplicados por dimensiones tipo 2.** `ClienteCabecera` une
  `gold.DimSalesperson` sin `IsCurrent`, y `CatalogoCliente` une `gold.vw_ProductUnitCost` por
  `ItemNo` a secas. Si esas fuentes tienen más de una fila por clave (histórico, o coste por
  almacén), la cabecera y el catálogo **duplican filas**. Comprobarlo con un `GROUP BY … HAVING
  COUNT(*) > 1` antes de aplicar.
- **M-3. Falta `GRANT EXECUTE ON core.usp_CerrarEscrituraBC`.** Si n8n entra como `crm_app` no
  puede llamarlo. Se resuelve con la decisión de B-2 (principal propio para n8n).
- **M-4. Emparejamiento no determinista.** Paso 1 de `usp_EmparejarActividadesImportadas`: el
  `CROSS APPLY OPENJSON` + `JOIN core.Contacto` puede casar varias filas por mensaje (varios
  interlocutores conocidos, o el mismo email en dos fichas) y el `UPDATE` se queda con una
  arbitraria. Usar `CROSS APPLY (SELECT TOP 1 … ORDER BY …)` con un criterio explícito:
  contacto cuyo dominio coincida, `EsPrincipal`, y el más reciente.
- **M-5. `UPDATE TOP (@MaxFilas)` por paso, no por ejecución.** Los cuatro pasos aplican el tope
  por separado y sin `ORDER BY`, así que una ejecución puede dejar filas en `pendiente`. Es
  aceptable (la siguiente pasada las coge), pero conviene documentarlo para que nadie lo lea como
  un fallo.
- **M-6. Código muerto.** `IF EXISTS (SELECT 1 … HAVING COUNT(*) = 0)` en
  `usp_EnviarPresupuestoABC` nunca es cierto; la condición útil es el `NOT EXISTS` de al lado.
- **M-7. `key-fields` incompletas en DAB.** `ClienteFacturas` declara `["DocumentNo"]` cuando la
  vista agrupa por `(CustomerNo, TipoDocumento, DocumentNo)`; `ClienteCronologia` tiene el mismo
  problema. Con claves no únicas, el endpoint de elemento y los `PATCH` se comportan de forma
  imprevisible. Poner la clave completa.
- **M-8. `GETDATE()` en las vistas, `SYSUTCDATETIME()` en los defaults.** En Azure SQL `GETDATE()`
  ya devuelve UTC, así que hoy coincide; usar `SYSUTCDATETIME()` también en las vistas evita la
  sorpresa el día que algo se mueva a un servidor con zona local.
- **M-9. Propiedades personalizadas incompletas.** `core.PropiedadDefinicion` admite
  `Entidad = 'actividad'` pero `core.Actividad` no tiene `PropiedadesJson`; y hay definiciones
  para `contacto` (`rol_decision`, `linkedin`, `canal_preferido`) sin su vista
  `crm_v.ContactoPropiedad`. El frontend se quedará sin dónde pintarlas.
- **M-10. Faltan `CHECK` en los enlaces polimórficos.** `core.Actividad.EntidadTipo` y
  `core.Adjunto.EntidadTipo` aceptan cualquier texto. Un `CHECK` con la lista cerrada
  (`oportunidad`, `ticket`, `pedido`, `presupuesto`) evita que cada módulo invente su propio
  valor.
- **M-11. El alta de usuarios comentada no cuadra con los datos.** El bloque de `db/01` incluye
  `JSF` (Julian Sanchez), que no aparece entre los comerciales con facturación de `CLAUDE.md`, y
  **falta `LBP`**, que tiene 9 clientes y es justamente el protagonista del caso `CL00691` que
  motiva la regla 4. Un comercial que falte en `core.UsuarioCartera` deja a sus clientes sin
  dueño: con la RLS activa no los ve nadie salvo dirección. Cotejar los ocho códigos contra
  `gold.DimSalesperson` antes de ejecutar.
- **M-12. Documentación desalineada.** `docs/arquitectura.md` dice «Scripts 01–05» y cita
  `ui/ficha-empresa.html`, cuando el paquete trae 01–06 y el prototipo está en
  `web/prototipos/ficha-empresa.html`.

---

## Lo que sí está bien resuelto

Conviene decirlo, porque condiciona lo que no hay que volver a tocar:

- La **fuente única de facturación** está bien encapsulada: todo pasa por `crm_v.VentaLinea` y
  ninguna vista mira a `gold.vw_FacturacionMensualCliente` ni a `vw_ResumenComercialCliente`
  (regla 2, cumplida).
- El **convenio de signos** está aplicado exactamente como dice la regla 3: `Importe` y `Profit`
  se suman directos y `Quantity` se invierte en los abonos, en un solo sitio.
- La **cartera se resuelve contra `gold.DimCustomer WHERE IsCurrent = 1`** en
  `core.vw_MiCartera`, no contra `ComercialAsignado` (regla 4, cumplida).
- **Ningún script crea, altera ni borra nada en `bc`, `gold` ni el resto de esquemas ajenos**
  (regla 1, cumplida). Las dependencias van en un solo sentido.
- El **fallo cerrado** está bien planteado: sin `SESSION_CONTEXT`, `core.vw_UsuarioActual` no
  devuelve filas y no hay ningún `OR 1=1` en ninguna parte (regla 7, cumplida). El precio de
  hacerlo bien es B-2, que hay que resolver por la vía del principal de servicio y no relajando
  el predicado.
- Los **adjuntos guardan metadatos y URL**, nunca el binario (regla 9, cumplida).
- **Toda escritura a BC pasa por `core.ColaEscrituraBC`** y no hay una sola llamada síncrona
  (regla 6, cumplida en la forma; la idempotencia es lo que falla, ver B-3).

## Orden sugerido para atacarlo

1. B-1 (una línea, y desbloquea la pestaña de cronología).
2. B-5 y A-9, antes de exponer nada en DAB: son las dos que dejan datos al aire.
3. B-2, que obliga a decidir el principal de n8n. Es la decisión con más cola.
4. A-6, comprobación de propietarios de esquema: se hace en un minuto y evita un arranque en
   falso del 03.
5. A-1, que es una decisión de negocio y conviene plantearla ya para no repetir la carga inicial.
6. B-3 y B-4, antes de la primera escritura real a BC y de la carga de contactos, respectivamente.
7. El resto, por orden de aparición.
