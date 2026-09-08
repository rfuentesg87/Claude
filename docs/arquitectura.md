# CRM Jomipsa — Documento de arquitectura

**Versión:** 2.0 · 8 de septiembre de 2026
**Autor:** Rodrigo Fuentes (IT / Datos) · Proyecto Tractor 18
**Estado:** diseño aprobado. Scripts 01–05 listos. Prototipo de la ficha de empresa construido.

---

## 1. Objetivo

Clonar las acciones básicas de HubSpot en un CRM propio para los comerciales de
Jomipsa, conectado al ERP (Business Central) y ampliable a compras e incidencias
sin rehacer nada de lo anterior.

El encargo es explícito: **las acciones más básicas de HubSpot primero, y funcionalidad
encima poco a poco.** Todo lo que no está en esa lista corta —marketing automation,
formularios, secuencias, presupuestos— queda fuera del alcance por escrito, para no
perseguirlo más adelante.

El punto de partida no es un CRM vacío. Jomipsa ya tiene ocho años de histórico de
facturación con coste real y margen calculado en la capa `gold` del Azure SQL. El CRM
nace, por tanto, con datos desde el primer día: no hay que esperar a que los comerciales
lo alimenten para que sirva de algo.

---

## 2. Decisiones de arquitectura

| Decisión | Elegido | Descartado |
|---|---|---|
| Base de datos | Esquemas propios en el Azure SQL existente | PostgreSQL local |
| Capa de API | Data API Builder (Microsoft, MIT) | Supabase; backend Node a medida; n8n como API |
| Autenticación | Entra ID / Microsoft 365 | Usuarios propios; sin login |
| Autorización | Row-Level Security en la base de datos | Filtros en el código de cada endpoint |
| Acceso | Público con HTTPS | Solo intranet; VPN |
| Frontend | Aplicación web responsive, móvil primero | App nativa; Power Apps |
| Automatización | n8n para lo asíncrono | n8n como servidor de aplicación |
| Fase 1 | Ficha de empresa (equivalente al *record page* de HubSpot) | Pipeline; agenda de visitas |
| Campos | Propiedades personalizables desde la interfaz | Campos fijos con migración por cada cambio |
| Actividad | Registro automático de emails y reuniones desde M365 | Solo registro manual |

### 2.1 Por qué la base de datos va en el Azure SQL y no en un servidor local

Poner el CRM en el mismo Azure SQL que la réplica de BC elimina por completo la capa de
sincronización. No hay que replicar clientes ni ventas a ningún sitio ni mantener
workflows de sync nocturnos: `crm.Oportunidad` hace JOIN directo contra `gold.DimCustomer`
en la misma consulta. La Fase 1 entera es un conjunto de vistas SQL.

El coste de esa decisión son cuatro riesgos, tres de ellos ya cerrados:

1. **El restore de Azure SQL es a nivel de base de datos.** Si hay que hacer
   point-in-time restore para recuperar `bc` o `gold` tras un fallo del PDE, ese restore
   se lleva por delante los datos del CRM. **Mitigación obligatoria:** export nocturno
   propio de los esquemas `core` y `crm` a Blob Storage más copia en el servidor local.
   No es opcional.
2. **El PDE está en evaluación de sustitución.** Regla de diseño permanente: el CRM
   nunca crea objetos dentro de `bc` ni `gold`, y todas las dependencias van en un solo
   sentido (`crm_v` → `gold` → `bc`). Así una migración futura es un export/import de
   `core` + `crm` y nada más.
3. **¿Qué toca el PDE al escribir?** Confirmado: el PDE nunca actúa sobre la base de
   datos completa. Riesgo cerrado.
4. **Mezcla de cargas** (analítica pesada + OLTP pequeño y concurrente). Con siete
   comerciales el volumen es despreciable, pero conviene revisar el tier antes de abrir
   a producción y vigilar DTU las primeras semanas.

### 2.2 Por qué no n8n como capa de aplicación

