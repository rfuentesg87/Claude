/* =====================================================================
   CRM JOMIPSA — Script 05: registro automático desde Microsoft 365

   Objetivo: que el histórico de comunicación con el cliente se llene
   solo. n8n lee buzón y calendario de cada comercial vía Graph API,
   deja los mensajes en una tabla de staging, y un proceso de
   emparejamiento los convierte en core.Actividad.

   Por qué staging y no insertar directo: el emparejamiento falla a
   menudo (dominios genéricos, clientes nuevos, gmail personales). Con
   staging, lo que no casa queda pendiente de revisión en vez de
   perderse o ensuciar la ficha del cliente equivocado.
   ===================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* --- Dominios de correo por empresa ----------------------------------
   El emparejamiento se apoya en esto. Una empresa puede tener varios
   dominios (matriz y filiales) y un dominio pertenece a una empresa.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.EmpresaDominio') IS NULL
CREATE TABLE core.EmpresaDominio (
    DominioId           INT IDENTITY(1,1) NOT NULL,
    EmpresaId           INT            NOT NULL,
    Dominio             NVARCHAR(150)  NOT NULL,   -- 'economat-armees.fr', en minúsculas
    EsPrincipal         BIT            NOT NULL CONSTRAINT DF_EmpDom_Principal DEFAULT 0,
    FechaCreacion       DATETIME2(3)   NOT NULL CONSTRAINT DF_EmpDom_FC DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_EmpresaDominio PRIMARY KEY CLUSTERED (DominioId),
    CONSTRAINT UQ_EmpresaDominio UNIQUE (Dominio),
    CONSTRAINT FK_EmpDom_Empresa FOREIGN KEY (EmpresaId)
        REFERENCES core.Empresa (EmpresaId) ON DELETE CASCADE
);
GO

/* --- Dominios que nunca se emparejan ---------------------------------
   Correo personal, proveedores de servicios y el propio dominio de
   Jomipsa. Sin esta lista, el primer día se crean cien actividades
   contra la empresa equivocada porque dos comerciales se escribieron
   entre ellos.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.DominioExcluido') IS NULL
CREATE TABLE core.DominioExcluido (
    Dominio             NVARCHAR(150)  NOT NULL,
    Motivo              NVARCHAR(200)  NULL,
    CONSTRAINT PK_DominioExcluido PRIMARY KEY CLUSTERED (Dominio)
);
GO

IF NOT EXISTS (SELECT 1 FROM core.DominioExcluido)
INSERT INTO core.DominioExcluido (Dominio, Motivo) VALUES
    (N'jomipsa.es',      N'Correo interno'),
    (N'gmail.com',       N'Correo personal'),
    (N'hotmail.com',     N'Correo personal'),
    (N'outlook.com',     N'Correo personal'),
    (N'yahoo.com',       N'Correo personal'),
    (N'icloud.com',      N'Correo personal'),
    (N'microsoft.com',   N'Proveedor de servicios'),
    (N'linkedin.com',    N'Notificaciones'),
    (N'noreply.com',     N'Notificaciones');
GO

/* --- Staging de mensajes y reuniones ---------------------------------
   n8n escribe aquí. GraphId es el identificador del mensaje o del
   evento en Microsoft Graph y es la clave de deduplicación: el
   workflow puede reejecutarse mil veces sin duplicar nada.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.ActividadImportada') IS NULL
CREATE TABLE core.ActividadImportada (
    ImportadaId         BIGINT IDENTITY(1,1) NOT NULL,
    Fuente              NVARCHAR(20)   NOT NULL,   -- 'outlook_mail' | 'outlook_calendar'
    GraphId             NVARCHAR(512)  NOT NULL,   -- id del mensaje o evento en Graph
    ConversationId      NVARCHAR(512)  NULL,       -- hilo, para agrupar respuestas
    BuzonEmail          NVARCHAR(200)  NOT NULL,   -- comercial cuyo buzón se leyó
    Direccion           NVARCHAR(10)   NULL,       -- 'entrante' | 'saliente'
    Asunto              NVARCHAR(500)  NULL,
    Cuerpo              NVARCHAR(MAX)  NULL,       -- texto plano, ya sin firma ni cita
    Interlocutores      NVARCHAR(MAX)  NULL,       -- JSON: [{"email":"...","nombre":"..."}]
    DominioPrincipal    NVARCHAR(150)  NULL,       -- dominio externo elegido para emparejar
    FechaMensaje        DATETIME2(3)   NOT NULL,
    DuracionMin         INT            NULL,       -- solo reuniones
    Ubicacion           NVARCHAR(200)  NULL,       -- solo reuniones
    TieneAdjuntos       BIT            NOT NULL CONSTRAINT DF_ActImp_Adj DEFAULT 0,
    Estado              NVARCHAR(20)   NOT NULL CONSTRAINT DF_ActImp_Estado DEFAULT N'pendiente',
    EmpresaId           INT            NULL,       -- resultado del emparejamiento
    ContactoId          INT            NULL,
    ActividadId         BIGINT         NULL,       -- actividad creada, si se creó
    MotivoDescarte      NVARCHAR(200)  NULL,
    FechaImportacion    DATETIME2(3)   NOT NULL CONSTRAINT DF_ActImp_FI DEFAULT SYSUTCDATETIME(),
    FechaProceso        DATETIME2(3)   NULL,
    CONSTRAINT PK_ActividadImportada PRIMARY KEY CLUSTERED (ImportadaId),
    CONSTRAINT UQ_ActividadImportada UNIQUE (Fuente, GraphId),
    CONSTRAINT CK_ActImp_Fuente CHECK (Fuente IN (N'outlook_mail', N'outlook_calendar')),
    CONSTRAINT CK_ActImp_Estado CHECK (Estado IN (N'pendiente', N'emparejada', N'sin_empresa',
                                                  N'excluida', N'descartada')),
    CONSTRAINT FK_ActImp_Empresa   FOREIGN KEY (EmpresaId)   REFERENCES core.Empresa (EmpresaId),
    CONSTRAINT FK_ActImp_Contacto  FOREIGN KEY (ContactoId)  REFERENCES core.Contacto (ContactoId),
    CONSTRAINT FK_ActImp_Actividad FOREIGN KEY (ActividadId) REFERENCES core.Actividad (ActividadId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_ActImp_Estado' AND object_id=OBJECT_ID('core.ActividadImportada'))
CREATE INDEX IX_ActImp_Estado ON core.ActividadImportada (Estado, FechaMensaje DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_ActImp_Dominio' AND object_id=OBJECT_ID('core.ActividadImportada'))
CREATE INDEX IX_ActImp_Dominio ON core.ActividadImportada (DominioPrincipal) WHERE Estado = N'sin_empresa';
GO

/* --- Marca de sincronización por buzón -------------------------------
   deltaLink de Graph, para pedir solo lo nuevo en cada ejecución en
   lugar de releer el buzón entero.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.SincronizacionBuzon') IS NULL
CREATE TABLE core.SincronizacionBuzon (
    BuzonEmail          NVARCHAR(200)  NOT NULL,
    Fuente              NVARCHAR(20)   NOT NULL,
    DeltaLink           NVARCHAR(MAX)  NULL,
    UltimaEjecucion     DATETIME2(3)   NULL,
    UltimoError         NVARCHAR(1000) NULL,
    Activo              BIT            NOT NULL CONSTRAINT DF_SincBuzon_Activo DEFAULT 1,
    CONSTRAINT PK_SincronizacionBuzon PRIMARY KEY CLUSTERED (BuzonEmail, Fuente)
);
GO

/* --- Trazabilidad en la actividad ------------------------------------
   Enlaza cada actividad creada con la fila de staging que la originó.
   Sin esto no hay forma fiable de saber qué se importó y qué se
   escribió a mano, ni de deshacer una importación mal emparejada.
   -------------------------------------------------------------------- */
