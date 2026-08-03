# Registro Horario de Producción (Cadena)

Aplicación web interna para que las **responsables de cadena** registren líneas
de horario/producción por Orden de Producción (OP), y las **responsables de
planta** las validen en bloque. Reimplementación standalone (Python + Flask) del
prototipo n8n, para alojarse en un servidor propio de JOMIPSA.

Flujo de estados de una línea: `Pendiente` (editable/borrable) → `Confirmado`
(inmutable, lista para el futuro envío a Business Central).

Un resumen de la arquitectura y el alcance está en [`CLAUDE.md`](CLAUDE.md); la
especificación funcional/técnica completa es el documento de traspaso original
del prototipo n8n.

---

## Stack

- **Backend / web**: Python 3 + Flask + plantillas Jinja2 (frontend vanilla, sin
  frameworks JS).
- **Base de datos**:
  - `sqlite` — backend por defecto para desarrollo/pruebas. Sin dependencias
    externas; arranca con datos de ejemplo.
  - `mssql` — producción, Azure SQL vía `pyodbc`, usando las tablas y vistas que
    ya existen (`gold.RegistroProduccion[_Temp]`, `gold.vw_PowerApp_*`).
- **Autenticación**: usuarios locales con contraseñas hasheadas (PBKDF2-SHA256,
  stdlib) y sesión firmada en cookie `HttpOnly` + `SameSite=Lax` + `Secure`.
  Preparada para sustituirse por Entra ID / LDAP más adelante (ver *Autenticación*).

## Estructura

```
main.py                    # entry point (dev server) + objeto WSGI `app`
manage.py                  # CLI de administración (crear usuarios, hashear claves)
config.py                  # configuración por variables de entorno
requirements.txt           # Flask
requirements-mssql.txt     # + pyodbc (solo producción)
sql/schema.sql             # DDL de referencia (Azure SQL) + tabla gold.AppUsers
app/
  __init__.py              # create_app() + filtros Jinja
  auth.py                  # hashing, sesión, login_required
  constants.py             # opciones de tipo de trabajo + validación de negocio
  routes.py                # endpoints (spec §3)
  repository/
    base.py                # interfaz abstracta
    sqlite_repo.py         # backend de desarrollo/test
    mssql_repo.py          # backend de producción (pyodbc, SQL exacto de la spec)
  templates/  static/      # UI
tests/                     # unittest (repositorio + rutas end-to-end)
```

## Puesta en marcha (desarrollo)

```bash
pip install -r requirements.txt
python3 main.py
# -> http://127.0.0.1:8000  (backend sqlite, datos de ejemplo)
```

Usuario inicial por defecto (cámbialo en cualquier entorno real):
`User` / `Cambiar2025!!!`.

### Ejecutar los tests

```bash
python3 -m unittest discover -s tests -v
```

## Despliegue en el servidor (recomendado)

Esto **es una aplicación web**: se instala una sola vez en un servidor y las
usuarias entran con el navegador. No hay que instalar nada en sus equipos ni
distribuir ejecutables.

En el servidor, con **PowerShell como administrador**, desde la carpeta del
repositorio:

```powershell
git clone https://github.com/rfuentesg87/Claude.git C:\RegistroHorario
cd C:\RegistroHorario
git checkout claude/registro-horario-produccion-ij9qp2

.\deploy\install-server.ps1            # o -Port 8080
```

El script hace todo lo mecánico: entorno virtual de Python aislado, dependencias
(incluido `pyodbc`), `registro-horario.env` con una `RHP_SECRET_KEY` aleatoria,
arranque automático al encender el servidor (con reintentos si se cae), regla de
firewall, y arranca la aplicación. Requisito previo: **Python 3.9+** y el
**ODBC Driver 18 for SQL Server** instalados en la máquina (el script avisa si
faltan).

Después queda solo configurar la base de datos (pasos de la sección siguiente) y:

```powershell
notepad C:\RegistroHorario\registro-horario.env      # pon la cadena de conexión
.\.venv\Scripts\python.exe manage.py check-db        # verifica la conexión
Restart-ScheduledTask -TaskName RegistroHorario
.\.venv\Scripts\python.exe manage.py create-user --username nombre.apellido --role cadena
```

Las usuarias acceden a `http://<nombre-del-servidor>:8000/`.

Gestión del servicio: `Start-ScheduledTask` / `Stop-ScheduledTask` /
`Get-ScheduledTask -TaskName RegistroHorario`.
Para actualizar: `git pull` y `Restart-ScheduledTask -TaskName RegistroHorario`.

> **TLS**: si se publica más allá de la red interna, pon IIS o un reverse proxy
> delante terminando HTTPS, y entonces `RHP_SESSION_COOKIE_SECURE=true`.

### Alternativa manual

Si se prefiere sin script, la app es un WSGI estándar (`main:app`):

```bash
pip install -r requirements-mssql.txt
waitress-serve --listen=0.0.0.0:8000 main:app
```

## Configuración de la base de datos (Azure SQL)