n8n es excelente para lo asíncrono y pésimo como servidor de aplicación:

- No tiene dónde guardar los datos propios del CRM (las *data tables* no tienen
  relaciones, integridad referencial ni JOIN).
- No tiene transacciones: una operación a medias deja registros huérfanos sin rollback.
- Obliga a reimplementar la validación del token y el filtro de cartera en cada workflow;
  un olvido expone márgenes de toda la empresa a Internet.
- No hay funciones reutilizables: la regla de margen acaba copiada en ocho nodos Code.
- No hay git, ni diff, ni tests, ni rollback: con cuarenta workflows-endpoint no se puede
  refactorizar.
- Cada petición HTTP es una ejecución que n8n guarda entera en su base de datos.

**Regla operativa:** petición síncrona con un comercial esperando → API.
Trabajo asíncrono, programado, integraciones e IA → n8n.

### 2.3 Por qué Data API Builder

Data API Builder (DAB) genera API REST y GraphQL sobre Azure SQL a partir de **un fichero
JSON de configuración**, sin escribir backend. Es open source de Microsoft, licencia MIT,
gratuito, y corre como contenedor Docker sin estado en el servidor local. Soporta Entra ID
de forma nativa y —lo decisivo— vuelca los claims del token en el `SESSION_CONTEXT` de SQL
Server, que es justo lo que necesita la Row-Level Security para filtrar por cartera.

Trae de serie paginación, filtros, ordenación, relaciones, agregaciones, OpenAPI/Swagger y
caché en memoria. La API del CRM es un fichero de configuración, no un proyecto de software.

---

## 3. Arquitectura de componentes

```
                     Internet (HTTPS)
                            │
              ┌─────────────▼──────────────┐
              │  Cloudflare Tunnel / Caddy │   crm.jomipsa.es
              └─────────────┬──────────────┘
                            │
        SERVIDOR LOCAL (Docker Compose)
        ┌───────────────────┴────────────────────┐
        │                                        │
   ┌────▼─────────────┐              ┌───────────▼────────┐
   │  Frontend web    │─── REST ────▶│ Data API Builder   │
   │  React, móvil    │              │ (contenedor)       │
   │  primero         │              │ Entra ID + claims  │
   └──────────────────┘              └───────────┬────────┘
                                                 │ usuario crm_app
   ┌──────────────────┐                          │ + SESSION_CONTEXT
   │  n8n (local)     │                          │
   │  · sync a BC     │                          │
   │  · IA OpenRouter │                          │
   │  · alertas       │              ┌───────────▼──────────────────┐
   │  · informes      │─────────────▶│  AZURE SQL                   │
   └────────┬─────────┘   MCP SQL    │  sqldb-jomipsapde-prod       │
            │                        │                              │
            │ API REST               │  core.*   núcleo compartido  │
            ▼                        │  crm.*    módulo comercial   │
   ┌──────────────────┐              │  crm_v.*  vistas (API)       │
   │ Business Central │              │  ─────────────────────────   │
   │      (ERP)       │              │  gold.*   BC curado  (RO)    │
   └──────────────────┘              │  bc.*     réplica PDE (RO)   │
                                     └──────────────────────────────┘
```

---

## 4. Modelo de datos

### 4.1 Principio de separación

En la base de datos del CRM vive **solo lo que BC no tiene y nunca tendrá**: oportunidades,
pipeline, actividades, visitas, notas, tareas, adjuntos, competidores y motivos de pérdida.
Cada registro guarda el `No_` de cliente de BC como única clave de enlace.

### 4.2 Esquemas

| Esquema | Contenido | Acceso del CRM |
|---|---|---|
| `core` | Núcleo compartido: Usuario, UsuarioCartera, Empresa, Contacto, Actividad, Tarea, Adjunto | lectura/escritura |
| `crm` | Módulo comercial: Etapa, MotivoPerdida, Competidor, Oportunidad, OportunidadLinea, OportunidadCompetidor, OportunidadHistorico | lectura/escritura |
| `crm_v` | Capa de vistas que consume la API. Única frontera con `gold` | solo lectura |
| `gold` | BC curado (dimensional). Propiedad del pipeline de datos | solo lectura, vía `crm_v` |
| `bc` | Réplica cruda del PDE | sin acceso directo |
| `compras`, `incidencias` | Futuros módulos, reutilizan `core` | — |

