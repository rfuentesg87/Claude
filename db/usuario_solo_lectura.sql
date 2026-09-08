/* =====================================================================
   CRM JOMIPSA — Usuario de SOLO LECTURA para herramientas y agentes
   Ejecutar como administrador de la base de datos, una sola vez.

   Para qué: dar acceso de lectura a un MCP de SQL, a una sesión de
   Claude Code en la nube o a cualquier herramienta de diagnóstico, sin
   entregarle nunca la identidad de nadie ni el usuario crm_app, que sí
   escribe. Es lo que PROMPT-INICIAL.md ya pedía para el MCP.

   Por qué no sirve la autenticación interactiva: el MCP del equipo de
   Rodrigo usa Authentication=Active Directory Interactive, que abre el
   navegador y pide MFA en esa máquina. No funciona sin persona delante,
   así que no vale para un proceso headless ni para un contenedor.

   Dos alternativas, en orden de preferencia:

   OPCIÓN A — Service principal de Entra ID (recomendada)
   No hay contraseña que rote a mano, se revoca desde Entra y hace falta
   un registro de aplicación, que de todas formas es el bloqueador nº 1
   del proyecto para la API de Business Central. Cadena de conexión:
     Server=tcp:<servidor>.database.windows.net,1433;
     Initial Catalog=sqldb-jomipsapde-prod-westeu-001;
     Authentication=Active Directory Service Principal;
     User Id=<CLIENT-ID>;Password=<CLIENT-SECRET>;Encrypt=Mandatory;

   OPCIÓN B — Usuario SQL contenido (rápida)
   Una contraseña larga guardada en el gestor de secretos. Cadena:
     Server=tcp:<servidor>.database.windows.net,1433;
     Initial Catalog=sqldb-jomipsapde-prod-westeu-001;
     User ID=crm_ro;Password=<...>;Encrypt=Mandatory;

   NUNCA en git ni en un chat: solo como variable de entorno.
   ===================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* --- OPCIÓN A: service principal ------------------------------------
   Ejecutar conectado con una identidad de Entra ID que sea administrador
   de Azure AD en el servidor. <NOMBRE-DE-LA-APP> es el nombre para
   mostrar del registro de aplicación, tal cual.
   -------------------------------------------------------------------- */
/*
CREATE USER [<NOMBRE-DE-LA-APP>] FROM EXTERNAL PROVIDER;
GO
*/

/* --- OPCIÓN B: usuario SQL contenido -------------------------------- */
/*
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'crm_ro')
    CREATE USER [crm_ro] WITH PASSWORD = N'<PON-AQUI-UNA-CONTRASENA-LARGA>';
GO
*/

/* =====================================================================
   PERMISOS — solo lectura, sin excepciones
   Sustituir @Principal por el nombre del usuario creado arriba.
   No se usa db_datareader a propósito: cubre demasiado y no deja
   constancia de qué se abrió.
   ===================================================================== */
/*
DECLARE @P SYSNAME = N'crm_ro';   -- o el nombre de la app en la opción A
DECLARE @sql NVARCHAR(MAX) = N'';

-- Lectura de lo que el CRM necesita conocer del ERP y de sí mismo.
SELECT @sql = @sql + N'GRANT SELECT ON SCHEMA::' + QUOTENAME(s) + N' TO ' + QUOTENAME(@P) + N';' + CHAR(10)
FROM (VALUES (N'bc'), (N'gold'), (N'core'), (N'crm'), (N'crm_v')) v(s);

-- Ver la definición de vistas y procedimientos, para poder revisarlos.
SELECT @sql = @sql + N'GRANT VIEW DEFINITION ON SCHEMA::' + QUOTENAME(s) + N' TO ' + QUOTENAME(@P) + N';' + CHAR(10)
FROM (VALUES (N'core'), (N'crm'), (N'crm_v'), (N'gold')) v(s);

-- Denegar escritura de forma explícita: un DENY gana a cualquier GRANT
-- que alguien conceda por error más adelante.
SELECT @sql = @sql + N'DENY INSERT, UPDATE, DELETE, EXECUTE, ALTER ON SCHEMA::' + QUOTENAME(s)
                   + N' TO ' + QUOTENAME(@P) + N';' + CHAR(10)
FROM (VALUES (N'bc'), (N'gold'), (N'core'), (N'crm'), (N'crm_v'), (N'dbo')) v(s);

PRINT @sql;      -- revisar antes de ejecutar
-- EXEC sp_executesql @sql;
GO
*/

/* =====================================================================
   COMPROBACIÓN
   Conectado ya como el usuario nuevo: la primera debe devolver filas y
   la segunda debe fallar con «permiso denegado».
   ===================================================================== */
/*
SELECT TOP 5 [No.], [Name] FROM bc.[Customer];
BEGIN TRY
    UPDATE core.Empresa SET Notas = N'prueba' WHERE 1 = 0;
    PRINT 'MAL: el usuario puede escribir';
END TRY
BEGIN CATCH
    PRINT 'BIEN: escritura denegada -> ' + ERROR_MESSAGE();
END CATCH
GO
*/

/* =====================================================================
   RECORDATORIO DE FIREWALL
   Una conexión desde un contenedor en la nube llega a Azure SQL con la
   IP de salida de ese contenedor, no con la de Jomipsa. Si el firewall
   no la admite, el error es el 40615 y trae la IP en el propio mensaje.
   Antes de abrir nada, sopesarlo: es la base de datos de producción que
   comparten los pipelines y los paneles.
   ===================================================================== */
