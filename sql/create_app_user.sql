-- =============================================================================
-- Usuario de base de datos para la aplicación Registro Horario de Producción
-- =============================================================================
-- Ejecutar en la base de datos sqldb-jomipsapde-prod-westeu-001, con un login
-- que tenga permisos de administración (p. ej. el administrador del servidor
-- Azure SQL, o un miembro de db_owner).
--
-- Cómo ejecutarlo:
--   * Portal de Azure -> SQL databases -> [la BBDD] -> "Query editor (preview)"
--   * o SSMS / Azure Data Studio conectado a la BBDD
--
-- Crea un "contained database user" (usuario contenido en la BBDD, sin login a
-- nivel de servidor), que es la práctica recomendada en Azure SQL.
--
-- IMPORTANTE: cambia la contraseña de la línea siguiente antes de ejecutar.
--             Usa una contraseña larga y aleatoria y guárdala en el gestor de
--             secretos / variable de entorno del servidor, no en este fichero.
-- =============================================================================

DECLARE @sql NVARCHAR(MAX);

-- ---------------------------------------------------------------------------
-- 1. Crear el usuario (si no existe)
-- ---------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'app_registro_horario')
BEGIN
    -- >>> CAMBIA ESTA CONTRASEÑA <<<
    SET @sql = N'CREATE USER [app_registro_horario] WITH PASSWORD = ''CAMBIAME-Xy7#pQ2mL9vR4tK!'';';
    EXEC sp_executesql @sql;
    PRINT 'Usuario app_registro_horario creado.';
END
ELSE
    PRINT 'El usuario app_registro_horario ya existía; solo se aplican permisos.';
GO


-- ---------------------------------------------------------------------------
-- 2. Permisos — MÍNIMO PRIVILEGIO
-- ---------------------------------------------------------------------------
-- Se conceden exactamente las operaciones que hace la aplicación, ni una más.
-- En particular NO se concede UPDATE ni DELETE sobre gold.RegistroProduccion:
-- así la inmutabilidad de las líneas ya validadas queda garantizada por la
-- propia base de datos, no solo por la capa de aplicación.

-- Lectura de las vistas (buscador de OPs e histórico)
GRANT SELECT ON gold.vw_PowerApp_OPsAbiertas       TO [app_registro_horario];
GRANT SELECT ON gold.vw_PowerApp_HistoricoCompleto TO [app_registro_horario];

-- Líneas pendientes: alta, edición y borrado
GRANT SELECT, INSERT, UPDATE, DELETE ON gold.RegistroProduccion_Temp TO [app_registro_horario];

-- Líneas definitivas: solo lectura e inserción (la validación copia aquí).
-- Sin UPDATE/DELETE -> una línea confirmada no se puede alterar ni borrar.
GRANT SELECT, INSERT ON gold.RegistroProduccion TO [app_registro_horario];

-- Usuarios de la aplicación (login y creación de usuarios vía manage.py)
GRANT SELECT, INSERT ON gold.AppUsers TO [app_registro_horario];
GO


-- ---------------------------------------------------------------------------
-- 3. Nota sobre "ownership chaining" (posible permiso extra necesario)
-- ---------------------------------------------------------------------------
-- gold.vw_PowerApp_OPsAbiertas lee de bc.[Production Order] y de
-- gold.OPsCerradasApp. Si los esquemas gold y bc tienen el MISMO propietario,
-- el GRANT SELECT sobre la vista es suficiente (la cadena de propiedad evita
-- comprobar permisos en las tablas base).
--
-- Si tienen propietarios distintos, la cadena se rompe y la consulta fallará
-- con "The SELECT permission was denied on the object 'Production Order'".
-- En ese caso, descomenta la línea que corresponda:
--
-- GRANT SELECT ON bc.[Production Order]   TO [app_registro_horario];
-- GRANT SELECT ON gold.OPsCerradasApp     TO [app_registro_horario];
--
-- Para comprobar los propietarios de los esquemas:
--   SELECT s.name AS esquema, dp.name AS propietario
--   FROM sys.schemas s JOIN sys.database_principals dp ON s.principal_id = dp.principal_id
--   WHERE s.name IN ('gold','bc');
GO


-- ---------------------------------------------------------------------------
-- 4. Verificación — permisos efectivos concedidos
-- ---------------------------------------------------------------------------
SELECT
    pr.name                AS usuario,
    p.permission_name      AS permiso,
    SCHEMA_NAME(o.schema_id) + '.' + o.name AS objeto
FROM sys.database_permissions p
JOIN sys.database_principals pr ON p.grantee_principal_id = pr.principal_id
JOIN sys.objects o              ON p.major_id = o.object_id
WHERE pr.name = 'app_registro_horario'
ORDER BY objeto, permiso;
GO


-- =============================================================================
-- 5. Después de ejecutar este script
-- =============================================================================
-- a) Asegúrate de que existe gold.AppUsers (sección "APP USERS" de schema.sql).
--
-- b) Permite la IP del servidor de la aplicación en el firewall de Azure SQL:
--      Portal -> SQL server -> Networking -> Firewall rules
--    (o activa "Allow Azure services" si la app corre dentro de Azure).
--
-- c) Configura la aplicación con la cadena de conexión:
--      RHP_DB_BACKEND=mssql
--      RHP_MSSQL_CONNECTION_STRING=Driver={ODBC Driver 18 for SQL Server};
--        Server=tcp:sqlserver-jomipsapde-prod-westeu-001.database.windows.net,1433;
--        Database=sqldb-jomipsapde-prod-westeu-001;
--        UID=app_registro_horario;PWD=<la contraseña que pusiste arriba>;
--        Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;
--
-- d) Verifica desde el servidor de la aplicación:
--      python3 manage.py check-db      # solo lectura
--      python3 manage.py test-write    # inserta y borra una línea de prueba
-- =============================================================================