`core` es lo que hace el sistema modular de verdad: cuando entre incidencias, se reutiliza
Empresa, Contacto, Actividad, Tarea, Adjunto y Usuario, y se añade un esquema. No se
reescribe nada.

### 4.3 Decisiones de modelado que merecen explicación

- **`core.Empresa` cubre clientes, prospectos y proveedores.** Un prospecto vive aquí sin
  `BcCustomerNo`; cuando se convierte en cliente se rellena el campo. `BcVendorNo` está
  reservado para el módulo de compras.
- **`core.Actividad` es una sola tabla para todos los módulos.** La visita comercial y la
  llamada de una incidencia son la misma cosa con distinto `Modulo`. `EntidadTipo` +
  `EntidadId` es el enlace polimórfico a la oportunidad, el ticket o el pedido.
- **Las visitas no tienen tabla propia**: son `core.Actividad` con `Tipo = 'visita'`.
- **`SalespersonCode` va desnormalizado** en Empresa, Actividad, Tarea y Oportunidad. Es
  la columna sobre la que actúa la RLS y tiene que ser barata de evaluar.
- **`crm.Oportunidad` tiene `ReferenciaLicitacion` y `FechaLimitePresentacion`** porque
  parte del pipeline de Jomipsa son licitaciones y consultas de mercado (tipo OPRAN o
  UNICEF), no ventas de ciclo corto. Sin esos campos el comercial acaba metiendo la fecha
  límite en el campo de notas.
- **`crm.OportunidadHistorico` registra cada cambio de etapa.** Sin ella no hay forma de
  calcular tiempo medio por etapa ni tasa de conversión real.
- **Los adjuntos guardan solo metadatos y una URL.** El binario va a SharePoint o Blob
  Storage: meter ficheros en la BBDD dispara el tamaño, encarece el tier y complica los
  backups.

---

## 5. Seguridad

### 5.1 Modelo

DAB se conecta con **un solo usuario SQL** (`crm_app`) y, antes de cada consulta, vuelca
los claims del token de Entra ID en `SESSION_CONTEXT`. La RLS lee ese contexto y filtra.
La regla "cada comercial ve su cartera" se escribe una vez, en la base de datos, y ningún
endpoint puede saltársela por mucho que se programe mal.

### 5.2 Roles

| Rol | Alcance de lectura | Escritura |
|---|---|---|
| `comercial` | Su cartera | Su cartera |
| `kam` | Su cartera (puede incluir varios códigos) | Su cartera |
| `direccion` | Todo | Todo |
| `admin` | Todo | Todo |
| `lectura` | Todo | Ninguna |

La cartera de cada usuario se define en `core.UsuarioCartera` como una lista de
`SalespersonCode`. Un comercial normal tiene una fila; un KAM que cubre a un compañero de
baja tiene dos. Dirección y admin no necesitan filas.

### 5.3 La trampa de la cartera histórica

**La cartera se resuelve siempre contra `gold.DimCustomer WHERE IsCurrent = 1`, nunca
contra `ComercialAsignado` de la vista de margen.**

`gold.DimCustomer` es una dimensión de tipo 2: guarda el histórico de asignaciones. La
columna `ComercialAsignado` de `gold.vw_FactMargenLineaFactura` lleva la asignación que
tenía la línea *en el momento de facturarla*. Caso real verificado: Economat Des Armées
(`CL00691`) está asignado hoy a LBP, pero sus líneas de 2025 llevan CGA. Si la cartera se
filtrase por la vista de margen, LBP no vería el histórico de su propio cliente y CGA
seguiría viéndolo después de habérselo quitado.

### 5.4 Permisos SQL