1. Crea la tabla de usuarios (las demás ya existen en producción):
   ```sql
   -- ejecuta la sección "APP USERS" de sql/schema.sql
   ```
2. Crea el usuario de base de datos de la aplicación, con mínimo privilegio:
   ```sql
   -- ejecuta sql/create_app_user.sql  (requiere un login administrador;
   -- desde el "Query editor" del portal de Azure o SSMS)
   ```
   Concede solo lo que la app usa. En particular **no** da `UPDATE`/`DELETE`
   sobre `gold.RegistroProduccion`, de modo que la inmutabilidad de las líneas
   validadas la garantiza la propia base de datos.
3. Permite la IP del servidor de la app en el firewall de Azure SQL
   (*SQL server → Networking → Firewall rules*).
4. Pon `RHP_DB_BACKEND=mssql` y `RHP_MSSQL_CONNECTION_STRING` en
   `registro-horario.env` (o como variables de entorno).
5. Crea el primer usuario real:
   ```bash
   python3 manage.py create-user --username jefa.planta --role planta --name "..."
   ```

## Escritura en el data warehouse (Azure SQL)

La aplicación **escribe directamente en el data warehouse**; es su función
principal. Con `RHP_DB_BACKEND=mssql` todas las operaciones van contra el
esquema `gold`, con SQL parametrizado:

| Acción en la app | Escritura en el warehouse |
|---|---|
| Alta de línea | `INSERT` en `gold.RegistroProduccion_Temp` (+ snapshot de la OP) |
| Editar línea pendiente | `UPDATE` en `gold.RegistroProduccion_Temp` |
| Borrar línea pendiente | `DELETE` en `gold.RegistroProduccion_Temp` |
| **Validar OP (bloque)** | `INSERT` en `gold.RegistroProduccion` + `DELETE` de la Temp, en **una transacción** |

Los datos **definitivos** quedan en `gold.RegistroProduccion`. La automatización
posterior hacia Business Central solo tiene que **leer** de ahí — la vista
`gold.vw_BC_DiarioSalida` ya expone las líneas confirmadas con el `OperationNo`
extraído y los campos resueltos por `COALESCE` (snapshot ↔ OP abierta), así que
sirve como origen directo sin tocar esta aplicación.

### Verificar la conexión y la escritura

Dos comandos para comprobar el warehouse real antes de dar acceso a las usuarias:

```bash
# 1) Solo lectura: conectividad + que existan las vistas/tablas. No escribe nada.
python3 manage.py check-db

# 2) Escritura de extremo a extremo: inserta una línea de prueba, la lee de
#    vuelta (comprobando el snapshot de la OP) y la BORRA automáticamente.
#    Nunca toca gold.RegistroProduccion (no valida nada).
python3 manage.py test-write --op PO-XXXXX --user tu.usuario
python3 manage.py test-write --keep     # deja la línea para verla en la UI
```

## Ejecutable para Windows (opcional — solo para demos)

> **No es la vía de despliegue.** Para el uso real, usa el despliegue en
> servidor de más arriba: una instalación, credenciales en un único sitio, y las
> usuarias solo necesitan un navegador. El `.exe` existe únicamente para poder
> **enseñar la aplicación en un portátil sin instalar Python ni base de datos**.

No hace falta instalar Python en la máquina destino: hay un `.exe` autocontenido
y un instalador.

**Descargarlos ya compilados**: cada push a la rama lanza el workflow
*Build Windows executable and installer* (GitHub → pestaña **Actions** → última
ejecución → sección **Artifacts**):

| Artefacto | Qué es |
|---|---|
| `RegistroHorario-exe` | `RegistroHorario.exe` suelto (portable). |
| `RegistroHorario-installer` | `RegistroHorarioSetup-1.0.0.exe` para el servidor. |

**Compilarlos a mano** (en Windows, porque PyInstaller no compila cruzado):

```bat
pip install -r requirements-packaging.txt
pyinstaller --clean --noconfirm packaging\registro-horario.spec
iscc packaging\installer.iss
```

### Modo demostración (portable)

```bat
RegistroHorario.exe --demo
```
Arranca con SQLite y datos de ejemplo, abre el navegador solo y **no se conecta
a Azure SQL**. Ideal para que las responsables prueben el flujo.

Al no estar firmado digitalmente, Windows mostrará *"Windows protegió su PC"*
(SmartScreen): pulsa **Más información → Ejecutar de todas formas**, o antes de
ejecutarlo, clic derecho → *Propiedades* → marca **Desbloquear**. Es otro motivo
para desplegar en el servidor: por navegador no aparece ningún aviso.

Un doble clic sin argumentos y sin `registro-horario.env` entra también en modo
demostración (y lo indica en la consola), guardando su base de datos en
`datos\` junto al ejecutable.

### Instalación en el servidor

El instalador copia la aplicación, crea los accesos del menú Inicio, y
opcionalmente registra el **arranque automático al encender** y abre el puerto
8000 en el Firewall de Windows. Después hay que editar
`registro-horario.env` (lo abre al terminar) con la cadena de conexión.

Los usuarios acceden por `http://<nombre-del-servidor>:8000/`.