IF COL_LENGTH('core.Actividad', 'OrigenImportacionId') IS NULL
    ALTER TABLE core.Actividad ADD OrigenImportacionId BIGINT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Actividad_Importacion' AND object_id=OBJECT_ID('core.Actividad'))
CREATE INDEX IX_Actividad_Importacion ON core.Actividad (OrigenImportacionId) WHERE OrigenImportacionId IS NOT NULL;
GO

/* =====================================================================
   EMPAREJAMIENTO
   Lo ejecuta n8n después de cada volcado, o se puede llamar a mano.
   Tres pasadas, de la más fiable a la menos:
     1. El email exacto de un contacto que ya existe.
     2. El dominio registrado en core.EmpresaDominio.
     3. Nada: queda en 'sin_empresa' para revisión.
   ===================================================================== */
CREATE OR ALTER PROCEDURE core.usp_EmparejarActividadesImportadas
    @MaxFilas INT = 500
AS
BEGIN
    SET NOCOUNT ON;

    /* 0. Descartar lo excluido: dominios de la lista negra o mensajes
          en los que no hay ningún interlocutor externo. */
    UPDATE TOP (@MaxFilas) ai
    SET Estado = N'excluida',
        MotivoDescarte = N'Dominio excluido o sin interlocutor externo',
        FechaProceso = SYSUTCDATETIME()
    FROM core.ActividadImportada ai
    WHERE ai.Estado = N'pendiente'
      AND ( ai.DominioPrincipal IS NULL
         OR EXISTS (SELECT 1 FROM core.DominioExcluido de WHERE de.Dominio = ai.DominioPrincipal) );

    /* 1. Por email exacto de contacto conocido. */
    UPDATE TOP (@MaxFilas) ai
    SET EmpresaId  = c.EmpresaId,
        ContactoId = c.ContactoId,
        Estado     = N'emparejada',
        FechaProceso = SYSUTCDATETIME()
    FROM core.ActividadImportada ai
    CROSS APPLY OPENJSON(ai.Interlocutores)
        WITH (Email NVARCHAR(200) '$.email') j
    JOIN core.Contacto c ON LOWER(c.Email) = LOWER(j.Email) AND c.Activo = 1
    WHERE ai.Estado = N'pendiente';

    /* 2. Por dominio registrado. */
    UPDATE TOP (@MaxFilas) ai
    SET EmpresaId = ed.EmpresaId,
        Estado    = N'emparejada',
        FechaProceso = SYSUTCDATETIME()
    FROM core.ActividadImportada ai
    JOIN core.EmpresaDominio ed ON ed.Dominio = ai.DominioPrincipal
    WHERE ai.Estado = N'pendiente';

    /* 3. Lo que queda, a revisión manual. */
    UPDATE TOP (@MaxFilas) ai
    SET Estado = N'sin_empresa',
        FechaProceso = SYSUTCDATETIME()
    FROM core.ActividadImportada ai
    WHERE ai.Estado = N'pendiente';

    /* 4. Crear la actividad para lo emparejado que aún no la tiene.
          OUTPUT devuelve el id de staging junto al de la actividad, así
          que el enlace del paso 5 es exacto y no depende de comparar
          fechas ni asuntos. */
    DECLARE @Creadas TABLE (ActividadId BIGINT, ImportadaId BIGINT);

    INSERT INTO core.Actividad
        (Modulo, Tipo, Asunto, Descripcion, EmpresaId, ContactoId,
         UsuarioId, SalespersonCode, FechaInicio, DuracionMin, Ubicacion,
         Estado, OrigenImportacionId)
    OUTPUT inserted.ActividadId, inserted.OrigenImportacionId INTO @Creadas
    SELECT
        N'crm',
        CASE WHEN ai.Fuente = N'outlook_calendar' THEN N'reunion' ELSE N'email' END,
        LEFT(ISNULL(ai.Asunto, N'(sin asunto)'), 200),
        ai.Cuerpo,
        ai.EmpresaId,
        ai.ContactoId,
        u.UsuarioId,
        u.SalespersonCode,
        ai.FechaMensaje,
        ai.DuracionMin,
        ai.Ubicacion,
        N'realizada',
        ai.ImportadaId
    FROM core.ActividadImportada ai
    JOIN core.Usuario u ON LOWER(u.Email) = LOWER(ai.BuzonEmail)
    WHERE ai.Estado = N'emparejada'
      AND ai.ActividadId IS NULL;

    /* 5. Enlazar la actividad creada con su fila de staging. */
    UPDATE ai
    SET ai.ActividadId = c.ActividadId
    FROM core.ActividadImportada ai
    JOIN @Creadas c ON c.ImportadaId = ai.ImportadaId;

    SELECT
        SUM(CASE WHEN Estado = N'emparejada'  THEN 1 ELSE 0 END) AS Emparejadas,
        SUM(CASE WHEN Estado = N'sin_empresa' THEN 1 ELSE 0 END) AS SinEmpresa,
        SUM(CASE WHEN Estado = N'excluida'    THEN 1 ELSE 0 END) AS Excluidas
    FROM core.ActividadImportada
    WHERE FechaProceso >= DATEADD(MINUTE, -5, SYSUTCDATETIME());