`crm_app` tiene `SELECT` sobre `crm_v` y CRUD sobre `crm` y `core`. Sobre `bc`, `gold` y
el resto de esquemas tiene **DENY explícito**. Las vistas de `crm_v` siguen funcionando
porque la cadena de propiedad (todo pertenece a `dbo`) evita la comprobación de permisos
sobre los objetos subyacentes al acceder a través de la vista.

### 5.5 Falla cerrada

Si no hay contexto de sesión, `core.vw_UsuarioActual` no devuelve filas y el usuario no ve
nada. Es el comportamiento correcto para una capa de seguridad: ante la duda, no enseñar.

---

## 6. El MVP: qué es "HubSpot básico"

El modelo de datos ya cubre los objetos de HubSpot. Lo que falta son pantallas.

| HubSpot | Equivalente en el CRM |
|---|---|
| Companies | `core.Empresa` |
| Contacts | `core.Contacto` |
| Deals | `crm.Oportunidad` |
| Deal stages / pipeline | `crm.Etapa` + `crm.OportunidadHistorico` |
| Engagements (nota, llamada, reunión, email) | `core.Actividad` |
| Tasks | `core.Tarea` |
| Record timeline | `crm_v.ClienteCronologia` |
| Owners y permisos por propietario | `core.Usuario` + `UsuarioCartera` + RLS |
| Attachments | `core.Adjunto` |
| Custom properties | `core.PropiedadDefinicion` + columnas JSON |

Las ocho acciones del MVP, y nada más:

1. Buscador global (empresa, contacto, oportunidad)
2. Ficha de empresa con contactos, oportunidades y cronología
3. Alta y edición de empresa y contacto
4. Tablero de oportunidades tipo Kanban, arrastrando entre etapas
5. Registrar actividad desde la ficha: nota, llamada, reunión, email
6. Tareas, con vista "lo que tengo hoy"
7. Vistas de lista filtrables y guardables
8. Panel mínimo: pipeline por etapa e importe ponderado

---

## 7. Propiedades personalizables

Definiciones en `core.PropiedadDefinicion` y valores en una columna JSON de cada
entidad. Se descarta el patrón EAV clásico (una fila por valor) porque obliga a un
PIVOT en cada lectura y hunde el rendimiento de las listas.

El frontend construye el formulario leyendo las definiciones, así que **añadir un
campo no requiere ni migración ni despliegue**. Para las tres o cuatro propiedades
que acaben siendo filtros habituales se añade una columna calculada persistida más
un índice; el resto vive en el JSON y se lee sin coste al abrir la ficha.

Se entregan propiedades iniciales pensadas para el negocio: tipo de organización,
canal, idioma preferido, requiere halal, certificaciones exigidas, vida útil mínima,
incoterm habitual, rol en la decisión, modalidad de licitación, lote, plazo de entrega.

---

## 8. Registro automático desde Microsoft 365

Lo que engancha al comercial en HubSpot no es el tablero: es que los emails y las
reuniones se registren solos. Si hay que teclear cada llamada, a los tres meses el
CRM está vacío.

**Cómo funciona.** Un workflow de n8n consulta Graph API cada 15 minutos por cada
buzón, usando el `deltaLink` guardado en `core.SincronizacionBuzon` para pedir solo
lo nuevo. Vuelca mensajes y eventos en `core.ActividadImportada`, con el id de Graph
como clave de deduplicación: el workflow puede reejecutarse mil veces sin duplicar
nada. Después llama a `core.usp_EmparejarActividadesImportadas`.

**El emparejamiento va en tres pasadas**, de la más fiable a la menos:

1. Email exacto de un contacto que ya existe → empresa y contacto resueltos.
2. Dominio registrado en `core.EmpresaDominio` → empresa resuelta.
3. Nada → queda en `sin_empresa` para revisión.

