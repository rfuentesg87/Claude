/* =====================================================================
   CRM JOMIPSA — Script 03: usuario de aplicación, permisos y RLS

   El modelo: Data API Builder se conecta con UN solo usuario SQL
   (crm_app) y, antes de cada consulta, vuelca los claims del token de
   Entra ID en SESSION_CONTEXT. La Row-Level Security lee ese contexto y
   filtra. Resultado: la regla "cada comercial ve su cartera" se escribe
   UNA vez, en la base de datos, y ningún endpoint puede saltársela por
   mucho que se programe mal.
   ===================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =====================================================================
   1. USUARIO DE APLICACIÓN
   ===================================================================== */
-- Cambia la contraseña y guárdala en el gestor de secretos, no en git.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'crm_app')
    CREATE USER [crm_app] WITH PASSWORD = N'<PON-AQUI-UNA-CONTRASENA-LARGA>';
GO

/* Alcance mínimo:
   - crm_v : solo SELECT. Es lo único que consume la API para leer.
   - crm / core : lectura y escritura de los datos propios del CRM.
   - todo lo demás : denegado explícitamente.

   Las vistas de crm_v leen gold.* y bc.*, pero no hace falta conceder
   permisos ahí: la cadena de propiedad (todo pertenece a dbo) hace que
   SQL Server no compruebe permisos sobre los objetos subyacentes al
   acceder a través de la vista. Por eso los DENY de abajo bloquean el
   acceso directo sin romper la ficha 360º. */
GRANT SELECT ON SCHEMA::crm_v TO [crm_app];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::crm  TO [crm_app];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::core TO [crm_app];
GO

DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::bc          TO [crm_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::gold        TO [crm_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::silver      TO [crm_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::snap        TO [crm_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::stg_raw     TO [crm_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::stg_curated TO [crm_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::ctl         TO [crm_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::config      TO [crm_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::helpdesk    TO [crm_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::logistica   TO [crm_app];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo         TO [crm_app];
GO

/* =====================================================================
   2. PREDICADOS DE SEGURIDAD
   ===================================================================== */

/* Lectura: dirección, admin y lectura ven todo; el resto, su cartera.
   Una fila con SalespersonCode NULL (por ejemplo un prospecto sin
   comercial asignado) solo la ven los roles globales. Es intencionado:
   más vale un prospecto invisible que una fila que ve todo el mundo. */
CREATE OR ALTER FUNCTION core.fn_FiltroCartera(@SalespersonCode NVARCHAR(20))
RETURNS TABLE
WITH SCHEMABINDING
AS RETURN
SELECT 1 AS Acceso
WHERE EXISTS (
        SELECT 1
        FROM core.Usuario u
        WHERE u.Activo = 1
          AND u.Rol IN (N'direccion', N'admin', N'lectura')
          AND ( u.EntraObjectId = TRY_CAST(CAST(SESSION_CONTEXT(N'oid') AS NVARCHAR(100)) AS UNIQUEIDENTIFIER)
             OR u.Email = CAST(SESSION_CONTEXT(N'preferred_username') AS NVARCHAR(200))
             OR u.Email = CAST(SESSION_CONTEXT(N'upn')   AS NVARCHAR(200))
             OR u.Email = CAST(SESSION_CONTEXT(N'email') AS NVARCHAR(200)) )
      )
   OR EXISTS (
        SELECT 1
        FROM core.Usuario u
        JOIN core.UsuarioCartera uc ON uc.UsuarioId = u.UsuarioId
        WHERE u.Activo = 1
          AND uc.SalespersonCode = @SalespersonCode
          AND ( u.EntraObjectId = TRY_CAST(CAST(SESSION_CONTEXT(N'oid') AS NVARCHAR(100)) AS UNIQUEIDENTIFIER)
             OR u.Email = CAST(SESSION_CONTEXT(N'preferred_username') AS NVARCHAR(200))
             OR u.Email = CAST(SESSION_CONTEXT(N'upn')   AS NVARCHAR(200))
             OR u.Email = CAST(SESSION_CONTEXT(N'email') AS NVARCHAR(200)) )
      );
GO

/* Escritura: igual, pero 'lectura' no puede escribir. */
CREATE OR ALTER FUNCTION core.fn_BloqueoCartera(@SalespersonCode NVARCHAR(20))
RETURNS TABLE
WITH SCHEMABINDING
AS RETURN
SELECT 1 AS Acceso
WHERE EXISTS (
        SELECT 1
        FROM core.Usuario u
        WHERE u.Activo = 1
          AND u.Rol IN (N'direccion', N'admin')
          AND ( u.EntraObjectId = TRY_CAST(CAST(SESSION_CONTEXT(N'oid') AS NVARCHAR(100)) AS UNIQUEIDENTIFIER)
             OR u.Email = CAST(SESSION_CONTEXT(N'preferred_username') AS NVARCHAR(200))
             OR u.Email = CAST(SESSION_CONTEXT(N'upn')   AS NVARCHAR(200))
             OR u.Email = CAST(SESSION_CONTEXT(N'email') AS NVARCHAR(200)) )
      )
   OR EXISTS (
        SELECT 1
        FROM core.Usuario u
        JOIN core.UsuarioCartera uc ON uc.UsuarioId = u.UsuarioId
        WHERE u.Activo = 1
          AND u.Rol IN (N'comercial', N'kam')
          AND uc.SalespersonCode = @SalespersonCode
          AND ( u.EntraObjectId = TRY_CAST(CAST(SESSION_CONTEXT(N'oid') AS NVARCHAR(100)) AS UNIQUEIDENTIFIER)
             OR u.Email = CAST(SESSION_CONTEXT(N'preferred_username') AS NVARCHAR(200))
             OR u.Email = CAST(SESSION_CONTEXT(N'upn')   AS NVARCHAR(200))
             OR u.Email = CAST(SESSION_CONTEXT(N'email') AS NVARCHAR(200)) )
      );
GO

/* Hijos de oportunidad: heredan el alcance del padre. */
CREATE OR ALTER FUNCTION core.fn_FiltroOportunidad(@OportunidadId BIGINT)
RETURNS TABLE
WITH SCHEMABINDING
AS RETURN
SELECT 1 AS Acceso
FROM crm.Oportunidad o
WHERE o.OportunidadId = @OportunidadId;   -- la RLS de crm.Oportunidad ya filtra aquí
GO

/* =====================================================================
   3. POLÍTICA DE SEGURIDAD
   ===================================================================== */
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = N'PoliticaCartera')
    DROP SECURITY POLICY core.PoliticaCartera;
GO

CREATE SECURITY POLICY core.PoliticaCartera
    ADD FILTER PREDICATE core.fn_FiltroCartera(SalespersonCode)  ON crm.Oportunidad,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON crm.Oportunidad AFTER INSERT,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON crm.Oportunidad AFTER UPDATE,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON crm.Oportunidad BEFORE UPDATE,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON crm.Oportunidad BEFORE DELETE,

    ADD FILTER PREDICATE core.fn_FiltroCartera(SalespersonCode)  ON core.Actividad,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Actividad AFTER INSERT,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Actividad AFTER UPDATE,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Actividad BEFORE UPDATE,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Actividad BEFORE DELETE,

    ADD FILTER PREDICATE core.fn_FiltroCartera(SalespersonCode)  ON core.Tarea,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Tarea AFTER INSERT,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Tarea AFTER UPDATE,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Tarea BEFORE UPDATE,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Tarea BEFORE DELETE,

    ADD FILTER PREDICATE core.fn_FiltroCartera(SalespersonCode)  ON core.Empresa,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Empresa AFTER INSERT,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Empresa AFTER UPDATE,
    ADD BLOCK  PREDICATE core.fn_BloqueoCartera(SalespersonCode) ON core.Empresa BEFORE UPDATE,

    ADD FILTER PREDICATE core.fn_FiltroOportunidad(OportunidadId) ON crm.OportunidadLinea,
    ADD FILTER PREDICATE core.fn_FiltroOportunidad(OportunidadId) ON crm.OportunidadHistorico,
    ADD FILTER PREDICATE core.fn_FiltroOportunidad(OportunidadId) ON crm.OportunidadCompetidor
WITH (STATE = ON, SCHEMABINDING = ON);
GO

/* =====================================================================
   4. PRUEBAS
   Ejecuta esto como dbo para comprobar el filtro sin levantar la API.
   ===================================================================== */
/*
-- Sin contexto: no debe devolver NADA (falla cerrada).
SELECT COUNT(*) AS SinContexto FROM core.vw_MiCartera;

-- Como un comercial: debe devolver solo su cartera.
EXEC sp_set_session_context @key = N'preferred_username', @value = N'<email-del-comercial>';
SELECT COUNT(*) AS ClientesVisibles FROM core.vw_MiCartera;
SELECT TOP 20 * FROM crm_v.MiCartera ORDER BY PrioridadAtencion DESC, Facturacion12m DESC;

-- Como dirección: debe devolver los 1.037 clientes.
EXEC sp_set_session_context @key = N'preferred_username', @value = N'<email-de-direccion>';
SELECT COUNT(*) AS ClientesVisibles FROM core.vw_MiCartera;
*/
GO