> **Por qué en un servidor y no en cada PC:** instalado una sola vez, las
> credenciales de la BBDD viven en un único sitio, solo hay que abrir una IP en
> el firewall de Azure SQL, y las actualizaciones se hacen una vez. Si se
> instalara en cada equipo habría que repartir las credenciales y mantener N
> instalaciones.

Nota sobre el arranque automático: se registra como **tarea programada al inicio
del sistema** (ejecutando como `SYSTEM`), no como servicio de Windows nativo, ya
que un ejecutable de consola no implementa el protocolo de control de servicios
y Windows lo mataría por no responder. Si se quiere un servicio real con
acciones de recuperación, envuelve el `.exe` con [NSSM](https://nssm.cc/) o
[WinSW](https://github.com/winsw/winsw).

## Variables de entorno

| Variable | Por defecto | Descripción |
|---|---|---|
| `RHP_SECRET_KEY` | *(inseguro)* | Clave para firmar la cookie de sesión. **Obligatoria en producción.** |
| `RHP_DB_BACKEND` | `sqlite` | `sqlite` o `mssql`. |
| `RHP_SQLITE_PATH` | `instance/rhp_dev.sqlite3` | Ruta del fichero SQLite (dev). |
| `RHP_SQLITE_SEED` | `true` | Sembrar OPs y usuario de ejemplo en SQLite. |
| `RHP_MSSQL_CONNECTION_STRING` | — | Cadena de conexión pyodbc (producción). |
| `RHP_SESSION_COOKIE_SECURE` | `true` | Poner `false` solo para pruebas por HTTP. |
| `RHP_SESSION_LIFETIME_SECONDS` | `28800` | Duración de la sesión (8 h). |
| `RHP_DEFAULT_ADMIN_USER` / `_PASSWORD` / `_ROLE` | `User` / `Cambiar2025!!!` / `planta` | Usuario semilla si la tabla de usuarios está vacía. |
| `RHP_HOST` / `RHP_PORT` / `RHP_DEBUG` | `127.0.0.1` / `8000` / `off` | Servidor de desarrollo. |

Ejemplo de `RHP_MSSQL_CONNECTION_STRING`:
```
Driver={ODBC Driver 18 for SQL Server};Server=tcp:sqlserver-jomipsapde-prod-westeu-001.database.windows.net,1433;Database=sqldb-jomipsapde-prod-westeu-001;UID=<usuario>;PWD=<clave>;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;
```

## Reglas de negocio implementadas (spec §4)

- **Unidades opcional** → se guarda `0` si se deja vacío (la columna no admite NULL).
- **Fecha por línea** obligatoria; el formulario la precarga con la fecha **local
  del navegador** (no la del servidor).
- **Tipo de trabajo**: lista cerrada (`005 Preparación`, `010 Fabricación/Comida`,
  `006 Reproceso`) + vacío. Los valores legacy (`Etiquetado`/`Reproceso`) no se
  ofrecen en altas nuevas.
- **Totales** de horas y unidades al pie de cada tabla.
- **Snapshot de la OP** al crear cada línea (ItemNo, descripción, almacén, ruta,
  centro de máquina, cantidad planificada) para no perder datos si la OP se cierra
  en BC antes de validar (spec §6).
- **Buscador principal** solo lista OPs abiertas (`Status = 3`); la pantalla de
  *líneas pendientes* muestra también OPs ya cerradas con pendientes sin validar.
- **Editar/Borrar por línea** viven solo en *líneas pendientes*.
- **Validar** es **por OP completa, irreversible**, en una transacción de dos
  pasos (copiar con guarda anti-duplicados → borrar de la temporal), con
  confirmación explícita en la UI.
- **Trazabilidad**: `CreatedBy`/`ModifiedBy` guardan el usuario autenticado real
  (el prototipo escribía siempre `'n8n'`).

## Autenticación — nota de evolución

Esta versión implementa la *alternativa mínima* de la spec §5 (usuarios locales
con hash + sesión de servidor). Para pasar a **Entra ID / LDAP** (recomendado, ya
que la empresa usa M365):

- Sustituir `authenticate()` en `app/auth.py` por el flujo OIDC (`msal`/`Authlib`).
- `current_user()`, `login_required` y `CreatedBy/ModifiedBy` no cambian.
- `gold.AppUsers` puede eliminarse o quedar como fallback.

## Business Central — fuera de alcance en esta versión

La escritura hacia BC (`MNOutputJournalLine`) **no está implementada**: en la spec
§7 solo se ha verificado *lectura* (GET), nunca escritura, ni el `Journal_Batch_Name`
ni el `Order_Line_No` están resueltos. La vista `gold.vw_BC_DiarioSalida` ya deja
los datos preparados para esa integración futura; ver las preguntas abiertas en
`CLAUDE.md` §7 y §10 antes de abordarla.