Hay staging precisamente porque el paso 3 ocurre a menudo: dominios genéricos,
clientes nuevos, correos personales. Con staging, lo que no casa queda pendiente en
vez de perderse o ensuciar la ficha del cliente equivocado. La vista
`crm_v.ImportacionPendiente` agrupa lo pendiente por dominio y lo ordena por
volumen, de modo que registrar el dominio más repetido resuelve decenas de mensajes
de golpe.

`core.DominioExcluido` evita el desastre del primer día: sin esa lista se crean cien
actividades contra la empresa equivocada porque dos comerciales se escribieron entre
ellos.

**Permisos de Graph necesarios** (aplicación, con consentimiento del administrador):
`Mail.Read`, `Calendars.Read` y `User.Read.All`. Conviene acotarlos con una
*application access policy* de Exchange limitada al grupo de comerciales, para que
la aplicación no pueda leer el correo de toda la empresa.

**Privacidad.** Hay que decirlo a los comerciales antes de activarlo, no después.
El diseño ya excluye el correo interno y el personal, y solo se importa el asunto y
el cuerpo de mensajes con un interlocutor externo identificado.

---

## 9. Fase 1 — La ficha de empresa

Es el *record page* de HubSpot: tres columnas.

- **Izquierda:** identidad y propiedades, agrupadas y con las personalizadas marcadas.
- **Centro:** tira de KPIs y pestañas de Resumen, Artículos, Pedidos abiertos y Cronología.
- **Derecha:** contactos, oportunidades y tareas.

Lo que la diferencia de HubSpot es que **llega llena**: ocho años de facturación con
coste real y margen ya están en `gold`. El comercial abre un cliente el primer día y
ve la evolución mensual, el margen, la cartera de pedidos y qué referencias ha dejado
de comprar, sin haber introducido ni un dato.

### 9.1 Fuente única de facturación

Todo sale de `gold.vw_FactMargenLineaFactura` (2018–2026, facturas y abonos, coste
real de movimientos de valor), normalizada en `crm_v.VentaLinea`.

**No se usan `gold.vw_FacturacionMensualCliente` ni `gold.vw_ResumenComercialCliente`**
porque solo cubren el año en curso: leen `bc.[Sales Invoice Line]`, que únicamente
contiene 2026 (357 filas). Mezclarlas daría dos cifras distintas para el mismo cliente
según la pantalla, que es la forma más rápida de perder la confianza del equipo.

Convenio de signos verificado contra los datos:

- `LineAmount_Neto` ya viene en negativo para los abonos → se suma directamente.
- `Profit_Definitivo` ya viene con el signo correcto → se suma directamente.
- `Quantity` **no** lleva signo → hay que invertirla en abonos.

Nota de calibración: para 2026 la vista de margen da 17,08 M€ y la vista directa de BC
17,90 M€ (4,6 % de diferencia, por líneas que no son de artículo). Es esperable; lo
importante es que el CRM use una sola de las dos en todas sus pantallas.

### 9.2 Vistas de la ficha

| Vista | Qué muestra |
|---|---|
| `crm_v.ClienteCabecera` | Facturación 12 m vs. 12 m anteriores, variación, margen, cartera de pedidos, días sin comprar, oportunidades abiertas |
| `crm_v.ClienteVentasAnual` | Evolución por año con margen |
| `crm_v.ClienteVentasMensual` | Serie mensual para la gráfica |
| `crm_v.ClienteArticulos` | Qué compra y **qué ha dejado de comprar**: abandonado / en_caida / nuevo / en_crecimiento / estable |
| `crm_v.ClientePedidosAbiertos` | Cartera viva, con fecha de entrega solicitada y marca de retraso |
| `crm_v.ClienteFacturas` | Facturas y abonos a nivel documento, con margen |
| `crm_v.ClienteCronologia` | Actividades del CRM e hitos del ERP en una sola línea de tiempo |
| `crm_v.MiCartera` | Pantalla de inicio: cartera ordenada por prioridad de atención |
| `crm_v.Pipeline` | Oportunidades con importe ponderado por probabilidad |

---

## 10. Papel de n8n

