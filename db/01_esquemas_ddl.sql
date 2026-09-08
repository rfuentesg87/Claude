/* =====================================================================
   CRM JOMIPSA — Script 01: esquemas core y crm
   Base de datos: sqldb-jomipsapde-prod-westeu-001
   Convención: PascalCase en español, igual que el esquema helpdesk.

   REGLA DE ORO: este script NO crea, altera ni borra NADA dentro de
   los esquemas bc, gold, silver, snap, stg_*, ctl ni config.
   Todas las dependencias van en un solo sentido: crm -> crm_v -> ERP,
   y del ERP solo se leen las vistas gold.vw_* y las tablas de bc a
   través de la capa base crm_v.Erp* del script 00.
   ===================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID('core') IS NULL EXEC('CREATE SCHEMA core AUTHORIZATION dbo');
GO
IF SCHEMA_ID('crm')  IS NULL EXEC('CREATE SCHEMA crm  AUTHORIZATION dbo');
GO
IF SCHEMA_ID('crm_v') IS NULL EXEC('CREATE SCHEMA crm_v AUTHORIZATION dbo');
GO

/* =====================================================================
   NÚCLEO COMPARTIDO (core)
   Lo reutilizarán compras e incidencias sin tocar una línea.
   ===================================================================== */

/* --- core.Usuario ---------------------------------------------------
   Un usuario del CRM = una identidad de Entra ID.
   EntraObjectId (claim 'oid') es el identificador estable: el email
   puede cambiar, el oid no. Rol decide el alcance global.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.Usuario') IS NULL
CREATE TABLE core.Usuario (
    UsuarioId           INT IDENTITY(1,1) NOT NULL,
    EntraObjectId       UNIQUEIDENTIFIER NULL,
    Email               NVARCHAR(200)  NOT NULL,
    Nombre              NVARCHAR(200)  NOT NULL,
    SalespersonCode     NVARCHAR(20)   NULL,   -- código en BC (crm_v.ErpComercial)
    Rol                 NVARCHAR(20)   NOT NULL CONSTRAINT DF_Usuario_Rol DEFAULT N'comercial',
    Activo              BIT            NOT NULL CONSTRAINT DF_Usuario_Activo DEFAULT 1,
    FechaCreacion       DATETIME2(3)   NOT NULL CONSTRAINT DF_Usuario_FC DEFAULT SYSUTCDATETIME(),
    FechaModificacion   DATETIME2(3)   NOT NULL CONSTRAINT DF_Usuario_FM DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Usuario PRIMARY KEY CLUSTERED (UsuarioId),
    CONSTRAINT UQ_Usuario_Email UNIQUE (Email),
    CONSTRAINT CK_Usuario_Rol CHECK (Rol IN (N'comercial', N'kam', N'direccion', N'admin', N'lectura'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_Usuario_Entra' AND object_id=OBJECT_ID('core.Usuario'))
CREATE UNIQUE INDEX UQ_Usuario_Entra ON core.Usuario (EntraObjectId) WHERE EntraObjectId IS NOT NULL;
GO

/* --- core.UsuarioCartera --------------------------------------------
   Qué códigos de comercial puede ver cada usuario.
   Un comercial normal tendrá una fila (la suya). Un KAM que cubre a un
   compañero de baja tendrá dos. Dirección no necesita filas: su rol
   ya le da acceso global.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.UsuarioCartera') IS NULL
CREATE TABLE core.UsuarioCartera (
    UsuarioId           INT           NOT NULL,
    SalespersonCode     NVARCHAR(20)  NOT NULL,
    FechaAlta           DATETIME2(3)  NOT NULL CONSTRAINT DF_UsuCart_FA DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_UsuarioCartera PRIMARY KEY CLUSTERED (UsuarioId, SalespersonCode),
    CONSTRAINT FK_UsuarioCartera_Usuario FOREIGN KEY (UsuarioId)
        REFERENCES core.Usuario (UsuarioId) ON DELETE CASCADE
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_UsuarioCartera_Code' AND object_id=OBJECT_ID('core.UsuarioCartera'))
CREATE INDEX IX_UsuarioCartera_Code ON core.UsuarioCartera (SalespersonCode) INCLUDE (UsuarioId);
GO

/* --- core.Empresa ---------------------------------------------------
   La entidad "organización" compartida por todos los módulos.
   Un cliente de BC, un prospecto que aún no existe en BC, o un
   proveedor cuando entre el módulo de compras: todos viven aquí.
   BcCustomerNo / BcVendorNo son el único punto de enlace con el ERP.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.Empresa') IS NULL
CREATE TABLE core.Empresa (
    EmpresaId           INT IDENTITY(1,1) NOT NULL,
    BcCustomerNo        NVARCHAR(20)   NULL,   -- bc.[Customer].[No.] / crm_v.ErpCliente.CustomerNo
    BcVendorNo          NVARCHAR(20)   NULL,   -- reservado para el módulo de compras
    Nombre              NVARCHAR(200)  NOT NULL,
    NombreComercial     NVARCHAR(200)  NULL,
    Tipo                NVARCHAR(20)   NOT NULL CONSTRAINT DF_Empresa_Tipo DEFAULT N'cliente',
    Segmento            NVARCHAR(50)   NULL,   -- militar / ayuda-humanitaria / retail / outdoor
    PaisCodigo          NVARCHAR(10)   NULL,
    Ciudad              NVARCHAR(100)  NULL,
    Direccion           NVARCHAR(250)  NULL,
    Web                 NVARCHAR(250)  NULL,
    Telefono            NVARCHAR(50)   NULL,
    Email               NVARCHAR(200)  NULL,
    SalespersonCode     NVARCHAR(20)   NULL,   -- propietario; para prospectos sin ficha en BC
    PotencialAnual      DECIMAL(18,2)  NULL,
    Notas               NVARCHAR(MAX)  NULL,
    Activo              BIT            NOT NULL CONSTRAINT DF_Empresa_Activo DEFAULT 1,
    CreadoPor           INT            NULL,
    FechaCreacion       DATETIME2(3)   NOT NULL CONSTRAINT DF_Empresa_FC DEFAULT SYSUTCDATETIME(),
    ModificadoPor       INT            NULL,
    FechaModificacion   DATETIME2(3)   NOT NULL CONSTRAINT DF_Empresa_FM DEFAULT SYSUTCDATETIME(),
    Version             ROWVERSION     NOT NULL,
    CONSTRAINT PK_Empresa PRIMARY KEY CLUSTERED (EmpresaId),
    CONSTRAINT CK_Empresa_Tipo CHECK (Tipo IN (N'cliente', N'prospecto', N'proveedor', N'otro')),
    CONSTRAINT FK_Empresa_CreadoPor  FOREIGN KEY (CreadoPor)     REFERENCES core.Usuario (UsuarioId),
    CONSTRAINT FK_Empresa_ModificadoPor FOREIGN KEY (ModificadoPor) REFERENCES core.Usuario (UsuarioId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_Empresa_BcCustomer' AND object_id=OBJECT_ID('core.Empresa'))
CREATE UNIQUE INDEX UQ_Empresa_BcCustomer ON core.Empresa (BcCustomerNo) WHERE BcCustomerNo IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Empresa_Salesperson' AND object_id=OBJECT_ID('core.Empresa'))
CREATE INDEX IX_Empresa_Salesperson ON core.Empresa (SalespersonCode) INCLUDE (Nombre, Tipo, Activo);
GO

/* --- core.Contacto --------------------------------------------------- */
IF OBJECT_ID('core.Contacto') IS NULL
CREATE TABLE core.Contacto (
    ContactoId          INT IDENTITY(1,1) NOT NULL,
    EmpresaId           INT            NOT NULL,
    BcContactNo         NVARCHAR(20)   NULL,   -- bc.Contact.No_ si existe
    Nombre              NVARCHAR(100)  NOT NULL,
    Apellidos           NVARCHAR(150)  NULL,
    Cargo               NVARCHAR(100)  NULL,
    Departamento        NVARCHAR(100)  NULL,
    Email               NVARCHAR(200)  NULL,
    Telefono            NVARCHAR(50)   NULL,
    Movil               NVARCHAR(50)   NULL,
    Idioma              NVARCHAR(10)   NULL,
    EsPrincipal         BIT            NOT NULL CONSTRAINT DF_Contacto_Principal DEFAULT 0,
    EsDecisor           BIT            NOT NULL CONSTRAINT DF_Contacto_Decisor DEFAULT 0,
    Notas               NVARCHAR(MAX)  NULL,
    Activo              BIT            NOT NULL CONSTRAINT DF_Contacto_Activo DEFAULT 1,
    CreadoPor           INT            NULL,
    FechaCreacion       DATETIME2(3)   NOT NULL CONSTRAINT DF_Contacto_FC DEFAULT SYSUTCDATETIME(),
    ModificadoPor       INT            NULL,
    FechaModificacion   DATETIME2(3)   NOT NULL CONSTRAINT DF_Contacto_FM DEFAULT SYSUTCDATETIME(),
    Version             ROWVERSION     NOT NULL,
    CONSTRAINT PK_Contacto PRIMARY KEY CLUSTERED (ContactoId),
    CONSTRAINT FK_Contacto_Empresa FOREIGN KEY (EmpresaId) REFERENCES core.Empresa (EmpresaId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Contacto_Empresa' AND object_id=OBJECT_ID('core.Contacto'))
CREATE INDEX IX_Contacto_Empresa ON core.Contacto (EmpresaId) INCLUDE (Nombre, Apellidos, Email, EsPrincipal);
GO

/* --- core.Actividad --------------------------------------------------
   Visitas, llamadas, emails, reuniones y notas. Una sola tabla para
   todos los módulos: la visita comercial y la llamada de una incidencia
   son la misma cosa con distinto Modulo.
   EntidadTipo/EntidadId es el enlace polimórfico a la oportunidad, el
   ticket o el pedido de compra al que pertenece la actividad.
   SalespersonCode va desnormalizado a propósito: es la columna sobre la
   que actúa el filtro de seguridad y tiene que ser barata de evaluar.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.Actividad') IS NULL
CREATE TABLE core.Actividad (
    ActividadId         BIGINT IDENTITY(1,1) NOT NULL,
    Modulo              NVARCHAR(20)   NOT NULL CONSTRAINT DF_Actividad_Modulo DEFAULT N'crm',
    Tipo                NVARCHAR(20)   NOT NULL,
    Asunto              NVARCHAR(200)  NOT NULL,
    Descripcion         NVARCHAR(MAX)  NULL,
    EmpresaId           INT            NULL,
    ContactoId          INT            NULL,
    EntidadTipo         NVARCHAR(30)   NULL,   -- 'oportunidad' | 'ticket' | 'pedido'
    EntidadId           BIGINT         NULL,
    UsuarioId           INT            NOT NULL,
    SalespersonCode     NVARCHAR(20)   NULL,
    FechaInicio         DATETIME2(3)   NOT NULL,
    FechaFin            DATETIME2(3)   NULL,
    DuracionMin         INT            NULL,
    Ubicacion           NVARCHAR(200)  NULL,
    Estado              NVARCHAR(20)   NOT NULL CONSTRAINT DF_Actividad_Estado DEFAULT N'realizada',
    Resultado           NVARCHAR(MAX)  NULL,
    ProximoPaso         NVARCHAR(MAX)  NULL,
    FechaCreacion       DATETIME2(3)   NOT NULL CONSTRAINT DF_Actividad_FC DEFAULT SYSUTCDATETIME(),
    FechaModificacion   DATETIME2(3)   NOT NULL CONSTRAINT DF_Actividad_FM DEFAULT SYSUTCDATETIME(),
    Version             ROWVERSION     NOT NULL,
    CONSTRAINT PK_Actividad PRIMARY KEY CLUSTERED (ActividadId),
    CONSTRAINT CK_Actividad_Tipo CHECK (Tipo IN (N'visita', N'llamada', N'email', N'reunion', N'nota', N'videollamada', N'feria', N'whatsapp')),
    CONSTRAINT CK_Actividad_Estado CHECK (Estado IN (N'planificada', N'realizada', N'cancelada')),
    CONSTRAINT FK_Actividad_Empresa  FOREIGN KEY (EmpresaId)  REFERENCES core.Empresa (EmpresaId),
    CONSTRAINT FK_Actividad_Contacto FOREIGN KEY (ContactoId) REFERENCES core.Contacto (ContactoId),
    CONSTRAINT FK_Actividad_Usuario  FOREIGN KEY (UsuarioId)  REFERENCES core.Usuario (UsuarioId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Actividad_Empresa_Fecha' AND object_id=OBJECT_ID('core.Actividad'))
CREATE INDEX IX_Actividad_Empresa_Fecha ON core.Actividad (EmpresaId, FechaInicio DESC) INCLUDE (Tipo, Asunto, UsuarioId, Estado);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Actividad_Entidad' AND object_id=OBJECT_ID('core.Actividad'))
CREATE INDEX IX_Actividad_Entidad ON core.Actividad (EntidadTipo, EntidadId) INCLUDE (FechaInicio, Tipo, Asunto);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Actividad_Cartera' AND object_id=OBJECT_ID('core.Actividad'))
CREATE INDEX IX_Actividad_Cartera ON core.Actividad (SalespersonCode, FechaInicio DESC);
GO

/* --- core.Tarea ------------------------------------------------------ */
IF OBJECT_ID('core.Tarea') IS NULL
CREATE TABLE core.Tarea (
    TareaId             BIGINT IDENTITY(1,1) NOT NULL,
    Modulo              NVARCHAR(20)   NOT NULL CONSTRAINT DF_Tarea_Modulo DEFAULT N'crm',
    Titulo              NVARCHAR(200)  NOT NULL,
    Descripcion         NVARCHAR(MAX)  NULL,
    EmpresaId           INT            NULL,
    ContactoId          INT            NULL,
    EntidadTipo         NVARCHAR(30)   NULL,
    EntidadId           BIGINT         NULL,
    AsignadoA           INT            NOT NULL,
    CreadoPor           INT            NOT NULL,
    SalespersonCode     NVARCHAR(20)   NULL,
    FechaVencimiento    DATE           NULL,
    Prioridad           NVARCHAR(10)   NOT NULL CONSTRAINT DF_Tarea_Prioridad DEFAULT N'media',
    Estado              NVARCHAR(20)   NOT NULL CONSTRAINT DF_Tarea_Estado DEFAULT N'pendiente',
    FechaCompletada     DATETIME2(3)   NULL,
    FechaCreacion       DATETIME2(3)   NOT NULL CONSTRAINT DF_Tarea_FC DEFAULT SYSUTCDATETIME(),
    FechaModificacion   DATETIME2(3)   NOT NULL CONSTRAINT DF_Tarea_FM DEFAULT SYSUTCDATETIME(),
    Version             ROWVERSION     NOT NULL,
    CONSTRAINT PK_Tarea PRIMARY KEY CLUSTERED (TareaId),
    CONSTRAINT CK_Tarea_Prioridad CHECK (Prioridad IN (N'baja', N'media', N'alta', N'urgente')),
    CONSTRAINT CK_Tarea_Estado CHECK (Estado IN (N'pendiente', N'en_curso', N'completada', N'cancelada')),
    CONSTRAINT FK_Tarea_Empresa   FOREIGN KEY (EmpresaId) REFERENCES core.Empresa (EmpresaId),
    CONSTRAINT FK_Tarea_Contacto  FOREIGN KEY (ContactoId) REFERENCES core.Contacto (ContactoId),
    CONSTRAINT FK_Tarea_Asignado  FOREIGN KEY (AsignadoA) REFERENCES core.Usuario (UsuarioId),
    CONSTRAINT FK_Tarea_Creador   FOREIGN KEY (CreadoPor) REFERENCES core.Usuario (UsuarioId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Tarea_Asignado_Estado' AND object_id=OBJECT_ID('core.Tarea'))
CREATE INDEX IX_Tarea_Asignado_Estado ON core.Tarea (AsignadoA, Estado, FechaVencimiento) INCLUDE (Titulo, Prioridad, EmpresaId);
GO

/* --- core.Adjunto ----------------------------------------------------
   Metadatos únicamente. El binario vive en SharePoint o en Blob Storage
   y aquí solo se guarda la URL: meter ficheros en la BBDD dispara el
   tamaño, encarece el tier y complica los backups.
   -------------------------------------------------------------------- */
IF OBJECT_ID('core.Adjunto') IS NULL
CREATE TABLE core.Adjunto (
    AdjuntoId           BIGINT IDENTITY(1,1) NOT NULL,
    Modulo              NVARCHAR(20)   NOT NULL CONSTRAINT DF_Adjunto_Modulo DEFAULT N'crm',
    EntidadTipo         NVARCHAR(30)   NOT NULL,
    EntidadId           BIGINT         NOT NULL,
    EmpresaId           INT            NULL,
    NombreFichero       NVARCHAR(255)  NOT NULL,
    TipoMime            NVARCHAR(100)  NULL,
    TamanoBytes         BIGINT         NULL,
    UrlAlmacen          NVARCHAR(1000) NOT NULL,
    Almacen             NVARCHAR(20)   NOT NULL CONSTRAINT DF_Adjunto_Almacen DEFAULT N'sharepoint',
    SubidoPor           INT            NOT NULL,
    FechaSubida         DATETIME2(3)   NOT NULL CONSTRAINT DF_Adjunto_FS DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Adjunto PRIMARY KEY CLUSTERED (AdjuntoId),
    CONSTRAINT CK_Adjunto_Almacen CHECK (Almacen IN (N'sharepoint', N'blob', N'local')),
    CONSTRAINT FK_Adjunto_Empresa FOREIGN KEY (EmpresaId) REFERENCES core.Empresa (EmpresaId),
    CONSTRAINT FK_Adjunto_Usuario FOREIGN KEY (SubidoPor) REFERENCES core.Usuario (UsuarioId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Adjunto_Entidad' AND object_id=OBJECT_ID('core.Adjunto'))
CREATE INDEX IX_Adjunto_Entidad ON core.Adjunto (EntidadTipo, EntidadId);
GO

/* =====================================================================
   MÓDULO COMERCIAL (crm)
   ===================================================================== */

IF OBJECT_ID('crm.Etapa') IS NULL
CREATE TABLE crm.Etapa (
    EtapaId             INT IDENTITY(1,1) NOT NULL,
    Codigo              NVARCHAR(20)   NOT NULL,
    Nombre              NVARCHAR(100)  NOT NULL,
    Orden               INT            NOT NULL,
    ProbabilidadPct     DECIMAL(5,2)   NOT NULL CONSTRAINT DF_Etapa_Prob DEFAULT 0,
    EsGanada            BIT            NOT NULL CONSTRAINT DF_Etapa_Ganada DEFAULT 0,
    EsPerdida           BIT            NOT NULL CONSTRAINT DF_Etapa_Perdida DEFAULT 0,
    Activa              BIT            NOT NULL CONSTRAINT DF_Etapa_Activa DEFAULT 1,
    CONSTRAINT PK_Etapa PRIMARY KEY CLUSTERED (EtapaId),
    CONSTRAINT UQ_Etapa_Codigo UNIQUE (Codigo)
);
GO

IF OBJECT_ID('crm.MotivoPerdida') IS NULL
CREATE TABLE crm.MotivoPerdida (
    MotivoId            INT IDENTITY(1,1) NOT NULL,
    Nombre              NVARCHAR(100)  NOT NULL,
    Orden               INT            NOT NULL CONSTRAINT DF_Motivo_Orden DEFAULT 0,
    Activo              BIT            NOT NULL CONSTRAINT DF_Motivo_Activo DEFAULT 1,
    CONSTRAINT PK_MotivoPerdida PRIMARY KEY CLUSTERED (MotivoId),
    CONSTRAINT UQ_MotivoPerdida_Nombre UNIQUE (Nombre)
);
GO

IF OBJECT_ID('crm.Competidor') IS NULL
CREATE TABLE crm.Competidor (
    CompetidorId        INT IDENTITY(1,1) NOT NULL,
    Nombre              NVARCHAR(150)  NOT NULL,
    PaisCodigo          NVARCHAR(10)   NULL,
    Web                 NVARCHAR(250)  NULL,
    Notas               NVARCHAR(MAX)  NULL,
    Activo              BIT            NOT NULL CONSTRAINT DF_Competidor_Activo DEFAULT 1,
    CONSTRAINT PK_Competidor PRIMARY KEY CLUSTERED (CompetidorId),
    CONSTRAINT UQ_Competidor_Nombre UNIQUE (Nombre)
);
GO

/* --- crm.Oportunidad -------------------------------------------------
   ReferenciaLicitacion y FechaLimitePresentacion existen porque en
   Jomipsa una parte del pipeline son licitaciones y consultas de mercado
   (tipo OPRAN o UNICEF), no ventas de ciclo corto. Sin esos campos el
   comercial acaba metiendo la fecha límite en el campo de notas.
   -------------------------------------------------------------------- */
IF OBJECT_ID('crm.Oportunidad') IS NULL
CREATE TABLE crm.Oportunidad (
    OportunidadId       BIGINT IDENTITY(1,1) NOT NULL,
    Codigo              AS (N'OPP-' + RIGHT(N'000000' + CAST(OportunidadId AS NVARCHAR(10)), 6)) PERSISTED,
    EmpresaId           INT            NOT NULL,
    ContactoId          INT            NULL,
    Titulo              NVARCHAR(200)  NOT NULL,
    Descripcion         NVARCHAR(MAX)  NULL,
    EtapaId             INT            NOT NULL,
    Estado              NVARCHAR(20)   NOT NULL CONSTRAINT DF_Oport_Estado DEFAULT N'abierta',
    SalespersonCode     NVARCHAR(20)   NOT NULL,
    PropietarioId       INT            NOT NULL,
    ImporteEstimado     DECIMAL(18,2)  NULL,
    Moneda              NCHAR(3)       NOT NULL CONSTRAINT DF_Oport_Moneda DEFAULT N'EUR',
    MargenEstimadoPct   DECIMAL(5,2)   NULL,
    ProbabilidadPct     DECIMAL(5,2)   NULL,   -- si es NULL se hereda de la etapa
    FechaApertura       DATE           NOT NULL CONSTRAINT DF_Oport_FApertura DEFAULT CAST(SYSUTCDATETIME() AS DATE),
    FechaCierrePrevista DATE           NULL,
    FechaCierreReal     DATE           NULL,
    MotivoPerdidaId     INT            NULL,
    Origen              NVARCHAR(30)   NULL,   -- licitacion / visita / feria / referencia / web / inbound
    TipoNegocio         NVARCHAR(30)   NULL,   -- militar / ayuda-humanitaria / retail / outdoor
    ReferenciaLicitacion NVARCHAR(100) NULL,
    FechaLimitePresentacion DATE       NULL,
    BcOpportunityNo     NVARCHAR(20)   NULL,   -- si algún día se sincroniza con bc.Opportunity
    CreadoPor           INT            NULL,
    FechaCreacion       DATETIME2(3)   NOT NULL CONSTRAINT DF_Oport_FC DEFAULT SYSUTCDATETIME(),
    ModificadoPor       INT            NULL,
    FechaModificacion   DATETIME2(3)   NOT NULL CONSTRAINT DF_Oport_FM DEFAULT SYSUTCDATETIME(),
    Version             ROWVERSION     NOT NULL,
    CONSTRAINT PK_Oportunidad PRIMARY KEY CLUSTERED (OportunidadId),
    CONSTRAINT CK_Oport_Estado CHECK (Estado IN (N'abierta', N'ganada', N'perdida', N'aplazada')),
    CONSTRAINT CK_Oport_Cierre CHECK (Estado = N'abierta' OR FechaCierreReal IS NOT NULL),
    CONSTRAINT FK_Oport_Empresa  FOREIGN KEY (EmpresaId)  REFERENCES core.Empresa (EmpresaId),
    CONSTRAINT FK_Oport_Contacto FOREIGN KEY (ContactoId) REFERENCES core.Contacto (ContactoId),
    CONSTRAINT FK_Oport_Etapa    FOREIGN KEY (EtapaId)    REFERENCES crm.Etapa (EtapaId),
    CONSTRAINT FK_Oport_Motivo   FOREIGN KEY (MotivoPerdidaId) REFERENCES crm.MotivoPerdida (MotivoId),
    CONSTRAINT FK_Oport_Propietario FOREIGN KEY (PropietarioId) REFERENCES core.Usuario (UsuarioId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Oport_Cartera' AND object_id=OBJECT_ID('crm.Oportunidad'))
CREATE INDEX IX_Oport_Cartera ON crm.Oportunidad (SalespersonCode, Estado) INCLUDE (EmpresaId, Titulo, ImporteEstimado, FechaCierrePrevista, EtapaId);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Oport_Empresa' AND object_id=OBJECT_ID('crm.Oportunidad'))
CREATE INDEX IX_Oport_Empresa ON crm.Oportunidad (EmpresaId, Estado) INCLUDE (Titulo, ImporteEstimado, FechaCierrePrevista);
GO

IF OBJECT_ID('crm.OportunidadLinea') IS NULL
CREATE TABLE crm.OportunidadLinea (
    LineaId             BIGINT IDENTITY(1,1) NOT NULL,
    OportunidadId       BIGINT         NOT NULL,
    Orden               INT            NOT NULL CONSTRAINT DF_OportLinea_Orden DEFAULT 1,
    BcItemNo            NVARCHAR(20)   NULL,   -- crm_v.ErpArticulo.ItemNo
    Descripcion         NVARCHAR(250)  NOT NULL,
    Cantidad            DECIMAL(18,4)  NULL,
    UnidadMedida        NVARCHAR(20)   NULL,
    PrecioUnitario      DECIMAL(18,4)  NULL,
    CosteUnitarioEst    DECIMAL(18,4)  NULL,
    Importe             AS (CAST(ISNULL(Cantidad,0) * ISNULL(PrecioUnitario,0) AS DECIMAL(18,2))) PERSISTED,
    CONSTRAINT PK_OportunidadLinea PRIMARY KEY CLUSTERED (LineaId),
    CONSTRAINT FK_OportLinea_Oport FOREIGN KEY (OportunidadId)
        REFERENCES crm.Oportunidad (OportunidadId) ON DELETE CASCADE
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_OportLinea_Oport' AND object_id=OBJECT_ID('crm.OportunidadLinea'))
CREATE INDEX IX_OportLinea_Oport ON crm.OportunidadLinea (OportunidadId, Orden);
GO

IF OBJECT_ID('crm.OportunidadCompetidor') IS NULL
CREATE TABLE crm.OportunidadCompetidor (
    OportunidadId       BIGINT         NOT NULL,
    CompetidorId        INT            NOT NULL,
    EsGanador           BIT            NOT NULL CONSTRAINT DF_OportComp_Ganador DEFAULT 0,
    PrecioEstimado      DECIMAL(18,2)  NULL,
    Notas               NVARCHAR(MAX)  NULL,
    CONSTRAINT PK_OportunidadCompetidor PRIMARY KEY CLUSTERED (OportunidadId, CompetidorId),
    CONSTRAINT FK_OportComp_Oport FOREIGN KEY (OportunidadId)
        REFERENCES crm.Oportunidad (OportunidadId) ON DELETE CASCADE,
    CONSTRAINT FK_OportComp_Comp FOREIGN KEY (CompetidorId) REFERENCES crm.Competidor (CompetidorId)
);
GO

/* --- crm.OportunidadHistorico ---------------------------------------
   Cada cambio de etapa deja rastro. Sin esta tabla no hay forma de
   calcular tiempo medio por etapa ni tasa de conversión real.
   -------------------------------------------------------------------- */
IF OBJECT_ID('crm.OportunidadHistorico') IS NULL
CREATE TABLE crm.OportunidadHistorico (
    HistoricoId         BIGINT IDENTITY(1,1) NOT NULL,
    OportunidadId       BIGINT         NOT NULL,
    EtapaOrigenId       INT            NULL,
    EtapaDestinoId      INT            NOT NULL,
    EstadoOrigen        NVARCHAR(20)   NULL,
    EstadoDestino       NVARCHAR(20)   NULL,
    ImporteEnCambio     DECIMAL(18,2)  NULL,
    UsuarioId           INT            NOT NULL,
    Comentario          NVARCHAR(MAX)  NULL,
    Fecha               DATETIME2(3)   NOT NULL CONSTRAINT DF_OportHist_Fecha DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_OportunidadHistorico PRIMARY KEY CLUSTERED (HistoricoId),
    CONSTRAINT FK_OportHist_Oport FOREIGN KEY (OportunidadId)
        REFERENCES crm.Oportunidad (OportunidadId) ON DELETE CASCADE,
    CONSTRAINT FK_OportHist_Usuario FOREIGN KEY (UsuarioId) REFERENCES core.Usuario (UsuarioId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_OportHist_Oport' AND object_id=OBJECT_ID('crm.OportunidadHistorico'))
CREATE INDEX IX_OportHist_Oport ON crm.OportunidadHistorico (OportunidadId, Fecha DESC);
GO

/* =====================================================================
   DATOS INICIALES
   ===================================================================== */

IF NOT EXISTS (SELECT 1 FROM crm.Etapa)
INSERT INTO crm.Etapa (Codigo, Nombre, Orden, ProbabilidadPct, EsGanada, EsPerdida) VALUES
    (N'IDENT',  N'Identificada',       1,  10, 0, 0),
    (N'CUALIF', N'Cualificada',        2,  25, 0, 0),
    (N'MUESTRA',N'Muestras enviadas',  3,  40, 0, 0),
    (N'OFERTA', N'Oferta presentada',  4,  60, 0, 0),
    (N'NEGOC',  N'Negociación',        5,  80, 0, 0),
    (N'GANADA', N'Ganada',             6, 100, 1, 0),
    (N'PERDIDA',N'Perdida',            7,   0, 0, 1);
GO

IF NOT EXISTS (SELECT 1 FROM crm.MotivoPerdida)
INSERT INTO crm.MotivoPerdida (Nombre, Orden) VALUES
    (N'Precio',                      1),
    (N'Plazo de entrega',            2),
    (N'Especificación técnica',      3),
    (N'Capacidad de producción',     4),
    (N'Competidor mejor posicionado',5),
    (N'Presupuesto cancelado',       6),
    (N'Sin respuesta del cliente',   7),
    (N'Requisitos de certificación', 8),
    (N'Otro',                        99);
GO

/* --- Alta de usuarios ------------------------------------------------
   Rellena el email real de Entra ID de cada comercial y ejecuta.
   Los códigos salen de crm_v.ErpComercial (activos con facturación).
   Dirección y admin no necesitan filas en core.UsuarioCartera.
   -------------------------------------------------------------------- */
/*
INSERT INTO core.Usuario (Email, Nombre, SalespersonCode, Rol) VALUES
    (N'???@jomipsa.es', N'Paco Marhuenda',            N'PMZ', N'comercial'),
    (N'???@jomipsa.es', N'Christelle Gasnier',        N'CGA', N'comercial'),
    (N'???@jomipsa.es', N'Dan Losada Lopez',          N'DLL', N'comercial'),
    (N'???@jomipsa.es', N'Miguel Pascual de Bonanza', N'MPB', N'kam'),
    (N'???@jomipsa.es', N'Ana Garcia Hernandez',      N'AGH', N'comercial'),
    (N'???@jomipsa.es', N'Julian Sanchez',            N'JSF', N'comercial'),
    (N'???@jomipsa.es', N'David Pascual',             N'DPB', N'direccion'),
    (N'rfuentes@jomipsa.es', N'Rodrigo Fuentes',      NULL,   N'admin');

-- Cada comercial ve su propio código:
INSERT INTO core.UsuarioCartera (UsuarioId, SalespersonCode)
SELECT UsuarioId, SalespersonCode FROM core.Usuario
WHERE SalespersonCode IS NOT NULL AND Rol IN (N'comercial', N'kam');
*/
GO