END
GO

/* --- Bandeja de revisión --------------------------------------------
   Lo que no ha casado, agrupado por dominio y ordenado por volumen:
   registrar el dominio más repetido resuelve decenas de mensajes de
   golpe.
   -------------------------------------------------------------------- */
CREATE OR ALTER VIEW crm_v.ImportacionPendiente
AS
SELECT
    ai.DominioPrincipal                 AS Dominio,
    COUNT(*)                            AS Mensajes,
    MIN(ai.FechaMensaje)                AS Desde,
    MAX(ai.FechaMensaje)                AS Hasta,
    COUNT(DISTINCT ai.BuzonEmail)       AS Comerciales,
    MAX(ai.Asunto)                      AS AsuntoEjemplo
FROM core.ActividadImportada ai
WHERE ai.Estado = N'sin_empresa'
GROUP BY ai.DominioPrincipal;
GO

/* --- Siembra inicial de dominios ------------------------------------
   Deduce los dominios a partir de los emails de contacto que ya
   existan. Ejecutar cuando haya contactos cargados.
   -------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE core.usp_SembrarDominiosEmpresa
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO core.EmpresaDominio (EmpresaId, Dominio, EsPrincipal)
    SELECT d.EmpresaId, d.Dominio, 0
    FROM (
        SELECT c.EmpresaId,
               LOWER(SUBSTRING(c.Email, CHARINDEX('@', c.Email) + 1, 200)) AS Dominio,
               COUNT(*) AS N
        FROM core.Contacto c
        WHERE c.Email LIKE '%@%' AND c.Activo = 1
        GROUP BY c.EmpresaId, LOWER(SUBSTRING(c.Email, CHARINDEX('@', c.Email) + 1, 200))
    ) d
    WHERE NOT EXISTS (SELECT 1 FROM core.EmpresaDominio ed WHERE ed.Dominio = d.Dominio)
      AND NOT EXISTS (SELECT 1 FROM core.DominioExcluido de WHERE de.Dominio = d.Dominio);
END
GO

GRANT SELECT ON crm_v.ImportacionPendiente TO [crm_app];
GRANT SELECT, INSERT, UPDATE ON core.ActividadImportada TO [crm_app];
GRANT SELECT, INSERT, UPDATE, DELETE ON core.EmpresaDominio TO [crm_app];
GRANT EXECUTE ON core.usp_EmparejarActividadesImportadas TO [crm_app];
GO