n8n no desaparece: se queda con lo que hace bien.

| Workflow | Disparador | Qué hace |
|---|---|---|
| Importación M365 | Cada 15 min | Graph API → `core.ActividadImportada` → emparejamiento |
| Escritura a BC | Cola / webhook desde la API | Crea o actualiza en BC vía API REST, con reintentos |
| Resumen pre-visita | Petición del comercial | OpenRouter genera un resumen del cliente antes de la visita |
| Transcripción de notas | Subida de audio | Voz a texto → `core.Actividad` |
| Alertas de cartera | Diario | Clientes en riesgo y oportunidades sin movimiento |
| Informe semanal | Lunes 6:00 | Excel + email, con el patrón OOXML ya existente |
| Backup de `core` + `crm` | Diario | Export a Blob Storage y copia local |

---

## 11. Hoja de ruta

| Fase | Alcance | Escribe en BC |
|---|---|---|
| **1** | Ficha de empresa + Mi cartera + propiedades personalizables | No |
| **2** | Contactos y actividades: alta, edición, cronología, tareas | No |
| **3** | Registro automático desde M365 y bandeja de revisión | No |
| **4** | Pipeline: tablero Kanban, etapas, competidores, motivos de pérdida | No |
| **5** | Buscador global, vistas de lista guardables, panel de dirección | No |
| **6** | IA: resúmenes pre-visita, transcripción de notas, siguiente acción | No |
| **7** | Escritura a BC: crear cliente desde prospecto, presupuestos | Sí |
| **8** | Módulo de compras y proveedores sobre `core` | Sí |
| **9** | Gestor de incidencias. Ver nota | Sí |

**Nota sobre incidencias:** el esquema `helpdesk` ya existe en esta misma base de datos
con Tickets, TicketComentarios, Categorias, SlaPoliticas y Tecnicos, incluyendo control
de SLA y escalado. Cuando llegue esa fase la decisión no es construir desde cero, sino
si se migra `helpdesk` a `core` + `incidencias` o se deja como está y se integra.

---

## 12. Scripts entregados

| Script | Contenido |
|---|---|
| `01_esquemas_ddl.sql` | Esquemas `core`, `crm`, `crm_v` y todas las tablas |
| `02_vistas_ficha360.sql` | Capa `crm_v`: identidad, cartera y vistas de la ficha |
| `03_seguridad_rls.sql` | Usuario `crm_app`, permisos y políticas de RLS |
| `04_propiedades_personalizadas.sql` | Definiciones de propiedades, columnas JSON y vistas |
| `05_autolog_m365.sql` | Staging, dominios, emparejamiento y bandeja de revisión |
| `dab-config.json` | Configuración de Data API Builder |
| `ui/ficha-empresa.html` | Prototipo navegable de la ficha de empresa |

Orden de ejecución: 01 → 02 → 03 → 04 → 05.

---

## 13. Pendientes antes de desplegar

1. Rellenar los emails de Entra ID de los comerciales en el bloque de alta de
   `01_esquemas_ddl.sql`.
2. Registrar la aplicación en Entra ID y anotar tenant ID y audience para `dab-config.json`.
3. Confirmar el nombre exacto del claim de email en el token emitido
   (`preferred_username`, `upn` o `email`); las vistas aceptan los tres.
4. Solicitar los permisos de Graph y la *application access policy* acotada al grupo
   de comerciales.
5. Revisar el tier del Azure SQL y establecer una línea base de DTU.
6. Montar el export nocturno de `core` + `crm` **antes** de que entre el primer dato real.
7. Decidir dominio y publicación (Cloudflare Tunnel recomendado, evita abrir puertos).
8. Aplicar el manual de marca de Jomipsa a la paleta del frontend: el prototipo usa
   tokens CSS, así que es cambiar un bloque de variables.
9. Higiene de datos: 58 clientes sin `SalespersonCode` y 100 asignados a JNA, que no
   factura desde 2023. Con la RLS activa, esos clientes no los verá nadie salvo dirección.
